#import "AccessibilityTree.h"
#import "Process.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>

@protocol ZXVisibleAXElement <NSObject>
+ (id)uiApplicationWithPid:(int)pid;
- (id)objectWithAXAttribute:(long)attribute;
- (NSArray *)uiElementsWithAttribute:(long)attribute;
@end

// iOS AXRuntime exports are resolved at runtime so the tweak does not link
// against an SDK that lacks private accessibility headers.
typedef CFTypeRef (*ZXCreateApplication)(pid_t);
typedef int32_t (*ZXCopyAttribute)(CFTypeRef, CFStringRef, CFTypeRef *);
typedef int32_t (*ZXSetTimeout)(CFTypeRef, float);
typedef CFTypeID (*ZXValueTypeID)(void);
typedef int32_t (*ZXValueType)(CFTypeRef);
typedef Boolean (*ZXValueGet)(CFTypeRef, int32_t, void *);
typedef pid_t (*ZXFocusedPID)(void);
typedef void (*ZXAssociatePID)(pid_t, pid_t, int);

typedef void (*ZXSetRequestingClient)(uint32_t);

static ZXSetRequestingClient zxSetRequestingClient = NULL;
static ZXCopyAttribute zxCopyAttribute = NULL;
static ZXValueTypeID zxValueTypeID = NULL;
static ZXValueType zxValueType = NULL;
static ZXValueGet zxValueGet = NULL;
static const NSUInteger zxMaxCandidates = 2000;
static const NSUInteger zxMaxTreeNodes = 2002;
static const NSUInteger zxMaxDepth = 16;

static NSString *zxString(CFTypeRef value)
{
    if (!value) return nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) return (__bridge NSString *)value;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) return [(__bridge NSNumber *)value stringValue];
    return nil;
}

static CFTypeRef zxAttribute(CFTypeRef element, CFStringRef key)
{
    CFTypeRef value = NULL;
    if (zxSetRequestingClient) zxSetRequestingClient(2);
    int32_t status = zxCopyAttribute(element, key, &value);
    if (status != 0) {
        if (value) CFRelease(value);
        return NULL;
    }
    return value;
}

static CFTypeRef zxNumericAttribute(CFTypeRef element, uint32_t attributeID)
{
    return zxAttribute(element, (CFStringRef)(uintptr_t)attributeID);
}

static NSString *zxNumericString(CFTypeRef element, uint32_t attributeID)
{
    CFTypeRef raw = zxNumericAttribute(element, attributeID);
    if (!raw) return nil;
    NSString *text = [zxString(raw) copy];
    CFRelease(raw);
    return text;
}

static NSNumber *zxNumericNumber(CFTypeRef element, uint32_t attributeID)
{
    CFTypeRef raw = zxNumericAttribute(element, attributeID);
    if (!raw) return nil;
    NSNumber *number = CFGetTypeID(raw) == CFNumberGetTypeID() ? [(__bridge NSNumber *)raw copy] : nil;
    CFRelease(raw);
    return number.longLongValue > 0 ? number : nil;
}

