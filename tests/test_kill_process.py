import os
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "layout" / "usr" / "share" / "zxtouch" / "python"))

from zxtouch import datahandler, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class FakeSocket:
    def __init__(self, reply):
        self.reply = reply
        self.sent = []

    def sendall(self, data):
        self.sent.append(data)

    def recv(self, size):
        part, self.reply = self.reply[:size], self.reply[size:]
        return part


def make_client(reply):
    client = zxtouch.__new__(zxtouch)
    client.s = FakeSocket(reply)
    client._recv_buffer = bytearray()
    return client


class KillProcessTests(unittest.TestCase):
    def test_bundle_id_returns_number_of_confirmed_exits(self):
        client = make_client(b"0;;1\r\n")
        self.assertEqual(client.kill_process("com.apple.Preferences"), (True, 1))
        self.assertEqual(client.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_KILL_PROCESS, "com.apple.Preferences")])

    def test_installed_app_not_running_returns_zero(self):
        self.assertEqual(make_client(b"0;;0\r\n").kill_process("com.apple.Preferences"), (True, 0))

    def test_termination_error_returns_failure(self):
        self.assertEqual(make_client(b"-1;;Application did not exit\r\n").kill_process("com.apple.Preferences"),
                         (False, "Application did not exit"))

    def test_invalid_name_sends_nothing(self):
        client = make_client(b"")
        for name in ("", None, "com.app;;other", "line\nfeed", "\x00"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                client.kill_process(name)
        self.assertEqual(client.s.sent, [])

    def test_native_terminates_by_bundle_id_and_confirms_exit(self):
        task = (ROOT / "pccontrol" / "Task.xm").read_text(encoding="utf-8")
        source = (ROOT / "pccontrol" / "Process.xm").read_text(encoding="utf-8")
        self.assertIn("zxTerminateApplication(bundleID, &error)", task)
        self.assertIn("zxApplicationProxy(bundleID)", source)
        self.assertIn("terminateApplication:forReason:andReport:withDescription:", source)
        self.assertIn("zxSpringBoardApplication(bundleID)", source)
        self.assertIn("if (!state.boolValue) return 1", source)
        self.assertNotIn('proc_pidpath', source)
        self.assertNotIn('kill(pid, SIGTERM)', source)


if __name__ == "__main__":
    unittest.main()
