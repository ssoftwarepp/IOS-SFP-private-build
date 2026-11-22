#import "PaddleOCRBridge.h"
#import <UIKit/UIKit.h>
#import <roothide.h>
#import "Common.h"
#import <sys/stat.h>
#import <math.h>
#import <errno.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>
#import <spawn.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *ZXOCRInstalledPath(NSString *suffix) {
    return [jbroot(suffix) copy];
}
static BOOL ZXOCRTransfer(int fd, void *buffer, size_t length, BOOL writing, CFAbsoluteTime deadline) {
    uint8_t *cursor = buffer;
    while (length) {
        NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) return NO;
        struct pollfd ready = {fd, writing ? POLLOUT : POLLIN, 0};
        int interval = (int)MIN(remaining * 1000, 1000);
        int result = poll(&ready, 1, interval);
        if (result < 0 && errno == EPERM && fd < FD_SETSIZE) {
            fd_set descriptors; FD_ZERO(&descriptors); FD_SET(fd, &descriptors);
            struct timeval wait = {interval / 1000, (interval % 1000) * 1000};
            result = select(fd + 1, writing ? NULL : &descriptors,
                            writing ? &descriptors : NULL, NULL, &wait);
        }
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0 || (ready.revents & (POLLERR | POLLNVAL))) {
            if (result == 0) continue;
            return NO;
        }
        ssize_t count = writing ? send(fd, cursor, length, MSG_DONTWAIT) : recv(fd, cursor, length, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

@implementation ZXPaddleOCRBridge {
    NSLock *_lock;
}
+ (instancetype)sharedBridge {
    static ZXPaddleOCRBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [self new]; });
    return bridge;
}
- (instancetype)init {
    if ((self = [super init])) _lock = [NSLock new];
    return self;
}
- (NSDictionary *)recognizePNG:(NSData *)png region:(NSArray<NSNumber *> *)region error:(NSString **)error {
    if (![_lock tryLock]) { if (error) *error = @"PaddleOCR 正忙"; return nil; }
    int pair[2] = {-1, -1}; pid_t pid = -1;
    @try {
        NSString *worker = ZXOCRInstalledPath(@"/usr/libexec/zxtouch/zxtouch-ocr-worker");
        NSString *resources = ZXOCRInstalledPath(@"/usr/share/zxtouch/paddleocr");
        if (!zxPathLooksExecutable(worker.fileSystemRepresentation)) {
            if (error) *error = @"PaddleOCR worker 未安装";
            return nil;
        }
        UIImage *image = [UIImage imageWithData:png];
        if (!image.CGImage || region.count != 4) {
            if (error) *error = @"OCR 截图或区域无效";
            return nil;
        }
        CGFloat width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
        if (!width || !height) { if (error) *error = @"OCR 图片尺寸无效"; return nil; }
        CGFloat x = region[0].doubleValue, y = region[1].doubleValue;
        CGFloat w = region[2].doubleValue, h = region[3].doubleValue;
        if (w <= 0 || h <= 0) { x = y = 0; w = width; h = height; }
        if (x < 0 || y < 0 || x + w > width || y + h > height) {
            if (error) *error = @"OCR 区域超出截图";
            return nil;
        }
        NSDictionary *payload = @{ @"image": [png base64EncodedStringWithOptions:0], @"orientation": @1,
                                   @"min_confidence": @0.3,
                                   @"roi": @[@(x / width), @(y / height), @(w / width), @(h / height)] };
        NSData *request = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!request || request.length > 32 * 1024 * 1024 || socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) {
            if (error) *error = @"OCR 请求过大或 IPC 建立失败";
            return nil;
        }
        for (int i = 0; i < 2; i++) {
            if (pair[i] < 3) {
                int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
                if (moved < 0) { if (error) *error = @"OCR IPC 描述符无效"; return nil; }
                close(pair[i]); pair[i] = moved;
            }
        }
        if (pair[0] < 0 || pair[1] < 0) { if (error) *error = @"OCR IPC 描述符无效"; return nil; }
        int noSignal = 1;
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        fcntl(pair[0], F_SETFD, FD_CLOEXEC);
        fcntl(pair[1], F_SETFD, FD_CLOEXEC);
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&actions, pair[0]);
        posix_spawn_file_actions_addclose(&actions, pair[1]);
        posix_spawnattr_t attributes;
        posix_spawnattr_init(&attributes);
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
        char *argv[] = {(char *)worker.fileSystemRepresentation, "--resources", (char *)resources.fileSystemRepresentation, NULL};
        char *env[] = {"PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", NULL};
        int launched = posix_spawn(&pid, worker.fileSystemRepresentation, &actions, &attributes, argv, env);
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        close(pair[1]); pair[1] = -1;
        if (launched) { pid = -1; if (error) *error = [NSString stringWithFormat:@"OCR worker 启动失败: %d", launched]; return nil; }
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 30;
        uint32_t length = htonl((uint32_t)request.length), responseLength = 0;
        BOOL ok = ZXOCRTransfer(pair[0], &length, 4, YES, deadline) &&
                  ZXOCRTransfer(pair[0], (void *)request.bytes, request.length, YES, deadline) &&
                  ZXOCRTransfer(pair[0], &responseLength, 4, NO, deadline);
        responseLength = ntohl(responseLength);
        if (!ok || !responseLength || responseLength > 1024 * 1024) {
            if (error) *error = @"OCR worker 超时或响应头无效";
            return nil;
        }
        NSMutableData *response = [NSMutableData dataWithLength:responseLength];
        if (!ZXOCRTransfer(pair[0], response.mutableBytes, responseLength, NO, deadline)) {
            if (error) *error = @"OCR worker 响应不完整";
            return nil;
        }
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
        if (![result isKindOfClass:NSDictionary.class] || ![result[@"texts"] isKindOfClass:NSArray.class]) {
            if (error) *error = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : @"OCR worker 响应无效";
            return nil;
        }
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *item in result[@"texts"]) {
            NSArray *box = item[@"box"];
            if (![box isKindOfClass:NSArray.class] || box.count != 4 || ![item[@"text"] isKindOfClass:NSString.class]) continue;
            [texts addObject:@{ @"text": item[@"text"], @"x": @((NSInteger)round([box[0] doubleValue] * width)),
                                @"y": @((NSInteger)round([box[1] doubleValue] * height)),
                                @"width": @((NSInteger)round([box[2] doubleValue] * width)),
                                @"height": @((NSInteger)round([box[3] doubleValue] * height)),
                                @"confidence": item[@"confidence"] ?: @0 }];
        }
        return @{ @"texts": texts, @"engine": @"paddleocr", @"provider": result[@"provider"] ?: @"CPUExecutionProvider" };
    } @finally {
        if (pair[0] >= 0) close(pair[0]);
        if (pair[1] >= 0) close(pair[1]);
        if (pid > 0) { kill(pid, SIGKILL); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} }
        [_lock unlock];
    }
}
@end
