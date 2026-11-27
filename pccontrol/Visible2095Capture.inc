// Included after the shared AX typedefs/PID helpers. No legacy AX globals are used.
#ifndef ZX_VISIBLE_NOW
#define ZX_VISIBLE_NOW() ([NSProcessInfo processInfo].systemUptime)
#endif
#ifndef ZX_VISIBLE_SERIALIZE
#define ZX_VISIBLE_SERIALIZE(object, errorPointer) [NSJSONSerialization dataWithJSONObject:(object) options:NSJSONWritingSortedKeys error:(errorPointer)]
#endif

@interface ZXVisibleCapture : NSObject
@property(nonatomic) ZXCreateApplication create;
@property(nonatomic) ZXCopyAttribute copyAttribute;
@property(nonatomic) ZXValueTypeID valueTypeID;
@property(nonatomic) ZXValueType valueType;
@property(nonatomic) ZXValueGet valueGet;
@property(nonatomic) ZXSetRequestingClient requestingClient;
@property(nonatomic) ZXAssociatePID associate;
@property(nonatomic) ZXSetTimeout setTimeout;
@property(nonatomic) NSTimeInterval started, captureStarted, deadline;
@property(nonatomic) pid_t pid;
@property(nonatomic) BOOL limited, readBudgetSkipped;
@property(nonatomic) NSUInteger examined, skipped;
@property(nonatomic) NSInteger nodeIndex;
@property(nonatomic, strong) NSNumber *attribute, *axStatus;
@property(nonatomic, strong) NSString *stage;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) NSMutableDictionary *diagnostics;
@end
@implementation ZXVisibleCapture
@end

static void zxVisibleCheckpoint(ZXVisibleCapture *capture, NSString *stage, NSString *state, NSDictionary *details)
{
    capture.stage = stage;
    capture.diagnostics[@"stage"] = stage;
    NSMutableDictionary *entry = [@{@"stage": stage, @"state": state,
        @"elapsedMs": @((ZX_VISIBLE_NOW() - capture.started) * 1000)} mutableCopy];
    if (details) [entry addEntriesFromDictionary:details];
    [capture.diagnostics[@"stages"] addObject:entry];
}

static void zxVisibleIssue(ZXVisibleCapture *capture, NSInteger code, NSString *stage,
                           NSNumber *attribute, NSNumber *status, NSInteger index, NSDictionary *details)
{
    NSMutableDictionary *issue = [@{@"code": @(code), @"stage": stage,
        @"attribute": attribute ?: (id)[NSNull null], @"axStatus": status ?: (id)[NSNull null],
        @"nodeIndex": index < 0 ? (id)[NSNull null] : @(index)} mutableCopy];
    if (details) [issue addEntriesFromDictionary:details];
    NSMutableDictionary *counts = capture.diagnostics[@"issueCounts"];
    NSString *key = [NSString stringWithFormat:@"%ld:%@:%@", (long)code, stage, status ?: @"none"];
    counts[key] = @([counts[key] unsignedIntegerValue] + 1);
    capture.diagnostics[@"issuesTotal"] = @([capture.diagnostics[@"issuesTotal"] unsignedIntegerValue] + 1);
    NSMutableArray *samples = capture.diagnostics[@"issues"];
    if (samples.count < 32) [samples addObject:issue];
    else capture.diagnostics[@"issuesTruncated"] = @YES;
}