static NSDictionary *zxFrame(CFTypeRef element)
{
    CFTypeRef raw = zxNumericAttribute(element, 2003);
    if (!raw) raw = zxAttribute(element, CFSTR("AXFrame"));
    if (!raw) return nil;
    CGRect frame = CGRectZero;
    BOOL valid = NO;
    if (zxValueTypeID && zxValueType && zxValueGet &&
        CFGetTypeID(raw) == zxValueTypeID() && zxValueType(raw) == 3)
        valid = zxValueGet(raw, 3, &frame);
    if (!valid && CFGetTypeID(raw) == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)raw;
        NSNumber *x = dict[@"x"] ?: dict[@"X"];
        NSNumber *y = dict[@"y"] ?: dict[@"Y"];
        NSNumber *width = dict[@"width"] ?: dict[@"Width"];
        NSNumber *height = dict[@"height"] ?: dict[@"Height"];
        if (x && y && width && height) {
            frame = CGRectMake(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
            valid = YES;
        }
    }
    CFRelease(raw);
    if (!valid) return nil;
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
             @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

static NSMutableDictionary *zxLeafNode(CFTypeRef element)
{
    NSMutableDictionary *node = [NSMutableDictionary dictionaryWithObject:@"AXElement" forKey:@"role"];
    NSString *identifier = zxNumericString(element, 5019);
    if (!identifier.length) {
        CFTypeRef rawIdentifier = zxAttribute(element, CFSTR("AXIdentifier"));
        identifier = [zxString(rawIdentifier) copy];
        if (rawIdentifier) CFRelease(rawIdentifier);
    }
    if (identifier.length) node[@"identifier"] = identifier;
    NSNumber *windowContextId = zxNumericNumber(element, 2021);
    if (windowContextId) node[@"windowContextId"] = windowContextId;
    NSNumber *displayId = zxNumericNumber(element, 2123);
    if (displayId) node[@"displayId"] = displayId;
    NSString *label = zxNumericString(element, 2001);
    if (label.length) node[@"label"] = label;
    if (!label.length) {
        CFTypeRef rawLabel = zxAttribute(element, CFSTR("AXLabel"));
        NSString *text = [zxString(rawLabel) copy];
        if (text.length) node[@"label"] = text;
        if (rawLabel) CFRelease(rawLabel);
    }
    NSString *value = zxNumericString(element, 2006);
    if (value.length) node[@"value"] = value;
    const NSDictionary<NSString *, NSString *> *attributes = @{
        @"AXRole": @"role", @"AXSubrole": @"subrole", @"AXHelp": @"hint",
        @"AXDescription": @"description", @"AXTitle": @"title",
        @"AXEnabled": @"enabled", @"AXFocused": @"focused"
    };
    for (NSString *key in @[@"AXRole", @"AXSubrole", @"AXHelp", @"AXDescription", @"AXTitle", @"AXEnabled", @"AXFocused"]) {
        CFTypeRef raw = zxAttribute(element, (__bridge CFStringRef)key);
        if (!raw) continue;
        CFTypeID type = CFGetTypeID(raw);
        if (type == CFStringGetTypeID()) {
            NSString *text = (__bridge NSString *)raw;
            if (text.length) node[attributes[key]] = text;
        } else if (([key isEqualToString:@"AXEnabled"] || [key isEqualToString:@"AXFocused"]) &&
                   (type == CFBooleanGetTypeID() || type == CFNumberGetTypeID())) {
            node[attributes[key]] = @([(__bridge NSNumber *)raw boolValue]);
        }
        CFRelease(raw);
    }
    CFTypeRef elementType = zxNumericAttribute(element, 5003);
    if (elementType) {
        NSString *typeName = zxString(elementType);
        if (typeName.length) node[@"elementType"] = typeName;
        CFRelease(elementType);
    }
    NSDictionary *frame = zxFrame(element);
    if (frame) node[@"frame"] = frame;
    if ([node[@"elementType"] isEqualToString:@"WebAccessibilityObjectWrapper"]) {
        for (NSString *key in @[@"AXRoleDescription", @"AXDOMIdentifier", @"AXURL", @"AXPlaceholderValue"]) {
            CFTypeRef raw = zxAttribute(element, (__bridge CFStringRef)key);
            if (!raw) continue;
            if (CFGetTypeID(raw) == CFStringGetTypeID()) {
                NSString *text = (__bridge NSString *)raw;
                if (text.length) node[key] = text;
            } else if (CFGetTypeID(raw) == CFURLGetTypeID()) {
                node[key] = [(__bridge NSURL *)raw absoluteString];
            }
            CFRelease(raw);
        }
    }
    node[@"children"] = @[];
    return node;
}

static BOOL zxRememberElement(CFTypeRef element, NSMutableDictionary<NSNumber *, NSMutableArray *> *seen)
{
    NSNumber *bucketKey = @(CFHash(element));
    NSMutableArray *bucket = seen[bucketKey];
    if (!bucket) {
        bucket = [NSMutableArray array];
        seen[bucketKey] = bucket;
    }
    for (id previous in bucket) {
        if (CFEqual(element, (__bridge CFTypeRef)previous)) return NO;
    }
    [bucket addObject:(__bridge id)element];
    return YES;
}

static BOOL zxWithinSnapshot(CFAbsoluteTime deadline, NSUInteger count, BOOL *limitReached)
{
    if (count < zxMaxTreeNodes && CFAbsoluteTimeGetCurrent() < deadline) return YES;
    *limitReached = YES;
    return NO;
}

static void zxWalkChildren(CFTypeRef element, NSMutableDictionary *node, NSString *path,
                           NSUInteger depth, CFAbsoluteTime deadline, CFTypeID elementType,
                           NSMutableDictionary<NSNumber *, NSMutableArray *> *seen,
                           NSMutableArray *sources, NSUInteger *count, BOOL *limitReached)
{
    if (CFAbsoluteTimeGetCurrent() >= deadline) {
        *limitReached = YES;
        return;
    }
    if (depth >= zxMaxDepth) {
        node[@"depthLimitReached"] = @YES;
        *limitReached = YES;
        return;
    }
    CFTypeRef raw = zxAttribute(element, CFSTR("AXChildren"));
    if (!raw) return;
    if (CFAbsoluteTimeGetCurrent() >= deadline) {
        *limitReached = YES;
        CFRelease(raw);
        return;
    }
    if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)raw;
        CFIndex length = CFArrayGetCount(array);
        NSMutableArray *children = [NSMutableArray array];
        for (CFIndex i = 0; i < length; ++i) {
            if (!zxWithinSnapshot(deadline, *count, limitReached)) break;
            CFTypeRef child = CFArrayGetValueAtIndex(array, i);
            if (!child || CFGetTypeID(child) != elementType || !zxRememberElement(child, seen)) continue;
            NSString *childPath = [path stringByAppendingFormat:@"/AXChildren[%ld]", (long)i];
            NSMutableDictionary *childNode = zxLeafNode(child);
            childNode[@"snapshotPath"] = childPath;
            childNode[@"source"] = @"AXChildren";
            [children addObject:childNode];
            [sources addObject:@{ @"element": (__bridge id)child, @"path": childPath }];
            ++*count;
            zxWalkChildren(child, childNode, childPath, depth + 1, deadline, elementType,
                           seen, sources, count, limitReached);
        }
        node[@"children"] = children;
    }
    CFRelease(raw);
}

