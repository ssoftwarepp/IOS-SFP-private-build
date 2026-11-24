#ifndef ZX_RUNTIME_LOGS_H
#define ZX_RUNTIME_LOGS_H

#import <Foundation/Foundation.h>

static NSString *ZXRuntimeLogDirectory(void) {
    return @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime";
}

static NSArray<NSString *> *ZXRuntimeLogPaths(void) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [calendar startOfDayForDate:[NSDate date]];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.calendar = calendar;
    formatter.timeZone = calendar.timeZone;
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSMutableArray *paths = [NSMutableArray array];
    for (NSInteger offset = 4; offset >= 0; --offset) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:-offset toDate:today options:0];
        [paths addObject:[ZXRuntimeLogDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"output-%@.log", [formatter stringFromDate:day]]]];
    }
    return paths;
}

static void ZXPruneRuntimeLogs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSSet *keep = [NSSet setWithArray:ZXRuntimeLogPaths()];
    NSString *directory = ZXRuntimeLogDirectory();
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (![name hasPrefix:@"output-"] || ![name hasSuffix:@".log"]) continue;
        if (name.length != @"output-0000-00-00.log".length) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![keep containsObject:path]) [fm removeItemAtPath:path error:nil];
    }
    NSString *legacy = [directory stringByAppendingPathComponent:@"output"];
    NSDate *modified = [[fm attributesOfItemAtPath:legacy error:nil] fileModificationDate];
    NSDate *oldest = [[NSCalendar currentCalendar] startOfDayForDate:
        [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:-4
                                               toDate:[NSDate date] options:0]];
    if (modified && [modified compare:oldest] == NSOrderedAscending)
        [fm removeItemAtPath:legacy error:nil];
}

static NSString *ZXReadRuntimeLogs(NSUInteger maximumLength) {
    ZXPruneRuntimeLogs();
    NSMutableArray *paths = [NSMutableArray array];
    NSString *legacy = [ZXRuntimeLogDirectory() stringByAppendingPathComponent:@"output"];
    NSDate *modified = [[[NSFileManager defaultManager] attributesOfItemAtPath:legacy error:nil] fileModificationDate];
    NSDate *oldest = [[NSCalendar currentCalendar] startOfDayForDate:
        [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:-4
                                               toDate:[NSDate date] options:0]];
    if (modified && [modified compare:oldest] != NSOrderedAscending) [paths addObject:legacy];
    [paths addObjectsFromArray:ZXRuntimeLogPaths()];
    NSMutableString *logs = [NSMutableString string];
    for (NSString *path in paths) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) continue;
        @try {
            unsigned long long length = [handle seekToEndOfFile];
            unsigned long long start = length > maximumLength * 4 ? length - maximumLength * 4 : 0;
            [handle seekToFileOffset:start];
            NSMutableData *data = [[handle readDataToEndOfFile] mutableCopy];
            NSString *content = nil;
            for (NSUInteger skip = 0; skip < 4 && skip < data.length; ++skip) {
                content = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(skip, data.length - skip)]
                                               encoding:NSUTF8StringEncoding];
                if (content) break;
            }
            if (content) [logs appendString:content];
        } @catch (NSException *exception) {
            NSLog(@"ZXTouch: read runtime log failed: %@", exception.reason);
        } @finally { [handle closeFile]; }
        if (logs.length > maximumLength)
            [logs deleteCharactersInRange:NSMakeRange(0, logs.length - maximumLength)];
    }
    return logs;
}

static BOOL ZXClearRuntimeLogs(NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray arrayWithObject:
        [ZXRuntimeLogDirectory() stringByAppendingPathComponent:@"output"]];
    [paths addObjectsFromArray:ZXRuntimeLogPaths()];
    for (NSString *name in [fm contentsOfDirectoryAtPath:ZXRuntimeLogDirectory() error:nil]) {
        if ([name hasPrefix:@"output-"] && [name hasSuffix:@".log"] &&
            name.length == @"output-0000-00-00.log".length)
            [paths addObject:[ZXRuntimeLogDirectory() stringByAppendingPathComponent:name]];
    }
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:error]) return NO;
    }
    return YES;
}

#endif
