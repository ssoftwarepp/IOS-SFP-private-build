#import "PointDeadline.h"
#import <mach/mach_time.h>
#import <float.h>
#import <limits.h>
#import <stdatomic.h>
#import <string.h>
#import <stdio.h>

// Task34-only implementation. It never assigns the legacy zx* function pointers.
static NSString *const zxPointMarker = @"AXPOINT-20261128-03/task34/v4";
typedef int32_t (*ZXPointHit)(CFTypeRef, CFTypeRef *, float, float);
typedef int32_t (*ZXPointHitWithParams)(CFTypeRef, CFTypeRef *, int32_t, float, float);
typedef CFTypeRef (*ZXPointCreateSystemWide)(void);
typedef CFTypeID (*ZXPointElementTypeID)(void);

typedef struct {
    ZXCreateApplication create;
    ZXPointHit hit;
    ZXPointHitWithParams hitWithParams;
    ZXPointCreateSystemWide createSystemWide;
    ZXCopyAttribute copy;
    ZXSetTimeout timeout;
    ZXSetRequestingClient client;
    ZXValueTypeID valueTypeID;
    ZXValueType valueType;
    ZXValueGet valueGet;
    ZXPointElementTypeID elementTypeID;
    ZXFocusedPID focused;
    ZXAssociatePID associate;
    const char *createName;
    const char *image;
    void *pinned[4];
    unsigned pinCount;
    int failure;
    char loaderError[160];
} ZXPointRuntime;

// One initialization retains every successfully opened image for process life.
// Never dlclose a pinned handle or RTLD_DEFAULT: late AX operations can retain pointers.
static ZXPointRuntime zxPointRuntime;
static dispatch_once_t zxPointRuntimeOnce;
static dispatch_once_t zxPointQueuesOnce;
static dispatch_queue_t zxPointSetupQueue;
static dispatch_queue_t zxPointCompletionQueue;
static dispatch_queue_t zxPointDeadlineQueue;
static atomic_bool zxPointOccupied = ATOMIC_VAR_INIT(false);

static uint64_t zxPointNow(void) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (uint64_t)(((__uint128_t)mach_continuous_time() * info.numer) / info.denom);
}
static void zxPointInit(void) {
    static const char *const images[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils"
    };
    ZXPointRuntime *r = &zxPointRuntime;
    BOOL sawCreate=NO, sawHit=NO, sawCopy=NO;
    for (unsigned i = 0; i < 4; ++i) {
        dlerror();
        void *handle = dlopen(images[i], RTLD_LAZY | RTLD_GLOBAL);
        if (!handle) {
            const char *failure = dlerror();
            if (failure && !r->loaderError[0]) {
                strncpy(r->loaderError, failure, sizeof(r->loaderError) - 1);
                r->loaderError[sizeof(r->loaderError) - 1] = 0;
            }
            continue;
        }
        r->pinned[r->pinCount++] = handle;
        if (i == 3) {
            r->focused = (ZXFocusedPID)dlsym(handle, "AXFrontBoardFocusedAppPID");
            continue;
        }
        if (!r->create || !r->hit || !r->copy) {
            ZXCreateApplication publicCreate = (ZXCreateApplication)dlsym(handle, "AXUIElementCreateApplication");
            ZXCreateApplication privateCreate = (ZXCreateApplication)dlsym(handle, "_AXUIElementCreateAppElementWithPid");
            ZXPointHit hit = (ZXPointHit)dlsym(handle, "AXUIElementCopyElementAtPosition");
            ZXCopyAttribute copy = (ZXCopyAttribute)dlsym(handle, "AXUIElementCopyAttributeValue");
            sawCreate |= publicCreate != NULL || privateCreate != NULL;
            sawHit |= hit != NULL; sawCopy |= copy != NULL;
            if (hit && copy && (publicCreate || privateCreate)) {
                r->image = images[i];
                r->create = publicCreate ?: privateCreate;
                r->createName = publicCreate ? "AXUIElementCreateApplication" : "_AXUIElementCreateAppElementWithPid";
                r->hit = hit;
                r->hitWithParams = (ZXPointHitWithParams)dlsym(handle, "AXUIElementCopyElementAtPositionWithParams");
                r->createSystemWide = (ZXPointCreateSystemWide)dlsym(handle, "AXUIElementCreateSystemWide");
                r->copy = copy;
                r->timeout = (ZXSetTimeout)dlsym(handle, "AXUIElementSetMessagingTimeout");
                r->client = (ZXSetRequestingClient)dlsym(handle, "__AXSetRequestingClient");
                r->valueTypeID = (ZXValueTypeID)dlsym(handle, "AXValueGetTypeID");
                r->valueType = (ZXValueType)dlsym(handle, "AXValueGetType");
                r->valueGet = (ZXValueGet)dlsym(handle, "AXValueGetValue");
                r->elementTypeID = (ZXPointElementTypeID)dlsym(handle, "AXUIElementGetTypeID");
                r->associate = (ZXAssociatePID)dlsym(handle, "_AXAddAssociatedPid");
            }
        }
    }
    if (!r->pinCount) r->failure = 3401;
    else if (!sawCreate) r->failure = 3402;
    else if (!sawHit) r->failure = 3403;
    else if (!sawCopy) r->failure = 3404;
    else if (!r->create) r->failure = 3402; // symbols exist, but never in one supported image
    else if (!r->timeout) r->failure = 3413;
}

