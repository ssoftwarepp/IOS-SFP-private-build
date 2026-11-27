#include "Task.h"
#include <roothide.h>
#include "Touch.h"
#include <mach/mach_time.h>
#include "ColorPicker.h"
#include "ScreenMatch.h"
#include "Process.h"
#include "AlertBox.h"
#include "Record.h"
#include "Play.h"
#include "SocketServer.h"
#include "Toast.h"
#include "Common.h"
#include "UIKeyboard.h"
#include "DeviceInfo.h"
#include "TouchIndicator/TouchIndicatorWindow.h"
#import <mach/mach.h>
#import <dlfcn.h>
#import <signal.h>
#import <errno.h>
#include <Foundation/NSDistributedNotificationCenter.h>
#include <TextRecognization/TextRecognizer.h>
#include "UpdateCache.h"
#include "Screen.h"
#include "Runner.h"
#include "AccessibilityTree.h"
#include "MaskedTemplateMatch.h"
#import "ScriptSettings.h"

extern CFRunLoopRef recordRunLoop;

static void zxReplyJSON(id object, CFWriteStreamRef stream) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!body) {
        notifyClient((UInt8 *)"-1;;Unable to encode response\r\n", stream);
        return;
    }
    NSData *header = [[NSString stringWithFormat:@"0;;application/json;;%lu\r\n",
        (unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding];
    if (notifyClientData((const UInt8 *)header.bytes, (CFIndex)header.length, stream) == 0)
        notifyClientData((const UInt8 *)body.bytes, (CFIndex)body.length, stream);
}

static BOOL zxAccessPasteboard(void (^operation)(void)) {
    if ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 16) {
        static dispatch_queue_t queue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ queue = dispatch_queue_create("com.zjx.zxtouch.pasteboard", DISPATCH_QUEUE_SERIAL); });
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        dispatch_async(queue, ^{ operation(); dispatch_semaphore_signal(finished); });
        return dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    }
    if ([NSThread isMainThread]) operation();
    else dispatch_sync(dispatch_get_main_queue(), operation);
    return YES;
}

static NSString *zxBundleIDFromRequest(UInt8 *data) {
    NSString *identifier = [NSString stringWithUTF8String:(const char *)data];
    if (!identifier.length || [identifier rangeOfString:@";;"].location != NSNotFound ||
        [identifier rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    return identifier;
}

static BOOL zxSendKeyEvent(IOHIDEventSystemClientRef client, uint16_t page, uint16_t usage, BOOL down) {
    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                        page, usage, down, 0);
    if (!event) return NO;
    IOHIDEventSetIntegerValue(event, 4, 1);
    IOHIDEventSetSenderID(event, 0x8000000817319372ULL);
    IOHIDEventSystemClientDispatchEvent(client, event);
    CFRelease(event);
    return YES;
}

static BOOL zxPressKey(NSString *key, NSUInteger durationMs) {
    static dispatch_queue_t keyQueue;
    static IOHIDEventSystemClientRef hidClient;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keyQueue = dispatch_queue_create("com.zjx.zxtouch.keys", DISPATCH_QUEUE_SERIAL);
        hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    });
    NSDictionary<NSString *, NSNumber *> *keys = @{
        @"enter": @40, @"return": @40, @"tab": @43, @"delete": @76, @"del": @76,
        @"backspace": @42, @"space": @44, @"up": @82, @"down": @81,
        @"left": @80, @"right": @79, @"home": @64, @"power": @48
    };
    NSString *name = key.lowercaseString;
    NSNumber *usage = keys[name];
    if (!usage || !hidClient) return NO;
    uint16_t page = ([name isEqualToString:@"home"] || [name isEqualToString:@"power"]) ? 0x0c : 0x07;
    __block BOOL success = NO;
    dispatch_sync(keyQueue, ^{
        BOOL pressed = zxSendKeyEvent(hidClient, page, usage.unsignedShortValue, YES);
        if (pressed) usleep((useconds_t)(durationMs * 1000));
        BOOL released = pressed && zxSendKeyEvent(hidClient, page, usage.unsignedShortValue, NO);
        success = pressed && released;
    });
    return success;
}

