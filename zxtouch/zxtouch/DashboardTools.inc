    [self.server addHandlerForMethod:@"GET" path:@"/api/screenshot" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSString *error = nil;
        NSData *image = [owner framedSocketCommand:@"30" mime:@"image/png" error:&error];
        if (!image) return [owner jsonResponse:@{ @"ok": @NO, @"error": error ?: @"截图失败" } status:502];
        return [GCDWebServerDataResponse responseWithData:image contentType:@"image/png"];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/ax/tree" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSString *error = nil;
        NSData *data = [owner framedSocketCommand:@"32" mime:@"application/json" error:&error];
        if (!data) return [owner jsonResponse:@{ @"ok": @NO, @"error": error ?: @"元素查询失败" } status:502];
        NSDictionary *tree = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![tree isKindOfClass:[NSDictionary class]] || ![tree[@"root"] isKindOfClass:[NSDictionary class]]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"元素树数据格式错误" } status:502];
        }
        return [owner jsonResponse:@{ @"ok": @YES, @"tree": tree } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/ax/tap" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        id xValue = body[@"x"], yValue = body[@"y"];
        if (![xValue isKindOfClass:[NSNumber class]] || ![yValue isKindOfClass:[NSNumber class]] ||
            !isfinite([xValue doubleValue]) || !isfinite([yValue doubleValue]) ||
            [xValue doubleValue] < 0 || [yValue doubleValue] < 0 ||
            [xValue doubleValue] >= 10000 || [yValue doubleValue] >= 10000) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"坐标超出屏幕范围" } status:400];
        }
        __block CGFloat touchScale = 1.0;
        void (^readScale)(void) = ^{ touchScale = [UIScreen mainScreen].scale; };
        if ([NSThread isMainThread]) readScale();
        else dispatch_sync(dispatch_get_main_queue(), readScale);
        int x = (int)lround([xValue doubleValue] * touchScale * 10), y = (int)lround([yValue doubleValue] * touchScale * 10);
        id jitterValue = body[@"jitter"], minDelayValue = body[@"minDelayMs"], maxDelayValue = body[@"maxDelayMs"];
        BOOL jitter = [jitterValue isKindOfClass:[NSNumber class]] ? [jitterValue boolValue] : NO;
        double minDelayDouble = [minDelayValue isKindOfClass:[NSNumber class]] ? [minDelayValue doubleValue] : 0;
        double maxDelayDouble = [maxDelayValue isKindOfClass:[NSNumber class]] ? [maxDelayValue doubleValue] : minDelayDouble;
        if (!isfinite(minDelayDouble) || !isfinite(maxDelayDouble) || minDelayDouble < 0 || maxDelayDouble < minDelayDouble || maxDelayDouble > 2000) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"点击间隔必须是 0 到 2000 毫秒，且最大值不小于最小值" } status:400];
        }
        uint32_t minDelay = jitter ? (uint32_t)llround(minDelayDouble) : 0;
        uint32_t maxDelay = jitter ? (uint32_t)llround(maxDelayDouble) : 0;
        NSString *tapResult = [owner sendTapAtPhysicalX:x y:y minDelay:minDelay maxDelay:maxDelay];
        if (![tapResult isEqualToString:@"0"]) return [owner jsonResponse:@{ @"ok": @NO, @"error": owner.lastError ?: @"触摸指令未发送" } status:502];
        owner.lastAction = @"点击元素";
        return [owner jsonResponse:@{ @"ok": @YES, @"x": xValue, @"y": yValue } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/color/pick" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        if (![body[@"x"] isKindOfClass:[NSNumber class]] || ![body[@"y"] isKindOfClass:[NSNumber class]] ||
            [body[@"x"] doubleValue] < 0 || [body[@"y"] doubleValue] < 0 ||
            [body[@"x"] doubleValue] >= 10000 || [body[@"y"] doubleValue] >= 10000) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"坐标格式错误" } status:400];
        }
        NSString *command = [NSString stringWithFormat:@"23%d;;%d", [body[@"x"] intValue], [body[@"y"] intValue]];
        NSString *reply = [owner sendSocketCommand:command expectsReply:YES];
        NSArray *parts = [[reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@";;"];
        if (parts.count < 4 || ![parts[0] isEqualToString:@"0"]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": reply ?: @"取色失败" } status:502];
        }
        if ([parts[1] intValue] < 0 || [parts[2] intValue] < 0 || [parts[3] intValue] < 0 ||
            [parts[1] intValue] > 255 || [parts[2] intValue] > 255 || [parts[3] intValue] > 255) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"取色坐标超出屏幕" } status:400];
        }
        return [owner jsonResponse:@{ @"ok": @YES, @"rgb": @[parts[1], parts[2], parts[3]] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/color/search" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSArray *region = body[@"region"], *rgb = body[@"rgb"];
        if (![region isKindOfClass:[NSArray class]] || region.count != 4 ||
            ![rgb isKindOfClass:[NSArray class]] || rgb.count != 3) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"区域或颜色格式错误" } status:400];
        }
        for (id value in [region arrayByAddingObjectsFromArray:rgb]) {
            if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue])) {
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"坐标或颜色不是数字" } status:400];
            }
        }
        int x = [region[0] intValue], y = [region[1] intValue], w = [region[2] intValue], h = [region[3] intValue];
        id toleranceValue = body[@"tolerance"];
        if (toleranceValue && ![toleranceValue isKindOfClass:[NSNumber class]])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"容差须为数字" } status:400];
        int tolerance = [toleranceValue intValue];
        if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > 10000 || y + h > 10000 || tolerance < 0 || tolerance > 255) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"搜索区域超出边界" } status:400];
        }
        int c[3];
        for (int i = 0; i < 3; i++) {
            c[i] = [rgb[i] intValue];
            if (c[i] < 0 || c[i] > 255) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"RGB 超出范围" } status:400];
        }
        NSString *command = [NSString stringWithFormat:@"281;;%d;;%d;;%d;;%d;;%d;;%d;;%d;;%d;;%d;;%d;;0",
                             x, y, w, h, MAX(0,c[0]-tolerance), MIN(255,c[0]+tolerance),
                             MAX(0,c[1]-tolerance), MIN(255,c[1]+tolerance), MAX(0,c[2]-tolerance), MIN(255,c[2]+tolerance)];
        NSString *reply = [owner sendSocketCommand:command expectsReply:YES];
        NSArray *parts = [[reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@";;"];
        if (parts.count < 6 || ![parts[0] isEqualToString:@"0"]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": reply ?: @"区域找色失败" } status:502];
        }
        if ([parts[1] intValue] < 0 || [parts[2] intValue] < 0) {
            return [owner jsonResponse:@{ @"ok": @YES, @"found": @NO } status:200];
        }
        return [owner jsonResponse:@{ @"ok": @YES, @"found": @YES, @"x": parts[1], @"y": parts[2], @"rgb": @[parts[3], parts[4], parts[5]] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/image/match" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundle = [owner bundlePathForRelativePath:body[@"path"]];
        NSString *name = body[@"template"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location != NSNotFound ||
            ![@[@"png", @"jpg", @"jpeg"] containsObject:name.pathExtension.lowercaseString] || !bundle) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"请选择脚本包内的 PNG/JPEG 模板" } status:400];
        }
        NSString *path = [[bundle stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
        if (![path hasPrefix:[bundle stringByAppendingString:@"/"]] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"模板文件不存在" } status:404];
        }
        id thresholdValue = body[@"threshold"];
        if (thresholdValue && ![thresholdValue isKindOfClass:[NSNumber class]])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"相似度须为数字" } status:400];
        double threshold = [thresholdValue doubleValue];
        if (threshold <= 0 || threshold > 1) threshold = 0.8;
        NSString *command = [NSString stringWithFormat:@"21%@;;2;;%.3f;;0.8", path, threshold];
        NSString *reply = [owner sendSocketCommand:command expectsReply:YES];
        NSArray *parts = [[reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@";;"];
        if (parts.count < 5 || ![parts[0] isEqualToString:@"0"]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": reply ?: @"找图失败" } status:502];
        }
        return [owner jsonResponse:@{ @"ok": @YES, @"frame": @{ @"x": parts[1], @"y": parts[2], @"width": parts[3], @"height": parts[4] } } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/script" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSString *bundle = [owner bundlePathForRelativePath:request.query[@"path"]];
        NSString *entry = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"info.plist"]][@"Entry"];
        if (!bundle || ![entry isKindOfClass:[NSString class]] || ![entry.pathExtension.lowercaseString isEqualToString:@"py"] ||
            ![entry.lastPathComponent isEqualToString:entry]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"仅能编辑脚本包中的 Python 入口文件" } status:400];
        }
        NSString *path = [[bundle stringByAppendingPathComponent:entry] stringByResolvingSymlinksInPath];
        if (![path hasPrefix:[bundle stringByAppendingString:@"/"]]) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"入口路径错误" } status:400];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"读取入口失败" } status:404];
        return [owner jsonResponse:@{ @"ok": @YES, @"path": request.query[@"path"], @"content": text } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundle = [owner bundlePathForRelativePath:body[@"path"]];
        NSString *entry = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"info.plist"]][@"Entry"];
        NSString *text = body[@"content"];
        if (!bundle || ![entry isKindOfClass:[NSString class]] || ![entry.pathExtension.lowercaseString isEqualToString:@"py"] ||
            ![entry.lastPathComponent isEqualToString:entry] || ![text isKindOfClass:[NSString class]] ||
            [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"脚本路径或内容错误" } status:400];
        }
        NSString *path = [[bundle stringByAppendingPathComponent:entry] stringByResolvingSymlinksInPath];
        if (![path hasPrefix:[bundle stringByAppendingString:@"/"]]) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"入口路径错误" } status:400];
        NSError *error = nil;
        if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"保存失败" } status:500];
        }
        owner.lastAction = @"保存脚本";
        return [owner jsonResponse:@{ @"ok": @YES } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script/new" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *name = body[@"name"], *text = body[@"content"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0 || name.length > 80 ||
            [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\r\n"]].location != NSNotFound ||
            ![text isKindOfClass:[NSString class]] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"名称或脚本内容错误" } status:400];
        }
        NSString *relative = [name stringByAppendingPathExtension:@"bdl"];
        NSString *bundle = [SCRIPTS_PATH stringByAppendingPathComponent:relative];
        NSFileManager *files = [NSFileManager defaultManager];
        if ([files fileExistsAtPath:bundle]) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"脚本名称已存在" } status:409];
        NSError *error = nil;
        if (![files createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:&error]) {
            return [owner jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"创建脚本失败" } status:500];
        }
        NSDictionary *info = @{ @"Entry": @"main.py", @"FrontApp": @"", @"Orientation": @"1" };
        BOOL saved = [info writeToFile:[bundle stringByAppendingPathComponent:@"info.plist"] atomically:YES] &&
                     [text writeToFile:[bundle stringByAppendingPathComponent:@"main.py"] atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!saved) {
            [files removeItemAtPath:bundle error:nil];
            return [owner jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"保存脚本失败" } status:500];
        }
        owner.lastAction = @"新建脚本";
        return [owner jsonResponse:@{ @"ok": @YES, @"path": relative } status:200];
    }];

#import "AdvancedTools.inc"