static void zxAppendCandidates(CFTypeRef source, NSString *sourcePath, NSMutableArray *candidates,
                               NSMutableDictionary<NSNumber *, NSMutableArray *> *seen,
                               CFTypeID elementType, CFAbsoluteTime deadline,
                               NSUInteger *count, NSUInteger *candidateCount, BOOL *limitReached)
{
    const uint32_t candidateIDs[] = {3015, 3025, 3022, 3029, 3031, 3032};
    for (NSUInteger index = 0; index < sizeof(candidateIDs) / sizeof(candidateIDs[0]); ++index) {
        if (*candidateCount >= zxMaxCandidates || !zxWithinSnapshot(deadline, *count, limitReached)) break;
        CFTypeRef raw = zxNumericAttribute(source, candidateIDs[index]);
        if (CFAbsoluteTimeGetCurrent() >= deadline) {
            *limitReached = YES;
            if (raw) CFRelease(raw);
            break;
        }
        if (!raw) continue;
        CFArrayRef array = CFGetTypeID(raw) == CFArrayGetTypeID() ? (CFArrayRef)raw : NULL;
        CFIndex length = array ? CFArrayGetCount(array) : 1;
        for (CFIndex i = 0; i < length; ++i) {
            if (*candidateCount >= zxMaxCandidates || !zxWithinSnapshot(deadline, *count, limitReached)) break;
            CFTypeRef candidate = array ? CFArrayGetValueAtIndex(array, i) : raw;
            if (!candidate || CFGetTypeID(candidate) != elementType ||
                CFEqual(candidate, source) || !zxRememberElement(candidate, seen)) continue;
            NSMutableDictionary *leaf = zxLeafNode(candidate);
            leaf[@"candidateAttribute"] = @(candidateIDs[index]);
            leaf[@"candidateIndex"] = @(i);
            leaf[@"candidateSourcePath"] = sourcePath;
            leaf[@"snapshotPath"] = [NSString stringWithFormat:@"%@/candidate[%u:%ld]", sourcePath,
                                     candidateIDs[index], (long)i];
            leaf[@"source"] = @"numericCandidate";
            [candidates addObject:leaf];
            ++*count;
            ++*candidateCount;
        }
        CFRelease(raw);
    }
    if (*candidateCount >= zxMaxCandidates) *limitReached = YES;
}

