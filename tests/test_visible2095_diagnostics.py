import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class Visible2095DiagnosticsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "pccontrol" / "Visible2095Capture.inc").read_text(encoding="utf-8")
        cls.docs = (ROOT / "AX_VISIBLE2095_DIAGNOSTICS.md").read_text(encoding="utf-8")
        cls.server = (ROOT / "zxtouch" / "zxtouch" / "RemoteDashboardServer.m").read_text(encoding="utf-8")
        cls.html = (ROOT / "zxtouch" / "zxtouch" / "http" / "index.html").read_text(encoding="utf-8")

    def test_error_code_table_matches_implementation(self):
        codes = {100, 101, 102, 103, 104, 105, 106, 107, 108, 110, 111, 112, 120,
                 121, 122, 123, 124, 130, 140, 190, 201, 202, 203, 204, 205,
                 210, 211, 212, 220, 221, 222, 223, 224, 230, 231}
        documented = {int(value) for value in __import__("re").findall(r"^\| (\d+) \|", self.docs, __import__("re").M)}
        self.assertEqual(documented, codes)
        for code in codes:
            with self.subTest(error_code=code):
                self.assertIn(str(code), self.source)

    def test_stage_error_and_telemetry_contract_exists(self):
        for field in ("schemaVersion", "backend", "stage", "stages", "runtimeCandidates", "symbols",
                      "attributeStats", "issuesTotal", "issueCounts", "issuesTruncated", "sourceCounts",
                      "examinedCount", "returnedCount", "skippedCount", "limitReason", "queueWaitMs",
                      "captureMs", "elapsedMs", "messagingTimeoutAvailable"):
            self.assertIn('@"' + field + '"', self.source)
        self.assertIn("errorCode=%ld pid=%d axStatus=%@ attribute=%@ nodeIndex=%ld diagnostics=%@", self.source)

    def test_no_objc_ax_wrappers_and_handle_cleanup(self):
        self.assertNotIn("uiApplicationWithPid:", self.source)
        self.assertNotIn("uiElementsWithAttribute:", self.source)
        self.assertNotIn("objectWithAXAttribute:", self.source)
        self.assertIn("AXUIElementCreateApplication", self.source)
        self.assertIn("AXUIElementCopyAttributeValue", self.source)
        self.assertIn("dlclose(handle.pointerValue)", self.source)
        self.assertIn("if (frontboard) dlclose(frontboard)", self.source)
        self.assertNotIn("@synchronized (visibleLock)", self.source)

    def test_deadline_checked_before_slow_setup_and_attributes(self):
        for marker in ("Budget exhausted before foreground PID", "Budget exhausted before framework loading",
                       "Budget exhausted before symbol resolution", "Budget exhausted before application creation"):
            self.assertIn(marker, self.source)
        self.assertIn("if (!zxVisibleWithinBudget(capture))", self.source)
        self.assertIn("Budget exhausted waiting for main queue", self.source)
        self.assertIn("budget-validate", self.docs)
        self.assertIn("不可取消", self.docs)

    def test_attribute_read_codes_and_indexes_are_recorded(self):
        for number in ("121", "220", "221"):
            with self.subTest(error_code=number):
                self.assertIn(", {}, @\"node-".format(number), self.source)
        for number, attribute in (("222", "2001"), ("223", "2006"), ("224", "2002")):
            with self.subTest(error_code=number):
                self.assertIn("zxVisibleStringC(capture, element, {}, {}".format(attribute, number), self.source)
        self.assertIn("point.x >= 0 && point.y >= 0", self.source)
        self.assertIn("nodeIndex", self.source)

    def test_diagnostics_panel_persists_and_exports_failure_or_success(self):
        for element_id in ("axDiagnostics", "axCopyDiagnostics", "axDownloadDiagnostics"):
            self.assertIn('id="{}"'.format(element_id), self.html)
        self.assertIn("result.tree.diagnostics", self.html)
        self.assertIn("error.message || String(error)", self.html)
        self.assertIn("ios-sfp-ax-diagnostics.json", self.html)

    def test_long_error_header_limit_covers_serialized_diagnostics(self):
        self.assertIn("while (header.length < 65536)", self.server)
        diagnostic = {"schemaVersion": 2, "issues": [{"reason": "x" * 5000} for _ in range(8)]}
        message = "ZXTouchAX: 121: stage=node-frame-copy diagnostics=" + json.dumps(diagnostic)
        self.assertLess(len(message.encode("utf-8")) + len(b"-1;;\r\n"), 65536)


if __name__ == "__main__":
    unittest.main()
