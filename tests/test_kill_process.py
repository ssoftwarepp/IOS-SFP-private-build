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
    def test_bundle_id_returns_number_of_signaled_processes(self):
        client = make_client(b"0;;2\r\n")
        self.assertEqual(client.kill_process("com.apple.Preferences"), (True, 2))
        self.assertEqual(client.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_KILL_PROCESS, "com.apple.Preferences")])

    def test_no_match_returns_zero(self):
        self.assertEqual(make_client(b"0;;0\r\n").kill_process("missing"), (True, 0))

    def test_signal_error_returns_failure(self):
        self.assertEqual(make_client(b"-1;;signal failed: 1\r\n").kill_process("Preferences"),
                         (False, "signal failed: 1"))

    def test_invalid_name_sends_nothing(self):
        client = make_client(b"")
        for name in ("", None, "com.app;;other", "line\nfeed", "\x00"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                client.kill_process(name)
        self.assertEqual(client.s.sent, [])

    def test_native_task_matches_bundle_executable_path_and_uses_sigterm(self):
        task = (ROOT / "pccontrol" / "Task.xm").read_text(encoding="utf-8")
        source = (ROOT / "pccontrol" / "Process.xm").read_text(encoding="utf-8")
        self.assertIn("zxTerminateApplication(bundleID, &error)", task)
        self.assertIn('dlsym(library, "proc_listpids")', source)
        self.assertIn('dlsym(library, "proc_pidpath")', source)
        self.assertIn("zxApplicationProxy(bundleID)", source)
        self.assertIn("[actual isEqualToString:target]", source)
        self.assertIn("kill(pid, SIGTERM)", source)
        self.assertIn("pid == getpid()", source)


if __name__ == "__main__":
    unittest.main()
