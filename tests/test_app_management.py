import base64
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'layout/usr/share/zxtouch/python'))
from zxtouch import datahandler, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


def framed(value):
    body = json.dumps(value, ensure_ascii=False).encode('utf-8')
    return b'0;;application/json;;%d\r\n' % len(body) + body


class Socket:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = []

    def sendall(self, data):
        self.sent.append(data)

    def recv(self, amount):
        if not self.chunks:
            return b''
        data = self.chunks.pop(0)
        self.chunks[:0] = [data[amount:]] if len(data) > amount else []
        return data[:amount]


def device(chunks):
    result = zxtouch.__new__(zxtouch)
    result.s = Socket(chunks)
    result._recv_buffer = bytearray()
    return result


class AppManagementTests(unittest.TestCase):
    def test_installed_apps_fragmented_and_next_reply(self):
        apps = {'apps': [{'bundleId': 'com.demo.app', 'name': '中文应用', 'type': 'User'}]}
        reply = framed(apps)
        phone = device([reply[:8], reply[8:22], reply[22:] + framed({'name': 'Demo'})])
        self.assertEqual(phone.get_installed_apps(), apps)
        self.assertEqual(phone.get_foreground_process_name(), 'Demo')
        self.assertEqual(phone.s.sent, [datahandler.format_socket_data(tasktypes.TASK_LIST_INSTALLED_APPS),
                                        datahandler.format_socket_data(tasktypes.TASK_GET_FOREGROUND_PROCESS_NAME)])

    def test_empty_apps_and_error(self):
        self.assertEqual(device([framed({'apps': []})]).get_installed_apps(), {'apps': []})
        with self.assertRaisesRegex(RuntimeError, 'unavailable'):
            device([b'-1;;unavailable\r\n']).get_installed_apps()

    def test_clear_data_uses_bundle_id(self):
        phone = device([framed({'bundleId': 'com.demo.app', 'removedEntries': 4})])
        self.assertEqual(phone.clear_app_data('com.demo.app')['removedEntries'], 4)
        self.assertEqual(phone.s.sent, [datahandler.format_socket_data(tasktypes.TASK_CLEAR_APP_DATA, 'com.demo.app')])
        for bad in ('', None, 'a;;b', 'a\r\nb'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                phone.clear_app_data(bad)
        self.assertEqual(len(phone.s.sent), 1)

    def test_clipboard_unicode_separators_newlines_and_empty(self):
        text = '你好;;世界\r\n第二行'
        phone = device([framed({'text': text}) + b'0\r\n'])
        self.assertEqual(phone.get_text_from_clipboard(), (True, text))
        self.assertEqual(phone.set_clipboard_text(text), (True, []))
        self.assertEqual(phone.s.sent[1], datahandler.format_socket_data(
            tasktypes.TASK_SET_CLIPBOARD_TEXT, base64.b64encode(text.encode()).decode('ascii')))
        self.assertEqual(device([framed({'text': ''})]).get_text_from_clipboard(), (True, ''))

    def test_clipboard_errors(self):
        self.assertEqual(device([b'-1;;clipboard unavailable\r\n']).get_text_from_clipboard(),
                         (False, 'clipboard unavailable'))
        self.assertEqual(device([b'-1;;write denied\r\n']).set_clipboard_text('x'),
                         (False, 'write denied'))
        with self.assertRaises(TypeError):
            device([]).set_clipboard_text(None)

    def test_native_container_and_task_protocol(self):
        native = (ROOT / 'pccontrol/Process.xm').read_text(encoding='utf-8')
        task = (ROOT / 'pccontrol/Task.xm').read_text(encoding='utf-8')
        self.assertIn('allInstalledApplications', native)
        self.assertIn('dataContainerURL', native)
        self.assertIn('zxTerminateApplication(bundleID, error)', native)
        self.assertIn('contentsOfDirectoryAtPath:path error:error', native)
        self.assertIn('hasPrefix:@".com.apple.mobile_container_manager."', native)
        self.assertIn('zxForegroundProcessName()', task)
        self.assertIn('UIPasteboard.generalPasteboard.string', task)
        for name, value in [('LIST_INSTALLED_APPS', 42), ('GET_CLIPBOARD_TEXT', 43),
                            ('CLEAR_APP_DATA', 44), ('GET_FOREGROUND_PROCESS_NAME', 45),
                            ('SET_CLIPBOARD_TEXT', 46)]:
            self.assertEqual(getattr(tasktypes, 'TASK_' + name), value)
            self.assertIn('#define TASK_%s %d' % (name, value),
                          (ROOT / 'pccontrol/Task.h').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