static NSDictionary *zxNode(CFTypeRef application, NSUInteger depth, NSUInteger *count,
                             NSUInteger *candidateCount, BOOL *limitReached,
                              NSTimeInterval budget, NSMutableDictionary *sourceCounts)
{
    *count = 1;
    *candidateCount = 0;
    *limitReached = NO;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;
    if (sourceCounts) {
        for (NSNumber *attribute in @[@3015, @2095]) {
            CFTypeRef raw = zxNumericAttribute(application, attribute.unsignedIntValue);
            if (!raw) continue;
            sourceCounts[attribute.stringValue] = @(CFGetTypeID(raw) == CFArrayGetTypeID() ? CFArrayGetCount((CFArrayRef)raw) : 1);
            CFRelease(raw);
        }
    }
    CFTypeID elementType = CFGetTypeID(application);
    NSMutableDictionary *root = zxLeafNode(application);
    root[@"role"] = @"AXApplication";
    root[@"source"] = @"application";
    root[@"snapshotPath"] = @"root";
    NSMutableArray *sources = [NSMutableArray arrayWithObject:@{ @"element": (__bridge id)application,
                                                                   @"path": @"root" }];
    NSMutableDictionary<NSNumber *, NSMutableArray *> *seen = [NSMutableDictionary dictionary];
    zxRememberElement(application, seen);
    zxWalkChildren(application, root, @"root", depth, deadline, elementType,
                   seen, sources, count, limitReached);

    // Window and numeric candidate lists are discovery sources, not AXChildren edges.
    NSMutableArray *candidates = [NSMutableArray array];
    CFTypeRef rawWindows = zxWithinSnapshot(deadline, *count, limitReached) ?
        zxNumericAttribute(application, 5001) : NULL;
    if (rawWindows && CFAbsoluteTimeGetCurrent() >= deadline) {
        *limitReached = YES;
        CFRelease(rawWindows);
        rawWindows = NULL;
    }
    if (rawWindows) {
        CFArrayRef windows = CFGetTypeID(rawWindows) == CFArrayGetTypeID() ? (CFArrayRef)rawWindows : NULL;
        CFIndex length = windows ? CFArrayGetCount(windows) : 1;
        for (CFIndex i = 0; i < length; ++i) {
            if (!zxWithinSnapshot(deadline, *count, limitReached)) break;
            CFTypeRef window = windows ? CFArrayGetValueAtIndex(windows, i) : rawWindows;
            if (!window || CFGetTypeID(window) != elementType) continue;
            NSString *windowPath = [NSString stringWithFormat:@"root/windowCandidate[%ld]", (long)i];
            if (zxRememberElement(window, seen)) {
                NSMutableDictionary *windowNode = zxLeafNode(window);
                windowNode[@"role"] = @"AXWindow";
                windowNode[@"source"] = @"windowCandidate";
                windowNode[@"snapshotPath"] = windowPath;
                [candidates addObject:windowNode];
                ++*count;
                zxWalkChildren(window, windowNode, windowPath, depth, deadline, elementType,
                               seen, sources, count, limitReached);
            }
            [sources addObject:@{ @"element": (__bridge id)window, @"path": windowPath }];
        }
        CFRelease(rawWindows);
    }
    // Discover all real children before visiting candidate lists, so duplicate
    // candidate references never steal the real child's tree position.
    for (NSDictionary *item in sources) {
        if (!zxWithinSnapshot(deadline, *count, limitReached)) break;
        zxAppendCandidates((__bridge CFTypeRef)item[@"element"], item[@"path"], candidates,
                           seen, elementType, deadline, count, candidateCount, limitReached);
    }
    if (candidates.count) {
        NSMutableArray *children = [root[@"children"] mutableCopy];
        [children addObject:@{ @"role": @"AXCandidateGroup", @"source": @"candidateGroup",
                               @"snapshotPath": @"root/candidates", @"children": candidates }];
        root[@"children"] = children;
    }
    return root;
}

static BOOL zxIsLivePID(pid_t pid)
{
    if (pid <= 0) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}

