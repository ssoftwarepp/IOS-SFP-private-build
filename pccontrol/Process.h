#ifndef PROCESS_H
#define PROCESS_H

#import <Foundation/Foundation.h>
#include <dlfcn.h>

int switchProcessForegroundFromRawData(UInt8 *eventData);
int bringAppForeground(NSString *appIdentifier);
id getFrontMostApplication();
NSArray *zxInstalledApplications(void);
NSInteger zxTerminateApplication(NSString *bundleID, NSError **error);
NSDictionary *zxClearApplicationData(NSString *bundleID, NSError **error);
NSString *zxForegroundProcessName(void);

#endif