@interface ZXPointContext : NSObject {
@public
    NSLock *lock;
    dispatch_semaphore_t wake;
    dispatch_source_t queueTimer;
    dispatch_source_t totalTimer;
    uint64_t start;
    BOOL running;
    BOOL claimed;
    BOOL abandoned;
    BOOL releasedPermit;
    BOOL inFlight;
    int code;
    int32_t axStatus;
    int32_t appHitStatus;
    int32_t appParamsStatus;
    int32_t systemHitStatus;
    int32_t systemParamsStatus;
    BOOL systemRootAvailable;
    BOOL systemRootTried;
    BOOL appParamsTried;
    NSString *hitMode;
    pid_t pid;
    CGPoint point;
    NSString *lastStage;
    NSDictionary *leaf;
    NSData *result;
    const ZXPointRuntime *runtime;
}
@end
@implementation ZXPointContext
- (instancetype)init {
    self = [super init];
    if (self) {
        lock = [NSLock new]; wake = dispatch_semaphore_create(0);
        axStatus = INT32_MIN; appHitStatus = INT32_MIN;
        appParamsStatus = INT32_MIN; systemHitStatus = INT32_MIN;
        systemParamsStatus = INT32_MIN;
        hitMode = @"none"; lastStage = @"created";
    }
    return self;
}
@end

static NSString *zxPointStage(int code) {
    switch (code) {
        case 0: return @"complete"; case 3400: return @"point-validate";
        case 3401: return @"runtime-load"; case 3402: return @"symbol-create";
        case 3403: return @"symbol-hit-test"; case 3404: return @"symbol-copy";
        case 3405: return @"foreground-pid"; case 3406: return @"application-create";
        case 3407: return @"native-hit-test"; case 3408: return @"hit-element";
        case 3409: return @"node-build"; case 3410: return @"json-serialize";
        case 3411: return @"queue-deadline"; case 3412: return @"request-deadline";
        case 3413: return @"messaging-timeout"; case 3414: return @"capture-busy";
        case 3415: return @"caller-thread"; case 3416: return @"native-exception";
        default: return @"protocol-size";
    }
}

