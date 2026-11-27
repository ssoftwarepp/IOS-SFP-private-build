// macOS native fixture for the exact production Task34 leaf/ASCII fallback.
// Compile under the next checkpoint with Foundation/CoreGraphics and -fobjc-arc.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#include <assert.h>
#include <stdint.h>

typedef CFTypeRef (*ZXCreateApplication)(pid_t);
typedef int32_t (*ZXCopyAttribute)(CFTypeRef, CFStringRef, CFTypeRef *);
typedef int32_t (*ZXSetTimeout)(CFTypeRef, float);
typedef CFTypeID (*ZXValueTypeID)(void);
typedef int32_t (*ZXValueType)(CFTypeRef);
typedef Boolean (*ZXValueGet)(CFTypeRef, int32_t, void *);
typedef pid_t (*ZXFocusedPID)(void);
typedef void (*ZXAssociatePID)(pid_t,pid_t,int);
typedef void (*ZXSetRequestingClient)(uint32_t);
static BOOL zxIsLivePID(pid_t pid) { return pid > 0; }
static pid_t zxPIDFromObject(id object) { (void)object; return getpid(); }
static id getFrontMostApplication(void) { return nil; }
#define ZX_POINT_TEST 1
int zxPointEncoderFault=0;
unsigned zxPointEncoderCalls=0;
#include "../../pccontrol/PointCapture.inc"

static int32_t fixtureTimeout(CFTypeRef element,float seconds) {
    (void)element; return seconds > 0 ? 0 : -1;
}
static int fixtureVariant=0;
static int32_t fixtureCopy(CFTypeRef element,CFStringRef key,CFTypeRef *out) {
    (void)element;
    uintptr_t raw=(uintptr_t)key;
    if (raw == 5019) *out=CFRetain(fixtureVariant ? CFSTR("switch-id") : CFSTR("button-id"));
    else if (raw == 2001) *out=CFRetain(fixtureVariant ? CFSTR("切换") : CFSTR("中文按钮"));
    else if (raw == 2006) *out=CFRetain(CFSTR("42"));
    else if (raw == 5003) *out=CFRetain(CFSTR("AXNativeButton"));
    else if (raw == 2021 || raw == 2123) {
        int64_t number=raw == 2021 ? (fixtureVariant ? 92 : 91) : (fixtureVariant ? 3 : 2);
        *out=CFNumberCreate(kCFAllocatorDefault,kCFNumberSInt64Type,&number);
    } else if (raw < 65536) *out=NULL; // numeric AX IDs are not CFString objects
    else if (CFEqual(key,CFSTR("AXRole"))) *out=CFRetain(fixtureVariant ? CFSTR("AXSwitch") : CFSTR("AXButton"));
    else if (CFEqual(key,CFSTR("AXSubrole"))) *out=CFRetain(CFSTR("AXCloseButton"));
    else if (CFEqual(key,CFSTR("AXHelp"))) *out=CFRetain(CFSTR("Close"));
    else if (CFEqual(key,CFSTR("AXDescription"))) *out=CFRetain(CFSTR("Description"));
    else if (CFEqual(key,CFSTR("AXTitle"))) *out=CFRetain(CFSTR("Title"));
    else if (CFEqual(key,CFSTR("AXEnabled"))) *out=CFRetain(kCFBooleanTrue);
    else if (CFEqual(key,CFSTR("AXFocused"))) *out=CFRetain(kCFBooleanFalse);
    else *out=NULL;
    return *out ? 0 : -25212;
}

int main(void) {
    @autoreleasepool {
        ZXPointRuntime table={}; table.copy=fixtureCopy; table.timeout=fixtureTimeout;
        ZXPointContext *context=[ZXPointContext new];
        context->runtime=&table;
        context->start=zxPointNow(); context->running=YES;
        NSDictionary *leaf=zxPointLeaf(context,CFSTR("synthetic element"));
        assert([leaf[@"role"] isEqual:@"AXButton"]);
        assert([leaf[@"subrole"] isEqual:@"AXCloseButton"]);
        assert([leaf[@"hint"] isEqual:@"Close"]);
        assert([leaf[@"description"] isEqual:@"Description"]);
        assert([leaf[@"title"] isEqual:@"Title"]);
        assert([leaf[@"label"] isEqual:@"中文按钮"]);
        assert([leaf[@"identifier"] isEqual:@"button-id"]);
        assert([leaf[@"windowContextId"] intValue] == 91);
        assert([leaf[@"displayId"] intValue] == 2);
        assert([leaf[@"enabled"] boolValue]);
        assert(![leaf[@"focused"] boolValue]);
        assert([leaf[@"children"] count] == 0);
        fixtureVariant=1;
        ZXPointContext *other=[ZXPointContext new];
        other->runtime=&table;
        other->start=zxPointNow(); other->running=YES;
        NSDictionary *switchLeaf=zxPointLeaf(other,CFSTR("second direct element"));
        assert([switchLeaf[@"role"] isEqual:@"AXSwitch"]);
        assert([switchLeaf[@"label"] isEqual:@"切换"]);
        assert([switchLeaf[@"identifier"] isEqual:@"switch-id"]);
        assert([switchLeaf[@"windowContextId"] intValue] == 92);
        assert([switchLeaf[@"displayId"] intValue] == 3);
        for (int fault=1;fault<=3;++fault) {
            zxPointEncoderFault=fault; zxPointEncoderCalls=0;
            NSString *description=zxPointErrorDescription(3407,-25212,42,@"native-hit-test",YES,5000000ULL,&table);
            assert(zxPointEncoderCalls == 1);
            NSRange marker=[description rangeOfString:@"diagnostics="];
            assert(marker.location != NSNotFound);
            NSString *json=[description substringFromIndex:NSMaxRange(marker)];
            NSData *bytes=[json dataUsingEncoding:NSUTF8StringEncoding];
            assert(bytes.length <= 32768);
            NSDictionary *payload=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
            assert([payload[@"schemaVersion"] intValue] == 1);
            assert([payload[@"task"] intValue] == 34);
            assert([payload[@"stage"] isEqual:@"native-hit-test"]);
            assert([payload[@"lastStage"] isEqual:@"native-hit-test"]);
            assert([payload[@"errorCode"] intValue] == 3407);
            assert([payload[@"pid"] intValue] == 42);
            assert([payload[@"axStatus"] intValue] == -25212);
            assert([payload[@"truncated"] boolValue]);
        }
        NSString *emptyStatus=zxPointASCIIErrorJSON(3411,INT32_MIN,0,@"runtime-load");
        NSDictionary *emptyPayload=[NSJSONSerialization JSONObjectWithData:
            [emptyStatus dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        assert(emptyPayload[@"axStatus"] == [NSNull null]);
        assert([emptyPayload[@"errorCode"] intValue] == 3411);
        assert([emptyPayload[@"lastStage"] isEqual:@"runtime-load"]);
    }
    return 0;
}
