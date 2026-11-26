#if ZX_DASHBOARD_SPRINGBOARD_SERVER
#import "../../pccontrol/RemoteDashboardServer.h"
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#else
#import "RemoteDashboardServer.h"
#endif

#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <notify.h>

#import "Config.h"
#if ZX_DASHBOARD_SPRINGBOARD_SERVER
#import "../../pccontrol/PaddleOCRBridge.h"
#endif
#if !ZX_DASHBOARD_SPRINGBOARD_SERVER
#import "Socket.h"
#endif
#import "GCDWebServer.h"
#import "RuntimeLogs.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerMultiPartFormRequest.h"

static NSString *const ZXDashboardConfigPath = @"/var/mobile/Library/ZXTouch/config/tweak/remote_dashboard.plist";
static NSString *const ZXDashboardEnabledKey = @"enabled";
static NSString *const ZXDashboardTokenKey = @"token";
static const char *ZXDashboardConfigurationNotification = "com.zjx.zxtouch.remote-dashboard-changed";
static const unsigned long long ZXDashboardMaximumAssetSize = 25ULL * 1024ULL * 1024ULL;
static const NSUInteger ZXDashboardMaximumLogLength = 256 * 1024;

static NSString *ZXDashboardIPAddress(void)
{
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) != 0) return nil;

    for (struct ifaddrs *entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:entry->ifa_name];
        if (![name isEqualToString:@"en0"] && ![name isEqualToString:@"en1"]) continue;

        char host[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *ipv4 = (struct sockaddr_in *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, host, sizeof(host))) {
            address = [NSString stringWithUTF8String:host];
            break;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

#if ZX_DASHBOARD_SPRINGBOARD_SERVER

@interface ZXRemoteDashboardServer : NSObject
@property(nonatomic, strong) GCDWebServer *server;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSString *lastAction;
- (NSString *)sendTapAtPhysicalX:(int)x y:(int)y minDelay:(uint32_t)minDelay maxDelay:(uint32_t)maxDelay;
- (NSString *)sendSocketCommand:(NSString *)command expectsReply:(BOOL)expectsReply;
- (NSData *)framedSocketCommand:(NSString *)command mime:(NSString *)mime error:(NSString **)error;
@end

@implementation ZXRemoteDashboardServer

- (instancetype)initWithToken:(NSString *)token
{
    self = [super init];
    if (self) {
        _token = [token copy];
        _lastAction = @"就绪";
    }
    return self;
}

- (BOOL)requestIsAuthorized:(GCDWebServerRequest *)request
{
    return [request.query[@"token"] isEqualToString:self.token];
}

- (GCDWebServerDataResponse *)jsonResponse:(NSDictionary *)payload status:(NSInteger)status
{
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:payload];
    response.statusCode = status;
    return response;
}

- (GCDWebServerDataResponse *)unauthorizedResponse
{
    return [self jsonResponse:@{ @"ok": @NO, @"error": @"配对令牌无效。" } status:403];
}