static void zxReplyError(NSError *error, CFWriteStreamRef stream) {
    NSString *detail = error.localizedDescription ?: @"Application operation failed";
    NSString *reply = [NSString stringWithFormat:@"-1;;%@\r\n", detail];
    notifyClient((UInt8 *)reply.UTF8String, stream);
}

/*
get task type
*/
static int getTaskType(UInt8* dataArray)
{
	int taskType = 0;
	for (int i = 0; i <= 1; i++)
	{
		taskType += (dataArray[i] - '0')*pow(10, 1-i);
	}
	return taskType;
}

/**
Process Task
*/
void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    //NSLog(@"### com.zjx.springboard: task type: %d. Data: %s", getTaskType(buff), buff);
    UInt8 *eventData = buff + 0x2;
    int taskType = getTaskType(buff);

    //for touching
    if (taskType == TASK_PERFORM_TOUCH)
    {
        @autoreleasepool{
            performTouchFromRawData(eventData);
        }
    }
    else if (taskType == TASK_PROCESS_BRING_FOREGROUND) //bring to foreground
    {
        @autoreleasepool{   
            switchProcessForegroundFromRawData(eventData);
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_SHOW_ALERT_BOX)
    {
        @autoreleasepool{   
            NSError *err = nil;
            showAlertBoxFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_USLEEP)
    {
        if (writeStreamRef)
        {
            int usleepTime = 0;
            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
            notifyClient((UInt8*)"0;;Sleep ends\r\n", writeStreamRef); 
        }
        else
        {
            int usleepTime = 0;

            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
        }

    }
    else if (taskType == TASK_RUN_SHELL)
    {
        @autoreleasepool{
            system2([[NSString stringWithFormat:@"%@ -c \"%s\"", jbroot(@"/bin/sh"), eventData] UTF8String], NULL, NULL);
            notifyClient((UInt8*)"0\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_START)
    {
        @autoreleasepool {
            NSError *err = nil;
            startRecording(writeStreamRef, &err);    
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_STOP)
    {
        @autoreleasepool {
            stopRecording(); 
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT)
    {
        @autoreleasepool {
            NSError *err = nil;
            playScript((UInt8*)eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT_FORCE_STOP)
    {
        @autoreleasepool {
            NSError *err = nil;
            stopScriptPlaying(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEMPLATE_MATCH)
    {
        @autoreleasepool {
            NSError *err = nil;
            CGRect result = screenMatchFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%.2f;;%.2f;;%.2f;;%.2f\r\n",
                    result.origin.x, result.origin.y, result.size.width, result.size.height] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SHOW_TOAST)
    {
        @autoreleasepool {
            NSError *err = nil;
            showToastFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_PICKER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSDictionary *result = getRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@;;%@;;%@\r\n",
                    result[@"red"], result[@"green"], result[@"blue"]] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = inputTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_GET_DEVICE_INFO)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *deviceInfo = getDeviceInfoFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", deviceInfo] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            handleTouchIndicatorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_RECOGNIZER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *text = performTextRecognizerTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", text] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_SEARCHER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = searchRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PROMPT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = promptInputFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                result = [[result stringByReplacingOccurrencesOfString:@"\r" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_MASKED_TEMPLATE_MATCH || taskType == TASK_ACCESSIBILITY_AT_POINT)
    {
        @autoreleasepool {
            if (!writeStreamRef) return;
            NSData *encoded = [[NSData alloc] initWithBase64EncodedString:
                [NSString stringWithUTF8String:(char *)eventData] options:0];
            NSDictionary *request = encoded ? [NSJSONSerialization JSONObjectWithData:encoded options:0 error:nil] : nil;
            if (![request isKindOfClass:[NSDictionary class]]) {
                notifyClient((UInt8 *)"-1;;Invalid JSON request\r\n", writeStreamRef);
                return;
            }
            NSError *error = nil;
            NSData *result = nil;
            if (taskType == TASK_MASKED_TEMPLATE_MATCH) {
                result = zxMaskedTemplateMatches(request, &error);
            } else if ([request[@"x"] isKindOfClass:[NSNumber class]] &&
                       [request[@"y"] isKindOfClass:[NSNumber class]]) {
                result = zxCopyAccessibilityElementAtPoint(CGPointMake([request[@"x"] doubleValue],
                                                                      [request[@"y"] doubleValue]), &error);
            }
            if (taskType == TASK_ACCESSIBILITY_AT_POINT) {
                static const UInt8 fallback[] = "-1;;AXPOINT-20261127-01/task34/v1 stage=protocol-size code=3417 diagnostics={}\r\n";
                if (!result) {
                    NSString *description = error.localizedDescription ?: @"Invalid AX position";
                    NSString *message = [NSString stringWithFormat:@"-1;;%@\r\n", description];
                    NSData *line = [message dataUsingEncoding:NSUTF8StringEncoding];
                    BOOL safe = line.length > 0 && line.length <= 65536 &&
                        [description rangeOfString:@";;"].location == NSNotFound &&
                        [description rangeOfString:@"\r"].location == NSNotFound &&
                        [description rangeOfString:@"\n"].location == NSNotFound;
                    if (safe) notifyClientData((const UInt8 *)line.bytes,(CFIndex)line.length,writeStreamRef);
                    else notifyClientData(fallback,sizeof(fallback)-1,writeStreamRef);
                    return;
                }
                if (result.length == 0 || result.length > 65536 ||
                    ![[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding]) {
                    notifyClientData(fallback,sizeof(fallback)-1,writeStreamRef);
                    return;
                }
            }
            if (!result) {
                NSString *message = [NSString stringWithFormat:@"-1;;%@\r\n",
                                     error.localizedDescription ?: @"Invalid AX position"];
                notifyClient((UInt8 *)message.UTF8String, writeStreamRef);
                return;
            }
            NSString *header = [NSString stringWithFormat:@"0;;application/json;;%lu\r\n", (unsigned long)result.length];
            NSData *head = [header dataUsingEncoding:NSUTF8StringEncoding];
            if (notifyClientData((const UInt8 *)head.bytes, (CFIndex)head.length, writeStreamRef) == 0)
                notifyClientData((const UInt8 *)result.bytes, (CFIndex)result.length, writeStreamRef);
        }
    }
    else if (taskType == TASK_ACCESSIBILITY_HIERARCHY)
    {
        @autoreleasepool {
            if (!writeStreamRef) return;
            NSError *error = nil;
            NSString *options = [NSString stringWithUTF8String:(const char *)eventData];
            NSArray<NSString *> *parts = [options componentsSeparatedByString:@";;"];
            NSString *budgetText = parts.firstObject;
            NSString *mode = parts.count > 1 ? parts[1] : @"legacy";
            if (parts.count > 2 || ![@[@"legacy", @"visible2095"] containsObject:mode]) {
                notifyClient((UInt8 *)"-1;;AX mode must be legacy or visible2095\r\n", writeStreamRef);
                return;
            }
            NSTimeInterval budget = 3.0;
            if (budgetText.length) {
                NSScanner *scanner = [NSScanner scannerWithString:budgetText];
                NSInteger milliseconds = 0;
                if (![scanner scanInteger:&milliseconds] || !scanner.isAtEnd || milliseconds < 100 || milliseconds > 30000) {
                    notifyClient((UInt8 *)"-1;;AX budget must be 100 to 30000 milliseconds\r\n", writeStreamRef);
                    return;
                }
                budget = milliseconds / 1000.0;
            }
            NSData *treeData = [mode isEqualToString:@"visible2095"] ?
                zxCopyAccessibilityVisible2095WithBudget(budget, &error) :
                zxCopyAccessibilityTreeWithBudget(budget, &error);
            if (!treeData) {
                NSLog(@"com.zjx.springboard: AX hierarchy failed: %@", error);
                NSString *detail = error ? [NSString stringWithFormat:@"%@: %ld: %@",
                                            error.domain, (long)error.code, error.localizedDescription]
                                         : @"ZXTouchAX: 0: AX hierarchy unavailable";
                NSString *reply = [NSString stringWithFormat:@"-1;;%@\r\n", detail];
                notifyClient((UInt8 *)reply.UTF8String, writeStreamRef);
                return;
            }
            NSString *header = [NSString stringWithFormat:@"0;;application/json;;%lu\r\n",
                                (unsigned long)[treeData length]];
            NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
            if (notifyClientData((const UInt8 *)[headerData bytes], (CFIndex)[headerData length],
                                 writeStreamRef) != 0) return;
            notifyClientData((const UInt8 *)[treeData bytes], (CFIndex)[treeData length], writeStreamRef);
        }
    }
    else if (taskType == TASK_ACCESSIBILITY_TREE)
    {
        @autoreleasepool {
            if (!writeStreamRef) {
                return;
            }
            NSDictionary *parameters = @{@"name": @"get_ui_elements",
                                         @"arguments": @{@"visible_only": @YES,
                                                         @"clickable_only": @NO,
                                                         @"max_elements": @2000,
                                                         @"debug": @NO}};
            NSDictionary *message = @{@"jsonrpc": @"2.0", @"id": @1,
                                      @"method": @"tools/call", @"params": parameters};
            NSError *encodingError = nil;
            NSData *body = [NSJSONSerialization dataWithJSONObject:message options:0 error:&encodingError];
            if (!body) {
                notifyClient((UInt8 *)"-1;;Unable to encode AX request\r\n", writeStreamRef);
                return;
            }

            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:@"http://127.0.0.1:8090/mcp"]];
            [request setHTTPMethod:@"POST"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [request setValue:@"application/json, text/event-stream" forHTTPHeaderField:@"Accept"];
            [request setHTTPBody:body];
            [request setTimeoutInterval:20];

            __block NSData *responseData = nil;
            __block NSInteger responseStatus = 0;
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            NSURLSession *session = [NSURLSession sessionWithConfiguration:
                [NSURLSessionConfiguration ephemeralSessionConfiguration]];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (!error) {
                        responseData = data;
                        responseStatus = [(NSHTTPURLResponse *)response statusCode];
                    }
                    dispatch_semaphore_signal(finished);
                }];
            [task resume];
            if (dispatch_semaphore_wait(finished,
                dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0) {
                [task cancel];
                [session invalidateAndCancel];
                notifyClient((UInt8 *)"-1;;AX service request timed out\r\n", writeStreamRef);
                return;
            }
            [session finishTasksAndInvalidate];
            if (responseStatus != 200 || [responseData length] == 0) {
                notifyClient((UInt8 *)"-1;;AX service unavailable or request failed\r\n", writeStreamRef);
                return;
            }
            NSString *header = [NSString stringWithFormat:@"0;;application/json;;%lu\r\n",
                                (unsigned long)[responseData length]];
            NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
            if (notifyClientData((const UInt8 *)[headerData bytes],
                                 (CFIndex)[headerData length], writeStreamRef) != 0) {
                return;
            }
            notifyClientData((const UInt8 *)[responseData bytes],
                             (CFIndex)[responseData length], writeStreamRef);
        }
    }
    else if (taskType == TASK_SCREENSHOT)
    {
        @autoreleasepool {
            if (!writeStreamRef) {
                return;
            }

            CGImageRef screenshot = NULL;
            BOOL responseHeaderSent = NO;

            @try {
                screenshot = [Screen createScreenShotCGImageRef];
                if (!screenshot) {
                    notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
                    return;
                }

                UIImageOrientation imageOrientation = UIImageOrientationUp;
                int screenOrientation = [Screen getScreenOrientation];
                if (screenOrientation == 4) {
                    imageOrientation = UIImageOrientationRight;
                } else if (screenOrientation == 3) {
                    imageOrientation = UIImageOrientationLeft;
                } else if (screenOrientation == 2) {
                    imageOrientation = UIImageOrientationDown;
                }

                UIImage *image = [UIImage imageWithCGImage:screenshot
                                                     scale:[Screen getScale]
                                               orientation:imageOrientation];
                if (image && imageOrientation != UIImageOrientationUp) {
                    CGFloat scale = [Screen getScale];
                    CGSize orientedSize = CGSizeMake(CGImageGetWidth(screenshot) / scale,
                                                     CGImageGetHeight(screenshot) / scale);
                    if (imageOrientation == UIImageOrientationLeft ||
                        imageOrientation == UIImageOrientationRight) {
                        orientedSize = CGSizeMake(orientedSize.height, orientedSize.width);
                    }

                    UIGraphicsBeginImageContextWithOptions(orientedSize, YES, scale);
                    [image drawInRect:CGRectMake(0, 0, orientedSize.width, orientedSize.height)];
                    UIImage *orientedImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    image = orientedImage;
                }

                NSData *pngData = image ? UIImagePNGRepresentation(image) : nil;
                if (!pngData || [pngData length] == 0) {
                    notifyClient((UInt8 *)"-1;;Unable to encode screenshot as PNG\r\n", writeStreamRef);
                    return;
                }

                NSString *header = [NSString stringWithFormat:@"0;;image/png;;%lu\r\n",
                                                             (unsigned long)[pngData length]];
                NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                if (!headerData || notifyClientData((const UInt8 *)[headerData bytes],
                                                    (CFIndex)[headerData length],
                                                    writeStreamRef) != 0) {
                    return;
                }
                responseHeaderSent = YES;

                if (notifyClientData((const UInt8 *)[pngData bytes],
                                     (CFIndex)[pngData length],
                                     writeStreamRef) != 0) {
                    NSLog(@"com.zjx.springboard: Failed to send screenshot PNG payload.");
                }
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Screenshot task failed: %@", exception.reason);
                if (!responseHeaderSent) {
                    notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
                }
            }
            @finally {
                if (screenshot) {
                    CGImageRelease(screenshot);
                }
            }
        }
    }
    else if (taskType == TASK_SHOW_SCRIPT_SETTINGS)
    {
        NSString *path = [NSString stringWithUTF8String:(const char *)eventData];
        if (!zxScriptHasSettings(path)) {
            notifyClient((UInt8 *)"-1;;Script settings page not found\r\n", writeStreamRef);
        } else if (!zxReserveScriptSettings()) {
            notifyClient((UInt8 *)"-1;;Settings page is already active\r\n", writeStreamRef);
        } else {
            zxPresentScriptSettings(path, NO, nil);
            notifyClient((UInt8 *)"0\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_KILL_PROCESS)
    {
        NSString *bundleID = zxBundleIDFromRequest(eventData);
        if (!bundleID) {
            notifyClient((UInt8 *)"-1;;Invalid Bundle ID\r\n", writeStreamRef);
            return;
        }
        NSError *error = nil;
        NSInteger count = zxTerminateApplication(bundleID, &error);
        if (count < 0) zxReplyError(error, writeStreamRef);
        else {
            NSString *reply = [NSString stringWithFormat:@"0;;%ld\r\n", (long)count];
            notifyClient((UInt8 *)reply.UTF8String, writeStreamRef);
        }
    }
    else if (taskType == TASK_LIST_INSTALLED_APPS)
    {
        NSArray *apps = zxInstalledApplications();
        if (!apps) notifyClient((UInt8 *)"-1;;Unable to list installed applications\r\n", writeStreamRef);
        else zxReplyJSON(@{@"apps": apps}, writeStreamRef);
    }
    else if (taskType == TASK_GET_CLIPBOARD_TEXT)
    {
        __block NSString *text = nil;
        void (^readClipboard)(void) = ^{ text = UIPasteboard.generalPasteboard.string ?: @""; };
        if (!zxAccessPasteboard(readClipboard))
            notifyClient((UInt8 *)"-1;;Clipboard read timed out\r\n", writeStreamRef);
        else zxReplyJSON(@{@"text": text}, writeStreamRef);
    }
    else if (taskType == TASK_SET_CLIPBOARD_TEXT)
    {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:
            [NSString stringWithUTF8String:(const char *)eventData] options:0];
        NSString *text = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if (!text) {
            notifyClient((UInt8 *)"-1;;Invalid clipboard text\r\n", writeStreamRef);
            return;
        }
        void (^writeClipboard)(void) = ^{ UIPasteboard.generalPasteboard.string = text; };
        if (!zxAccessPasteboard(writeClipboard))
            notifyClient((UInt8 *)"-1;;Clipboard write timed out\r\n", writeStreamRef);
        else notifyClient((UInt8 *)"0\r\n", writeStreamRef);
    }
    else if (taskType == TASK_INPUT_TEXT)
    {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:
            [NSString stringWithUTF8String:(const char *)eventData] options:0];
        NSString *text = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if (!text) {
            notifyClient((UInt8 *)"-1;;Invalid input text\r\n", writeStreamRef);
        } else {
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.zjx.zxtouch.keyboardcontrol" object:nil
                userInfo:@{@"task_id": @"1", @"task_content": text} deliverImmediately:NO];
            notifyClient((UInt8 *)"0\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_PRESS_KEY)
    {
        NSString *request = [NSString stringWithUTF8String:(const char *)eventData];
        NSArray<NSString *> *parts = [request componentsSeparatedByString:@";;"];
        NSInteger duration = parts.count == 2 ? [parts[1] integerValue] : 50;
        NSString *key = parts.firstObject.lowercaseString;
        if (parts.count > 2 || duration < 1 || duration > 5000 || !zxPressKey(key, (NSUInteger)duration))
            notifyClient((UInt8 *)"-1;;Invalid key or HID dispatch failed\r\n", writeStreamRef);
        else notifyClient((UInt8 *)"0\r\n", writeStreamRef);
    }
    else if (taskType == TASK_CLEAR_APP_DATA)
    {
        NSString *bundleID = zxBundleIDFromRequest(eventData);
        if (!bundleID) {
            notifyClient((UInt8 *)"-1;;Invalid Bundle ID\r\n", writeStreamRef);
            return;
        }
        NSError *error = nil;
        NSDictionary *result = zxClearApplicationData(bundleID, &error);
        if (!result) zxReplyError(error, writeStreamRef);
        else zxReplyJSON(result, writeStreamRef);
    }
    else if (taskType == TASK_GET_FOREGROUND_PROCESS_NAME)
    {
        NSString *name = zxForegroundProcessName();
        if (!name) notifyClient((UInt8 *)"-1;;Foreground process unavailable\r\n", writeStreamRef);
        else zxReplyJSON(@{@"name": name}, writeStreamRef);
    }
    else if (taskType == TASK_UPDATE_CACHE)
    {
        @autoreleasepool{
            NSError *err = nil;
            updateCacheFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[@"0\r\n" UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_RUNNER_REGISTER)
    {
        // No reply on purpose: this connection is the runner's job channel and
        // it reads every line written to it as an instruction.
        zxRunnerRegister((const char *)eventData, writeStreamRef);
    }
    else if (taskType == TASK_RUNNER_EVENT)
    {
        zxRunnerHandleEvent((const char *)eventData, writeStreamRef);
    }
    else if (taskType == TASK_TEST)
    {

    }
}
