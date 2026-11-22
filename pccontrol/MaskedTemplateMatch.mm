#import "MaskedTemplateMatch.h"
#import "Screen.h"
#import <UIKit/UIKit.h>
#import <math.h>

static NSError *zxMatchError(NSString *message) {
    return [NSError errorWithDomain:@"IOS-SFP.Match" code:1
                           userInfo:@{NSLocalizedDescriptionKey:message}];
}

// Decode both images into the same top-left-origin RGBA bitmap convention.
static unsigned char *zxRGBA(CGImageRef image, size_t *width, size_t *height) {
    *width = CGImageGetWidth(image);
    *height = CGImageGetHeight(image);
    if (!*width || !*height || *width > 8192 || *height > 8192) return NULL;
    unsigned char *pixels = (unsigned char *)calloc(*width * *height, 4);
    if (!pixels) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, *width, *height, 8, *width * 4,
                                                space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) { free(pixels); return NULL; }
    CGContextTranslateCTM(bitmap, 0, *height);
    CGContextScaleCTM(bitmap, 1, -1);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, *width, *height), image);
    CGContextRelease(bitmap);
    return pixels;
}

static BOOL zxOverlap(NSDictionary *a, NSDictionary *b) {
    double x = MAX([a[@"x"] doubleValue], [b[@"x"] doubleValue]);
    double y = MAX([a[@"y"] doubleValue], [b[@"y"] doubleValue]);
    double r = MIN([a[@"x"] doubleValue] + [a[@"width"] doubleValue],
                   [b[@"x"] doubleValue] + [b[@"width"] doubleValue]);
    double bottom = MIN([a[@"y"] doubleValue] + [a[@"height"] doubleValue],
                        [b[@"y"] doubleValue] + [b[@"height"] doubleValue]);
    double intersection = MAX(0, r - x) * MAX(0, bottom - y);
    double small = MIN([a[@"width"] doubleValue] * [a[@"height"] doubleValue],
                       [b[@"width"] doubleValue] * [b[@"height"] doubleValue]);
    return small > 0 && intersection / small > .45;
}

