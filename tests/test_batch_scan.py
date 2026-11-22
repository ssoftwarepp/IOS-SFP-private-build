import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent /
                       "layout/usr/share/zxtouch/python"))

from zxtouch.batch_scan import _scan_pass, scan_batch


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now

    def sleep(self, duration):
        self.now += duration


class Device:
    def __init__(self, task_hits=1):
        self.x = 0
        self.direction = None
        self.task_hits = task_hits
        self.visited = []
        self.events = []
        self.stage = "entry"
        self.app = "com.yy.kiwi"
        self.matched = []

    def get_screen_scale(self):
        return True, "2"

    def get_element_tree(self):
        return {"root": {"children": [{"identifier": "row", "frame": {
            "x": self.x / 2, "y": 200, "width": 200, "height": 30}}]}}

    def match_templates(self, paths, **kwargs):
        name = paths[0]
        self.matched.append((name, kwargs.get("region")))
        found = False
        if name == "entry.png":
            found = self.stage == "entry"
        elif name == "entry_ok.png":
            found = self.stage == "scan"
        elif name == "task.png":
            found = self.stage == "scan" and self.task_hits > 0
        elif name == "claim.png":
            found = self.stage == "claim"
        elif name == "close.png":
            found = self.stage == "close"
        x = 80 + self.x if name == "task.png" else 80
        return {"matches": [{"index": 0, "score": .96, "x": x, "y": 520,
                             "width": 20, "height": 20}] if found else []}

    def touch(self, kind, finger, x, y):
        self.events.append((kind, finger, x, y))
        if kind == 2:
            self.direction = "right" if x > self.events[-2][2] else "left"
        elif kind == 0 and self.direction:
            self.x = max(0, min(100, self.x + (50 if self.direction == "right" else -50)))
            self.visited.append(self.x)
            self.direction = None
        elif kind == 0 and self.stage == "entry":
            self.stage = "scan"
        elif kind == 0 and self.stage == "scan":
            self.task_hits -= 1
            self.stage = "external"
        elif kind == 0 and self.stage == "claim":
            self.stage = "close"
        elif kind == 0 and self.stage == "close":
            self.stage = "scan"

    def switch_to_app(self, bundle):
        self.app = bundle
        self.stage = "claim"
        return True, ""


def row(tree):
    return tree["root"]["children"][0]