static void zxPointClaim(ZXPointContext *c, int requested, NSData *value) {
    [c->lock lock];
    if (!c->claimed) {
        if (requested == 3411 && c->running) { [c->lock unlock]; return; }
        int deadline = zxPointDeadlineCode(c->start, zxPointNow(), c->running, NO);
        c->code = deadline ?: requested;
        c->result = c->code ? nil : value;
        c->claimed = YES; c->abandoned = c->code == 3411 || c->code == 3412;
        dispatch_semaphore_signal(c->wake);
    }
    [c->lock unlock];
}
static BOOL zxPointIsClaimed(ZXPointContext *c) {
    [c->lock lock]; BOOL done=c->claimed; [c->lock unlock]; return done;
}
static BOOL zxPointStillLive(ZXPointContext *c) {
    [c->lock lock];
    int deadline = zxPointDeadlineCode(c->start, zxPointNow(), c->running, YES);
    BOOL alive = !c->abandoned && !c->claimed && !deadline;
    [c->lock unlock];
    if (!alive && deadline) zxPointClaim(c, deadline, nil);
    return alive;
}
static BOOL zxPointSetTimeout(ZXPointContext *c, CFTypeRef e) {
    if (!zxPointStillLive(c)) return NO;
    float budget = zxPointTimeoutSeconds(c->start, zxPointNow());
    if (!budget) { zxPointClaim(c, 3412, nil); return NO; }
    if (!c->runtime->timeout || c->runtime->timeout(e, budget) != 0) {
        zxPointClaim(c, 3413, nil); return NO;
    }
    return zxPointStillLive(c);
}
static NSString *zxPointString(CFTypeRef raw, NSUInteger cap) {
    if (!raw) return nil;
    CFTypeID t = CFGetTypeID(raw);
    NSString *text = t == CFStringGetTypeID() ? (__bridge NSString *)raw :
        t == CFNumberGetTypeID() ? [(__bridge NSNumber *)raw stringValue] : nil;
    if (!text.length) return nil;
    NSMutableString *bounded = [NSMutableString string];
    for (NSUInteger index = 0; index < text.length;) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:index];
        NSString *piece = [text substringWithRange:range];
        if ([[bounded stringByAppendingString:piece] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > cap) break;
        [bounded appendString:piece]; index = NSMaxRange(range);
    }
    return [bounded copy];
}
static CFTypeRef zxPointAttribute(ZXPointContext *c, CFTypeRef element, CFStringRef key) {
    if (!zxPointSetTimeout(c, element)) return NULL;
    if (c->runtime->client) c->runtime->client(2);
    CFTypeRef value = NULL;
    @try {
        int32_t status = c->runtime->copy(element, key, &value);
        if (!zxPointStillLive(c) || status != 0) {
            if (value) { CFRelease(value); value=NULL; }
            return NULL;
        }
        CFTypeRef owned=value; value=NULL;
        return owned; // caller owns +1; even a nonzero status output was released above
    } @finally { if (value) CFRelease(value); }
}
static void zxPointAddText(ZXPointContext *c, CFTypeRef e, CFStringRef key,
                           NSString *field, NSMutableDictionary *leaf) {
    CFTypeRef raw = zxPointAttribute(c, e, key);
    @try {
        NSString *text = zxPointString(raw, 2048);
        if (text.length) leaf[field] = text;
    } @finally { if (raw) CFRelease(raw); }
}
static void zxPointAddPositiveID(ZXPointContext *c, CFTypeRef e, uint32_t attribute,
                                 NSString *field, NSMutableDictionary *leaf) {
    CFTypeRef raw = zxPointAttribute(c, e, (CFStringRef)(uintptr_t)attribute);
    @try {
        if (raw && CFGetTypeID(raw) == CFNumberGetTypeID()) {
            NSNumber *number = [(__bridge NSNumber *)raw copy];
            if (number.longLongValue > 0) leaf[field] = number;
        }
    } @finally { if (raw) CFRelease(raw); }
}
static NSDictionary *zxPointLeaf(ZXPointContext *c, CFTypeRef e) {
    NSMutableDictionary *node = [@{@"role":@"AXElement", @"children":@[]} mutableCopy];
    zxPointAddText(c, e, (CFStringRef)(uintptr_t)5019, @"identifier", node);
    if (!node[@"identifier"]) zxPointAddText(c, e, CFSTR("AXIdentifier"), @"identifier", node);
    zxPointAddText(c, e, (CFStringRef)(uintptr_t)2001, @"label", node);
    if (!node[@"label"]) zxPointAddText(c, e, CFSTR("AXLabel"), @"label", node);
    zxPointAddText(c, e, (CFStringRef)(uintptr_t)2006, @"value", node);
    zxPointAddText(c, e, (CFStringRef)(uintptr_t)5003, @"elementType", node);
    zxPointAddPositiveID(c, e, 2021, @"windowContextId", node);
    zxPointAddPositiveID(c, e, 2123, @"displayId", node);
    NSDictionary *fields = @{@"AXRole":@"role", @"AXSubrole":@"subrole", @"AXHelp":@"hint",
        @"AXDescription":@"description", @"AXTitle":@"title",
        @"AXEnabled":@"enabled", @"AXFocused":@"focused"};
    NSMutableArray *keys = [@[@"AXRole",@"AXSubrole",@"AXHelp",@"AXDescription",@"AXTitle",
                              @"AXEnabled",@"AXFocused"] mutableCopy];
    if ([node[@"elementType"] isEqualToString:@"WebAccessibilityObjectWrapper"])
        [keys addObjectsFromArray:@[@"AXRoleDescription",@"AXDOMIdentifier",@"AXURL",@"AXPlaceholderValue"]];
    for (NSString *key in keys) {
        if (!zxPointStillLive(c)) return nil;
        CFTypeRef raw = zxPointAttribute(c, e, (__bridge CFStringRef)key);
        @try {
            if ([key isEqualToString:@"AXEnabled"] || [key isEqualToString:@"AXFocused"]) {
                if (raw && (CFGetTypeID(raw) == CFBooleanGetTypeID() || CFGetTypeID(raw) == CFNumberGetTypeID()))
                    node[fields[key]] = @([(__bridge NSNumber *)raw boolValue]);
            } else {
                NSString *text = zxPointString(raw, 2048);
                if (raw && !text && CFGetTypeID(raw) == CFURLGetTypeID())
                    text = zxPointString((__bridge CFTypeRef)[(__bridge NSURL *)raw absoluteString], 2048);
                if (text.length) node[fields[key] ?: key] = text;
            }
        } @finally { if (raw) CFRelease(raw); }
    }
    CFTypeRef frame = zxPointAttribute(c, e, (CFStringRef)(uintptr_t)2003);
    if (!frame) frame = zxPointAttribute(c, e, CFSTR("AXFrame"));
    @try {
        CGRect rect = CGRectZero;
        if (frame && c->runtime->valueTypeID && c->runtime->valueType && c->runtime->valueGet &&
            CFGetTypeID(frame) == c->runtime->valueTypeID() && c->runtime->valueType(frame) == 3 &&
            c->runtime->valueGet(frame, 3, &rect) && isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
            isfinite(rect.size.width) && isfinite(rect.size.height))
            node[@"frame"] = @{@"x":@(rect.origin.x),@"y":@(rect.origin.y),
                                @"width":@(rect.size.width),@"height":@(rect.size.height)};
    } @finally { if (frame) CFRelease(frame); }
    return zxPointStillLive(c) ? [node copy] : nil;
}

