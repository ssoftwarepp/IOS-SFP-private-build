from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent


class DashboardToolsTests(unittest.TestCase):
    def test_all_routes_keep_token_check(self):
        server = (ROOT / "zxtouch/zxtouch/DashboardTools.inc").read_text(encoding="utf-8")
        routes = re.findall(r'path:@"(/api/[^\"]+)"', server)
        self.assertEqual(routes, [
            "/api/screenshot", "/api/ax/tree", "/api/ax/tap",
            "/api/color/pick", "/api/color/search", "/api/image/match",
            "/api/script", "/api/script", "/api/script/new",
        ])
        self.assertEqual(server.count("[owner requestIsAuthorized:request]"), len(routes))
        self.assertIn('request.query[@"budgetMs"]', server)
        self.assertIn('request.query[@"mode"]', server)
        self.assertIn('framedSocketCommand:command mime:@"application/json"', server)
        advanced = (ROOT / "zxtouch/zxtouch/AdvancedTools.inc").read_text(encoding="utf-8")
        advanced_routes = re.findall(r'path:@"(/api/[^\"]+)"', advanced)
        self.assertEqual(advanced_routes, ["/api/ax/point", "/api/image/templates",
                                           "/api/image/matches", "/api/ocr"])
        self.assertEqual(advanced.count("[owner requestIsAuthorized:request]"), len(advanced_routes))
        self.assertIn('framedSocketCommand:@"30" mime:@"image/png"', server)

    def test_framing_and_path_checks(self):
        source = (ROOT / "zxtouch/zxtouch/RemoteDashboardServer.m").read_text(encoding="utf-8")
        tools = (ROOT / "zxtouch/zxtouch/DashboardTools.inc").read_text(encoding="utf-8")
        self.assertIn('stringByResolvingSymlinksInPath', source)
        self.assertIn('while (offset < (NSUInteger)size)', source)
        self.assertIn('size > 16 * 1024 * 1024', source)
        self.assertIn('#import "DashboardTools.inc"', source)
        self.assertIn('- (NSData *)framedSocketCommand:(NSString *)command mime:(NSString *)mime error:(NSString **)error\n{', source)
        self.assertIn('[down lengthOfBytesUsingEncoding:NSUTF8StringEncoding]', source)
        self.assertIn('[up lengthOfBytesUsingEncoding:NSUTF8StringEncoding]', source)
        self.assertNotIn('.lengthOfBytesUsingEncoding:', source)
        self.assertIn('![[NSFileManager defaultManager] fileExistsAtPath:path]', tools)
        self.assertIn('!isfinite([xValue doubleValue])', tools)
        self.assertIn('[UIScreen mainScreen].scale', tools)
        self.assertIn('![toleranceValue isKindOfClass:[NSNumber class]]', tools)
        self.assertIn('![thresholdValue isKindOfClass:[NSNumber class]]', tools)
        self.assertIn('@"found": @NO', tools)
        self.assertIn('[files removeItemAtPath:bundle error:nil]', tools)

    def test_dashboard_tools_connected(self):
        html = (ROOT / "zxtouch/zxtouch/http/index.html").read_text(encoding="utf-8")
        for name in ('editor', 'vision', 'ax'):
            self.assertIn('data-view="{}"'.format(name), html)
            self.assertIn('id="view-{}"'.format(name), html)
        for endpoint in ('/api/script/new', '/api/script', '/api/color/pick',
                         '/api/color/search', '/api/image/match', '/api/ax/tree',
                         '/api/ax/tap', '/api/screenshot'):
            self.assertIn(endpoint, html)
        for endpoint in ('/api/image/templates', '/api/image/matches', '/api/ax/point', '/api/ocr'):
            self.assertIn(endpoint, html)
        self.assertIn('id="axMode"', html)
        self.assertIn('id="axBudget"', html)
        self.assertIn('mode=${JSON.stringify(axSnapshotMode)}', html)
        self.assertIn('/api/ax/tree?mode=${encodeURIComponent(mode)}&budgetMs=${budget}', html)
        for control in ('axOverlay', 'axImage', 'axCopyCode', 'axDownloadCode',
                        'standaloneTemplate', 'visionCrop', 'screenExport'):
            self.assertIn('id="{}"'.format(control), html)
        self.assertNotIn('id="standaloneMask"', html)
        self.assertIn('showMatches(result)', html)
        self.assertIn('for (const match of imageMatches)', html)
        for control in ('searchX', 'searchY', 'searchWidth', 'searchHeight', 'searchClear', 'visionModeSearch'):
            self.assertIn('id="{}"'.format(control), html)
        self.assertIn('region: imageSearchRegion()', html)
        for control in ('searchCoordinates', 'searchCopy', 'searchExport'):
            self.assertIn('id="{}"'.format(control), html)
        self.assertIn('return `${x},${y},${x + w - 1},${y + h - 1}`;', html)
        self.assertIn("'ios-sfp-search-region.txt'", html)
        self.assertIn("elements.searchCopy.addEventListener('click', copySearchCoordinates)", html)
        self.assertIn("elements.searchExport.addEventListener('click', exportSearchCoordinates)", html)
        self.assertIn("if (visionMode === 'search') updateSearchCoordinates();", html)
        self.assertIn('id="matchFrame"', html)
        self.assertIn('await matchParameters({ name: uploaded.name })', html)
        self.assertIn('payload.snapshot = snapshotName', html)
        self.assertNotIn('const sub = document.createElement(\'small\'); const f = node.frame;', html)
        self.assertIn("visionMode === 'search'", html)
        self.assertIn('elements.ocrStatus.textContent = `${label}失败：${error.message}`', html)
        self.assertIn('elements.ocrResults.textContent = elements.ocrStatus.textContent', html)
        self.assertIn('node.candidateAttribute ? ` [${node.candidateAttribute}:${node.candidateIndex}]`', html)
        self.assertIn('id="ocrFind"', html)
        self.assertIn('id="ocrEngine"', html)
        self.assertIn('id="ocrStatus"', html)
        self.assertLess(html.index('id="ocrResults"'), html.index('id="visionModeColor"'))
        self.assertEqual(html.count('id="ocrFind"'), 1)
        self.assertIn('elements.ocrStatus.textContent = title.textContent', html)
        matcher = (ROOT / "pccontrol/MaskedTemplateMatch.mm").read_text(encoding="utf-8")
        self.assertIn('CGContextDrawImage(bitmap, CGRectMake(0, 0, *width, *height), image);', matcher)
        self.assertNotIn('CGContextTranslateCTM(bitmap, 0, *height);', matcher)
        self.assertNotIn('CGContextScaleCTM(bitmap, 1, -1);', matcher)
        self.assertIn('while (insert < matches.count && [matches[insert][@"score"] doubleValue]', matcher)
        self.assertIn('[matches insertObject:hit atIndex:insert]', matcher)
        self.assertNotIn('if (matches.count >= (NSUInteger)limit) break;', matcher)
        self.assertIn('`inset_pixels=${Math.max(0, Number(elements.axInsetPx.value) || 0)}`', html)
        self.assertIn("elements.axInsetPx.addEventListener('input'", html)
        self.assertNotIn('inset_pixels=2', html)
        self.assertNotIn('Number(f.width) * .2', html)
        advanced = (ROOT / "zxtouch/zxtouch/AdvancedTools.inc").read_text(encoding="utf-8")
        self.assertIn('recognizePNG:png region:region', advanced)
        self.assertIn('framedSocketCommand:@"30" mime:@"image/png"', advanced)
        self.assertIn('parameters[@"screenshot"] = path;', advanced)
        matcher = (ROOT / "pccontrol/MaskedTemplateMatch.mm").read_text(encoding="utf-8")
        self.assertIn('snapshotPath ? CGImageRetain(snapshot.CGImage)', matcher)
        self.assertIn('snapshotPath ? 1 : [Screen getScreenOrientation]', matcher)
        bridge = (ROOT / "pccontrol/PaddleOCRBridge.m").read_text(encoding="utf-8")
        self.assertIn('posix_spawn(&pid', bridge)
        self.assertIn('if (_socket >= 0 && _pid > 0) return YES;', bridge)
        self.assertIn('ZXOCRTransfer(_socket, &responseLength, 4, NO, deadline, &systemError)', bridge)
        self.assertIn('OCR_%@_%@', bridge)
        self.assertIn('WEXITSTATUS(childStatus)', bridge)
        self.assertIn('[self resetWorker]', bridge)
        worker = (ROOT / "ocrworker/main.mm").read_text(encoding="utf-8")
        self.assertIn('poll(&f, 1, -1)', worker)
        self.assertIn('if (!engine) engine =', worker)
        common = (ROOT / "pccontrol/Common.h").read_text(encoding="utf-8")
        self.assertRegex(common, r'extern "C"\s*\{\s*#endif\s*void zxAppendRuntimeLog\(NSString \*text\);\s*Boolean zxPathLooksExecutable')
        self.assertIn('OCR 识别选区', html)
        self.assertIn('Math.random()', html)
        self.assertIn('candidateAttribute', html)
        server = (ROOT / "zxtouch/zxtouch/DashboardTools.inc").read_text(encoding="utf-8")
        self.assertIn('sendTapAtPhysicalX', server)


if __name__ == "__main__":
    unittest.main()
