from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class IOSSFPBrandingTests(unittest.TestCase):
    def test_ios_app_and_package_names(self):
        app = (ROOT / 'zxtouch/zxtouch/Info.plist').read_text(encoding='utf-8')
        self.assertIn('<key>CFBundleDisplayName</key>\n\t<string>IOS-SFP</string>', app)
        self.assertIn('<string>IOS-SFP</string>', app)
        for metadata in ('control', 'pccontrol/control'):
            content = (ROOT / metadata).read_text(encoding='utf-8')
            self.assertIn('Name: IOS-SFP', content)
            self.assertIn('Version: 1.0.2-sfp10-axpoint20261127', content)
        html = (ROOT / 'zxtouch/zxtouch/http/index.html').read_text(encoding='utf-8')
        self.assertIn('class="brand-title">IOS-SFP</h1>', html)

    def test_localized_trigger_mapping_and_numeric_editor(self):
        settings = (ROOT / 'zxtouch/zxtouch/Settings/SettingsPageViewController.m').read_text(encoding='utf-8')
        self.assertIn('isEqualToString:@"音量加键"]) return ZX_TRIGGER_VOLUME_UP;', settings)
        self.assertIn('isEqualToString:@"主屏幕键"]) return ZX_TRIGGER_HOME;', settings)
        for name in ('Volume Up', 'Volume Down', 'Home Button', 'Script Finished Popup',
                     'Settings', 'Script Registry', 'Example Scripts'):
            self.assertNotIn('title:@"' + name + '"', settings)
        editor = (ROOT / 'zxtouch/zxtouch/RecordingEditorViewController.m').read_text(encoding='utf-8')
        self.assertIn('[label containsString:@"坐标"]', editor)
        self.assertIn('[label containsString:@"秒"]', editor)
        self.assertIn('alertControllerWithTitle:@"录制编辑器"', editor)
    def test_chinese_add_menu_preserves_import_actions(self):
        import xml.etree.ElementTree as ET
        path = ROOT / 'zxtouch/zxtouch/ScriptManagement/zh-Hans.lproj/AdderPopOverViewController.xib'
        root = ET.parse(path).getroot()
        buttons = {button.find('state').get('title'): button for button in root.iter('button')}
        for title, selector in (('新建文件夹', 'createFolderButtonClick:'),
                                ('新建脚本', 'createScriptButtonClick:'),
                                ('导入图片', 'importImageButtonClick:'),
                                ('导入文件', 'importFileButtonClick:')):
            self.assertIn(title, buttons)
            self.assertEqual(buttons[title].find('connections/action').get('selector'), selector)


if __name__ == '__main__':
    unittest.main()
