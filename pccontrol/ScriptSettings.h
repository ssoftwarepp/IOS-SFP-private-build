#ifndef SCRIPT_SETTINGS_H
#define SCRIPT_SETTINGS_H

#import <Foundation/Foundation.h>

BOOL zxScriptHasSettings(NSString *bundlePath);
BOOL zxScriptSettingsVisible(void);
BOOL zxReserveScriptSettings(void);
void zxPresentScriptSettings(NSString *bundlePath, BOOL runAfterSave, void (^completion)(BOOL saved));

#endif