- (NSString *)bundlePathForRelativePath:(NSString *)relativePath
{
    if (![relativePath isKindOfClass:[NSString class]] || ![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) {
        return nil;
    }

    NSString *root = [[SCRIPTS_PATH stringByStandardizingPath] stringByResolvingSymlinksInPath];
    NSString *candidate = [[[root stringByAppendingPathComponent:relativePath] stringByStandardizingPath] stringByResolvingSymlinksInPath];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    BOOL isDirectory = NO;
    if (![candidate hasPrefix:rootPrefix] || ![[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) {
        return nil;
    }
    return candidate;
}

- (NSArray<NSDictionary *> *)scripts
{
    NSMutableArray<NSDictionary *> *scripts = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:SCRIPTS_PATH];
    NSString *relativePath = nil;

    while ((relativePath = [enumerator nextObject])) {
        if (![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) continue;
        NSString *bundlePath = [SCRIPTS_PATH stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) continue;

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
        NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : @"";
        [scripts addObject:@{
            @"path": relativePath,
            @"name": relativePath.lastPathComponent.stringByDeletingPathExtension,
            @"entry": entry,
            @"type": entry.pathExtension.lowercaseString ?: @""
        }];
        [enumerator skipDescendants];
    }
    return [scripts sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
}

- (NSString *)sendSocketCommand:(NSString *)command expectsReply:(BOOL)expectsReply
{
    int socketHandle = socket(AF_INET, SOCK_STREAM, 0);
    if (socketHandle < 0) {
        self.lastError = @"创建 ZXTouch 本机连接失败。";
        return @"-1;;ZXTouch 服务不可用。";
    }
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(6000);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    struct timeval timeout = {2, 0};
    setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketHandle, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(socketHandle, (struct sockaddr *)&address, sizeof(address)) != 0) {
        self.lastError = @"连接 ZXTouch 本机服务失败。";
        close(socketHandle);
        return @"-1;;ZXTouch 服务不可用。";
    }
    NSString *framedCommand = [command stringByAppendingString:@"\r\n"];
    const char *message = framedCommand.UTF8String;
    if (send(socketHandle, message, strlen(message), 0) < 0) {
        self.lastError = @"向 ZXTouch 本机服务发送命令失败。";
        close(socketHandle);
        return @"-1;;ZXTouch 服务不可用。";
    }
    NSMutableData *responseData = [NSMutableData data];
    char chunk[4096];
    while (responseData.length < 1024 * 1024) {
        ssize_t received = recv(socketHandle, chunk, sizeof(chunk), 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) break;
        [responseData appendBytes:chunk length:(NSUInteger)received];
        const UInt8 *bytes = responseData.bytes;
        if (responseData.length >= 2 && bytes[responseData.length - 2] == '\r' && bytes[responseData.length - 1] == '\n') break;
    }
    close(socketHandle);
    NSString *result = expectsReply ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"0";
    if (result.length == 0 || [result hasPrefix:@"-1"]) {
        self.lastError = result.length ? result : @"ZXTouch 本机服务没有响应。";
    } else {
        self.lastError = @"";
    }
    return result ?: @"";
}

- (NSString *)sendTapAtPhysicalX:(int)x y:(int)y minDelay:(uint32_t)minDelay maxDelay:(uint32_t)maxDelay
{
    int socketHandle = socket(AF_INET, SOCK_STREAM, 0);
    if (socketHandle < 0) { self.lastError = @"创建 ZXTouch 本机连接失败。"; return @"-1"; }
    struct sockaddr_in address; memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET; address.sin_port = htons(6000); inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    struct timeval timeout = {2, 0};
    setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketHandle, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(socketHandle, (struct sockaddr *)&address, sizeof(address)) != 0) { close(socketHandle); self.lastError = @"连接 ZXTouch 本机服务失败。"; return @"-1"; }
    NSString *down = [NSString stringWithFormat:@"101101%05d%05d\r\n", x, y];
    NSString *up = [NSString stringWithFormat:@"101001%05d%05d\r\n", x, y];
    BOOL sent = send(socketHandle, down.UTF8String, [down lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 0) >= 0;
    uint32_t delay = minDelay;
    if (sent && maxDelay > minDelay) delay += arc4random_uniform(maxDelay - minDelay + 1);
    if (sent && delay) usleep(delay * 1000);
    if (sent) sent = send(socketHandle, up.UTF8String, [up lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 0) >= 0;
    close(socketHandle);
    if (!sent) { self.lastError = @"触摸指令未发送。"; return @"-1"; }
    self.lastError = @"";
    return @"0";
}

- (NSData *)framedSocketCommand:(NSString *)command mime:(NSString *)mime error:(NSString **)error
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (error) *error = @"创建本机连接失败"; return nil; }
    struct timeval timeout = {45, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(6000);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        if (error) *error = @"ZXTouch 服务未连接";
        return nil;
    }
    NSData *request = [[command stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *bytes = request.bytes;
    NSUInteger sent = 0;
    while (sent < request.length) {
        ssize_t written = send(fd, bytes + sent, request.length - sent, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { close(fd); if (error) *error = @"发送查询失败"; return nil; }
        sent += (NSUInteger)written;
    }
    NSMutableData *header = [NSMutableData data];
    char c = 0;
    while (header.length < 65536) {
        ssize_t received = recv(fd, &c, 1, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received != 1) break;
        [header appendBytes:&c length:1];
        const char *chars = header.bytes;
        if (header.length >= 2 && chars[header.length - 2] == '\r' && chars[header.length - 1] == '\n') break;
    }
    NSString *line = [[NSString alloc] initWithData:header encoding:NSUTF8StringEncoding];
    if (![line hasSuffix:@"\r\n"]) { close(fd); if (error) *error = @"响应头不完整"; return nil; }
    NSArray *parts = [[line substringToIndex:line.length - 2] componentsSeparatedByString:@";;"];
    if (parts.count != 3 || ![parts[0] isEqualToString:@"0"] || ![parts[1] isEqualToString:mime]) {
        close(fd);
        if (error) *error = parts.count > 1 ? parts[1] : @"响应类型错误";
        return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:parts[2]];
    long long size = 0;
    if (![scanner scanLongLong:&size] || !scanner.isAtEnd || size <= 0 || size > 16 * 1024 * 1024) {
        close(fd);
        if (error) *error = @"响应长度错误";
        return nil;
    }
    NSMutableData *body = [NSMutableData dataWithLength:(NSUInteger)size];
    NSUInteger offset = 0;
    while (offset < (NSUInteger)size) {
        ssize_t received = recv(fd, (char *)body.mutableBytes + offset, (NSUInteger)size - offset, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) { close(fd); if (error) *error = @"响应内容不完整"; return nil; }
        offset += (NSUInteger)received;
    }
    close(fd);
    return body;
}

- (NSString *)payloadFromSocketReply:(NSString *)reply
{
    NSString *trimmed = [reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed hasPrefix:@"0;;"] ? [trimmed substringFromIndex:3] : trimmed;
}

- (NSDictionary *)status
{
    NSString *rawSize = [self sendSocketCommand:@"251" expectsReply:YES];
    NSString *rawOrientation = [self sendSocketCommand:@"252" expectsReply:YES];
    NSString *rawBattery = [self sendSocketCommand:@"2531" expectsReply:YES];
    NSString *rawRuntime = [self sendSocketCommand:@"2532" expectsReply:YES];
    NSString *size = [self payloadFromSocketReply:rawSize];
    NSString *orientation = [self payloadFromSocketReply:rawOrientation];
    NSString *battery = [self payloadFromSocketReply:rawBattery];
    NSString *runtime = [self payloadFromSocketReply:rawRuntime];
    NSArray *sizeParts = [size componentsSeparatedByString:@";;"];
    NSArray *batteryParts = [battery componentsSeparatedByString:@";;"];
    NSArray *runtimeParts = [runtime componentsSeparatedByString:@";;"];
    __block CGFloat screenScale = 1;
    void (^readScale)(void) = ^{ screenScale = [UIScreen mainScreen].scale; };
    if ([NSThread isMainThread]) readScale();
    else dispatch_sync(dispatch_get_main_queue(), readScale);
    return @{
        @"running": @(self.server.running),
        @"serviceOnline": @([rawSize hasPrefix:@"0"]),
        @"port": @(self.server.port),
        @"screen": @{ @"width": sizeParts.count > 0 ? sizeParts[0] : @"", @"height": sizeParts.count > 1 ? sizeParts[1] : @"" },
        @"screenScale": @(screenScale),
        @"orientation": orientation ?: @"",
        @"battery": batteryParts.count > 1 ? batteryParts[1] : @"",
        @"foregroundApp": runtimeParts.count > 0 ? runtimeParts[0] : @"",
        @"scriptPlaying": runtimeParts.count > 1 ? @([runtimeParts[1] boolValue]) : @NO,
        @"recording": runtimeParts.count > 2 ? @([runtimeParts[2] boolValue]) : @NO,
        @"lastAction": self.lastAction ?: @"就绪",
        @"lastError": self.lastError ?: @"",
        @"scriptCount": @([self scripts].count)
    };
}

- (NSString *)recentLogs
{
    NSString *logs = ZXReadRuntimeLogs(ZXDashboardMaximumLogLength);
    if (logs.length <= ZXDashboardMaximumLogLength) return logs;
    return [@"[仅显示最新日志。]\n" stringByAppendingString:[logs substringFromIndex:logs.length - ZXDashboardMaximumLogLength]];
}

- (BOOL)isSafeAssetFileName:(NSString *)fileName
{
    if (fileName.length == 0 || [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."] ||
        [fileName rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location != NSNotFound) {
        return NO;
    }
    return [fileName caseInsensitiveCompare:@"info.plist"] != NSOrderedSame;
}

- (NSString *)dashboardHTML
{
    NSString *path = @"/var/jb/Applications/zxtouch.app/index.html";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = nil;
    NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    return html ?: @"<h1>IOS-SFP 控制台暂不可用。</h1>";
}

- (void)configureHandlers
{
    __weak typeof(self) weakSelf = self;

    [self.server addHandlerForMethod:@"GET" path:@"/" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [GCDWebServerDataResponse responseWithHTML:[strongSelf dashboardHTML]];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/scripts" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"scripts": [strongSelf scripts] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"status": [strongSelf status] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/logs" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"logs": [strongSelf recentLogs] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/logs/clear" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSError *error = nil;
        if (!ZXClearRuntimeLogs(&error)) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"清空日志失败。" } status:500];
        strongSelf.lastAction = @"清空日志";
        return [strongSelf jsonResponse:@{ @"ok": @YES } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/run" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:body[@"path"]];
        if (!bundlePath) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"找不到脚本。" } status:404];
        NSString *result = [strongSelf sendSocketCommand:[@"19" stringByAppendingString:bundlePath] expectsReply:YES];
        strongSelf.lastAction = [NSString stringWithFormat:@"运行 %@", bundlePath.lastPathComponent];
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"20" expectsReply:YES];
        strongSelf.lastAction = @"停止脚本";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/start" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"14" expectsReply:YES];
        strongSelf.lastAction = @"开始录制";
        return [strongSelf jsonResponse:@{ @"ok": @(![result hasPrefix:@"-1"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"15" expectsReply:YES];
        strongSelf.lastAction = @"停止录制";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/assets" requestClass:[GCDWebServerMultiPartFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerMultiPartFormRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *relativePath = [[request firstArgumentForControlName:@"script"] string];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:relativePath];
        GCDWebServerMultiPartFile *upload = [request firstFileForControlName:@"asset"];
        NSString *fileName = upload.fileName.lastPathComponent;
        NSDictionary *attributes = upload.temporaryPath.length ? [[NSFileManager defaultManager] attributesOfItemAtPath:upload.temporaryPath error:nil] : nil;
        unsigned long long size = [attributes fileSize];
        if (!bundlePath || upload == nil || ![strongSelf isSafeAssetFileName:fileName]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"请选择脚本和素材文件。" } status:400];
        }
        if (size > ZXDashboardMaximumAssetSize) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"素材文件不得超过 25 MB。" } status:413];
        }
        NSString *destination = [bundlePath stringByAppendingPathComponent:fileName];
        [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
        NSError *error = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:upload.temporaryPath toPath:destination error:&error];
        if (!copied) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"保存素材文件失败。" } status:500];
        strongSelf.lastAction = [NSString stringWithFormat:@"上传 %@", fileName];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"file": fileName } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/download" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:request.query[@"path"]];
        NSString *entry = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]][@"Entry"];
        NSString *entryPath = entry.length ? [bundlePath stringByAppendingPathComponent:entry] : nil;
        if (!entryPath || ![[NSFileManager defaultManager] fileExistsAtPath:entryPath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"找不到脚本入口文件。" } status:404];
        }
        return [GCDWebServerFileResponse responseWithFile:entryPath isAttachment:YES];
    }];

