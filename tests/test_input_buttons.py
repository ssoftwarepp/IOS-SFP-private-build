import base64
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'layout/usr/share/zxtouch/python'))
from zxtouch import datahandler, kbdtasktypes, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class FakeSocket:
    def __init__(self, replies):
        self.replies = list(replies)
        self.sent = []

    def sendall(self, value):
        self.sent.append(value)

    def recv(self, count):
        chunk = self.replies.pop(0)
        if len(chunk) > count:
            self.replies.insert(0, chunk[count:])
        return chunk[:count]


def phone(replies):
    client = zxtouch.__new__(zxtouch)
    client.s = FakeSocket(replies)
    client._recv_buffer = bytearray()
    return client


class InputButtonTests(unittest.TestCase):
    def test_bulk_input_preserves_unicode_delimiters_and_empty_text(self):
        text = '你好;;第二行\r\n完成'
        client = phone([b'0\r\n0\r\n'])
        self.assertEqual(client.input_text(text), (True, []))
        self.assertEqual(client.input_text(''), (True, []))
        self.assertEqual(client.s.sent, [
            datahandler.format_socket_data(tasktypes.TASK_INPUT_TEXT, base64.b64encode(value.encode()).decode())
            for value in (text, '')])
        with self.assertRaises(TypeError):
            client.input_text(None)

    def test_type_text_uses_per_character_reply_and_delay(self):
        client = phone([b'0\r\n0\r\n'])
        with patch('zxtouch.client.time.sleep') as sleep:
            self.assertEqual(client.type_text('甲乙', delay_ms=25), (True, ''))
            self.assertEqual(sleep.call_count, 2)
            sleep.assert_called_with(0.025)
        self.assertEqual(client.s.sent, [datahandler.format_socket_data(
            tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_INSERT_TEXT, char) for char in '甲乙'])
        failed = phone([b'-1;;keyboard unavailable\r\n'])
        self.assertEqual(failed.type_text('ab'), (False, 'keyboard unavailable'))
        self.assertEqual(len(failed.s.sent), 1)
        with self.assertRaises(ValueError):
            failed.type_text('a', delay_ms=-1)

    def test_crlf_types_one_enter_and_unregisters_keyboard_observer(self):
        client = phone([b'0\r\n0\r\n0\r\n'])
        with patch('zxtouch.client.time.sleep'):
            self.assertEqual(client.type_text('a\r\nb'), (True, ''))
        self.assertEqual(client.s.sent[1], datahandler.format_socket_data(
            tasktypes.TASK_PRESS_KEY, 'enter', 50))
        self.assertEqual(len(client.s.sent), 3)
        keyboard = (ROOT / 'appdelegate/UIKeyboard.xm').read_text(encoding='utf-8')
        self.assertEqual(keyboard.count('name:@"com.zjx.zxtouch.keyboardcontrol"'), 3)

    def test_special_and_hardware_buttons(self):
        client = phone([b'0\r\n0\r\n0\r\n'])
        self.assertEqual(client.press_key('Enter'), (True, []))
        self.assertEqual(client.press_home(), (True, []))
        self.assertEqual(client.press_power(175), (True, []))
        self.assertEqual(client.s.sent, [
            datahandler.format_socket_data(tasktypes.TASK_PRESS_KEY, 'enter', 50),
            datahandler.format_socket_data(tasktypes.TASK_PRESS_KEY, 'home', 100),
            datahandler.format_socket_data(tasktypes.TASK_PRESS_KEY, 'power', 175),
        ])
        with self.assertRaises(ValueError):
            client.press_key('home')
        with self.assertRaises(ValueError):
            client.press_power(5001)

    def test_native_dispatch_contract(self):
        task = (ROOT / 'pccontrol/Task.xm').read_text(encoding='utf-8')
        header = (ROOT / 'pccontrol/Task.h').read_text(encoding='utf-8')
        for name, number in [('TASK_INPUT_TEXT', 47), ('TASK_PRESS_KEY', 48)]:
            self.assertIn('#define %s %d' % (name, number), header)
            self.assertEqual(getattr(tasktypes, name), number)
        self.assertIn('initWithBase64EncodedString:', task)
        self.assertIn('postNotificationName:@"com.zjx.zxtouch.keyboardcontrol"', task)
        self.assertIn('IOHIDEventCreateKeyboardEvent(', task)
        self.assertIn('IOHIDEventSystemClientDispatchEvent(client, event)', task)
        self.assertIn('zxSendKeyEvent(hidClient, page, usage.unsignedShortValue, YES)', task)
        self.assertIn('zxSendKeyEvent(hidClient, page, usage.unsignedShortValue, NO)', task)
        self.assertIn('@"home": @64, @"power": @48', task)


if __name__ == '__main__':
    unittest.main()