static void zxPointCapture(ZXPointContext *c) {
    [c->lock lock];
    int deadline = zxPointDeadlineCode(c->start, zxPointNow(), NO, NO);
    if (deadline || c->claimed || c->abandoned) {
        [c->lock unlock]; if (deadline) zxPointClaim(c, deadline, nil); return;
    }
    c->running = YES; c->inFlight = YES; c->lastStage = @"foreground-pid";
    [c->lock unlock];
    CFTypeRef app = NULL;
    CFTypeRef systemRoot = NULL;
    CFTypeRef element = NULL;
    @try {
        const ZXPointRuntime *r = c->runtime;
        pid_t selectedPID = r->focused ? r->focused() : 0;
        [c->lock lock]; c->pid=selectedPID; [c->lock unlock];
        if (!zxIsLivePID(c->pid)) {
            id foreground = getFrontMostApplication();
            [c->lock lock]; c->pid=zxPIDFromObject(foreground); [c->lock unlock];
            if (!zxIsLivePID(c->pid) && [foreground respondsToSelector:@selector(processState)]) {
                id state = ((id (*)(id,SEL))objc_msgSend)(foreground,@selector(processState));
                pid_t statePID = zxPIDFromObject(state);
                [c->lock lock]; c->pid=statePID; [c->lock unlock];
            }
            NSString *bundle = [foreground respondsToSelector:@selector(bundleIdentifier)] ?
                ((id (*)(id,SEL))objc_msgSend)(foreground,@selector(bundleIdentifier)) : nil;
            if (!zxIsLivePID(c->pid) && (!foreground || [bundle isEqualToString:@"com.apple.springboard"])) {
                [c->lock lock]; c->pid=getpid(); [c->lock unlock];
            }
        }
        if (!zxPointStillLive(c)) return;
        if (!zxIsLivePID(c->pid)) { zxPointClaim(c,3405,nil); return; }
        if (r->associate) {
            r->associate(getpid(),c->pid,1); r->associate(c->pid,getpid(),1);
            r->associate(getpid(),c->pid,0); r->associate(c->pid,getpid(),0);
        }
        if (!zxPointStillLive(c)) return;
        [c->lock lock]; c->lastStage=@"application-create"; [c->lock unlock];
        app = r->create(c->pid);
        if (!zxPointStillLive(c)) return;
        if (!app) { zxPointClaim(c,3406,nil); return; }
        if (r->elementTypeID && CFGetTypeID(app) != r->elementTypeID()) { zxPointClaim(c,3409,nil); return; }
        [c->lock lock]; c->lastStage=@"native-hit-test"; [c->lock unlock];
        if (!zxPointSetTimeout(c,app)) return;
        if (r->client) r->client(2);
        if (!zxPointStillLive(c)) return;
        [c->lock lock]; c->hitMode=@"application-direct"; [c->lock unlock];
        int32_t hitStatus=r->hit(app,&element,(float)c->point.x,(float)c->point.y);
        [c->lock lock]; c->appHitStatus=hitStatus; c->axStatus=hitStatus; [c->lock unlock];
        if (!zxPointStillLive(c)) return;
        if (hitStatus == -25202 && r->hitWithParams) {
            if (element) { CFRelease(element); element=NULL; }
            if (r->createSystemWide) {
                systemRoot = r->createSystemWide();
                [c->lock lock]; c->systemRootAvailable=systemRoot != NULL; [c->lock unlock];
            }
            if (systemRoot) {
                if (r->elementTypeID && CFGetTypeID(systemRoot) != r->elementTypeID()) {
                    zxPointClaim(c,3409,nil); return;
                }
                if (!zxPointSetTimeout(c,systemRoot)) return;
                if (r->client) r->client(2);
                if (!zxPointStillLive(c)) return;
                [c->lock lock]; c->systemRootTried=YES; c->hitMode=@"systemwide-with-params"; [c->lock unlock];
                hitStatus=r->hitWithParams(systemRoot,&element,1,(float)c->point.x,(float)c->point.y);
                [c->lock lock]; c->systemParamsStatus=hitStatus; c->axStatus=hitStatus; [c->lock unlock];
                if (!zxPointStillLive(c)) return;
            }
            if (hitStatus != 0 || !element) {
                if (element) { CFRelease(element); element=NULL; }
                if (!zxPointSetTimeout(c,app)) return;
                if (r->client) r->client(2);
                if (!zxPointStillLive(c)) return;
                [c->lock lock]; c->appParamsTried=YES; c->hitMode=@"application-with-params"; [c->lock unlock];
                hitStatus=r->hitWithParams(app,&element,1,(float)c->point.x,(float)c->point.y);
                [c->lock lock]; c->appParamsStatus=hitStatus; c->axStatus=hitStatus; [c->lock unlock];
                if (!zxPointStillLive(c)) return;
            }
        }
        if (hitStatus != 0) { zxPointClaim(c,3407,nil); return; }
        if (!element) { zxPointClaim(c,3408,nil); return; }
        if (r->elementTypeID && CFGetTypeID(element) != r->elementTypeID()) { zxPointClaim(c,3409,nil); return; }
        [c->lock lock]; c->lastStage=@"node-build"; [c->lock unlock];
        c->leaf = zxPointLeaf(c,element);
        if (!zxPointStillLive(c)) return;
        if (!c->leaf) { zxPointClaim(c,3409,nil); return; }
    } @catch (NSException *exception) {
        [c->lock lock]; c->lastStage=@"native-exception"; [c->lock unlock];
        zxPointClaim(c,3416,nil);
    } @finally {
        if (element) { CFRelease(element); element=NULL; }
        if (systemRoot) { CFRelease(systemRoot); systemRoot=NULL; }
        if (app) { CFRelease(app); app=NULL; }
    }
}

