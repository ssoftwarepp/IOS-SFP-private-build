#include "Process.h"
#include "Common.h"
#import <UIKit/UIKit.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>

@interface NSObject (ZXApplicationLookup)
+ (id)defaultWorkspace;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSArray *)allInstalledApplications;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (NSString *)bundleExecutable;
- (NSNumber *)processIdentifier;
+ (id)containerWithIdentifier:(NSString *)identifier createIfNecessary:(BOOL)create existed:(BOOL *)existed error:(NSError **)error;
- (NSURL *)url;
@end

static NSError *zxProcessError(NSString *message) {
    return [NSError errorWithDomain:@"ZXTouchApplication" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id zxApplicationProxy(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    return [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)] ?
        [proxyClass applicationProxyForIdentifier:bundleID] : nil;
}

static NSString *zxExecutablePath(id proxy) {
    NSURL *bundle = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;
    if (!bundle.isFileURL) return nil;
    NSString *executable = [proxy respondsToSelector:@selector(bundleExecutable)] ? [proxy bundleExecutable] : nil;
    if (!executable.length) executable = [NSDictionary dictionaryWithContentsOfURL:
        [bundle URLByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    if (![executable isKindOfClass:NSString.class] || !executable.length ||
        ![executable.lastPathComponent isEqualToString:executable]) return nil;
    return [[bundle.path stringByAppendingPathComponent:executable] stringByResolvingSymlinksInPath];
}

typedef int (*ZXListPIDs)(uint32_t, uint32_t, void *, int);
typedef int (*ZXPIDPath)(int, void *, uint32_t);

static BOOL zxProcessFunctions(ZXListPIDs *list, ZXPIDPath *path) {
    static void *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY); });
    *list = library ? (ZXListPIDs)dlsym(library, "proc_listpids") : NULL;
    *path = library ? (ZXPIDPath)dlsym(library, "proc_pidpath") : NULL;
    return *list && *path;
}

static NSArray<NSNumber *> *zxPIDsForExecutable(NSString *target, NSError **error) {
    ZXListPIDs list = NULL;
    ZXPIDPath path = NULL;
    if (!zxProcessFunctions(&list, &path)) {
        if (error) *error = zxProcessError(@"Process enumeration unavailable");
        return nil;
    }
    int bytes = list(1, 0, NULL, 0);
    if (bytes <= 0) {
        if (error) *error = zxProcessError(@"Unable to list processes");
        return nil;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)bytes + 1024 * sizeof(pid_t)];
    int used = list(1, 0, buffer.mutableBytes, (int)buffer.length);
    if (used <= 0) {
        if (error) *error = zxProcessError(@"Unable to list processes");
        return nil;
    }
    NSMutableArray *matches = [NSMutableArray array];
    pid_t *pids = buffer.mutableBytes;
    for (int i = 0; i < used / (int)sizeof(pid_t); ++i) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == getpid()) continue;
        char raw[4096] = {0};
        if (path(pid, raw, sizeof(raw)) <= 0) continue;
        NSString *actual = [[NSString stringWithUTF8String:raw] stringByResolvingSymlinksInPath];
        if ([actual isEqualToString:target]) [matches addObject:@(pid)];
    }
    return matches;
}

NSArray *zxInstalledApplications(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)] ?
        [workspaceClass defaultWorkspace] : nil;
    NSArray *proxies = [workspace respondsToSelector:@selector(allInstalledApplications)] ?
        [workspace allInstalledApplications] : nil;
    if (![proxies isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)] ?
            [proxy applicationIdentifier] : nil;
        if (![identifier isKindOfClass:NSString.class] || !identifier.length || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
        NSString *type = [proxy respondsToSelector:@selector(applicationType)] ? [proxy applicationType] : nil;
        [apps addObject:@{@"bundleId": identifier, @"name": name ?: @"", @"type": type ?: @""}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"bundleId"] compare:b[@"bundleId"]];
    }];
    return apps;
}

NSInteger zxTerminateApplication(NSString *bundleID, NSError **error) {
    id proxy = zxApplicationProxy(bundleID);
    NSString *target = zxExecutablePath(proxy);
    if (!target.length) {
        if (error) *error = zxProcessError(@"Bundle ID is not an installed application or has no executable");
        return -1;
    }
    NSArray<NSNumber *> *matches = zxPIDsForExecutable(target, error);
    if (!matches) return -1;
    ZXPIDPath pidPath = NULL;
    ZXListPIDs list = NULL;
    zxProcessFunctions(&list, &pidPath);
    NSInteger terminated = 0;
    for (NSNumber *entry in matches) {
        pid_t pid = entry.intValue;
        char raw[4096] = {0};
        if (pidPath(pid, raw, sizeof(raw)) <= 0 ||
            ![[[NSString stringWithUTF8String:raw] stringByResolvingSymlinksInPath] isEqualToString:target]) continue;
        if (kill(pid, SIGTERM) == 0) ++terminated;
        else if (errno != ESRCH) {
            if (error) *error = zxProcessError([NSString stringWithFormat:@"SIGTERM failed: %d", errno]);
            return -1;
        }
    }
    return terminated;
}