#import "DashboardTools.inc"
}

- (BOOL)start
{
    if (self.server.running) return YES;
    self.server = [[GCDWebServer alloc] init];
    [self configureHandlers];
    NSError *error = nil;
    BOOL started = [self.server startWithOptions:@{
        GCDWebServerOption_Port: @8080,
        GCDWebServerOption_ServerName: @"ZXTouch Dashboard",
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO
    } error:&error];
    self.lastError = started ? @"" : (error.localizedDescription ?: @"控制台启动失败。");
    if (!started) self.server = nil;
    return started;
}

- (void)stop
{
    [self.server stop];
    self.server = nil;
}

@end

static ZXRemoteDashboardServer *ZXDashboardServer;

void ZXDashboardReloadConfiguration(void)
{
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:ZXDashboardConfigPath];
    if (![configuration isKindOfClass:[NSDictionary class]]) {
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.zjx.zxtouch.plist"];
        NSMutableDictionary *migrated = [NSMutableDictionary dictionary];
        id legacyEnabled = legacy[@"zxtouch_remote_dashboard_enabled"];
        NSString *legacyToken = [legacy[@"zxtouch_remote_dashboard_token"] isKindOfClass:[NSString class]] ? legacy[@"zxtouch_remote_dashboard_token"] : @"";
        if (legacyEnabled) migrated[ZXDashboardEnabledKey] = legacyEnabled;
        if (legacyToken.length) migrated[ZXDashboardTokenKey] = legacyToken;
        if (migrated.count) [migrated writeToFile:ZXDashboardConfigPath atomically:YES];
        configuration = migrated;
    }
    BOOL enabled = [configuration[ZXDashboardEnabledKey] boolValue];
    NSString *token = [configuration[ZXDashboardTokenKey] isKindOfClass:[NSString class]] ? configuration[ZXDashboardTokenKey] : @"";
    if (!enabled || token.length == 0) {
        [ZXDashboardServer stop];
        ZXDashboardServer = nil;
        return;
    }
    if (ZXDashboardServer && ![ZXDashboardServer.token isEqualToString:token]) {
        [ZXDashboardServer stop];
        ZXDashboardServer = nil;
    }
    if (!ZXDashboardServer) ZXDashboardServer = [[ZXRemoteDashboardServer alloc] initWithToken:token];
    [ZXDashboardServer start];
}