class BatchScanTests(unittest.TestCase):
    def config(self, device, clock, **extra):
        options = dict(short_templates=["task.png"], container=row,
                       region=(0, 493, 300, 190), claim_template="claim.png",
                       close_template="close.png", target_app="com.yy.kiwi",
                       edge_x=(0, 100), edge_tolerance=2, step=50,
                       short_dwell=0, swipe_duration=0, pause=.1,
                       clock=clock, sleep=clock.sleep)
        options.update(extra)
        return scan_batch(device, **options)

    def test_entry_task_return_claim_close_and_both_edges(self):
        device, clock = Device(), Clock()
        device.x = 50
        result = self.config(device, clock, entry_template="entry.png",
                             entry_region=(20, 0, 50, 150),
                             entry_verify_template="entry_ok.png")
        self.assertEqual(result, {"status": "complete", "count": 1})
        self.assertEqual(device.app, "com.yy.kiwi")
        self.assertIn(0, device.visited)
        self.assertIn(100, device.visited)
        self.assertIn(("entry.png", (20, 0, 50, 150)), device.matched)
        self.assertIn(("task.png", (0, 493, 300, 190)), device.matched)
        self.assertEqual(len([event for event in device.events if event[0] == 0 and
                              event[2] == 90]), 3)
        self.assertIn((0, 1, 140, 530), device.events)

    def test_different_templates_at_same_relative_x_remain_distinct(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        device.match_templates = lambda paths, **kwargs: {"matches": [
            {"index": 0, "score": .96, "x": 80, "y": 520, "width": 20, "height": 20},
            {"index": 1, "score": .95, "x": 80, "y": 520, "width": 20, "height": 20},
        ]}
        hit, relative = _scan_pass(device, ["task-a.png", "task-b.png"],
                                    (0, 493, 300, 190), .92, row, 2, (0, 100), 2,
                                    50, None, 0, .1, 10, 12, [(0, 90)], 10,
                                    clock, clock.sleep)
        self.assertEqual(hit["index"], 1)
        self.assertEqual(relative, 90)

    def test_relative_x_deduplicates_repeat_hit_after_return(self):
        device, clock = Device(task_hits=3), Clock()
        device.stage = "scan"
        result = self.config(device, clock)
        self.assertEqual(result, {"status": "complete", "count": 1})
        self.assertEqual(device.task_hits, 2)

    def test_limit_and_timeout(self):
        device, clock = Device(task_hits=3), Clock()
        device.stage = "scan"
        self.assertEqual(self.config(device, clock, max_hits=1),
                         {"status": "hit_limit", "count": 1})
        device, clock = Device(task_hits=0), Clock()
        device.stage = "scan"
        self.assertEqual(self.config(device, clock, scan_timeout=.05),
                         {"status": "scan_timeout", "count": 0})

    def test_scan_deadline_expires_during_matching(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_match = device.match_templates

        def slow_match(paths, **kwargs):
            result = original_match(paths, **kwargs)
            clock.now += 1
            return result

        device.match_templates = slow_match
        self.assertEqual(self.config(device, clock, scan_timeout=.5),
                         {"status": "scan_timeout", "count": 0})
        self.assertEqual(device.task_hits, 1)

    def test_claim_is_found_by_horizontal_seek_after_app_return(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        device.x = 0
        match = device.match_templates

        def claim_at_other_end(paths, **kwargs):
            if paths == ["claim.png"] and device.x < 100:
                return {"matches": []}
            return match(paths, **kwargs)

        device.match_templates = claim_at_other_end
        result = self.config(device, clock)
        self.assertEqual(result, {"status": "complete", "count": 1})
        self.assertIn(100, device.visited)

    def test_claim_search_honors_region(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        result = self.config(device, clock, claim_region=(10, 25, 100, 200))
        self.assertEqual(result, {"status": "complete", "count": 1})
        self.assertIn(("claim.png", (10, 25, 100, 200)), device.matched)

    def test_claim_match_after_deadline_is_ignored(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_match = device.match_templates

        def delayed_claim(paths, **kwargs):
            result = original_match(paths, **kwargs)
            if paths == ["claim.png"]:
                clock.now += 9
            return result

        device.match_templates = delayed_claim
        self.assertEqual(self.config(device, clock, scan_timeout=8),
                         {"status": "claim_not_found", "count": 1})
        self.assertEqual(device.stage, "claim")

    def test_claim_scan_can_outlast_app_switch_timeout(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_match = device.match_templates
        waited = [False]

        def delayed_claim(paths, **kwargs):
            if paths == ["claim.png"] and not waited[0]:
                waited[0] = True
                clock.now += 9
                return {"matches": []}
            return original_match(paths, **kwargs)

        device.match_templates = delayed_claim
        self.assertEqual(self.config(device, clock, app_timeout=8, scan_timeout=45),
                         {"status": "complete", "count": 1})

    def test_app_switch_uses_its_own_timeout(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_switch = device.switch_to_app

        def slow_switch(bundle):
            result = original_switch(bundle)
            clock.now += 9
            return result

        device.switch_to_app = slow_switch
        self.assertEqual(self.config(device, clock, app_timeout=8),
                         {"status": "app_switch_failed", "count": 1, "detail": ""})

    def test_close_must_disappear(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_touch = device.touch

        def keep_close(kind, finger, x, y):
            original_touch(kind, finger, x, y)
            if kind == 0 and device.stage == "scan" and device.task_hits == 0:
                device.stage = "close"

        device.touch = keep_close
        self.assertEqual(self.config(device, clock, verify_timeout=.3),
                         {"status": "close_verify_failed", "count": 1})

    def test_close_disappearance_ignores_late_result(self):
        device, clock = Device(), Clock()
        device.stage = "scan"
        original_match = device.match_templates
        close_calls = [0]

        def late_disappearance(paths, **kwargs):
            result = original_match(paths, **kwargs)
            if paths == ["close.png"]:
                close_calls[0] += 1
                if close_calls[0] == 2:
                    clock.now += 7
            return result

        device.match_templates = late_disappearance
        self.assertEqual(self.config(device, clock, verify_timeout=6),
                         {"status": "close_verify_failed", "count": 1})

    def test_entry_verification_ignores_late_match(self):
        device, clock = Device(), Clock()
        original_match = device.match_templates

        def late_match(paths, **kwargs):
            result = original_match(paths, **kwargs)
            if paths == ["entry_ok.png"]:
                clock.now += 7
            return result

        device.match_templates = late_match
        self.assertEqual(self.config(device, clock, entry_template="entry.png",
                                     entry_verify_template="entry_ok.png", verify_timeout=6),
                         {"status": "entry_verify_failed", "count": 0})

    def test_entry_verification_failure(self):
        device, clock = Device(), Clock()
        result = self.config(device, clock, entry_template="entry.png",
                             entry_verify_template="missing.png", verify_timeout=.3)
        self.assertEqual(result, {"status": "entry_verify_failed", "count": 0})


if __name__ == "__main__":
    unittest.main()
