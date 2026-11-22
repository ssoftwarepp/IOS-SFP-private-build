"""Reusable image-driven horizontal task scan using the native ZXTouch APIs.

All image coordinates and ROIs are physical screenshot pixels. ``container`` receives
an AX tree and returns a node with a logical-point ``frame``; no XPath is assumed.
Template arguments are existing device-side PNG paths, never MQ Attachment URIs.
"""

import time


def _match(device, paths, region, threshold, max_results=30):
    response = device.match_templates(paths, region=region, threshold=threshold,
                                      max_results=max_results)
    return response["matches"]


def _tap(device, x, y):
    device.touch(1, 1, round(x), round(y))
    device.touch(0, 1, round(x), round(y))


def _wait_for(device, path, region, threshold, present, deadline, clock, sleep,
              interval):
    while clock() < deadline:
        hits = _match(device, [path], region, threshold, 1)
        if clock() >= deadline:
            return False
        if bool(hits) == present:
            return hits[0] if present else True
        sleep(min(interval, max(0, deadline - clock())))
    return False


def _swipe(device, region, direction, step, y, duration, pause, sleep):
    start_x = region[0] + region[2] * (0.7 if direction == "left" else 0.3)
    end_x = start_x + (-step if direction == "left" else step)
    device.touch(1, 1, round(start_x), round(y))
    for part in range(1, 7):
        sleep(duration / 6)
        x = start_x + (end_x - start_x) * part / 6
        device.touch(2, 1, round(x), round(y))
    device.touch(0, 1, round(end_x), round(y))
    sleep(pause)


def _seek_claim(device, path, region, claim_region, threshold, container, scale, edge_x,
                edge_tolerance, step, swipe_y, swipe_duration, pause,
                max_segments, deadline, clock, sleep):
    last_x, stalls = None, 0
    for segment in range(max_segments + 1):
        if clock() >= deadline:
            return None
        hits = _match(device, [path], claim_region, threshold, 1)
        if clock() >= deadline:
            return None
        if hits:
            return hits[0]
        node = container(device.get_element_tree())
        if not node or not node.get("frame"):
            return None
        frame = node["frame"]
        x = float(frame["x"]) * scale
        stalls = stalls + 1 if last_x is not None and abs(x - last_x) <= 2 else 0
        at_edge = (edge_x is not None and x >= edge_x[1]) or stalls >= 2
        if at_edge:
            sleep(min(pause, max(0, deadline - clock())))
            hits = _match(device, [path], claim_region, threshold, 1)
            return hits[0] if hits and clock() < deadline else None
        if segment == max_segments:
            return None
        y = swipe_y if swipe_y is not None else (float(frame["y"]) + float(frame["height"]) / 2) * scale
        last_x = x
        _swipe(device, region, "right", step, y, swipe_duration, pause, sleep)
    return None


def _scan_pass(device, paths, region, threshold, container, scale, edge_x,
               edge_tolerance, step, swipe_y, swipe_duration, pause, max_segments,
               dedupe_pixels, seen, deadline, clock, sleep):
    """Return (hit, relative_x) or (None, None) after both edges are seen."""
    low_seen = high_seen = False
    direction = "right"
    last_x = None
    stalls = 0
    for segment in range(max_segments):
        if clock() >= deadline:
            raise TimeoutError("horizontal scan timed out")
        node = container(device.get_element_tree())
        if not node or not node.get("frame"):
            raise LookupError("horizontal AX container not found")
        frame = node["frame"]
        row_x = float(frame["x"]) * scale
        row_y = float(frame["y"]) * scale
        row_height = float(frame["height"]) * scale
        hits = _match(device, paths, region, threshold)
        if clock() >= deadline:
            raise TimeoutError("horizontal scan timed out")
        for hit in sorted(hits, key=lambda item: item["score"], reverse=True):
            if clock() >= deadline:
                raise TimeoutError("horizontal scan timed out")
            relative_x = hit["x"] + hit["width"] / 2 - row_x
            if all(hit["index"] != index or abs(relative_x - previous) > dedupe_pixels
                   for index, previous in seen):
                return hit, relative_x
        if edge_x is not None:
            low, high = edge_x
            if row_x <= low + edge_tolerance:
                low_seen = True
                direction = "right"
            elif row_x >= high - edge_tolerance:
                high_seen = True
                direction = "left"
        elif last_x is not None:
            stalls = stalls + 1 if abs(row_x - last_x) <= 2 else 0
            if stalls >= 2:
                if direction == "right":
                    high_seen = True
                    direction = "left"
                else:
                    low_seen = True
                    direction = "right"
                stalls = 0
        if low_seen and high_seen:
            return None, None
        if segment == max_segments - 1:
            break
        y = swipe_y if swipe_y is not None else row_y + row_height / 2
        _swipe(device, region, direction, step, y, swipe_duration, pause, sleep)
        last_x = row_x
    raise TimeoutError("horizontal scan segment limit reached before both edges")