// The fallback uses only fixed ASCII enum tokens and bounded decimal integers.
// It does not invoke JSON serialization after an encoder fault.
static NSString *zxPointASCIIErrorJSON(int code, int32_t status, pid_t pid,
                                       NSString *lastStage) {
    NSString *stage = zxPointStage(code);
    NSSet *allowed = [NSSet setWithArray:@[@"created",@"queued",@"unknown",@"point-validate",
        @"runtime-load",@"symbol-create",@"symbol-hit-test",@"symbol-copy",@"foreground-pid",
        @"application-create",@"native-hit-test",@"hit-element",@"node-build",@"json-serialize",
        @"queue-deadline",@"request-deadline",@"messaging-timeout",@"capture-busy",@"caller-thread",
        @"native-exception",@"protocol-size",@"complete"]];
    NSString *last = [allowed containsObject:lastStage] ? lastStage : @"unknown";
    const char *statusValue = status == INT32_MIN ? "null" : NULL;
    char bytes[512];
    int count;
    if (statusValue)
        count = snprintf(bytes, sizeof(bytes), "{\"schemaVersion\":1,\"task\":34,\"stage\":\"%s\",\"errorCode\":%d,\"pid\":%d,\"axStatus\":%s,\"lastStage\":\"%s\",\"truncated\":true}",
            stage.UTF8String,code,(int)pid,statusValue,last.UTF8String);
    else
        count = snprintf(bytes, sizeof(bytes), "{\"schemaVersion\":1,\"task\":34,\"stage\":\"%s\",\"errorCode\":%d,\"pid\":%d,\"axStatus\":%d,\"lastStage\":\"%s\",\"truncated\":true}",
            stage.UTF8String,code,(int)pid,(int)status,last.UTF8String);
    // Fixed tokens <= 32 bytes and three int32 decimals keep count below 256.
    return [[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSASCIIStringEncoding];
}
static NSData *zxPointEncodeDiagnostics(NSDictionary *details) {
#if defined(ZX_POINT_TEST)
    extern int zxPointEncoderFault;
    extern unsigned zxPointEncoderCalls;
    ++zxPointEncoderCalls;
    if (zxPointEncoderFault == 1) return nil;
    if (zxPointEncoderFault == 2) [NSException raise:@"FixtureEncoderFailure" format:@"injected encoder fault"];
    if (zxPointEncoderFault == 3) return [NSMutableData dataWithLength:32769];
#endif
    return [NSJSONSerialization dataWithJSONObject:details options:0 error:nil];
}
static NSString *zxPointErrorDescriptionDetails(int code, int32_t status, pid_t pid,
                                         NSString *lastStage, BOOL inFlight, uint64_t elapsed,
                                         const ZXPointRuntime *r, NSDictionary *attempts) {
    NSString *stage = zxPointStage(code);
    NSString *statusText = status == INT32_MIN ? @"null" : [NSString stringWithFormat:@"%d",status];
    NSMutableDictionary *details = [@{@"schemaVersion":@1,@"task":@34,@"buildMarker":zxPointMarker,
        @"stage":stage,@"errorCode":@(code),@"pid":@(pid),
        @"axStatus":status == INT32_MIN ? (id)[NSNull null] : @(status),
        @"lastStage":lastStage ?: @"unknown",@"elapsedMs":@(elapsed / 1000000ULL),
        @"inFlightAtReturn":@(inFlight),@"truncated":@NO} mutableCopy];
    if (r && r->image) details[@"runtimeImage"] = [NSString stringWithUTF8String:r->image];
    if (r && r->createName) details[@"createSymbol"] = [NSString stringWithUTF8String:r->createName];
    if (r && r->loaderError[0]) details[@"loaderError"] = zxPointString((__bridge CFTypeRef)[NSString stringWithUTF8String:r->loaderError],512);
    if (attempts) [details addEntriesFromDictionary:attempts];
    NSData *encoded = nil;
    @try { encoded = zxPointEncodeDiagnostics(details); }
    @catch (NSException *exception) { encoded = nil; }
    NSString *json = encoded.length && encoded.length <= 32768 ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
    if (!json) json = zxPointASCIIErrorJSON(code,status,pid,lastStage);
    json = [[[[json stringByReplacingOccurrencesOfString:@";" withString:@"\\u003B"]
             stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
             stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
             stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    json = [json stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    if ([json lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 32768)
        json = zxPointASCIIErrorJSON(code,status,pid,lastStage);
    return [NSString stringWithFormat:@"%@ stage=%@ code=%d axStatus=%@ diagnostics=%@",
            zxPointMarker,stage,code,statusText,json];
}
static NSString *zxPointErrorDescription(int code, int32_t status, pid_t pid,
    NSString *stage, BOOL inFlight, uint64_t elapsed, const ZXPointRuntime *r) {
    return zxPointErrorDescriptionDetails(code,status,pid,stage,inFlight,elapsed,r,nil);
}
static NSDictionary *zxPointAttemptsLocked(ZXPointContext *c) {
    return @{@"applicationHitStatus": c->appHitStatus == INT32_MIN ? (id)[NSNull null] : @(c->appHitStatus),
        @"applicationWithParamsStatus": c->appParamsStatus == INT32_MIN ? (id)[NSNull null] : @(c->appParamsStatus),
        @"systemHitStatus": c->systemHitStatus == INT32_MIN ? (id)[NSNull null] : @(c->systemHitStatus),
        @"systemWithParamsStatus": c->systemParamsStatus == INT32_MIN ? (id)[NSNull null] : @(c->systemParamsStatus),
        @"runtimeWithParamsSymbol": @(c->runtime && c->runtime->hitWithParams != NULL),
        @"systemRootSymbol": @(c->runtime && c->runtime->createSystemWide != NULL),
        @"systemRootAvailable": @(c->systemRootAvailable), @"systemRootTried": @(c->systemRootTried),
        @"applicationWithParamsTried": @(c->appParamsTried),
        @"systemWithParamsTried": @(c->systemRootTried),
        @"hitRoot": c->appParamsTried ? @"application" : (c->systemRootTried ? @"system-wide" : @"application"),
        @"hitMode": c->hitMode ?: @"none"};
}
static NSError *zxPointError(int code, int32_t status, pid_t pid, NSString *stage,
                             BOOL inFlight, uint64_t elapsed, const ZXPointRuntime *r) {
    return [NSError errorWithDomain:@"ZXTouchAXTask34" code:code userInfo:@{
        NSLocalizedDescriptionKey:zxPointErrorDescription(code,status,pid,stage,inFlight,elapsed,r)}];
}
static void zxPointFinish(ZXPointContext *c) {
    [c->lock lock]; c->inFlight = NO;
    if (!c->releasedPermit) {
        c->releasedPermit = YES;
        atomic_store_explicit(&zxPointOccupied,false,memory_order_release);
    }
    [c->lock unlock];
}

NSData *zxCopyAccessibilityElementAtPoint(CGPoint point, NSError **error) {
    uint64_t start = zxPointNow();
    if (!isfinite(point.x) || !isfinite(point.y) || point.x < 0 || point.y < 0 ||
        point.x > FLT_MAX || point.y > FLT_MAX) {
        if (error) *error = zxPointError(3400,INT32_MIN,0,@"point-validate",NO,0,NULL);
        return nil;
    }
    if ([NSThread isMainThread]) {
        if (error) *error = zxPointError(3415,INT32_MIN,0,@"caller-thread",NO,zxPointNow()-start,NULL);
        return nil;
    }
    bool vacant = false;
    if (!atomic_compare_exchange_strong_explicit(&zxPointOccupied,&vacant,true,memory_order_acq_rel,memory_order_acquire)) {
        if (error) *error = zxPointError(3414,INT32_MIN,0,@"capture-busy",YES,zxPointNow()-start,NULL);
        return nil;
    }
    ZXPointContext *c = [ZXPointContext new]; c->start=start; c->point=point;
    dispatch_once(&zxPointQueuesOnce, ^{
        zxPointSetupQueue = dispatch_queue_create("com.zxtouch.task34.setup", DISPATCH_QUEUE_SERIAL);
        zxPointCompletionQueue = dispatch_queue_create("com.zxtouch.task34.complete", DISPATCH_QUEUE_SERIAL);
        zxPointDeadlineQueue = dispatch_queue_create("com.zxtouch.task34.deadline", DISPATCH_QUEUE_SERIAL);
    });
    __weak ZXPointContext *weak = c;
    c->queueTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,zxPointDeadlineQueue);
    uint64_t elapsed=zxPointNow()-start;
    dispatch_source_set_timer(c->queueTimer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(elapsed<zxPointQueueNS ? zxPointQueueNS-elapsed : 0)),DISPATCH_TIME_FOREVER,1000000);
    dispatch_source_set_event_handler(c->queueTimer, ^{
        ZXPointContext *strong=weak;
        if (strong) {
            [strong->lock lock]; BOOL preRunning=!strong->running; [strong->lock unlock];
            if(preRunning) zxPointClaim(strong,3411,nil);
        }
    });
    dispatch_resume(c->queueTimer);
    c->totalTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,zxPointDeadlineQueue);
    elapsed=zxPointNow()-start;
    dispatch_source_set_timer(c->totalTimer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(elapsed<zxPointTotalNS ? zxPointTotalNS-elapsed : 0)),DISPATCH_TIME_FOREVER,1000000);
    dispatch_source_set_event_handler(c->totalTimer, ^{ ZXPointContext *strong=weak; if(strong) zxPointClaim(strong,3412,nil); });
    dispatch_resume(c->totalTimer);
    dispatch_async(zxPointSetupQueue, ^{
        BOOL mainSubmitted=NO;
        @try {
            [c->lock lock]; c->inFlight=YES; c->lastStage=@"runtime-load"; [c->lock unlock];
            if (!zxPointStillLive(c)) return;
            dispatch_once(&zxPointRuntimeOnce, ^{ zxPointInit(); });
            [c->lock lock]; c->runtime=&zxPointRuntime; [c->lock unlock];
            if (!zxPointStillLive(c)) return;
            if (c->runtime->failure) { zxPointClaim(c,c->runtime->failure,nil); return; }
            [c->lock lock]; c->lastStage=@"queued"; [c->lock unlock];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL completionSubmitted=NO;
                @try {
                    zxPointCapture(c);
                    if (!zxPointStillLive(c) || !c->leaf) {
                        if (!zxPointIsClaimed(c)) zxPointClaim(c,3409,nil);
                        return;
                    }
                    dispatch_async(zxPointCompletionQueue, ^{
                        @try {
                            if (zxPointStillLive(c)) {
                                [c->lock lock]; c->lastStage=@"json-serialize"; [c->lock unlock];
                                [c->lock lock]; NSMutableDictionary *attempts=[zxPointAttemptsLocked(c) mutableCopy]; [c->lock unlock];
                                attempts[@"stage"]=@"complete"; attempts[@"errorCode"]=@0;
                                NSDictionary *payload=@{@"pid":@(c->pid),@"x":@(c->point.x),@"y":@(c->point.y),
                                    @"element":c->leaf,@"buildMarker":zxPointMarker,
                                    @"diagnostics":attempts};
                                NSData *body=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                                zxPointClaim(c,body.length && body.length<=65536 ? 0 : (body ? 3417 : 3410),body);
                            }
                        } @catch(NSException *exception) { zxPointClaim(c,3416,nil); }
                        @finally { zxPointFinish(c); }
                    });
                    completionSubmitted=YES;
                } @catch(NSException *exception) { zxPointClaim(c,3416,nil); }
                @finally { if (!completionSubmitted) zxPointFinish(c); }
            });
            mainSubmitted=YES;
        } @catch(NSException *exception) { zxPointClaim(c,3416,nil); }
        @finally { if (!mainSubmitted) zxPointFinish(c); }
    });
    uint64_t now=zxPointNow();
    uint64_t remaining=now >= start && now-start < zxPointTotalNS ? zxPointTotalNS-(now-start) : 0;
    dispatch_time_t until=dispatch_time(DISPATCH_TIME_NOW,(int64_t)remaining);
    dispatch_semaphore_wait(c->wake,until);
    zxPointClaim(c,3412,nil); // on timeout; if already claimed preserves exactly one outcome
    [c->lock lock];
    int code=c->code; NSData *result=c->result;
    int32_t raw=c->axStatus; pid_t pid=c->pid;
    BOOL inFlight=c->inFlight || !c->releasedPermit;
    NSString *stage=[c->lastStage copy]; const ZXPointRuntime *runtime=c->runtime;
    NSDictionary *attempts=zxPointAttemptsLocked(c);
    [c->lock unlock];
    if (c->queueTimer) { dispatch_source_cancel(c->queueTimer); c->queueTimer=nil; }
    if (c->totalTimer) { dispatch_source_cancel(c->totalTimer); c->totalTimer=nil; }
    if (code && error) *error=[NSError errorWithDomain:@"ZXTouchAXTask34" code:code userInfo:@{
        NSLocalizedDescriptionKey:zxPointErrorDescriptionDetails(code,raw,pid,stage,inFlight,zxPointNow()-start,runtime,attempts)}];
    return code ? nil : result;
}