NSData *zxMaskedTemplateMatches(NSDictionary *request, NSError **error) {
    if (![request isKindOfClass:[NSDictionary class]] || ![request[@"templates"] isKindOfClass:[NSArray class]] ||
        [request[@"templates"] count] == 0 || [request[@"templates"] count] > 12) {
        if (error) *error = zxMatchError(@"templates must contain 1..12 image paths");
        return nil;
    }
    NSArray *roi = request[@"region"];
    if (roi && (![roi isKindOfClass:[NSArray class]] || roi.count != 4)) {
        if (error) *error = zxMatchError(@"region must be [x,y,width,height]");
        return nil;
    }
    double threshold = request[@"threshold"] ? [request[@"threshold"] doubleValue] : .85;
    int limit = request[@"maxResults"] ? [request[@"maxResults"] intValue] : 30;
    int steps = request[@"steps"] ? [request[@"steps"] intValue] : 1;
    double minScale = request[@"minScale"] ? [request[@"minScale"] doubleValue] : 1;
    double maxScale = request[@"maxScale"] ? [request[@"maxScale"] doubleValue] : 1;
    if (!isfinite(threshold) || threshold <= 0 || threshold > 1 || limit < 1 || limit > 100 ||
        steps < 1 || steps > 9 || !isfinite(minScale) || !isfinite(maxScale) ||
        minScale < .25 || maxScale > 3 || minScale > maxScale) {
        if (error) *error = zxMatchError(@"invalid threshold, scales or maxResults");
        return nil;
    }
    CGImageRef screenshot = [Screen createScreenShotCGImageRef];
    if (!screenshot) { if (error) *error = zxMatchError(@"screen capture failed"); return nil; }
    int orientation = [Screen getScreenOrientation];
    UIImageOrientation turn = orientation == 4 ? UIImageOrientationRight :
                              orientation == 3 ? UIImageOrientationLeft :
                              orientation == 2 ? UIImageOrientationDown : UIImageOrientationUp;
    UIImage *image = [UIImage imageWithCGImage:screenshot scale:1 orientation:turn];
    CGImageRelease(screenshot);
    if (turn != UIImageOrientationUp) {
        CGSize size = CGSizeMake(CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage));
        if (turn == UIImageOrientationLeft || turn == UIImageOrientationRight) size = CGSizeMake(size.height, size.width);
        UIGraphicsBeginImageContextWithOptions(size, YES, 1);
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    size_t sw = 0, sh = 0;
    unsigned char *screen = image.CGImage ? zxRGBA(image.CGImage, &sw, &sh) : NULL;
    if (!screen) { if (error) *error = zxMatchError(@"screen bitmap unavailable"); return nil; }
    int left = 0, top = 0, right = (int)sw, bottom = (int)sh;
    if (roi) {
        for (id value in roi) if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue])) {
            free(screen); if (error) *error = zxMatchError(@"region contains a non-number"); return nil;
        }
        left = MAX(0, [roi[0] intValue]); top = MAX(0, [roi[1] intValue]);
        right = MIN((int)sw, left + [roi[2] intValue]);
        bottom = MIN((int)sh, top + [roi[3] intValue]);
        if (left >= right || top >= bottom) { free(screen); if (error) *error = zxMatchError(@"region is empty"); return nil; }
    }
    NSMutableArray *matches = [NSMutableArray array];
    NSArray *masks = request[@"masks"];
    if (masks && (![masks isKindOfClass:[NSArray class]] || masks.count != [request[@"templates"] count])) {
        if (error) *error = zxMatchError(@"masks must match templates count");
        free(screen); return nil;
    }
    NSUInteger index = 0;
    for (id entry in request[@"templates"]) {
        if (![entry isKindOfClass:[NSString class]] || ![entry length] || ![[NSFileManager defaultManager] fileExistsAtPath:entry]) {
            free(screen); if (error) *error = zxMatchError(@"template path does not exist"); return nil;
        }
        UIImage *original = [UIImage imageWithContentsOfFile:entry];
        if (!original.CGImage) { free(screen); if (error) *error = zxMatchError(@"template decode failed"); return nil; }
        for (int step = 0; step < steps; step++) {
            double factor = steps == 1 ? minScale : minScale + (maxScale - minScale) * step / (steps - 1);
            size_t width = (size_t)llround(CGImageGetWidth(original.CGImage) * factor);
            size_t height = (size_t)llround(CGImageGetHeight(original.CGImage) * factor);
            if (width < 2 || height < 2 || width > 1024 || height > 1024 || width > right - left || height > bottom - top) continue;
            UIImage *scaled = original;
            if (fabs(factor - 1) > .0001) {
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, 1);
                [original drawInRect:CGRectMake(0, 0, width, height)];
                scaled = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
            }
            size_t tw = 0, th = 0;
            unsigned char *pattern = zxRGBA(scaled.CGImage, &tw, &th);
            if (!pattern) continue;
            unsigned char *mask = NULL;
            size_t mw = 0, mh = 0;
            id maskEntry = masks ? masks[index] : nil;
            if (maskEntry && maskEntry != [NSNull null]) {
                if (![maskEntry isKindOfClass:[NSString class]] || ![[NSFileManager defaultManager] fileExistsAtPath:maskEntry]) {
                    free(pattern); free(screen); if (error) *error = zxMatchError(@"mask path does not exist"); return nil;
                }
                UIImage *maskImage = [UIImage imageWithContentsOfFile:maskEntry];
                if (!maskImage.CGImage || CGImageGetWidth(maskImage.CGImage) != CGImageGetWidth(original.CGImage) ||
                    CGImageGetHeight(maskImage.CGImage) != CGImageGetHeight(original.CGImage)) {
                    free(pattern); free(screen); if (error) *error = zxMatchError(@"mask dimensions differ from template"); return nil;
                }
                if (fabs(factor - 1) > .0001) {
                    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, 1);
                    [maskImage drawInRect:CGRectMake(0, 0, width, height)];
                    maskImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                }
                mask = zxRGBA(maskImage.CGImage, &mw, &mh);
                if (!mask || mw != tw || mh != th) {
                    free(mask); free(pattern); free(screen); if (error) *error = zxMatchError(@"mask decode failed"); return nil;
                }
            }
            // Standard PNG alpha: opaque pixels participate, transparent pixels do not.
            size_t active = 0;
            for (size_t p = 0; p < tw * th; p++) {
                unsigned char alpha = mask ? mask[p * 4 + 3] : pattern[p * 4 + 3];
                if (alpha == 255) active++;
            }
            if (!active) { free(mask); free(pattern); continue; }
            double budget = (1 - threshold) * (1 - threshold) * 255 * 255 * 3 * active;
            for (int y = top; y + (int)th <= bottom; y++) {
                for (int x = left; x + (int)tw <= right; x++) {
                    double squared = 0;
                    for (size_t yy = 0; yy < th && squared <= budget; yy++) {
                        size_t target = ((size_t)y + yy) * sw * 4 + (size_t)x * 4;
                        size_t source = yy * tw * 4;
                        for (size_t xx = 0; xx < tw; xx++, target += 4, source += 4) {
                            unsigned char alpha = pattern[source + 3];
                            unsigned char maskAlpha = mask ? mask[source + 3] : alpha;
                            if (maskAlpha != 255) continue;
                            for (int channel = 0; channel < 3; channel++) {
                                double color = alpha ? MIN(255.0, pattern[source + channel] * 255.0 / alpha) : pattern[source + channel];
                                double difference = screen[target + channel] - color;
                                squared += difference * difference;
                            }
                            if (squared > budget) break;
                        }
                    }
                    if (squared > budget) continue;
                    NSDictionary *hit = @{ @"index": @(index), @"x": @(x), @"y": @(y),
                                           @"width": @(tw), @"height": @(th), @"scale": @(factor),
                                           @"score": @(MAX(0, 1 - sqrt(squared / (3 * active)) / 255.0)) };
                    BOOL suppressed = NO;
                    for (NSDictionary *prior in matches) if ([prior[@"index"] isEqual:hit[@"index"]] && zxOverlap(prior, hit)) {
                        suppressed = YES; break;
                    }
                    if (!suppressed) [matches addObject:hit];
                    if (matches.count >= (NSUInteger)limit) break;
                }
                if (matches.count >= (NSUInteger)limit) break;
            }
            free(mask);
            free(pattern);
            if (matches.count >= (NSUInteger)limit) break;
        }
        if (matches.count >= (NSUInteger)limit) break;
        index++;
    }
    free(screen);
    return [NSJSONSerialization dataWithJSONObject:@{ @"matches": matches, @"count": @(matches.count),
                                                     @"width": @(sw), @"height": @(sh) } options:0 error:error];
}
