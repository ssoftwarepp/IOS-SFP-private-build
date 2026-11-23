import os
import sys
import unittest


CLIENT_ROOT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python"))
sys.path.insert(0, CLIENT_ROOT)

from zxtouch import datahandler, deviceinfotasktypes, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class FakeSocket:
    def __init__(self, response):
        self.response = response
        self.sent = []

    def sendall(self, data):
        self.sent.append(data)

    def send(self, data):
        self.sent.append(data)
        return len(data)

    def recv(self, size):
        result = self.response[:size]
        self.response = self.response[size:]
        return result


def make_client(response):
    client = zxtouch.__new__(zxtouch)
    client.s = FakeSocket(response)
    client._recv_buffer = bytearray()
    return client


class ForegroundAppTests(unittest.TestCase):
    def test_returns_foreground_bundle_id(self):
        client = make_client(b"0;;com.apple.Preferences;;0;;0\r\n")
        self.assertEqual(client.get_foreground_app(), (True, "com.apple.Preferences"))
        self.assertEqual(client.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_GET_DEVICE_INFO,
            deviceinfotasktypes.DEVICE_INFO_TASK_GET_RUNTIME_STATUS)])

    def test_returns_server_error(self):
        client = make_client(b"-1;;runtime unavailable\r\n")
        self.assertEqual(client.get_foreground_app(), (False, "runtime unavailable"))

    def test_does_not_consume_next_response(self):
        client = make_client(b"0;;com.apple.springboard;;0;;0\r\n0;;2.000000\r\n")
        self.assertEqual(client.get_foreground_app(), (True, "com.apple.springboard"))
        self.assertEqual(client.get_screen_scale(), (True, "2.000000"))


if __name__ == "__main__":
    unittest.main()