def scan_batch(device, *, short_templates, container, region, claim_template,
               close_template, target_app, entry_template=None, entry_region=None,
               entry_verify_template=None, entry_verify_region=None,
               long_templates=(), edge_x=None, edge_tolerance=20, threshold=0.92,
               step=180, swipe_y=None, swipe_duration=0.28, pause=0.45,
               max_segments=60, scan_timeout=45, max_hits=5, dedupe_pixels=12,
               short_dwell=17, long_dwell=62, app_timeout=8,
               verify_timeout=6, verify_interval=0.2, claim_region=None,
               close_region=None, clock=time.monotonic, sleep=time.sleep):
    """Run entry verification and priority batches; return a status/count dictionary.

    ``entry_template=None`` skips the optional entry step. Each pass exhausts both
    horizontal edges before trying the next batch. Every hit is processed once and
    the screen is re-queried after returning to ``target_app``.
    """
    if not short_templates and not long_templates:
        raise ValueError("at least one task template is required")
    if len(short_templates) > 12 or len(long_templates) > 12:
        raise ValueError("each batch supports at most 12 templates")
    if len(region) != 4 or region[2] <= 0 or region[3] <= 0:
        raise ValueError("region must be (x, y, width, height)")
    if entry_template is not None:
        entry = _match(device, [entry_template], entry_region, threshold, 1)
        if not entry:
            return {"status": "entry_not_found", "count": 0}
        hit = entry[0]
        _tap(device, hit["x"] + hit["width"] / 2,
             hit["y"] + hit["height"] / 2)
        if entry_verify_template and not _wait_for(device, entry_verify_template,
                entry_verify_region, threshold, True, clock() + verify_timeout,
                clock, sleep, verify_interval):
            return {"status": "entry_verify_failed", "count": 0}
    success, raw_scale = device.get_screen_scale()
    if not success:
        raise RuntimeError("screen scale unavailable: {}".format(raw_scale))
    scale = float(raw_scale)
    count = 0
    seen = {"short": [], "long": []}
    for _ in range(max_hits):
        for batch, paths, dwell in (("short", short_templates, short_dwell),
                                    ("long", long_templates, long_dwell)):
            if not paths:
                continue
            deadline = clock() + scan_timeout
            try:
                hit, relative_x = _scan_pass(
                    device, paths, region, threshold, container, scale, edge_x,
                    edge_tolerance, step, swipe_y, swipe_duration, pause,
                    max_segments, dedupe_pixels, seen[batch], deadline, clock, sleep)
            except TimeoutError:
                return {"status": "scan_timeout", "count": count}
            if hit is not None:
                seen[batch].append((hit["index"], relative_x))
                _tap(device, hit["x"] + hit["width"] / 2,
                     hit["y"] + hit["height"] / 2)
                count += 1
                sleep(dwell)
                switch_start = clock()
                switched, detail = device.switch_to_app(target_app)
                if not switched or clock() - switch_start >= app_timeout:
                    return {"status": "app_switch_failed", "count": count, "detail": detail}
                claim = _seek_claim(device, claim_template, region, claim_region, threshold,
                                  container, scale, edge_x, edge_tolerance,
                                   step, swipe_y, swipe_duration, pause,
                                   max_segments, clock() + scan_timeout, clock, sleep)
                if not claim:
                    return {"status": "claim_not_found", "count": count}
                _tap(device, claim["x"] + claim["width"] / 2,
                     claim["y"] + claim["height"] / 2)
                close = _wait_for(device, close_template, close_region, threshold,
                                  True, clock() + verify_timeout, clock, sleep, verify_interval)
                if not close:
                    return {"status": "close_not_found", "count": count}
                _tap(device, close["x"] + close["width"] / 2,
                     close["y"] + close["height"] / 2)
                if not _wait_for(device, close_template, close_region, threshold,
                                 False, clock() + verify_timeout, clock, sleep, verify_interval):
                    return {"status": "close_verify_failed", "count": count}
                break
        else:
            return {"status": "complete", "count": count}
    return {"status": "hit_limit", "count": count}