#else

static NSString *ZXDashboardSettingsLastError = @"";

static NSMutableDictionary *ZXDashboardConfiguration(void)
{
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ZXDashboardConfigPath];
    if ([stored isKindOfClass:[NSDictionary class]]) return [stored mutableCopy];

    NSMutableDictionary *configuration = [NSMutableDictionary dictionary];
    NSUserDefaults *legacyDefaults = [NSUserDefaults standardUserDefaults];
    id legacyEnabled = [legacyDefaults objectForKey:@"zxtouch_remote_dashboard_enabled"];
    NSString *legacyToken = [legacyDefaults stringForKey:@"zxtouch_remote_dashboard_token"];
    if (legacyEnabled) configuration[ZXDashboardEnabledKey] = legacyEnabled;
    if (legacyToken.length) configuration[ZXDashboardTokenKey] = legacyToken;
    return configuration;
}

static NSString *ZXDashboardToken(NSMutableDictionary *configuration)
{
    NSString *token = [configuration[ZXDashboardTokenKey] isKindOfClass:[NSString class]] ? configuration[ZXDashboardTokenKey] : @"";
    if (token.length == 0) {
        token = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        configuration[ZXDashboardTokenKey] = token;
    }
    return token;
}

BOOL ZXRemoteDashboardSetEnabled(BOOL enabled)
{
    NSMutableDictionary *configuration = ZXDashboardConfiguration();
    ZXDashboardToken(configuration);
    configuration[ZXDashboardEnabledKey] = @(enabled);
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[ZXDashboardConfigPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&directoryError];
    BOOL saved = directoryError == nil && [configuration writeToFile:ZXDashboardConfigPath atomically:YES];
    ZXDashboardSettingsLastError = saved ? @"" : (directoryError.localizedDescription ?: @"保存远程控制台设置失败。");
    if (saved) notify_post(ZXDashboardConfigurationNotification);
    return saved;
}

BOOL ZXRemoteDashboardIsEnabled(void)
{
    return [ZXDashboardConfiguration()[ZXDashboardEnabledKey] boolValue];
}

NSString *ZXRemoteDashboardURL(void)
{
    NSMutableDictionary *configuration = ZXDashboardConfiguration();
    NSString *token = ZXDashboardToken(configuration);
    NSString *host = ZXDashboardIPAddress() ?: @"iPad-IP-address";
    return [NSString stringWithFormat:@"http://%@:%d/?token=%@", host, 8080, token];
}

NSString *ZXRemoteDashboardLastError(void)
{
    return ZXDashboardSettingsLastError ?: @"";
}

#endif