static pid_t zxPIDFromObject(id object)
{
    if (!object) return 0;
    for (NSString *name in @[@"pid", @"processIdentifier"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (!signature || (signature.methodReturnType[0] != 'i' && signature.methodReturnType[0] != 'I')) continue;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = object;
        call.selector = selector;
        [call invoke];
        pid_t pid = 0;
        [call getReturnValue:&pid];
        if (zxIsLivePID(pid)) return pid;
    }
    return 0;
}

NSData *zxCopyAccessibilityTreeWithBudget(NSTimeInterval budget, NSError **error)
{
    if (!isfinite(budget) || budget < 0.1 || budget > 30.0) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:6
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX budget must be 100 to 30000 milliseconds"}];
        return nil;
    }
    static NSObject *captureLock;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ captureLock = [NSObject new]; });
    @synchronized(captureLock) {
    void *frontBoard = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_LAZY);
    ZXFocusedPID focusedPID = frontBoard ? (ZXFocusedPID)dlsym(frontBoard, "AXFrontBoardFocusedAppPID") : NULL;
    __block pid_t pid = 0;
    void (^readForegroundPID)(void) = ^{
        pid = focusedPID ? focusedPID() : 0;
        if (!zxIsLivePID(pid)) {
            id app = getFrontMostApplication();
            pid = zxPIDFromObject(app);
            if (!pid && [app respondsToSelector:@selector(processState)]) {
                id state = ((id (*)(id, SEL))objc_msgSend)(app, @selector(processState));
                pid = zxPIDFromObject(state);
            }
            NSString *bundleID = nil;
            if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                bundleID = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
            }
            if (!zxIsLivePID(pid) && (!app || [bundleID isEqualToString:@"com.apple.springboard"])) {
                pid = getpid();
            }
        }
    };
    if ([NSThread isMainThread]) readForegroundPID();
    else dispatch_sync(dispatch_get_main_queue(), readForegroundPID);
    const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility"
    };
    void *runtime = NULL;
    ZXCreateApplication create = NULL;
    zxCopyAttribute = NULL;
    zxValueTypeID = NULL;
    zxValueType = NULL;
    zxValueGet = NULL;
    for (NSUInteger i = 0; i < sizeof(frameworks) / sizeof(frameworks[0]); ++i) {
        void *candidate = dlopen(frameworks[i], RTLD_LAZY | RTLD_GLOBAL);
        if (!candidate) continue;
        ZXCreateApplication nextCreate = (ZXCreateApplication)dlsym(candidate, "AXUIElementCreateApplication");
        if (!nextCreate) nextCreate = (ZXCreateApplication)dlsym(candidate, "_AXUIElementCreateAppElementWithPid");
        ZXCopyAttribute nextCopy = (ZXCopyAttribute)dlsym(candidate, "AXUIElementCopyAttributeValue");
        if (nextCreate && nextCopy) {
            runtime = candidate;
            create = nextCreate;
            zxCopyAttribute = nextCopy;
            zxSetRequestingClient = (ZXSetRequestingClient)dlsym(candidate, "__AXSetRequestingClient");
            zxValueTypeID = (ZXValueTypeID)dlsym(candidate, "AXValueGetTypeID");
            zxValueType = (ZXValueType)dlsym(candidate, "AXValueGetType");
            zxValueGet = (ZXValueGet)dlsym(candidate, "AXValueGetValue");
            break;
        }
    }
    if (pid <= 0 || !create || !zxCopyAttribute) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX runtime or foreground PID unavailable"}];
        return nil;
    }
    ZXAssociatePID associate = (ZXAssociatePID)dlsym(runtime, "_AXAddAssociatedPid");
    ZXSetTimeout setTimeout = (ZXSetTimeout)dlsym(runtime, "AXUIElementSetMessagingTimeout");
    __block NSUInteger count = 0;
    __block NSUInteger candidateCount = 0;
    __block NSMutableDictionary *sourceCounts = nil;
    __block BOOL limitReached = NO;
    __block NSDictionary *tree = nil;
    __block NSString *failure = nil;
    const useconds_t delays[] = {150000, 450000, 900000};
    for (NSUInteger attempt = 0; attempt < 4; ++attempt) {
        void (^capture)(void) = ^{
            readForegroundPID();
            failure = nil;
            if (!zxIsLivePID(pid)) {
                failure = @"AX foreground PID unavailable";
                return;
            }
            if (associate) {
                associate(getpid(), pid, 1);
                associate(pid, getpid(), 1);
                associate(getpid(), pid, 0);
                associate(pid, getpid(), 0);
            }
            if (zxSetRequestingClient) zxSetRequestingClient(2);
            CFTypeRef application = create(pid);
            if (!application) {
                failure = @"AX application element unavailable";
                return;
            }
            if (setTimeout) setTimeout(application, 0.5f);
            sourceCounts = [@{@"2095": [NSNull null], @"3015": [NSNull null]} mutableCopy];
            tree = zxNode(application, 0, &count, &candidateCount, &limitReached, budget, sourceCounts);
            if (count <= 1) {
                NSMutableArray *details = [NSMutableArray array];
                const uint32_t numericIDs[] = {3015, 3025, 3022, 3029, 3031, 3032, 5001};
                CFAbsoluteTime diagnosticDeadline = CFAbsoluteTimeGetCurrent() + 2.0;
                for (NSUInteger i = 0; i < sizeof(numericIDs) / sizeof(numericIDs[0]) &&
                                       CFAbsoluteTimeGetCurrent() < diagnosticDeadline; ++i) {
                    CFTypeRef value = NULL;
                    if (zxSetRequestingClient) zxSetRequestingClient(2);
                    int32_t status = zxCopyAttribute(application, (CFStringRef)(uintptr_t)numericIDs[i], &value);
                    CFIndex size = value && CFGetTypeID(value) == CFArrayGetTypeID()
                        ? CFArrayGetCount((CFArrayRef)value) : (value ? 1 : 0);
                    [details addObject:[NSString stringWithFormat:@"%u=%d/%ld", numericIDs[i], status, (long)size]];
                    if (value) CFRelease(value);
                }
                failure = [NSString stringWithFormat:@"AX application pid=%d returned no child elements (%@)",
                           pid, [details componentsJoinedByString:@", "]];
            }
            CFRelease(application);
        };
        if ([NSThread isMainThread]) capture();
        else dispatch_sync(dispatch_get_main_queue(), capture);
        if (count > 1 || [failure isEqualToString:@"AX application element unavailable"]) break;
        if (attempt < 3 && ![NSThread isMainThread]) usleep(delays[attempt]);
    }
    if (count <= 1) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX"
                                                code:[failure isEqualToString:@"AX application element unavailable"] ? 2 : 3
                                            userInfo:@{NSLocalizedDescriptionKey: failure ?: @"AX candidates empty"}];
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"pid": @(pid), @"count": @(count),
                                                     @"candidateCount": @(candidateCount),
                                                     @"sourceCounts": sourceCounts ?: @{},
                                                     @"mode": @"legacy",
                                                     @"budgetMs": @(budget * 1000),
                                                     @"limitReached": @(limitReached),
                                                     @"root": tree} options:0 error:error];
    }
}

