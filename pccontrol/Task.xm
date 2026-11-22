#include "Task.h"
#include <roothide.h>
#include "Touch.h"
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
#include <Foundation/NSDistributedNotificationCenter.h>
#include <TextRecognization/TextRecognizer.h>
#include "UpdateCache.h"
#include "Screen.h"
#include "Runner.h"
#include "AccessibilityTree.h"
#include "MaskedTemplateMatch.h"

extern CFRunLoopRef recordRunLoop;

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
            NSData *treeData = zxCopyAccessibilityTree(&error);
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