static void zxVisibleFail(ZXVisibleCapture *capture, NSInteger code, NSString *stage,
                          NSNumber *attribute, NSNumber *status, NSInteger index, NSString *reason)
{
    zxVisibleIssue(capture, code, stage, attribute, status, index, @{@"reason": reason});
    zxVisibleCheckpoint(capture, stage, @"failed", @{@"code": @(code)});
    capture.diagnostics[@"captureMs"] = @((ZX_VISIBLE_NOW() - capture.captureStarted) * 1000);
    capture.diagnostics[@"elapsedMs"] = @((ZX_VISIBLE_NOW() - capture.started) * 1000);
    capture.diagnostics[@"pid"] = @(capture.pid);
    capture.diagnostics[@"failure"] = @{@"code": @(code), @"stage": stage, @"reason": reason,
        @"attribute": attribute ?: (id)[NSNull null], @"axStatus": status ?: (id)[NSNull null],
        @"nodeIndex": index < 0 ? (id)[NSNull null] : @(index)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:capture.diagnostics options:NSJSONWritingSortedKeys error:nil];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    NSString *message = [NSString stringWithFormat:
        @"AX 2095 capture failed: stage=%@ errorCode=%ld pid=%d axStatus=%@ attribute=%@ nodeIndex=%ld diagnostics=%@",
        stage, (long)code, capture.pid, status ?: @"none", attribute ?: @"none", (long)index, text];
    NSLog(@"com.zjx.springboard: %@", message);
    capture.failure = [NSError errorWithDomain:@"ZXTouchAX" code:code
        userInfo:@{NSLocalizedDescriptionKey: message, @"stage": stage, @"diagnostics": capture.diagnostics}];
}

static NSMutableDictionary *zxVisibleStats(ZXVisibleCapture *capture, uint32_t attribute)
{
    NSMutableDictionary *all = capture.diagnostics[@"attributeStats"];
    NSString *key = [@(attribute) stringValue];
    if (!all[key]) all[key] = [@{@"attempted": @0, @"ok": @0, @"empty": @0, @"axError": @0,
        @"typeError": @0, @"invalid": @0, @"budgetSkipped": @0} mutableCopy];
    return all[key];
}

static void zxVisibleIncrement(NSMutableDictionary *stats, NSString *key)
{
    stats[key] = @([stats[key] unsignedIntegerValue] + 1);
}

static void zxVisibleLimit(ZXVisibleCapture *capture, NSString *reason, NSInteger code, NSString *stage)
{
    if (!capture.limited) {
        zxVisibleIssue(capture, code, stage, capture.attribute, nil, capture.nodeIndex, @{@"reason": reason});
        capture.diagnostics[@"limitReason"] = reason;
    }
    capture.limited = YES;
}

static BOOL zxVisibleWithinBudget(ZXVisibleCapture *capture)
{
    return ZX_VISIBLE_NOW() < capture.deadline;
}

static CFTypeRef zxVisibleCopy(ZXVisibleCapture *capture, CFTypeRef element, uint32_t attribute,
                               NSInteger index, NSString *stage)
{
    capture.stage = stage;
    capture.diagnostics[@"stage"] = stage;
    capture.attribute = @(attribute);
    capture.nodeIndex = index;
    capture.axStatus = nil;
    capture.readBudgetSkipped = NO;
    NSMutableDictionary *stats = zxVisibleStats(capture, attribute);
    if (!zxVisibleWithinBudget(capture)) {
        zxVisibleIncrement(stats, @"budgetSkipped");
        capture.readBudgetSkipped = YES;
        return NULL;
    }
    if (capture.requestingClient) capture.requestingClient(2);
    if (capture.setTimeout) {
        float seconds = (float)fmin(0.5, fmax(0.001, capture.deadline - ZX_VISIBLE_NOW()));
        capture.diagnostics[@"lastMessagingTimeoutSeconds"] = @(seconds);
        int32_t timeoutStatus = capture.setTimeout(element, seconds);
        if (timeoutStatus) zxVisibleIssue(capture, 205, @"messaging-timeout", @(attribute), @(timeoutStatus), index, nil);
    }
    zxVisibleIncrement(stats, @"attempted");
    CFTypeRef value = NULL;
    int32_t status = capture.copyAttribute(element, (CFStringRef)(uintptr_t)attribute, &value);
    capture.axStatus = @(status);
    if (status) {
        zxVisibleIncrement(stats, @"axError");
        if (value) CFRelease(value);
        return NULL;
    }
    zxVisibleIncrement(stats, value ? @"ok" : @"empty");
    return value;
}

static void zxVisibleAttributeIssue(ZXVisibleCapture *capture, uint32_t attribute, NSInteger code,
                                    NSString *stage, NSString *reason, CFTypeRef value)
{
    NSMutableDictionary *details = [@{@"reason": reason} mutableCopy];
    if (value) details[@"cfTypeID"] = @(CFGetTypeID(value));
    zxVisibleIssue(capture, code, stage, @(attribute), capture.axStatus, capture.nodeIndex, details);
}

