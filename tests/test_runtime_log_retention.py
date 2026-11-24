import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class RuntimeLogRetentionTests(unittest.TestCase):
    def test_five_calendar_days_and_all_readers(self):
        logs = (ROOT / 'zxtouch/zxtouch/RuntimeLogs.h').read_text(encoding='utf-8')
        self.assertIn('for (NSInteger offset = 4; offset >= 0; --offset)', logs)
        self.assertIn('output-%@.log', logs)
        self.assertIn('ZXPruneRuntimeLogs', logs)
        self.assertIn('ZXReadRuntimeLogs', logs)
        self.assertIn('ZXClearRuntimeLogs', logs)
        common = (ROOT / 'pccontrol/Common.xm').read_text(encoding='utf-8')
        self.assertIn('ZXRuntimeLogPaths().lastObject', common)
        self.assertIn('open(logPathForChild,', common)
        for name in ('zxtouch/zxtouch/RemoteDashboardServer.m',
                     'zxtouch/zxtouch/LogViewController.m', 'pccontrol/ScriptPlayer.xm'):
            self.assertIn('ZXReadRuntimeLogs(', (ROOT / name).read_text(encoding='utf-8'))

    def test_both_installers_use_shared_daily_writer(self):
        shared = (ROOT / 'layout/usr/share/zxtouch/add_datetime.sh').read_text(encoding='utf-8')
        installed = (ROOT / 'layout/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/add_datetime.sh').read_text(encoding='utf-8')
        self.assertEqual(shared, installed)
        self.assertIn('for offset in 0 1 2 3 4', shared)
        self.assertIn('output-$today.log', shared)
        for name in ('postinst', 'postinst-roothide'):
            installer = (ROOT / 'layout/DEBIAN' / name).read_text(encoding='utf-8')
            self.assertIn('usr/share/zxtouch/add_datetime.sh', installer)
            self.assertNotIn('OUTPUT=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output\n', installer)

    def test_new_package_does_not_seed_examples(self):
        registry = plistlib.loads((ROOT / 'layout/usr/share/zxtouch/script-registry.plist').read_bytes())
        self.assertEqual(registry['scripts'], [])
        for directory in ('layout/usr/share/zxtouch/examples',
                          'layout/var/mobile/Library/ZXTouch/scripts/examples'):
            self.assertFalse(any(path for path in (ROOT / directory).rglob('info.plist')
                                 if path.parent.name != 'Settings Form.bdl'))

    def test_crop_destination_and_upload_endpoint(self):
        html = (ROOT / 'zxtouch/zxtouch/http/index.html').read_text(encoding='utf-8')
        self.assertIn('id="cropDestination"', html)
        self.assertIn('id="cropFileName"', html)
        self.assertIn('showSaveFilePicker', html)
        self.assertIn("form.append('destination', destination)", html)
        endpoint = (ROOT / 'zxtouch/zxtouch/AdvancedTools.inc').read_text(encoding='utf-8')
        self.assertIn('firstArgumentForControlName:@"destination"', endpoint)
        self.assertIn('bundlePathForRelativePath:script', endpoint)


if __name__ == '__main__':
    unittest.main()