static NSString *zxVisibleString(id element, long attribute)
{
    id value = [element objectWithAXAttribute:attribute];
    if ([value isKindOfClass:[NSAttributedString class]]) return [value string];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSDictionary *zxVisible2095Node(id element, NSUInteger index, ZXValueGet getValue)
{
    CFTypeRef rawFrame = (__bridge CFTypeRef)[element objectWithAXAttribute:2003];
    CGRect frame = CGRectZero;
    if (!rawFrame || !getValue || !getValue(rawFrame, 3, &frame) ||
        !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height)) return nil;
    CGPoint activation = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CFTypeRef rawPoint = (__bridge CFTypeRef)[element objectWithAXAttribute:2007];
    CGPoint point = CGPointZero;
    if (rawPoint && getValue(rawPoint, 1, &point) && isfinite(point.x) && isfinite(point.y) && point.x < 100000)
        activation = point;
    id rawTraits = [element objectWithAXAttribute:2004];
    uint64_t bits = [rawTraits respondsToSelector:@selector(unsignedLongLongValue)] ? [rawTraits unsignedLongLongValue] : 0;
    NSMutableArray *traits = [NSMutableArray array];
    NSArray *names = @[@"button", @"link", @"image", @"selected", @"playsSound", @"keyboardKey", @"staticText", @"summaryElement", @"notEnabled", @"updatesFrequently", @"searchField", @"startsMediaSession", @"adjustable", @"allowsDirectInteraction", @"causesPageTurn", @"", @"header"];
    for (NSUInteger bit = 0; bit < names.count; ++bit)
        if ((bits & (1ULL << bit)) && [names[bit] length]) [traits addObject:names[bit]];
    NSMutableDictionary *node = [@{@"id": [NSString stringWithFormat:@"n%lu", (unsigned long)index],
                                   @"role": @"AXElement", @"source": @"visible2095", @"candidateAttribute": @2095,
                                   @"candidateIndex": @(index), @"traits": traits,
                                   @"enabled": @((bits & (1ULL << 8)) == 0),
                                   @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                                               @"width": @(frame.size.width), @"height": @(frame.size.height)},
                                   @"activationPoint": @{@"x": @(activation.x), @"y": @(activation.y)},
                                   @"children": @[]} mutableCopy];
    NSString *label = zxVisibleString(element, 2001);
    NSString *value = zxVisibleString(element, 2006);
    NSString *hint = zxVisibleString(element, 2002);
    if (label.length) node[@"label"] = label;
    if (value.length) node[@"value"] = value;
    if (hint.length) node[@"hint"] = hint;
    return node;
}