static NSString *zxVisibleStringC(ZXVisibleCapture *capture, CFTypeRef element, uint32_t attribute,
                                  NSInteger code, NSString *name, NSInteger index)
{
    NSString *stage = [@"node-" stringByAppendingFormat:@"%@-copy", name];
    CFTypeRef value = zxVisibleCopy(capture, element, attribute, index, stage);
    if (!value) {
        if (capture.axStatus.intValue) zxVisibleAttributeIssue(capture, attribute, code, stage, @"AX read failed", NULL);
        return nil;
    }
    @try {
        if (CFGetTypeID(value) == CFStringGetTypeID()) return [(__bridge NSString *)value copy];
        zxVisibleIncrement(zxVisibleStats(capture, attribute), @"typeError");
        zxVisibleAttributeIssue(capture, attribute, code, [@"node-" stringByAppendingFormat:@"%@-type", name], @"Expected CFString", value);
        return nil;
    } @finally { CFRelease(value); }
}

static NSDictionary *zxVisibleNodeC(ZXVisibleCapture *capture, CFTypeRef element, NSUInteger index)
{
    CFTypeRef raw = zxVisibleCopy(capture, element, 2003, index, @"node-frame-copy");
    if (!raw) {
        if (!capture.readBudgetSkipped) zxVisibleAttributeIssue(capture, 2003, 121, @"node-frame-copy", @"Frame missing or AX read failed", NULL);
        return nil;
    }
    CGRect frame = CGRectZero;
    @try {
        capture.stage = @"node-frame-type";
        if (CFGetTypeID(raw) != capture.valueTypeID() || capture.valueType(raw) != 3) {
            zxVisibleIncrement(zxVisibleStats(capture, 2003), @"typeError");
            zxVisibleAttributeIssue(capture, 2003, 122, @"node-frame-type", @"Expected CGRect AXValue", raw);
            return nil;
        }
        capture.stage = @"node-frame-decode";
        if (!capture.valueGet(raw, 3, &frame)) {
            zxVisibleIncrement(zxVisibleStats(capture, 2003), @"invalid");
            zxVisibleAttributeIssue(capture, 2003, 123, @"node-frame-decode", @"AXValueGetValue failed", raw);
            return nil;
        }
        capture.stage = @"node-frame-finite";
        if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) {
            zxVisibleIncrement(zxVisibleStats(capture, 2003), @"invalid");
            zxVisibleAttributeIssue(capture, 2003, 124, @"node-frame-finite", @"Non-finite CGRect", raw);
            return nil;
        }
    } @finally { CFRelease(raw); }
    CGPoint activation = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    raw = zxVisibleCopy(capture, element, 2007, index, @"node-activation-copy");
    if (raw) {
        @try {
            CGPoint point = CGPointZero;
            capture.stage = @"node-activation-decode";
            if (CFGetTypeID(raw) == capture.valueTypeID() && capture.valueType(raw) == 1 &&
                capture.valueGet(raw, 1, &point) && isfinite(point.x) && isfinite(point.y) &&
                point.x >= 0 && point.y >= 0 && point.x < 100000 && point.y < 100000) activation = point;
            else {
                zxVisibleIncrement(zxVisibleStats(capture, 2007), @"invalid");
                zxVisibleAttributeIssue(capture, 2007, 220, @"node-activation-decode", @"Using frame center", raw);
            }
        } @finally { CFRelease(raw); }
    } else if (capture.axStatus.intValue) zxVisibleAttributeIssue(capture, 2007, 220, @"node-activation-copy", @"Using frame center after AX error", NULL);
    raw = zxVisibleCopy(capture, element, 2004, index, @"node-traits-copy");
    NSMutableArray *traits = [NSMutableArray array];
    NSNumber *enabled = nil;
    if (raw) {
        @try {
            int64_t bits = 0;
            if (CFGetTypeID(raw) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)raw, kCFNumberSInt64Type, &bits)) {
                NSArray *names = @[@"button", @"link", @"image", @"selected", @"playsSound", @"keyboardKey", @"staticText", @"summaryElement", @"notEnabled", @"updatesFrequently", @"searchField", @"startsMediaSession", @"adjustable", @"allowsDirectInteraction", @"causesPageTurn", @"", @"header"];
                for (NSUInteger bit = 0; bit < names.count; ++bit) if (((uint64_t)bits & (1ULL << bit)) && [names[bit] length]) [traits addObject:names[bit]];
                enabled = @(((uint64_t)bits & (1ULL << 8)) == 0);
            } else {
                zxVisibleIncrement(zxVisibleStats(capture, 2004), @"typeError");
                zxVisibleAttributeIssue(capture, 2004, 221, @"node-traits-type", @"Expected integer CFNumber", raw);
            }
        } @finally { CFRelease(raw); }
    } else if (capture.axStatus.intValue) zxVisibleAttributeIssue(capture, 2004, 221, @"node-traits-copy", @"AX read failed", NULL);
    NSString *label = zxVisibleStringC(capture, element, 2001, 222, @"label", index);
    NSString *value = zxVisibleStringC(capture, element, 2006, 223, @"value", index);
    NSString *hint = zxVisibleStringC(capture, element, 2002, 224, @"hint", index);
    if (capture.readBudgetSkipped || !zxVisibleWithinBudget(capture)) return nil;
    NSMutableDictionary *node = [@{@"id": [NSString stringWithFormat:@"n%lu", (unsigned long)index],
        @"role": @"AXElement", @"source": @"visible2095", @"candidateAttribute": @2095,
        @"candidateIndex": @(index), @"snapshotPath": [NSString stringWithFormat:@"root/visible2095[%lu]", (unsigned long)index],
        @"traits": traits, @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)},
        @"activationPoint": @{@"x": @(activation.x), @"y": @(activation.y)}, @"children": @[]} mutableCopy];
    if (enabled) node[@"enabled"] = enabled;
    if (label.length) node[@"label"] = label;
    if (value.length) node[@"value"] = value;
    if (hint.length) node[@"hint"] = hint;
    return node;
}

