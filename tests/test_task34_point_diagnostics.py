"""Task34 point-only framing and source-contract cases; native/device tests run separately."""
import json
import socket
from pathlib import Path
import unittest
from test_ax_elements import make_device, framed_response
from zxtouch.client import zxtouch
from zxtouch import tasktypes

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / 'layout/usr/share/zxtouch/python/zxtouch/client.py'
NATIVE = ROOT / 'pccontrol/PointCapture.inc'
ENTRY = ROOT / 'pccontrol/AccessibilityTree.xm'
TASK = ROOT / 'pccontrol/Task.xm'


class PointProtocol(unittest.TestCase):
    def test_point_success_and_next_packet(self):
        obj = {"pid": 42, "element": {"role": "AXButton", "label": "中文😀"}}
        next_packet = framed_response({"after": True})
        device = make_device([framed_response(obj) + next_packet])
        self.assertEqual(device.get_element_at_point(10, 20), obj)
        self.assertEqual(device._recv_buffer, next_packet)
        self.assertEqual(device.s.gettimeout(), None)
        self.assertEqual(device._json_query(tasktypes.TASK_MASKED_TEMPLATE_MATCH, {}), {"after": True})

    def test_error_and_next_packet(self):
        response = b'-1;;AXPOINT-20261127-01/task34/v1 diagnostics={"label":"a\\u003Bb"}\r\n'
        next_packet = framed_response({"after": 2})
        device = make_device([response + next_packet])
        with self.assertRaisesRegex(RuntimeError, 'AXPOINT-20261127-01'):
            device.get_element_at_point(1, 2)
        self.assertEqual(device._recv_buffer, next_packet)
        self.assertIsNone(device.s.gettimeout())
        self.assertEqual(device._json_query(tasktypes.TASK_MASKED_TEMPLATE_MATCH, {}), {"after": 2})

    def test_header_exact_limit_and_overflow(self):
        device = make_device([b'-1;;' + b'a' * (65536 - 6) + b'\r\n'])
        with self.assertRaises(RuntimeError):
            device.get_element_at_point(1, 2)
        self.assertFalse(device.s.closed)
        device = make_device([b'-1;;' + b'a' * (65537 - 6) + b'\r\n'])
        with self.assertRaisesRegex(RuntimeError, 'header exceeds'):
            device.get_element_at_point(1, 2)
        self.assertTrue(device.s.closed)
        self.assertEqual(device._recv_buffer, b'')

    def test_unterminated_header_and_bad_length_close(self):
        for packet in (b'X' * 65537, b'0;;application/json;;not-a-number\r\n'):
            with self.subTest(packet=packet[:20]):
                device = make_device([packet])
                with self.assertRaises(RuntimeError):
                    device.get_element_at_point(1, 2)
                self.assertTrue(device.s.closed)

    def test_point_body_boundary(self):
        for size, valid in ((65536, True), (65537, False)):
            body = json.dumps({"text": "x" * (size - 11)}, separators=(',', ':')).encode()
            assert len(body) == size
            device = make_device([b'0;;application/json;;%d\r\n' % size + body])
            if valid:
                self.assertEqual(len(device.get_element_at_point(1, 2)['text']), size - 11)
            else:
                with self.assertRaisesRegex(RuntimeError, 'length'):
                    device.get_element_at_point(1, 2)
                self.assertTrue(device.s.closed)

    def test_real_socketpair_keeps_protocol_exception_after_close(self):
        client, server = socket.socketpair()
        try:
            device = zxtouch.__new__(zxtouch)
            device.s = client
            device._recv_buffer = bytearray()
            server.sendall(b'0;;application/json;;invalid\r\n')
            with self.assertRaisesRegex(RuntimeError, 'Malformed JSON response length'):
                device.get_element_at_point(1, 2)
            self.assertEqual(client.fileno(), -1)
        finally:
            client.close()
            server.close()

    def test_real_socketpair_oversize_exception_after_close(self):
        client, server = socket.socketpair()
        try:
            device = zxtouch.__new__(zxtouch)
            device.s = client
            device._recv_buffer = bytearray(b'X' * 65537)
            with self.assertRaisesRegex(RuntimeError, 'header exceeds 65536'):
                device.get_element_at_point(1, 2)
            self.assertEqual(client.fileno(), -1)
        finally:
            client.close()
            server.close()

    def test_other_tasks_keep_default_limits(self):
        device = make_device([framed_response({"ok": True})])
        self.assertEqual(device._json_query(tasktypes.TASK_MASKED_TEMPLATE_MATCH, {}), {"ok": True})
        self.assertFalse(device.s.closed)


class NativeContract(unittest.TestCase):
    def test_unique_direct_hit_and_private_create(self):
        source = NATIVE.read_text(encoding='utf-8')
        entry = ENTRY.read_text(encoding='utf-8')
        self.assertIn('#include "PointCapture.inc"', entry)
        self.assertEqual(entry.count('NSData *zxCopyAccessibilityElementAtPoint('), 0)
        self.assertIn('"_AXUIElementCreateAppElementWithPid"', source)
        self.assertIn('"AXUIElementCopyElementAtPosition"', source)
        self.assertNotIn('CopyElementAtPositionWithParams', source)
        self.assertNotIn('dlclose(', source.replace('Never dlclose(', ''))
        self.assertNotIn('zxCopyAttribute =', source)

    def test_process_state_fallback_precedes_desktop_fallback(self):
        source = NATIVE.read_text(encoding='utf-8')
        capture = source.split('static void zxPointCapture(', 1)[1]
        direct = capture.index('c->pid=zxPIDFromObject(foreground)')
        state = capture.index('pid_t statePID = zxPIDFromObject(state)')
        desktop = capture.index('c->pid=getpid()')
        failure = capture.index('zxPointClaim(c,3405,nil)')
        self.assertLess(direct, state)
        self.assertLess(state, desktop)
        self.assertLess(desktop, failure)
        self.assertIn('[foreground respondsToSelector:@selector(processState)]', capture)
        self.assertIn('[bundle isEqualToString:@"com.apple.springboard"]', capture)
        self.assertIn('AXPOINT-20261128-01/task34/v2', source)

    def test_deadline_and_ownership_paths(self):
        source = NATIVE.read_text(encoding='utf-8')
        header = (ROOT / 'pccontrol/PointDeadline.h').read_text(encoding='utf-8')
        self.assertIn('zxPointQueueNS = 750000000ULL', header)
        self.assertIn('zxPointTotalNS = 3000000000ULL', header)
        self.assertIn('zxPointReserveNS = 250000000ULL', header)
        self.assertIn('mach_continuous_time()', source)
        self.assertIn('if (!mainSubmitted) zxPointFinish(c);', source)
        self.assertIn('if (!completionSubmitted) zxPointFinish(c);', source)
        self.assertIn('if (element) { CFRelease(element); element=NULL; }', source)
        self.assertIn('if (app) { CFRelease(app); app=NULL; }', source)
        self.assertIn('c->axStatus != 0', source)
        self.assertIn('atomic_compare_exchange_strong_explicit', source)

    def test_wire_only_task34_branch(self):
        source = TASK.read_text(encoding='utf-8')
        self.assertIn('if (taskType == TASK_ACCESSIBILITY_AT_POINT) {', source)
        self.assertIn('line.length <= 65536', source)
        self.assertIn('result.length > 65536', source)
        client = CLIENT.read_text(encoding='utf-8')
        self.assertIn('header_limit=65536, response_limit=65536', client)


if __name__ == '__main__':
    unittest.main()
