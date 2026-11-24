    [self.server addHandlerForMethod:@"POST" path:@"/api/ax/point" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        id x = body[@"x"], y = body[@"y"];
        if (![x isKindOfClass:[NSNumber class]] || ![y isKindOfClass:[NSNumber class]] ||
            !isfinite([x doubleValue]) || !isfinite([y doubleValue]) ||
            [x doubleValue] < 0 || [y doubleValue] < 0 || [x doubleValue] > 10000 || [y doubleValue] > 10000)
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"坐标格式错误" } status:400];
        NSData *parameters = [NSJSONSerialization dataWithJSONObject:@{ @"x": x, @"y": y } options:0 error:nil];
        NSString *command = [@"34" stringByAppendingString:[parameters base64EncodedStringWithOptions:0]];
        NSString *failure = nil;
        NSData *result = [owner framedSocketCommand:command mime:@"application/json" error:&failure];
        if (!result) return [owner jsonResponse:@{ @"ok": @NO, @"error": failure ?: @"该位置没有元素" } status:502];
        NSDictionary *hit = [NSJSONSerialization JSONObjectWithData:result options:0 error:nil];
        return [owner jsonResponse:@{ @"ok": @YES, @"result": hit ?: @{} } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/image/templates" requestClass:[GCDWebServerMultiPartFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerMultiPartFormRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        GCDWebServerMultiPartFile *upload = [request firstFileForControlName:@"asset"];
        NSString *name = upload.fileName.lastPathComponent;
        if (!upload || ![owner isSafeAssetFileName:name] || ![name.pathExtension.lowercaseString isEqualToString:@"png"])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"请选择 PNG 模板或掩模" } status:400];
        unsigned long long length = [[[NSFileManager defaultManager] attributesOfItemAtPath:upload.temporaryPath error:nil] fileSize];
        if (!length || length > ZXDashboardMaximumAssetSize)
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"模板需小于 25 MB" } status:413];
        NSString *destinationType = [[request firstArgumentForControlName:@"destination"] string];
        NSString *directory = @"/var/mobile/Library/ZXTouch/templates";
        if (destinationType.length && ![destinationType isEqualToString:@"template"] &&
            ![destinationType isEqualToString:@"script"])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"保存位置无效" } status:400];
        if ([destinationType isEqualToString:@"script"]) {
            NSString *script = [[request firstArgumentForControlName:@"script"] string];
            directory = [owner bundlePathForRelativePath:script];
            if (!directory) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"脚本包不存在" } status:400];
        }
        NSFileManager *files = [NSFileManager defaultManager];
        NSError *failure = nil;
        if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&failure])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": failure.localizedDescription ?: @"创建模板库失败" } status:500];
        NSString *destination = [directory stringByAppendingPathComponent:name];
        if (destinationType.length && [files fileExistsAtPath:destination])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"文件已存在，请更换文件名" } status:409];
        NSData *content = [NSData dataWithContentsOfFile:upload.temporaryPath];
        if (![content writeToFile:destination options:NSDataWritingAtomic error:&failure])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": failure.localizedDescription ?: @"上传模板失败" } status:500];
        owner.lastAction = @"上传模板";
        return [owner jsonResponse:@{ @"ok": @YES, @"name": name, @"path": destination } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/image/matches" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSArray *entries = body[@"templates"], *maskEntries = body[@"masks"];
        if (![entries isKindOfClass:[NSArray class]] || !entries.count || entries.count > 12 ||
            (maskEntries && (![maskEntries isKindOfClass:[NSArray class]] || maskEntries.count != entries.count)))
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"模板与掩模数量不一致" } status:400];
        NSMutableArray *paths = [NSMutableArray array], *maskPaths = [NSMutableArray array];
        NSMutableArray *allEntries = [entries mutableCopy];
        if (maskEntries) [allEntries addObjectsFromArray:maskEntries];
        NSString *standalone = [[@"/var/mobile/Library/ZXTouch/templates" stringByStandardizingPath] stringByResolvingSymlinksInPath];
        for (id entry in allEntries) {
            if (entry == [NSNull null]) { [maskPaths addObject:[NSNull null]]; continue; }
            if (![entry isKindOfClass:[NSDictionary class]])
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"图片选项格式错误" } status:400];
            NSString *name = entry[@"name"], *bundle = nil;
            if (![name isKindOfClass:[NSString class]] || ![owner isSafeAssetFileName:name] ||
                ![name.pathExtension.lowercaseString isEqualToString:@"png"])
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"图片必须是 PNG" } status:400];
            NSString *directory = entry[@"script"] ? [owner bundlePathForRelativePath:entry[@"script"]] : standalone;
            if (!directory) return [owner jsonResponse:@{ @"ok": @NO, @"error": @"脚本包不存在" } status:400];
            bundle = [[directory stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
            if (![bundle hasPrefix:[directory stringByAppendingString:@"/"]] || ![[NSFileManager defaultManager] fileExistsAtPath:bundle])
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"模板图片不存在" } status:404];
            if ([paths count] < entries.count) [paths addObject:bundle]; else [maskPaths addObject:bundle];
        }
        NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObject:paths forKey:@"templates"];
        if (maskEntries) parameters[@"masks"] = maskPaths;
        NSString *snapshot = body[@"snapshot"];
        if (snapshot) {
            if (![snapshot isKindOfClass:NSString.class] || ![owner isSafeAssetFileName:snapshot] ||
                ![snapshot.pathExtension.lowercaseString isEqualToString:@"png"])
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"截图名称无效" } status:400];
            NSString *path = [[standalone stringByAppendingPathComponent:snapshot] stringByResolvingSymlinksInPath];
            if (![path hasPrefix:[standalone stringByAppendingString:@"/"]] || ![[NSFileManager defaultManager] fileExistsAtPath:path])
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"截图不存在" } status:404];
            parameters[@"screenshot"] = path;
        }
        for (NSString *key in @[@"threshold", @"maxResults", @"minScale", @"maxScale", @"steps"]) {
            id value = body[key];
            if (value) {
                if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]))
                    return [owner jsonResponse:@{ @"ok": @NO, @"error": @"找图参数必须是数字" } status:400];
                parameters[key] = value;
            }
        }
        id region = body[@"region"];
        if (region) {
            if (![region isKindOfClass:[NSArray class]] || [region count] != 4)
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"区域格式错误" } status:400];
            for (id value in region) if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]))
                return [owner jsonResponse:@{ @"ok": @NO, @"error": @"区域坐标必须是数字" } status:400];
            parameters[@"region"] = region;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:nil];
        NSString *command = [@"33" stringByAppendingString:[data base64EncodedStringWithOptions:0]];
        NSString *failure = nil;
        NSData *result = [owner framedSocketCommand:command mime:@"application/json" error:&failure];
        if (!result) return [owner jsonResponse:@{ @"ok": @NO, @"error": failure ?: @"原生找图失败" } status:502];
        NSDictionary *hits = [NSJSONSerialization JSONObjectWithData:result options:0 error:nil];
        return [owner jsonResponse:@{ @"ok": @YES, @"result": hits ?: @{} } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/ocr" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *owner = weakSelf;
        if (!owner || ![owner requestIsAuthorized:request]) return [owner unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSArray *region = body[@"region"] ?: @[@0, @0, @0, @0];
        if (![region isKindOfClass:[NSArray class]] || region.count != 4)
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"OCR 区域格式错误" } status:400];
        for (id value in region) if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]) ||
                                    [value doubleValue] < 0 || [value doubleValue] > 10000)
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"OCR 坐标超出范围" } status:400];
        NSString *engine = body[@"engine"] ?: @"vision";
        if (![engine isKindOfClass:NSString.class] || ![@[@"vision", @"paddleocr"] containsObject:engine])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"OCR 引擎无效" } status:400];
        if ([engine isEqualToString:@"paddleocr"]) {
#if ZX_DASHBOARD_SPRINGBOARD_SERVER
            NSString *captureError = nil;
            NSData *png = [owner framedSocketCommand:@"30" mime:@"image/png" error:&captureError];
            if (!png) return [owner jsonResponse:@{ @"ok": @NO, @"error": captureError ?: @"截图失败" } status:502];
            NSString *failure = nil;
            NSDictionary *result = [[ZXPaddleOCRBridge sharedBridge] recognizePNG:png region:region error:&failure];
            if (!result) return [owner jsonResponse:@{ @"ok": @NO, @"error": failure ?: @"PaddleOCR 失败" } status:502];
            return [owner jsonResponse:@{ @"ok": @YES, @"texts": result[@"texts"], @"engine": @"paddleocr",
                                          @"provider": result[@"provider"], @"worker_pid": result[@"worker_pid"] } status:200];
#else
            return [owner jsonResponse:@{ @"ok": @NO, @"error": @"PaddleOCR 需要 SpringBoard 服务" } status:503];
#endif
        }
        NSString *rect = [NSString stringWithFormat:@"%d,,%d,,%d,,%d", [region[0] intValue],
                          [region[1] intValue], [region[2] intValue], [region[3] intValue]];
        NSString *reply = [owner sendSocketCommand:[NSString stringWithFormat:@"271;;%@;;;;0;;0;;;;0;;", rect] expectsReply:YES];
        NSArray *parts = [[reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@";;"];
        if (!parts.count || ![parts[0] isEqualToString:@"0"])
            return [owner jsonResponse:@{ @"ok": @NO, @"error": reply ?: @"OCR 识别失败" } status:502];
        NSMutableArray *texts = [NSMutableArray array];
        for (NSUInteger i = 1; i < parts.count; i++) {
            NSArray *fields = [parts[i] componentsSeparatedByString:@",,"];
            if (fields.count >= 5) [texts addObject:@{ @"text": fields[0], @"x": fields[1],
                                                @"y": fields[2], @"width": fields[3], @"height": fields[4] }];
        }
        return [owner jsonResponse:@{ @"ok": @YES, @"texts": texts } status:200];
    }];
