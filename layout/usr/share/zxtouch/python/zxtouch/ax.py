"""Decode native iOS accessibility snapshots returned by ios-mcp."""

import json
import re


def label_matches(actual, expected):
    if expected is None:
        return True
    if isinstance(expected, str) and expected.startswith("re:"):
        return isinstance(actual, str) and re.search(expected[3:], actual) is not None
    return actual == expected


def decode_mcp_elements(data):
    response = json.loads(data)
    if "error" in response:
        raise RuntimeError("AX query failed: {}".format(response["error"].get("message", response["error"])))
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("AX response is missing a result")
    payload = result.get("structuredContent")
    if payload is None:
        for item in result.get("content", []):
            if item.get("type") == "text":
                payload = json.loads(item["text"])
                break
    if result.get("isError") or not isinstance(payload, dict) or not payload.get("ok", True):
        detail = payload.get("error", payload) if isinstance(payload, dict) else payload
        raise RuntimeError("AX query failed: {}".format(detail))
    if not isinstance(payload.get("elements"), list):
        raise RuntimeError("AX response is missing the elements array")
    return payload


def find_tree_elements(tree, *, identifier=None, label=None, value=None, role=None):
    """Find matching nodes in preorder without modifying the AX snapshot."""
    root = tree["root"] if "root" in tree else tree
    filters = {"identifier": identifier, "value": value, "role": role}
    matches = []
    pending = [root]
    while pending:
        node = pending.pop()
        if label_matches(node.get("label"), label) and all(
                expected is None or node.get(key) == expected
                for key, expected in filters.items()):
            matches.append(node)
        pending.extend(reversed(node.get("children", [])))
    return matches


def find_elements(snapshot, *, text=None, type=None, clickable=None):
    """Filter the flat AX snapshot using exact node attributes."""
    elements = snapshot["elements"] if isinstance(snapshot, dict) else snapshot
    return [
        element for element in elements
        if (text is None or element.get("text") == text)
        and (type is None or element.get("type") == type)
        and (clickable is None or element.get("clickable") is clickable)
    ]
