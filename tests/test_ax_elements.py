import json
import os
from pathlib import Path
import socket
import sys
from unittest.mock import patch
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
        self.timeout = None
        self.closed = False

    def gettimeout(self):
        return self.timeout

    def settimeout(self, timeout):
        self.timeout = timeout

    def close(self):
        self.closed = True

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
        self.assertIn('tree = zxNode(application, 0, &count, &candidateCount, &limitReached, budget, sourceCounts);', source)
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
        self.assertIn('zxNumericAttribute(application, 5001) : NULL;', source)
        self.assertIn('zxWalkChildren(application, root, @"root", depth, deadline', source)
        self.assertIn('zxAppendCandidates((__bridge CFTypeRef)item[@"element"]', source)
        self.assertIn('root[@"children"] = children;', source)
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
        self.assertIn('@"limitReached": @(limitReached)', source)
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
        self.assertIn("zxRememberElement(window, seen)", source)
        self.assertIn("!zxRememberElement(child, seen)", source)
        self.assertNotIn("fingerprint", source.lower())
        self.assertIn('CFSTR("AXChildren")', source)
        self.assertIn('childNode[@"snapshotPath"] = childPath;', source)
        self.assertIn('leaf[@"candidateAttribute"] = @(candidateIDs[index]);', source)
        self.assertIn('leaf[@"candidateIndex"] = @(i);', source)
        self.assertIn('leaf[@"candidateSourcePath"] = sourcePath;', source)
        self.assertIn('@"source": @"candidateGroup"', source)
        self.assertIn('root[@"children"] = children;', source)
        self.assertIn('zxMaxDepth = 16', source)
        self.assertIn('CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;', source)
        self.assertIn('zxMaxTreeNodes = 2002', source)
        self.assertLess(source.index('zxWalkChildren(application, root,'),
                        source.index('zxAppendCandidates((__bridge CFTypeRef)item[@"element"]'))

    def test_webkit_proxy_optional_metadata_preserves_real_values(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        self.assertIn('if ([node[@"elementType"] isEqualToString:@"WebAccessibilityObjectWrapper"])', source)
        for attribute in ("AXRoleDescription", "AXDOMIdentifier", "AXURL", "AXPlaceholderValue"):
            self.assertIn('@"{}"'.format(attribute), source)
        self.assertIn('CFGetTypeID(raw) == CFURLGetTypeID()', source)
        self.assertIn('if (text.length) node[key] = text;', source)
        self.assertIn('node[key] = [(__bridge NSURL *)raw absoluteString];', source)

    def test_candidate_group_keeps_same_label_different_identity_nodes(self):
        tree = {"pid": 123, "count": 3, "candidateCount": 2, "limitReached": False,
                "root": {"role": "AXApplication", "source": "application", "children": [
                    {"role": "AXCandidateGroup", "source": "candidateGroup", "children": [
                        {"role": "WebAccessibilityObjectWrapper", "label": "继续",
                         "candidateAttribute": 3015, "candidateIndex": 157,
                         "candidateSourcePath": "root/windowCandidate[0]",
                         "snapshotPath": "root/windowCandidate[0]/candidate[3015:157]", "children": []},
                        {"role": "WebAccessibilityObjectWrapper", "label": "继续",
                         "candidateAttribute": 3015, "candidateIndex": 162,
                         "candidateSourcePath": "root/windowCandidate[0]",
                         "snapshotPath": "root/windowCandidate[0]/candidate[3015:162]", "children": []}
                    ]}]}}
        result = make_device([framed_response(tree)]).get_element_tree()
        matches = make_device([]).find_tree_elements(label="继续", tree=result)
        self.assertEqual([n["candidateIndex"] for n in matches], [157, 162])
        self.assertEqual(len({n["snapshotPath"] for n in matches}), 2)
        self.assertTrue(all(n["candidateSourcePath"] == "root/windowCandidate[0]" for n in matches))

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
            tasktypes.TASK_ACCESSIBILITY_HIERARCHY, 3000)])

    def test_hierarchy_budget_request_and_validation(self):
        tree = {"pid": 123, "count": 2, "candidateCount": 1,
                "sourceCounts": {"2095": 1, "3015": 2}, "budgetMs": 12000,
                "limitReached": False, "root": {"role": "AXApplication", "children": []}}
        device = make_device([framed_response(tree)])
        self.assertEqual(device.get_element_tree(timeout=15, budget_ms=12000), tree)
        self.assertEqual(device.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_ACCESSIBILITY_HIERARCHY, 12000)])
        for invalid in (0, 99, 30001, 3.0, "3000", True):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                device.get_element_tree(budget_ms=invalid)

    def test_hierarchy_source_counts_and_budget_are_exposed(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        task = (Path(__file__).resolve().parent.parent / "pccontrol" /
                "Task.xm").read_text(encoding="utf-8")
        self.assertIn("const uint32_t candidateIDs[] = {3015, 3025, 3022, 3029, 3031, 3032};", source)
        self.assertIn('for (NSNumber *attribute in @[@3015, @2095])', source)
        self.assertIn('sourceCounts[attribute.stringValue] = @(CFGetTypeID(raw) == CFArrayGetTypeID()', source)
        self.assertIn('@"sourceCounts": sourceCounts', source)
        self.assertIn('@"budgetMs": @(budget * 1000)', source)
        self.assertIn('zxNode(application, 0, &count, &candidateCount, &limitReached, budget, sourceCounts)', source)
        self.assertIn('zxCopyAccessibilityTreeWithBudget(budget, &error)', task)

    def test_hierarchy_label_regex_keeps_other_filters_exact(self):
        tree = {"root": {"role": "AXApplication", "children": [
            {"role": "AXButton", "label": "下一步 1", "identifier": "next", "children": []},
            {"role": "AXStaticText", "label": "下一步 2", "identifier": "next", "children": []},
            {"role": "AXButton", "label": "下一步 3", "identifier": "other", "children": []},
            {"role": "AXButton", "children": []}]}}
        device = make_device([])
        matches = device.find_tree_elements(label=r"re:^下一步 \d+$", identifier="next",
                                            role="AXButton", tree=tree)
        self.assertEqual([node["label"] for node in matches], ["下一步 1"])
        self.assertEqual(device.find_tree_elements(label="下一步 1", tree=tree), matches)
        self.assertEqual(device.find_tree_elements(label="下一步", tree=tree), [])

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

    def test_ax_query_restores_previous_socket_timeout(self):
        device = make_device([framed_response({"root": {"role": "AXApplication"}})])
        device.s.settimeout(25)
        self.assertEqual(device.get_element_tree(timeout=2)["root"]["role"], "AXApplication")
        self.assertEqual(device.s.gettimeout(), 25)
        self.assertFalse(device.s.closed)

    def test_ax_query_timeout_closes_connection(self):
        device = make_device([])
        with patch.object(device.s, "recv", side_effect=socket.timeout):
            with self.assertRaisesRegex(TimeoutError, "reconnect"):
                device.get_element_tree(timeout=0.1)
        self.assertTrue(device.s.closed)

    def test_ax_query_rejects_invalid_timeout(self):
        device = make_device([])
        for timeout in (0, -1, float("nan"), float("inf"), "10", True):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                device.get_ui_elements(timeout=timeout)
        self.assertEqual(device.s.sent, [])

    def test_ax_deadline_covers_fragmented_response(self):
        device = make_device([framed_response({"root": {"role": "AXApplication"}})[:5]])
        with patch("zxtouch.client.time.monotonic", side_effect=[10, 10, 10, 12]):
            with self.assertRaisesRegex(TimeoutError, "reconnect"):
                device.get_element_tree(timeout=1)
        self.assertTrue(device.s.closed)

    def test_element_at_point_uses_timeout(self):
        device = make_device([framed_response({"pid": 1, "element": {"role": "AXButton"}})])
        self.assertEqual(device.get_element_at_point(10, 20, timeout=3)["element"]["role"], "AXButton")
        self.assertEqual(device.s.gettimeout(), None)

    def test_filter_methods_pass_timeout_when_fetching(self):
        device = make_device([framed_response({"root": {"role": "AXButton", "children": []}})])
        self.assertEqual(len(device.find_tree_elements(role="AXButton", timeout=2)), 1)
        with patch.object(device, "get_element_tree", return_value={"root": {"role": "AXButton", "children": []}}) as get_tree:
            self.assertEqual(len(device.find_tree_elements(role="AXButton", budget_ms=12000)), 1)
            get_tree.assert_called_once_with(timeout=None, budget_ms=12000)
        with patch.object(device, "get_ui_elements", return_value={"elements": []}) as get_ui:
            self.assertEqual(device.find_elements(text="missing", timeout=3), [])
            get_ui.assert_called_once_with(timeout=3)

    def test_hierarchy_empty_children_returns_empty_tree(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "Task.xm").read_text(encoding="utf-8")
        self.assertIn("error.domain, (long)error.code, error.localizedDescription", source)
        device = make_device([b"-1;;ZXTouchAX: 3: AX application pid=12887 returned no child elements (3015=-25215/0)\r\n"])
        tree = device.get_element_tree()
        self.assertEqual(tree["count"], 0)
        self.assertEqual(tree["root"]["children"], [])
        self.assertEqual(device.find_tree_elements(label="missing", tree=tree), [])

    def test_hierarchy_other_errors_still_raise(self):
        for message in (b"ZXTouchAX: 2: AX application element unavailable",
                        b"ZXTouchAX: 3: AX candidates empty",
                        b"ZXTouchAX: 1: AX runtime unavailable"):
            with self.subTest(message=message):
                device = make_device([b"-1;;" + message + b"\r\n"])
                with self.assertRaisesRegex(RuntimeError, "ZXTouch AX hierarchy failed"):
                    device.get_element_tree()

    def test_hierarchy_refreshes_foreground_pid_per_attempt(self):
        source = (Path(__file__).resolve().parent.parent / "pccontrol" /
                  "AccessibilityTree.xm").read_text(encoding="utf-8")
        loop = source.split("for (NSUInteger attempt = 0; attempt < 4; ++attempt) {", 1)[1]
        self.assertLess(loop.index("readForegroundPID();"), loop.index("CFTypeRef application = create(pid);"))

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
