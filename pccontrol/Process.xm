#include "Process.h"
#include "Common.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>

@interface NSObject (ZXApplicationLookup)
+ (id)defaultWorkspace;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
+ (id)sharedInstance;
+ (id)sharedService;
- (id)applicationWithBundleIdentifier:(NSString *)identifier;
- (NSString *)bundleIdentifier;
- (NSArray *)runningApplications;
- (NSArray *)allApplications;
- (BOOL)isRunning;
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
    id proxy = [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)] ?
        [proxyClass applicationProxyForIdentifier:bundleID] : nil;
    if (proxy && [proxy respondsToSelector:@selector(applicationIdentifier)] &&
        [[proxy applicationIdentifier] isEqualToString:bundleID]) return proxy;
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)] ?
        [workspaceClass defaultWorkspace] : nil;
    NSArray *installed = [workspace respondsToSelector:@selector(allInstalledApplications)] ?
        [workspace allInstalledApplications] : nil;
    for (id candidate in installed) {
        if ([candidate respondsToSelector:@selector(applicationIdentifier)] &&
            [[candidate applicationIdentifier] isEqualToString:bundleID]) return candidate;
    }
    return nil;
}

static NSString *zxExecutablePath(id proxy) {
    NSURL *bundle = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;
    if (!bundle.isFileURL) return nil;
    NSString *executable = [proxy respondsToSelector:@selector(bundleExecutable)] ? [proxy bundleExecutable] : nil;
    if (!executable.length) executable = [NSDictionary dictionaryWithContentsOfURL:
        [bundle URLByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    if (![executable isKindOfClass:NSString.class] || !executable.length ||
        ![executable.lastPathComponent isEqualToString:executable]) return nil;
    return [bundle.path stringByAppendingPathComponent:executable];
}

static NSString *zxSpringBoardBundleID(id app) {
    if ([app respondsToSelector:@selector(bundleIdentifier)]) return [app bundleIdentifier];
    if ([app respondsToSelector:@selector(applicationIdentifier)]) return [app applicationIdentifier];
    return nil;
}

static NSNumber *zxRunningState(NSString *bundleID) {
    __block NSNumber *running = nil;
    void (^readState)(void) = ^{
        Class controllerClass = objc_getClass("SBApplicationController");
        id controller = [controllerClass respondsToSelector:@selector(sharedInstance)] ?
            [controllerClass sharedInstance] : nil;
        if ([controller respondsToSelector:@selector(runningApplications)]) {
            NSArray *apps = [controller runningApplications];
            if ([apps isKindOfClass:NSArray.class]) {
                BOOL found = NO;
                for (id app in apps) {
                    if ([zxSpringBoardBundleID(app) isEqualToString:bundleID]) {
                        found = YES;
                        break;
                    }
                }
                running = @(found);
                return;
            }
        }
        if ([controller respondsToSelector:@selector(allApplications)]) {
            NSArray *apps = [controller allApplications];
            if ([apps isKindOfClass:NSArray.class]) {
                for (id app in apps) {
                    if ([zxSpringBoardBundleID(app) isEqualToString:bundleID] &&
                        [app respondsToSelector:@selector(isRunning)]) {
                        running = @([app isRunning]);
                        return;
                    }
                }
            }
        }
        id app = [controller respondsToSelector:@selector(applicationWithBundleIdentifier:)] ?
            [controller applicationWithBundleIdentifier:bundleID] : nil;
        if ([app respondsToSelector:@selector(isRunning)]) running = @([app isRunning]);
    };
    if ([NSThread isMainThread]) readState();
    else dispatch_sync(dispatch_get_main_queue(), readState);
    return running;
}

static BOOL zxRequestTermination(NSString *bundleID, NSError **error) {
    __block BOOL requested = NO;
    __block NSString *failure = nil;
    void (^terminate)(void) = ^{
        @try {
            Class serviceClass = objc_getClass("FBSSystemService");
            id service = [serviceClass respondsToSelector:@selector(sharedService)] ?
                [serviceClass sharedService] : nil;
            SEL selector = @selector(terminateApplication:forReason:andReport:withDescription:);
            NSMethodSignature *signature = [service methodSignatureForSelector:selector];
            if (!signature || signature.numberOfArguments != 6) {
                failure = @"FrontBoard termination service unavailable";
                return;
            }
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = service;
            invocation.selector = selector;
            NSString *identifier = bundleID;
            int reason = 1;
            BOOL report = NO;
            NSString *description = @"Terminated via ZXTouch";
            [invocation setArgument:&identifier atIndex:2];
            [invocation setArgument:&reason atIndex:3];
            [invocation setArgument:&report atIndex:4];
            [invocation setArgument:&description atIndex:5];
            [invocation invoke];
            requested = YES;
        } @catch (NSException *exception) {
            failure = exception.reason ?: @"FrontBoard termination failed";
        }
    };
    if ([NSThread isMainThread]) terminate();
    else dispatch_sync(dispatch_get_main_queue(), terminate);
    if (!requested && error) *error = zxProcessError(failure ?: @"FrontBoard termination failed");
    return requested;
}

NSArray *zxInstalledApplications(void) {
    __block NSArray *result = nil;
    void (^collect)(void) = ^{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)] ?
        [workspaceClass defaultWorkspace] : nil;
    NSArray *proxies = [workspace respondsToSelector:@selector(allInstalledApplications)] ?
        [workspace allInstalledApplications] : nil;
    if (![proxies isKindOfClass:NSArray.class]) return;
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)] ?
            [proxy applicationIdentifier] : nil;
        if (![identifier isKindOfClass:NSString.class] || !identifier.length || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
        NSString *type = [proxy respondsToSelector:@selector(applicationType)] ? [proxy applicationType] : nil;
        if (![name isKindOfClass:NSString.class]) name = @"";
        if (![type isKindOfClass:NSString.class]) type = @"";
        NSURL *bundle = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;
        if ([type isEqualToString:@"User"] || [bundle.path containsString:@"/Containers/Bundle/Application/"] ||
            ![identifier hasPrefix:@"com.apple."]) type = @"User";
        else if ([type isEqualToString:@"Internal"] || !type.length) type = @"System";
        [apps addObject:@{@"bundleId": identifier, @"name": name, @"type": type}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"bundleId"] compare:b[@"bundleId"]];
    }];
    result = [apps copy];
    };
    if ([NSThread isMainThread]) collect();
    else dispatch_sync(dispatch_get_main_queue(), collect);
    return result;
}

NSInteger zxTerminateApplication(NSString *bundleID, NSError **error) {
    if (!zxApplicationProxy(bundleID)) {
        if (error) *error = zxProcessError(@"Bundle ID is not an installed application");
        return -1;
    }
    NSNumber *state = zxRunningState(bundleID);
    if (state && !state.boolValue) return 0;
    if (!zxRequestTermination(bundleID, error)) return -1;
    if (!state) return 1;
    for (int attempt = 0; attempt < 50; ++attempt) {
        usleep(100000);
        state = zxRunningState(bundleID);
        if (!state) return 1;
        if (!state.boolValue) return 1;
    }
    if (error) *error = zxProcessError(@"Application did not exit after termination request");
    return -1;
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
    NSNumber *state = zxRunningState(bundleID);
    if (!state || state.boolValue) {
        if (error) *error = zxProcessError(@"Application still running; data not cleared");
        return nil;
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
    if ([identifier isEqualToString:@"com.apple.springboard"]) return @"SpringBoard";
    if (!identifier.length) return nil;
    NSString *path = zxExecutablePath(zxApplicationProxy(identifier));
    return path.lastPathComponent.length ? path.lastPathComponent : nil;
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