NSData *zxCopyAccessibilityVisible2095WithBudget(NSTimeInterval budget, NSError **error)
{
    if (!isfinite(budget) || budget < 0.1 || budget > 30.0) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:6
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX budget must be 100 to 30000 milliseconds"}];
        return nil;
    }
    static NSObject *visibleLock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ visibleLock = [NSObject new]; });
    @synchronized (visibleLock) {
        __block pid_t pid = 0;
        __block NSDictionary *snapshot = nil;
        void (^capture)(void) = ^{
            void *frontBoard = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_LAZY);
            ZXFocusedPID focusedPID = frontBoard ? (ZXFocusedPID)dlsym(frontBoard, "AXFrontBoardFocusedAppPID") : NULL;
            pid = focusedPID ? focusedPID() : 0;
            if (!zxIsLivePID(pid)) {
                id app = getFrontMostApplication();
                pid = zxPIDFromObject(app);
                if (!pid && [app respondsToSelector:@selector(processState)])
                    pid = zxPIDFromObject(((id (*)(id, SEL))objc_msgSend)(app, @selector(processState)));
                NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ?
                    ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier)) : nil;
                if (!zxIsLivePID(pid) && (!app || [bundleID isEqualToString:@"com.apple.springboard"])) pid = getpid();
            }
            if (!zxIsLivePID(pid)) return;
            dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW | RTLD_GLOBAL);
            Class elementClass = NSClassFromString(@"AXUIElement");
            if (!elementClass || ![elementClass respondsToSelector:@selector(uiApplicationWithPid:)]) return;
            ZXSetRequestingClient requestingClient = (ZXSetRequestingClient)dlsym(RTLD_DEFAULT, "__AXSetRequestingClient");
            ZXValueGet getValue = (ZXValueGet)dlsym(RTLD_DEFAULT, "AXValueGetValue");
            if (requestingClient) requestingClient(2);
            if (!getValue) return;
            id application = [(id<ZXVisibleAXElement>)elementClass uiApplicationWithPid:pid];
            if (!application) return;
            ZXSetTimeout setTimeout = (ZXSetTimeout)dlsym(RTLD_DEFAULT, "AXUIElementSetMessagingTimeout");
            if (setTimeout) setTimeout((__bridge CFTypeRef)application, 0.5f);
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;
            NSArray *visible = [application uiElementsWithAttribute:2095];
            if (![visible isKindOfClass:[NSArray class]]) return;
            id list3015 = [application uiElementsWithAttribute:3015];
            id count3015 = [list3015 isKindOfClass:[NSArray class]] ? @([list3015 count]) : [NSNull null];
            NSMutableArray *children = [NSMutableArray array];
            BOOL limitReached = CFAbsoluteTimeGetCurrent() >= deadline;
            NSUInteger index = 0;
            for (id element in visible) {
                if (index >= zxMaxCandidates || CFAbsoluteTimeGetCurrent() >= deadline) {
                    limitReached = YES;
                    break;
                }
                @autoreleasepool {
                    NSDictionary *node = zxVisible2095Node(element, index, getValue);
                    if (node) [children addObject:node];
                }
                ++index;
            }
            NSMutableDictionary *root = [@{@"role": @"AXApplication", @"source": @"application",
                                           @"snapshotPath": @"root", @"children": children} mutableCopy];
            snapshot = @{@"pid": @(pid), @"mode": @"visible2095", @"count": @(children.count + 1),
                         @"candidateCount": @(children.count), @"sourceCounts": @{@"2095": @(visible.count), @"3015": count3015},
                         @"budgetMs": @(budget * 1000), @"limitReached": @(limitReached), @"root": root};
        };
        if ([NSThread isMainThread]) capture();
        else dispatch_sync(dispatch_get_main_queue(), capture);
        if (!snapshot) {
            if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:7
                                                userInfo:@{NSLocalizedDescriptionKey: @"AX 2095 visible elements unavailable"}];
            return nil;
        }
        return [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:error];
    }
}

