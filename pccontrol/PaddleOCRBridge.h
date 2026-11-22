#import <Foundation/Foundation.h>

@interface ZXPaddleOCRBridge : NSObject
+ (instancetype)sharedBridge;
- (NSDictionary *)recognizePNG:(NSData *)png region:(NSArray<NSNumber *> *)region error:(NSString **)error;
@end