NSDictionary *zxClearApplicationData(NSString *bundleID, NSError **error) {
    id proxy = zxApplicationProxy(bundleID);
    if (!proxy || !zxExecutablePath(proxy).length) {
        if (error) *error = zxProcessError(@"Bundle ID is not an installed application");
        return nil;
    }
    NSURL *container = [proxy respondsToSelector:@selector(dataContainerURL)] ? [proxy dataContainerURL] : nil;
    if (!container.isFileURL) {
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_LAZY);
        Class dataClass = NSClassFromString(@"MCMAppDataContainer");
        BOOL existed = NO;
        id dataContainer = [dataClass respondsToSelector:@selector(containerWithIdentifier:createIfNecessary:existed:error:)] ?
            [dataClass containerWithIdentifier:bundleID createIfNecessary:NO existed:&existed error:error] : nil;
        container = [dataContainer respondsToSelector:@selector(url)] ? [dataContainer url] : nil;
    }
    if (!container.isFileURL) {
        if (error && !*error) *error = zxProcessError(@"App data container unavailable");
        return nil;
    }
    BOOL directory = NO;
    NSString *path = [[container.path stringByResolvingSymlinksInPath] stringByStandardizingPath];
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (!container.isFileURL ||
        !([parent isEqualToString:@"/var/mobile/Containers/Data/Application"] ||
          [parent isEqualToString:@"/private/var/mobile/Containers/Data/Application"]) ||
        ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory] || !directory) {
        if (error) *error = zxProcessError(@"App data container unavailable");
        return nil;
    }
    NSInteger count = zxTerminateApplication(bundleID, error);
    if (count < 0) return nil;
    NSString *executable = zxExecutablePath(proxy);
    for (int attempt = 0; attempt < 40; ++attempt) {
        NSArray *running = zxPIDsForExecutable(executable, error);
        if (!running) return nil;
        if (!running.count) break;
        if (attempt == 39) {
            if (error) *error = zxProcessError(@"Application did not exit");
            return nil;
        }
        usleep(100000);
    }
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:error];
    if (!contents) return nil;
    NSUInteger removed = 0;
    for (NSString *child in contents) {
        if ([child hasPrefix:@".com.apple.mobile_container_manager."]) continue;
        if (![[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingPathComponent:child] error:error]) return nil;
        ++removed;
    }
    return @{@"bundleId": bundleID, @"removedEntries": @(removed)};
}

NSString *zxForegroundProcessName(void) {
    id app = getFrontMostApplication();
    NSString *identifier = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
    if (!identifier.length || [identifier isEqualToString:@"com.apple.springboard"]) return @"SpringBoard";
    id proxy = zxApplicationProxy(identifier);
    NSString *path = zxExecutablePath(proxy);
    if (!path.length) return nil;
    NSError *error = nil;
    NSArray *running = zxPIDsForExecutable(path, &error);
    return running.count ? path.lastPathComponent : nil;
}

int (*openApp)(CFStringRef, Boolean);

static void* sbServices = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);

int switchProcessForegroundFromRawData(UInt8 *eventData)
{
    return bringAppForeground([NSString stringWithFormat:@"%s", eventData]);
}

int bringAppForeground(NSString *appIdentifier)
{
    CFStringRef appBundleName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), appIdentifier);
    //[NSString stringWithFormat:@"%s", eventData];
    NSLog(@"### com.zjx.springboard: Switch to application: %@", appBundleName);
    if (!openApp)
        openApp = (int(*)(CFStringRef, Boolean))dlsym(sbServices,"SBSLaunchApplicationWithIdentifier");

    return openApp(appBundleName, false);
}

id getFrontMostApplication()
{
    //TODO: might cause problem here. Both _accessibilityFrontMostApplication failed or front most application springboard will cause app be nil.
    __block id app = nil;
    // This is reached both from the socket server (background thread) and from
    // the hotkey/panel handlers, which already run on the main queue. An
    // unconditional dispatch_sync to the main queue makes the main queue wait
    // on itself in the latter case, and libdispatch traps the process:
    //   "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already
    //    owned by current thread"
    // which took SpringBoard into safe mode every time recording was toggled
    // with the hotkey. Run the block inline when we are already on main.
    void (^fetchBlock)(void) = ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            app = [springboard _accessibilityFrontMostApplication];
            //NSLog(@"com.zjx.springboard: app: %@, id: %@", app, [app displayIdentifier]);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
        };

    if ([NSThread isMainThread])
    {
        fetchBlock();
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), fetchBlock);
    }
    return app;
}