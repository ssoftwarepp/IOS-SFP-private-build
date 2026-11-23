import json
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / 'layout/usr/share/zxtouch/examples/Settings Form.bdl'


class ScriptSettingsTests(unittest.TestCase):
    def test_example_bundle_is_complete(self):
        info = plistlib.loads((EXAMPLE / 'info.plist').read_bytes())
        self.assertEqual(info['Entry'], 'main.py')
        self.assertTrue((EXAMPLE / 'index.html').is_file())
        self.assertIn('settings.js', (EXAMPLE / 'index.html').read_text(encoding='utf-8'))
        script = (EXAMPLE / 'settings.js').read_text(encoding='utf-8')
        self.assertIn('iosSfpSettingsSubmit', script)
        self.assertIn('iosSfpSettings.postMessage', script)
        self.assertIn('ios-sfp-settings', script)
        self.assertIn('settings.json', (EXAMPLE / 'main.py').read_text(encoding='utf-8'))

    def test_settings_are_saved_before_script_starts(self):
        presenter = (ROOT / 'pccontrol/ScriptSettings.xm').read_text(encoding='utf-8')
        self.assertIn('writeToFile:[self.bundlePath stringByAppendingPathComponent:@"settings.json"] atomically:YES', presenter)
        self.assertIn('[self finish:YES]', presenter)
        play = (ROOT / 'pccontrol/Play.xm').read_text(encoding='utf-8')
        self.assertIn('zxPresentScriptSettings(bundlePath, YES', play)
        self.assertIn('if (saved)', play)
        self.assertIn('zxStartScript(bundlePath', play)
        self.assertIn('zxReserveScriptSettings()', play)
        self.assertIn('zxScriptSettingsVisible()', play)

    def test_settings_button_and_socket_task(self):
        task_h = (ROOT / 'pccontrol/Task.h').read_text(encoding='utf-8')
        task = (ROOT / 'pccontrol/Task.xm').read_text(encoding='utf-8')
        menu = (ROOT / 'zxtouch/zxtouch/ScriptManagement/MoreOptionsPopOverTableViewController.m').read_text(encoding='utf-8')
        panel = (ROOT / 'pccontrol/Popup.xm').read_text(encoding='utf-8')
        self.assertIn('#define TASK_SHOW_SCRIPT_SETTINGS 36', task_h)
        self.assertIn('taskType == TASK_SHOW_SCRIPT_SETTINGS', task)
        self.assertIn('zxPresentScriptSettings(path, NO, nil)', task)
        self.assertIn('openScriptSettings:', menu)
        self.assertIn('zxPresentScriptSettings(path, NO, nil)', panel)

    def test_package_declares_python3_dependency(self):
        for path in ('control', 'pccontrol/control'):
            with self.subTest(path=path):
                control = (ROOT / path).read_text(encoding='utf-8')
                self.assertIn('python3', next(line for line in control.splitlines()
                                               if line.startswith('Depends: ')).split(', '))

    def test_sample_python_can_read_saved_values(self):
        import importlib.util
        import tempfile
        from unittest.mock import patch
        sample = (EXAMPLE / 'main.py').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'main.py'
            path.write_text(sample, encoding='utf-8')
            (Path(folder) / 'settings.json').write_text(
                json.dumps({'account': 'demo', 'loops': 2, 'mode': 'fast', 'notify': True}), encoding='utf-8')
            with patch('builtins.print') as output:
                exec(compile(sample, str(path), 'exec'), {'__file__': str(path)})
            self.assertEqual(output.call_count, 3)
            output.assert_any_call('run', 1, 'account', 'demo', 'mode', 'fast')


if __name__ == '__main__':
    unittest.main()
