"""Python automation helpers for AX elements, color and multi-scale OpenCV matching.

OpenCV matching runs in the calling Python process; native device matching uses
Accelerate and exposes a single full-screen match through ``image_match``.
"""

import random
import time
from pathlib import Path


def _rect(node):
    frame = node.get("frame") or {}
    if not all(key in frame for key in ("x", "y", "width", "height")):
        return None
    x, y, w, h = (float(frame[key]) for key in ("x", "y", "width", "height"))
    return (x, y, w, h) if w > 0 and h > 0 else None


def locate_elements(tree, *, identifier=None, label=None, value=None, role=None,
                    element_type=None, window_context_id=None):
    """Find AX nodes in preorder; repeated labels remain distinct results."""
    pending = [tree.get("root", tree)]
    matches = []
    expected = {"identifier": identifier, "label": label, "value": value,
                "role": role, "elementType": element_type,
                "windowContextId": window_context_id}
    while pending:
        node = pending.pop()
        if all(want is None or node.get(key) == want for key, want in expected.items()):
            matches.append(node)
        pending.extend(reversed(node.get("children") or []))
    return matches


def tap_element(device, *, index=0, tree=None, identifier=None, label=None,
                value=None, role=None, element_type=None, window_context_id=None,
                delay=0.05, inset_pixels=2):
    """Requery and tap an AX element center; zero-based index disambiguates duplicates."""
    if tree is None:
        tree = device.get_element_tree()
    matches = locate_elements(tree, identifier=identifier, label=label, value=value,
                              role=role, element_type=element_type,
                              window_context_id=window_context_id)
    if index < 0 or index >= len(matches):
        raise LookupError("AX element not found at index {}".format(index))
    rectangle = _rect(matches[index])
    if rectangle is None:
        raise ValueError("AX element has no tappable frame")
    x, y, w, h = rectangle
    inset = max(0.0, float(inset_pixels))
    inset_x = min(inset, w / 3.0)
    inset_y = min(inset, h / 3.0)
    point = (random.uniform(x + inset_x, x + w - inset_x),
             random.uniform(y + inset_y, y + h - inset_y))
    success, raw_scale = device.get_screen_scale()
    if not success:
        raise RuntimeError("Screen scale unavailable: {}".format(raw_scale))
    scale = float(raw_scale)
    point = (point[0] * scale, point[1] * scale)
    device.touch_with_list([
        {"type": 1, "finger_index": 1, "x": point[0], "y": point[1]},
        {"type": 0, "finger_index": 1, "x": point[0], "y": point[1]},
    ])
    return {"x": point[0], "y": point[1], "node": matches[index]}


def find_color(device, rgb, region, tolerance=0):
    """Search device pixels within an RGB tolerance in (x, y, width, height)."""
    channels = tuple(int(value) for value in rgb)
    if len(channels) != 3 or any(value < 0 or value > 255 for value in channels):
        raise ValueError("rgb must contain three 0..255 channels")
    if not 0 <= tolerance <= 255:
        raise ValueError("tolerance must be 0..255")
    bounds = [(max(0, value - tolerance), min(255, value + tolerance)) for value in channels]
    success, result = device.search_color(region, bounds[0][0], bounds[0][1],
                                          bounds[1][0], bounds[1][1],
                                          bounds[2][0], bounds[2][1])
    return result if success and int(result["x"]) >= 0 and int(result["y"]) >= 0 else None


def _intersection_ratio(a, b):
    left = max(a["x"], b["x"])
    top = max(a["y"], b["y"])
    right = min(a["x"] + a["w"], b["x"] + b["w"])
    bottom = min(a["y"] + a["h"], b["y"] + b["h"])
    overlap = max(0, right - left) * max(0, bottom - top)
    return overlap / float(min(a["w"] * a["h"], b["w"] * b["h"]))


def find_img_all(screen_bytes, templates, *, region=None, similarity=0.8,
                 min_scale=0.5, max_scale=1.5, steps=5, gray=True, max_results=100):
    """Return ranked (index, score, x, y, w, h) matches across templates/scales."""
    import cv2
    import numpy as np

    if not 0 < similarity <= 1 or not 0 < min_scale <= max_scale or not 1 <= steps <= 50:
        raise ValueError("invalid similarity or scale range")
    if not 1 <= max_results <= 1000:
        raise ValueError("max_results must be 1..1000")
    raw = cv2.imdecode(np.frombuffer(screen_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if raw is None:
        raise ValueError("screenshot is not a decodable image")
    image_height, image_width = raw.shape[:2]
    if region is None:
        x0, y0, width, height = 0, 0, image_width, image_height
    else:
        x0, y0, width, height = (int(value) for value in region)
        if x0 < 0 or y0 < 0 or width <= 0 or height <= 0 or x0 + width > image_width or y0 + height > image_height:
            raise ValueError("region outside screenshot")
    crop = raw[y0:y0 + height, x0:x0 + width]
    target = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY) if gray else crop
    candidates = []
    for index, path in enumerate(templates):
        template_bytes = np.fromfile(str(Path(path)), dtype=np.uint8)
        source = cv2.imdecode(template_bytes, cv2.IMREAD_COLOR)
        if source is None:
            raise ValueError("template is not a decodable image: {}".format(path))
        if gray:
            source = cv2.cvtColor(source, cv2.COLOR_BGR2GRAY)
        scales = [min_scale + (max_scale - min_scale) * k / max(steps - 1, 1) for k in range(steps)]
        for scale in scales:
            tw, th = round(source.shape[1] * scale), round(source.shape[0] * scale)
            if tw <= 1 or th <= 1 or tw > width or th > height:
                continue
            needle = cv2.resize(source, (tw, th), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR)
            if float(needle.std()) < 1e-6:
                channels = 1 if gray else 3
                error = cv2.matchTemplate(target, needle, cv2.TM_SQDIFF)
                result = 1.0 - np.sqrt(np.maximum(error, 0) / (tw * th * channels)) / 255.0
            else:
                result = cv2.matchTemplate(target, needle, cv2.TM_CCOEFF_NORMED)
            mask = (result >= similarity).astype(np.uint8)
            count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
            for component in range(1, count):
                left, top, comp_width, comp_height, _ = stats[component]
                window = result[top:top + comp_height, left:left + comp_width]
                _, score, _, best = cv2.minMaxLoc(window)
                candidates.append({"index": index, "score": round(float(score), 5),
                                   "x": int(x0 + left + best[0]), "y": int(y0 + top + best[1]),
                                   "w": tw, "h": th})
    candidates.sort(key=lambda item: item["score"], reverse=True)
    matches = []
    for candidate in candidates:
        if all(_intersection_ratio(candidate, previous) < 0.5 for previous in matches):
            matches.append(candidate)
            if len(matches) >= max_results:
                break
    return matches


def find_img_best(screen_bytes, templates, **options):
    """Return the highest score across templates or None."""
    result = find_img_all(screen_bytes, templates, max_results=1, **options)
    return result[0] if result else None


def find_screen_images(device, templates, **options):
    """Capture once then search all templates from the calling Python process."""
    return find_img_all(device.screenshot(), templates, **options)
