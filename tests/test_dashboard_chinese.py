import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "zxtouch/zxtouch/http/index.html"
SERVER = ROOT / "zxtouch/zxtouch/RemoteDashboardServer.m"


class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hidden = 0
        self.text = []
        self.labels = []

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script"):
            self.hidden += 1
        if not self.hidden:
            self.labels.extend(value for name, value in attrs if name in
                               ("title", "placeholder", "aria-label", "alt") and value)

    def handle_endtag(self, tag):
        if tag in ("style", "script"):
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden and data.strip():
            self.text.append(data.strip())


class DashboardChineseTests(unittest.TestCase):
    def test_visible_dashboard_labels_are_translated(self):
        html = PAGE.read_text(encoding="utf-8")
        self.assertIn('<html lang="zh-CN">', html)
        parser = VisibleText()
        parser.feed(html)
        visible = parser.text + parser.labels
        english = [label for label in visible if re.fullmatch(r"[A-Za-z][A-Za-z ]{2,}", label)
                   and label not in ("ZXTouch", "Python")]
        self.assertEqual(english, [])

    def test_dynamic_and_server_messages_are_translated(self):
        html = PAGE.read_text(encoding="utf-8")
        server = SERVER.read_text(encoding="utf-8")
        for marker in ("脚本运行中", "录制中", "已连接", "运行日志已清空。", "上传素材？"):
            self.assertIn(marker, html)
        for marker in ("配对令牌无效。", "控制台启动失败。", "找不到脚本。"):
            self.assertIn(marker, server)
        self.assertIn("ZXDashboardReloadConfiguration();", (ROOT / "pccontrol/Tweak.xm").read_text(encoding="utf-8"))

    def test_dashboard_socket_commands_are_crlf_framed(self):
        source = SERVER.read_text(encoding="utf-8")
        socket_source = (ROOT / "pccontrol/SocketServer.xm").read_text(encoding="utf-8")
        self.assertIn('NSString *framedCommand = [command stringByAppendingString:@"\\r\\n"];', source)
        self.assertIn('const char *message = framedCommand.UTF8String;', source)
        self.assertIn("bytes[index] == '\\r' && bytes[index + 1] == '\\n'", socket_source)

    def test_socket_server_has_delayed_bootstrap(self):
        tweak = (ROOT / "pccontrol/Tweak.xm").read_text(encoding="utf-8")
        self.assertIn("static void zxStartSpringBoardServices(void)", tweak)
        self.assertEqual(tweak.count("zxStartSpringBoardServices();"), 2)
        self.assertEqual(tweak.count("socketServer();"), 1)
        self.assertIn("dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC))", tweak)

    def test_package_and_artifact_version_match(self):
        control = (ROOT / "control").read_text(encoding="utf-8")
        tweak = (ROOT / "pccontrol/control").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        version = re.search(r"^Version: (.+)$", control, re.MULTILINE).group(1)
        self.assertIn("Version: " + version, tweak)
        self.assertEqual(workflow.count("VERSION=$(grep '^Version:' control"), 2)


if __name__ == "__main__":
    unittest.main()