static void *zxVisibleResolve(NSArray<NSValue *> *handles, const char *name)
{
    for (NSValue *value in handles) {
        void *symbol = dlsym(value.pointerValue, name);
        if (symbol) return symbol;
    }
    return dlsym(RTLD_DEFAULT, name);
}

static BOOL zxVisibleSymbol(ZXVisibleCapture *capture, NSString *name, BOOL found, NSInteger code, NSString *stage)
{
    capture.diagnostics[@"symbols"][name] = @(found);
    zxVisibleCheckpoint(capture, stage, found ? @"ok" : (code < 200 ? @"failed" : @"warning"), @{@"symbol": name, @"found": @(found)});
    if (found) return YES;
    if (code < 200) zxVisibleFail(capture, code, stage, nil, nil, -1, [@"Missing symbol " stringByAppendingString:name]);
    else zxVisibleIssue(capture, code, stage, nil, nil, -1, @{@"symbol": name});
    return NO;
}

NSData *zxCopyAccessibilityVisible2095WithBudget(NSTimeInterval budget, NSError **error)
{
    ZXVisibleCapture *capture = [ZXVisibleCapture new];
    capture.started = ZX_VISIBLE_NOW();
    capture.captureStarted = capture.started;
    capture.nodeIndex = -1;
    capture.stage = @"budget-validate";
    capture.diagnostics = [@{@"schemaVersion": @2, @"backend": @"c-ax", @"stage": @"budget-validate",
        @"budgetMs": isfinite(budget) ? (id)@(budget * 1000) : (id)[NSNull null],
        @"stages": [NSMutableArray array], @"runtimeCandidates": [NSMutableArray array],
        @"symbols": [NSMutableDictionary dictionary], @"attributeStats": [NSMutableDictionary dictionary],
        @"issues": [NSMutableArray array], @"issueCounts": [NSMutableDictionary dictionary],
        @"issuesTotal": @0, @"issuesTruncated": @NO, @"limitReason": [NSNull null]} mutableCopy];
    for (NSNumber *attribute in @[@2095, @3015, @2003, @2007, @2004, @2001, @2006, @2002]) zxVisibleStats(capture, attribute.unsignedIntValue);
    if (!isfinite(budget) || budget < 0.1 || budget > 30.0) {
        zxVisibleFail(capture, 100, @"budget-validate", nil, nil, -1, @"Budget must be 100 to 30000 milliseconds");
        if (error) *error = capture.failure;
        return nil;
    }
    zxVisibleCheckpoint(capture, @"budget-validate", @"ok", nil);
    capture.captureStarted = ZX_VISIBLE_NOW();
    capture.deadline = capture.captureStarted + budget;
    {
        __block NSDictionary *snapshot = nil;
        void (^runCapture)(void) = ^{
            CFTypeRef application = NULL;
            CFTypeRef visible = NULL;
            void *frontboard = NULL;
            NSMutableArray<NSValue *> *handles = [NSMutableArray array];
            capture.diagnostics[@"queueWaitMs"] = @((ZX_VISIBLE_NOW() - capture.captureStarted) * 1000);
            if (!zxVisibleWithinBudget(capture)) {
                zxVisibleFail(capture, 101, @"foreground-pid", nil, nil, -1, @"Budget exhausted waiting for main queue");
                return;
            }
            @try {
                capture.stage = @"foreground-pid";
                dlerror();
                if (!zxVisibleWithinBudget(capture)) { zxVisibleFail(capture, 101, @"foreground-pid", nil, nil, -1, @"Budget exhausted before foreground PID"); return; }
                frontboard = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_LAZY | RTLD_GLOBAL);
                const char *loadError = frontboard ? NULL : dlerror();
                if (!frontboard) zxVisibleIssue(capture, 201, @"frontboard-load", nil, nil, -1,
                    @{@"reason": loadError ? [NSString stringWithUTF8String:loadError] : @"dlopen returned NULL"});
                ZXFocusedPID focusedPID = frontboard ? (ZXFocusedPID)dlsym(frontboard, "AXFrontBoardFocusedAppPID") : NULL;
                if (frontboard && !focusedPID) zxVisibleIssue(capture, 201, @"frontboard-symbol", nil, nil, -1, nil);
                capture.pid = focusedPID ? focusedPID() : 0;
                NSString *pidSource = @"AXFrontBoardFocusedAppPID";
                if (!zxIsLivePID(capture.pid)) {
                    id app = getFrontMostApplication();
                    capture.pid = zxPIDFromObject(app);
                    pidSource = @"frontmost-application";
                    if (!capture.pid && [app respondsToSelector:@selector(processState)]) {
                        capture.pid = zxPIDFromObject(((id (*)(id, SEL))objc_msgSend)(app, @selector(processState)));
                        pidSource = @"frontmost-process-state";
                    }
                    NSString *bundle = [app respondsToSelector:@selector(bundleIdentifier)] ?
                        ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier)) : nil;
                    if (!zxIsLivePID(capture.pid) && (!app || [bundle isEqualToString:@"com.apple.springboard"])) {
                        capture.pid = getpid();
                        pidSource = @"springboard-self";
                    }
                }
                capture.diagnostics[@"pidSource"] = pidSource;
                capture.diagnostics[@"pid"] = @(capture.pid);
                if (!zxIsLivePID(capture.pid)) { zxVisibleFail(capture, 101, @"foreground-pid", nil, nil, -1, @"No live foreground PID"); return; }
                zxVisibleCheckpoint(capture, @"foreground-pid", @"ok", @{@"pid": @(capture.pid), @"source": pidSource});
                capture.stage = @"runtime-load";
                const char *paths[] = {"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
                    "/System/Library/Frameworks/Accessibility.framework/Accessibility",
                    "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
                    "/usr/lib/libAccessibility.dylib"};
                for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
                    if (!zxVisibleWithinBudget(capture)) { zxVisibleFail(capture, 102, @"runtime-load", nil, nil, -1, @"Budget exhausted before framework loading"); return; }
                    dlerror();
                    void *handle = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
                    const char *message = handle ? NULL : dlerror();
                    NSMutableDictionary *item = [@{@"path": [NSString stringWithUTF8String:paths[i]], @"loaded": @(handle != NULL)} mutableCopy];
                    if (message) item[@"error"] = [NSString stringWithUTF8String:message];
                    [capture.diagnostics[@"runtimeCandidates"] addObject:item];
                    if (handle) {
                        if ([handles indexOfObjectPassingTest:^BOOL(NSValue *entry, NSUInteger idx, BOOL *stop) { return entry.pointerValue == handle; }] == NSNotFound)
                            [handles addObject:[NSValue valueWithPointer:handle]];
                        else dlclose(handle);
                    }
                }
                if (!handles.count) { zxVisibleFail(capture, 102, @"runtime-load", nil, nil, -1, @"All AX framework loads failed"); return; }
                zxVisibleCheckpoint(capture, @"runtime-load", @"ok", @{@"loadedCount": @(handles.count)});
                if (!zxVisibleWithinBudget(capture)) { zxVisibleFail(capture, 102, @"runtime-load", nil, nil, -1, @"Budget exhausted before symbol resolution"); return; }
                capture.create = (ZXCreateApplication)zxVisibleResolve(handles, "AXUIElementCreateApplication");
                NSString *createSymbol = @"AXUIElementCreateApplication";
                if (!capture.create) { capture.create = (ZXCreateApplication)zxVisibleResolve(handles, "_AXUIElementCreateAppElementWithPid"); createSymbol = @"_AXUIElementCreateAppElementWithPid"; }
                capture.diagnostics[@"createSymbol"] = createSymbol;
                if (!zxVisibleSymbol(capture, createSymbol, capture.create != NULL, 103, @"symbol-create")) return;
                capture.copyAttribute = (ZXCopyAttribute)zxVisibleResolve(handles, "AXUIElementCopyAttributeValue");
                if (!zxVisibleSymbol(capture, @"AXUIElementCopyAttributeValue", capture.copyAttribute != NULL, 104, @"symbol-copy")) return;
                capture.valueTypeID = (ZXValueTypeID)zxVisibleResolve(handles, "AXValueGetTypeID");
                if (!zxVisibleSymbol(capture, @"AXValueGetTypeID", capture.valueTypeID != NULL, 105, @"symbol-value-type-id")) return;
                capture.valueType = (ZXValueType)zxVisibleResolve(handles, "AXValueGetType");
                if (!zxVisibleSymbol(capture, @"AXValueGetType", capture.valueType != NULL, 106, @"symbol-value-type")) return;
                capture.valueGet = (ZXValueGet)zxVisibleResolve(handles, "AXValueGetValue");
                if (!zxVisibleSymbol(capture, @"AXValueGetValue", capture.valueGet != NULL, 107, @"symbol-value-get")) return;
                capture.requestingClient = (ZXSetRequestingClient)zxVisibleResolve(handles, "__AXSetRequestingClient");
                zxVisibleSymbol(capture, @"__AXSetRequestingClient", capture.requestingClient != NULL, 202, @"symbol-requesting-client");
                capture.associate = (ZXAssociatePID)zxVisibleResolve(handles, "_AXAddAssociatedPid");
                zxVisibleSymbol(capture, @"_AXAddAssociatedPid", capture.associate != NULL, 203, @"symbol-associate");
                capture.setTimeout = (ZXSetTimeout)zxVisibleResolve(handles, "AXUIElementSetMessagingTimeout");
                zxVisibleSymbol(capture, @"AXUIElementSetMessagingTimeout", capture.setTimeout != NULL, 204, @"symbol-timeout");
                capture.diagnostics[@"messagingTimeoutAvailable"] = @(capture.setTimeout != NULL);
                capture.stage = @"client-configure";
                if (!zxVisibleWithinBudget(capture)) { zxVisibleFail(capture, 108, @"client-configure", nil, nil, -1, @"Budget exhausted before AX client configuration"); return; }
                if (capture.associate) {
                    capture.associate(getpid(), capture.pid, 1); capture.associate(capture.pid, getpid(), 1);
                    capture.associate(getpid(), capture.pid, 0); capture.associate(capture.pid, getpid(), 0);
                }
                if (capture.requestingClient) capture.requestingClient(2);
                zxVisibleCheckpoint(capture, @"client-configure", @"ok", @{@"associateInvoked": @(capture.associate != NULL), @"requestingClientInvoked": @(capture.requestingClient != NULL)});
                capture.stage = @"application-create";
                if (!zxVisibleWithinBudget(capture)) { zxVisibleFail(capture, 108, @"application-create", nil, nil, -1, @"Budget exhausted before application creation"); return; }
                application = capture.create(capture.pid);
                if (!application) { zxVisibleFail(capture, 108, @"application-create", nil, nil, -1, @"C creation function returned NULL"); return; }
                CFTypeID elementType = CFGetTypeID(application);
                zxVisibleCheckpoint(capture, @"application-create", @"ok", @{@"elementTypeID": @(elementType)});
                visible = zxVisibleCopy(capture, application, 2095, -1, @"visible-copy-2095");
                if (capture.readBudgetSkipped) { zxVisibleFail(capture, 112, @"visible-budget-2095", @2095, nil, -1, @"Budget exhausted before 2095 query"); return; }
                if (!visible) { zxVisibleFail(capture, 110, @"visible-copy-2095", @2095, capture.axStatus, -1, @"2095 AX read failed or returned NULL"); return; }
                zxVisibleCheckpoint(capture, @"visible-copy-2095", @"ok", @{@"axStatus": capture.axStatus});
                if (CFGetTypeID(visible) != CFArrayGetTypeID()) {
                    zxVisibleIncrement(zxVisibleStats(capture, 2095), @"typeError");
                    capture.diagnostics[@"visibleCFTypeID"] = @(CFGetTypeID(visible));
                    zxVisibleFail(capture, 111, @"visible-type-2095", @2095, capture.axStatus, -1, @"2095 is not CFArray"); return;
                }
                NSUInteger length = (NSUInteger)CFArrayGetCount((CFArrayRef)visible);
                zxVisibleCheckpoint(capture, @"visible-type-2095", @"ok", @{@"count": @(length)});
                NSMutableDictionary *sourceCounts = [@{@"2095": @(length), @"3015": [NSNull null]} mutableCopy];
                capture.diagnostics[@"sourceCounts"] = sourceCounts;
                CFTypeRef other = zxVisibleCopy(capture, application, 3015, -1, @"count-copy-3015");
                @try {
                    if (capture.readBudgetSkipped) {
                        zxVisibleIssue(capture, 212, @"count-budget-3015", @3015, nil, -1, nil);
                        zxVisibleLimit(capture, @"budget", 230, @"node-budget");
                        zxVisibleCheckpoint(capture, @"count-budget-3015", @"partial", nil);
                    } else if (!other) {
                        zxVisibleIssue(capture, 210, @"count-copy-3015", @3015, capture.axStatus, -1, @{@"reason": @"AX error or NULL value"});
                        zxVisibleCheckpoint(capture, @"count-copy-3015", @"warning", @{@"axStatus": capture.axStatus});
                    } else if (CFGetTypeID(other) != CFArrayGetTypeID()) {
                        zxVisibleIncrement(zxVisibleStats(capture, 3015), @"typeError");
                        zxVisibleIssue(capture, 211, @"count-type-3015", @3015, capture.axStatus, -1, @{@"cfTypeID": @(CFGetTypeID(other))});
                        zxVisibleCheckpoint(capture, @"count-type-3015", @"warning", nil);
                    } else {
                        sourceCounts[@"3015"] = @(CFArrayGetCount((CFArrayRef)other));
                        zxVisibleCheckpoint(capture, @"count-type-3015", @"ok", @{@"count": sourceCounts[@"3015"]});
                    }
                } @finally { if (other) CFRelease(other); }
                NSMutableArray *children = [NSMutableArray array];
                for (NSUInteger index = 0; index < length; ++index) {
                    capture.nodeIndex = index;
                    capture.attribute = nil;
                    capture.axStatus = nil;
                    if (!zxVisibleWithinBudget(capture)) { zxVisibleLimit(capture, @"budget", 230, @"node-budget"); break; }
                    if (index >= zxMaxCandidates) { zxVisibleLimit(capture, @"candidate-limit", 231, @"candidate-limit"); break; }
                    ++capture.examined;
                    @autoreleasepool {
                        capture.stage = @"node-element-type";
                        CFTypeRef element = CFArrayGetValueAtIndex((CFArrayRef)visible, index);
                        if (!element || CFGetTypeID(element) != elementType) {
                            zxVisibleIssue(capture, 120, @"node-element-type", nil, nil, index,
                                @{@"cfTypeID": element ? (id)@(CFGetTypeID(element)) : (id)[NSNull null], @"expectedTypeID": @(elementType)});
                            ++capture.skipped;
                            continue;
                        }
                        NSDictionary *node = zxVisibleNodeC(capture, element, index);
                        if (node) [children addObject:node];
                        else if (capture.readBudgetSkipped || !zxVisibleWithinBudget(capture)) {
                            zxVisibleLimit(capture, @"budget", 230, @"node-budget"); break;
                        } else ++capture.skipped;
                    }
                }
                if (!zxVisibleWithinBudget(capture)) zxVisibleLimit(capture, @"budget", 230, @"node-budget");
                capture.nodeIndex = -1;
                capture.attribute = nil;
                capture.axStatus = nil;
                capture.diagnostics[@"examinedCount"] = @(capture.examined);
                capture.diagnostics[@"returnedCount"] = @(children.count);
                capture.diagnostics[@"skippedCount"] = @(capture.skipped);
                capture.diagnostics[@"captureMs"] = @((ZX_VISIBLE_NOW() - capture.captureStarted) * 1000);
                if (length && !children.count && !capture.limited) { zxVisibleFail(capture, 130, @"node-build", nil, nil, -1, @"Nonempty 2095 list produced no valid nodes"); return; }
                zxVisibleCheckpoint(capture, @"node-build", capture.limited ? @"partial" : @"ok", @{@"returned": @(children.count), @"skipped": @(capture.skipped)});
                snapshot = @{@"pid": @(capture.pid), @"mode": @"visible2095", @"backend": @"c-ax",
                    @"count": @(children.count + 1), @"candidateCount": @(children.count), @"sourceCounts": sourceCounts,
                    @"budgetMs": @(budget * 1000), @"limitReached": @(capture.limited), @"diagnostics": capture.diagnostics,
                    @"root": @{@"role": @"AXApplication", @"source": @"application", @"snapshotPath": @"root", @"children": children}};
            } @catch (NSException *exception) {
                zxVisibleFail(capture, 190, capture.stage, capture.attribute, capture.axStatus, capture.nodeIndex,
                    [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]);
            } @finally {
                if (visible) CFRelease(visible);
                if (application) CFRelease(application);
                for (NSValue *handle in handles) if (handle.pointerValue) dlclose(handle.pointerValue);
                if (frontboard) dlclose(frontboard);
            }
        };
        if ([NSThread isMainThread]) runCapture();
        else dispatch_sync(dispatch_get_main_queue(), runCapture);
        if (capture.failure) { if (error) *error = capture.failure; return nil; }
        @try {
            capture.stage = @"json-serialize";
            NSError *jsonError = nil;
            // Encode once before recording success, then include that checkpoint in the final payload.
            if (!ZX_VISIBLE_SERIALIZE(snapshot, &jsonError)) {
                zxVisibleFail(capture, 140, @"json-serialize", nil, nil, -1, jsonError.localizedDescription ?: @"JSON encoding failed");
            } else {
                zxVisibleCheckpoint(capture, @"json-serialize", @"ok", nil);
                capture.diagnostics[@"stage"] = @"complete";
                capture.diagnostics[@"elapsedMs"] = @((ZX_VISIBLE_NOW() - capture.started) * 1000);
                NSData *data = ZX_VISIBLE_SERIALIZE(snapshot, &jsonError);
                if (data) return data;
                zxVisibleFail(capture, 140, @"json-serialize", nil, nil, -1, jsonError.localizedDescription ?: @"Final JSON encoding failed");
            }
        } @catch (NSException *exception) {
            zxVisibleFail(capture, 190, @"json-serialize", nil, nil, -1,
                [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]);
        }
        if (error) *error = capture.failure;
        return nil;
    }
}
