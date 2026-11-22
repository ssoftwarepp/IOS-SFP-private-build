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
        self.assertIn("framedSocketCommand:@\"32\" mime:@\"application/json\"", server)
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
        for control in ('axOverlay', 'axImage', 'axCopyCode', 'axDownloadCode',
                        'standaloneTemplate', 'standaloneMask', 'visionCrop', 'screenExport'):
            self.assertIn('id="{}"'.format(control), html)
        self.assertIn('id="ocrFind"', html)
        self.assertIn('id="ocrEngine"', html)
        self.assertIn('`inset_pixels=${Math.max(0, Number(elements.axInsetPx.value) || 0)}`', html)
        self.assertIn("elements.axInsetPx.addEventListener('input'", html)
        self.assertNotIn('inset_pixels=2', html)
        self.assertNotIn('Number(f.width) * .2', html)
        advanced = (ROOT / "zxtouch/zxtouch/AdvancedTools.inc").read_text(encoding="utf-8")
        self.assertIn('recognizePNG:png region:region', advanced)
        self.assertIn('framedSocketCommand:@"30" mime:@"image/png"', advanced)
        bridge = (ROOT / "pccontrol/PaddleOCRBridge.m").read_text(encoding="utf-8")
        self.assertIn('posix_spawn(&pid', bridge)
        self.assertIn('ZXOCRTransfer(pair[0]', bridge)
        self.assertIn('OCR 识别选区', html)
        self.assertIn('Math.random()', html)
        self.assertIn('candidateAttribute', html)
        server = (ROOT / "zxtouch/zxtouch/DashboardTools.inc").read_text(encoding="utf-8")
        self.assertIn('sendTapAtPhysicalX', server)


if __name__ == "__main__":
    unittest.main()