NSData *zxCopyAccessibilityElementAtPoint(CGPoint point, NSError **error)
{
    if (!isfinite(point.x) || !isfinite(point.y) || point.x < 0 || point.y < 0) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:4
                                             userInfo:@{NSLocalizedDescriptionKey:@"invalid screen point"}];
        return nil;
    }
    void *runtime = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_LAZY | RTLD_GLOBAL);
    ZXCreateApplication create = runtime ? (ZXCreateApplication)dlsym(runtime, "AXUIElementCreateApplication") : NULL;
    typedef int32_t (*ZXHitTest)(CFTypeRef, CFTypeRef *, float, float);
    ZXHitTest hitTest = runtime ? (ZXHitTest)dlsym(runtime, "AXUIElementCopyElementAtPosition") : NULL;
    if (!create || !hitTest) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:5
                                             userInfo:@{NSLocalizedDescriptionKey:@"AX hit test unavailable"}];
        return nil;
    }
    zxCopyAttribute = (ZXCopyAttribute)dlsym(runtime, "AXUIElementCopyAttributeValue");
    zxSetRequestingClient = (ZXSetRequestingClient)dlsym(runtime, "__AXSetRequestingClient");
    zxValueTypeID = (ZXValueTypeID)dlsym(runtime, "AXValueGetTypeID");
    zxValueType = (ZXValueType)dlsym(runtime, "AXValueGetType");
    zxValueGet = (ZXValueGet)dlsym(runtime, "AXValueGetValue");
    ZXSetTimeout setTimeout = (ZXSetTimeout)dlsym(runtime, "AXUIElementSetMessagingTimeout");
    void *frontBoard = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_LAZY);
    ZXFocusedPID focusedPID = frontBoard ? (ZXFocusedPID)dlsym(frontBoard, "AXFrontBoardFocusedAppPID") : NULL;
    __block pid_t pid = 0;
    __block NSDictionary *node = nil;
    __block int32_t status = -1;
    void (^capture)(void) = ^{
        pid = focusedPID ? focusedPID() : 0;
        if (!zxIsLivePID(pid)) {
            id app = getFrontMostApplication();
            pid = zxPIDFromObject(app);
            NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ?
                ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier)) : nil;
            if (!zxIsLivePID(pid) && (!app || [bundleID isEqualToString:@"com.apple.springboard"])) pid = getpid();
        }
        if (!zxIsLivePID(pid)) return;
        CFTypeRef application = create(pid);
        if (!application) return;
        if (setTimeout) setTimeout(application, .5f);
        CFTypeRef element = NULL;
        if (zxSetRequestingClient) zxSetRequestingClient(2);
        status = hitTest(application, &element, (float)point.x, (float)point.y);
        if (status == 0 && element && zxCopyAttribute) node = zxLeafNode(element);
        if (element) CFRelease(element);
        CFRelease(application);
    };
    if ([NSThread isMainThread]) capture();
    else dispatch_sync(dispatch_get_main_queue(), capture);
    if (!node) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:status
                                             userInfo:@{NSLocalizedDescriptionKey:@"No AX element at this point"}];
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:@{ @"pid": @(pid), @"x": @(point.x),
                                                       @"y": @(point.y), @"element": node } options:0 error:error];
}
