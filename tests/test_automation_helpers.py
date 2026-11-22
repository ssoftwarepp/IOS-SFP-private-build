import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "layout/usr/share/zxtouch/python"))

from zxtouch.automation import find_color, find_img_all, find_img_best, locate_elements, tap_element


class MockDevice:
    def __init__(self, tree):
        self.tree = tree
        self.events = []
        self.color_args = None

    def get_element_tree(self):
        return self.tree

    def get_screen_scale(self):
        return True, "3.0"

    def touch(self, *args):
        self.events.append(args)

    def touch_with_list(self, events):
        self.events.append(events)

    def search_color(self, *args):
        self.color_args = args
        return True, {"x": 7, "y": 12}


class AutomationHelpersTests(unittest.TestCase):
    def test_same_label_different_context_preserved_and_tapped(self):
        first = {"role": "AXElement", "label": "确定", "windowContextId": 3,
                 "frame": {"x": 10, "y": 20, "width": 40, "height": 20}, "children": []}
        second = {"role": "AXElement", "label": "确定", "windowContextId": 4,
                  "frame": {"x": 10, "y": 20, "width": 40, "height": 20}, "children": []}
        tree = {"root": {"role": "AXApplication", "children": [first, second]}}
        self.assertEqual(locate_elements(tree, label="确定"), [first, second])
        device = MockDevice(tree)
        with patch("zxtouch.automation.random.uniform", side_effect=[30.0, 30.0]):
            result = tap_element(device, label="确定", window_context_id=4)
        self.assertIs(result["node"], second)
        self.assertEqual(device.events, [[
            {"type": 1, "finger_index": 1, "x": 90.0, "y": 90.0},
            {"type": 0, "finger_index": 1, "x": 90.0, "y": 90.0},
        ]])
        with self.assertRaises(LookupError):
            tap_element(device, label="missing")

    def test_rgb_tolerance_saturates(self):
        device = MockDevice({})
        self.assertEqual(find_color(device, (1, 100, 254), (0, 0, 30, 40), 8), {"x": 7, "y": 12})
        self.assertEqual(device.color_args, ((0, 0, 30, 40), 0, 9, 92, 108, 246, 255))
        device.search_color = lambda *args: (True, {"x": "-1", "y": "-1"})
        self.assertIsNone(find_color(device, (1, 100, 254), (0, 0, 30, 40), 8))

    def test_cv_multi_template_roi_and_duplicate_suppression(self):
        try:
            import cv2
            import numpy as np
        except ImportError:
            self.skipTest("OpenCV is not installed in the test interpreter")
        import tempfile
        rng = np.random.default_rng(19)
        image = np.zeros((100, 140, 3), dtype=np.uint8)
        template = rng.integers(0, 255, (14, 12, 3), dtype=np.uint8)
        image[30:44, 40:52] = template
        image[65:79, 90:102] = template
        _, screen_bytes = cv2.imencode(".png", image)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "template.png"
            path.write_bytes(cv2.imencode(".png", template)[1].tobytes())
            results = find_img_all(screen_bytes.tobytes(), [path], region=(25, 20, 95, 70),
                                   similarity=0.98, min_scale=1, max_scale=1, steps=1)
            black_path = Path(temp) / "black.png"
            black_path.write_bytes(cv2.imencode(".png", np.zeros((4, 4, 3), dtype=np.uint8))[1].tobytes())
            black_screen = cv2.imencode(".png", np.zeros((20, 20, 3), dtype=np.uint8))[1].tobytes()
            self.assertIsNotNone(find_img_best(black_screen, [black_path], similarity=0.99,
                                               min_scale=1, max_scale=1, steps=1))
        self.assertEqual({(item["x"], item["y"]) for item in results}, {(40, 30), (90, 65)})
        self.assertEqual([item["index"] for item in results], [0, 0])
        self.assertEqual(find_img_best(screen_bytes.tobytes(), []), None)
        with self.assertRaises(ValueError):
            find_img_all(screen_bytes.tobytes(), [], region=(120, 0, 40, 10))


if __name__ == "__main__":
    unittest.main()
