import json
import os
from pathlib import Path
import sys
import unittest


PYTHON_CLIENT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python")
)
sys.path.insert(0, PYTHON_CLIENT_ROOT)

from zxtouch import datahandler, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class ChunkedSocket:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = []

    def sendall(self, data):
        self.sent.append(data)

    def send(self, data):
        self.sent.append(data)
        return len(data)

    def recv(self, size):
        if not self.chunks:
            return b""
        chunk = self.chunks[0]
        result = chunk[:size]
        if len(result) == len(chunk):
            self.chunks.pop(0)
        else:
            self.chunks[0] = chunk[size:]
        return result


def make_device(chunks):
    device = zxtouch.__new__(zxtouch)
    device.s = ChunkedSocket(chunks)
    device._recv_buffer = bytearray()
    return device


ELEMENTS = [
    {"index": 0, "type": "control", "text": "通用", "clickable": True,
     "rect": {"x": 10, "y": 20, "width": 80, "height": 40}, "tap": {"x": 50, "y": 40}},
    {"index": 1, "type": "element", "text": "设置", "clickable": False,
     "rect": {"x": 0, "y": 0, "width": 100, "height": 80}},
]
SNAPSHOT = {"screen": {"width": 375, "height": 667}, "count": 2, "elements": ELEMENTS}


def framed_response(payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return b"0;;application/json;;%d\r\n" % len(data) + data


class AXProtocolTests(unittest.TestCase):
    def test_frontboard_pid_lookup_runs_on_main_queue(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        lookup = source.split("void (^readForegroundPID)(void) = ^{", 1)[1].split("    };", 1)[0]
        self.assertIn("focusedPID()", lookup)
        self.assertIn("getFrontMostApplication()", lookup)
        self.assertIn("if ([NSThread isMainThread]) readForegroundPID();", source)
        self.assertIn("else dispatch_sync(dispatch_get_main_queue(), readForegroundPID);", source)
        self.assertIn('tree = zxNode(application, 0, &count, &candidateCount);', source)
        self.assertIn('else dispatch_sync(dispatch_get_main_queue(), capture);', source)
        self.assertIn('if (attempt < 3 && ![NSThread isMainThread]) usleep(delays[attempt]);', source)

    def test_invalid_frontboard_pid_uses_live_springboard_pid(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        self.assertIn("kill(pid, 0) == 0 || errno == EPERM", source)
        self.assertIn("if (!zxIsLivePID(pid))", source)
        self.assertIn("pid = zxPIDFromObject(app);", source)
        self.assertIn('if (!zxIsLivePID(pid) && (!app || [bundleID isEqualToString:@"com.apple.springboard"]))', source)
        self.assertIn("pid = getpid();", source)
        self.assertIn("pid = zxPIDFromObject(state);", source)
        self.assertIn("[NSThread isMainThread]) readForegroundPID();", source)

    def test_ax_root_fallback_and_automation_client(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        self.assertIn('dlsym(candidate, "__AXSetRequestingClient")', source)
        self.assertIn('if (zxSetRequestingClient) zxSetRequestingClient(2);', source)
        for left, right, display in (("getpid()", "pid", 1), ("pid", "getpid()", 1),
                                     ("getpid()", "pid", 0), ("pid", "getpid()", 0)):
            self.assertIn(f"associate({left}, {right}, {display});", source)
        self.assertIn('CFTypeRef rawWindows = zxNumericAttribute(application, 5001);', source)
        self.assertIn('zxAppendCandidates(window, windowChildren, seen, count, candidateCount);', source)
        self.assertIn('zxAppendCandidates(application, children, seen, count, candidateCount);', source)
        self.assertIn('pid, [details componentsJoinedByString:', source)

    def test_empty_tree_reports_numeric_ax_attribute_results(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        self.assertIn("const uint32_t numericIDs[] = {3015, 3025, 3022, 3029, 3031, 3032, 5001};", source)
        self.assertIn("(CFStringRef)(uintptr_t)numericIDs[i]", source)
        self.assertIn("if (zxSetRequestingClient) zxSetRequestingClient(2);", source)
        self.assertIn('stringWithFormat:@"%u=%d/%ld"', source)
        self.assertIn("if (setTimeout) setTimeout(application, 0.5f);", source)
        self.assertIn("if (value) CFRelease(value);", source)

    def test_numeric_candidates_preserve_real_duplicate_controls(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        self.assertIn("static const NSUInteger zxMaxCandidates = 2000;", source)
        self.assertIn('@"candidateCount": @(candidateCount)', source)
        self.assertIn('@"limitReached": @(candidateCount >= zxMaxCandidates)', source)
        self.assertIn("if (setTimeout) setTimeout(application, 0.5f);", source)
        for attribute in (2001, 2003, 2006, 5003, 5019):
            self.assertIn(f"zxNumericAttribute(element, {attribute})" if attribute in (2003, 5003)
                          else f"zxNumericString(element, {attribute})", source)
        self.assertIn('dlsym(candidate, "AXValueGetTypeID")', source)
        self.assertIn("CFGetTypeID(raw) == zxValueTypeID() && zxValueType(raw) == 3", source)
        self.assertIn("const uint32_t candidateIDs[] = {3015, 3025, 3022, 3029, 3031, 3032};", source)
        self.assertIn('CFSTR("AXIdentifier")', source)
        self.assertIn('zxNumericNumber(element, 2021)', source)
        self.assertIn('zxNumericNumber(element, 2123)', source)
        self.assertIn('node[@"windowContextId"] = windowContextId;', source)
        self.assertIn('node[@"displayId"] = displayId;', source)
        self.assertIn("NSNumber *bucketKey = @(CFHash(element));", source)
        self.assertIn("CFEqual(element, (__bridge CFTypeRef)previous)", source)
        self.assertIn("!zxRememberElement(candidate, seen)", source)
        self.assertIn("!zxRememberElement(window, seen)", source)
        self.assertNotIn("fingerprint", source.lower())
        self.assertNotIn("zxNode(child,", source)
        self.assertLess(source.index("zxAppendCandidates(window, windowChildren"),
                        source.index("zxAppendCandidates(application, children"))

    def test_fragmented_unicode_snapshot_and_following_response(self):
        response = framed_response({"jsonrpc": "2.0", "id": 1,
                                    "result": {"structuredContent": SNAPSHOT}})
        device = make_device([response[:5], response[5:43], response[43:] + b"0;;1170;;2532\r\n"])
        snapshot = device.get_ui_elements()
        self.assertEqual(snapshot["elements"][0]["text"], "通用")
        self.assertEqual(device.find_elements(text="通用", clickable=True, snapshot=snapshot), ELEMENTS[:1])
        self.assertEqual(device.find_elements(type="element", snapshot=snapshot), ELEMENTS[1:])
        self.assertEqual(device.get_screen_size(), (True, {"width": "1170", "height": "2532"}))
        self.assertEqual(device.s.sent[0], datahandler.format_socket_data(tasktypes.TASK_ACCESSIBILITY_TREE))

    def test_hierarchy_and_identifier_query(self):
        tree = {"pid": 123, "count": 3, "root": {
            "role": "AXApplication", "children": [
                {"identifier": "settings", "label": "设置", "children": [
                    {"identifier": "general", "label": "通用", "role": "AXButton",
                     "frame": {"x": 10, "y": 20, "width": 80, "height": 40},
                     "children": []}
                ]}
            ]}}
        response = framed_response(tree)
        device = make_device([response[:7], response[7:30], response[30:]])
        self.assertEqual(device.get_element_tree(), tree)
        found = device.find_tree_elements(identifier="general", role="AXButton", tree=tree)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["label"], "通用")
        self.assertEqual(device.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_ACCESSIBILITY_HIERARCHY)])

    def test_hierarchy_2000_nodes_fragmented_response_preserves_next_packet(self):
        nodes = [{"role": "AXElement", "label": "相同标签", "frame": {"x": i, "y": 1, "width": 20, "height": 20},
                  "children": []} for i in range(2000)]
        tree = {"pid": 123, "count": 2002, "candidateCount": 2000, "limitReached": True,
                "root": {"role": "AXApplication", "children": [
                    {"role": "AXWindow", "children": nodes}]}}
        response = framed_response(tree)
        self.assertGreater(len(response), 4096)
        device = make_device([response[i:i + 733] for i in range(0, len(response), 733)] +
                             [b"0;;ok\r\n"])
        received = device.get_element_tree()
        self.assertEqual(received["count"], 2002)
        self.assertEqual(received["candidateCount"], 2000)
        self.assertTrue(received["limitReached"])
        self.assertEqual(len(received["root"]["children"][0]["children"]), 2000)
        self.assertEqual(device._recv_line(), b"0;;ok\r\n")
        server = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "Task.xm").read_text(encoding="utf-8")
        self.assertIn("notifyClientData((const UInt8 *)[treeData bytes]", server)

    def test_hierarchy_error_preserves_native_error_code(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "Task.xm").read_text(encoding="utf-8")
        self.assertIn("error.domain, (long)error.code, error.localizedDescription", source)
        device = make_device([b"-1;;ZXTouchAX: 3: AX application returned no child elements\r\n"])
        with self.assertRaisesRegex(RuntimeError, "ZXTouchAX: 3: AX application returned no child elements"):
            device.get_element_tree()

    def test_hierarchy_rejects_missing_root(self):
        device = make_device([framed_response({"count": 0})])
        with self.assertRaisesRegex(RuntimeError, "missing root"):
            device.get_element_tree()

    def test_json_rpc_error(self):
        device = make_device([framed_response({"jsonrpc": "2.0", "id": 1,
                                              "error": {"code": -32602, "message": "bad args"}})])
        with self.assertRaisesRegex(RuntimeError, "bad args"):
            device.get_ui_elements()

    def test_ax_backend_error(self):
        device = make_device([framed_response({"jsonrpc": "2.0", "id": 1,
                                              "result": {"isError": True,
                                                         "structuredContent": {"ok": False, "error": "timeout"}}})])
        with self.assertRaisesRegex(RuntimeError, "timeout"):
            device.get_ui_elements()

    def test_socket_error(self):
        device = make_device([b"-1;;AX service unavailable or request failed\r\n"])
        with self.assertRaisesRegex(RuntimeError, "AX service unavailable"):
            device.get_ui_elements()

    def test_missing_elements(self):
        device = make_device([framed_response({"result": {"structuredContent": {"count": 0}}})])
        with self.assertRaisesRegex(RuntimeError, "elements array"):
            device.get_ui_elements()


if __name__ == "__main__":
    unittest.main()
