"""Prepare an isolated old-account branch snapshot for AX C-interface CI."""
import argparse
import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "ssoftwarepp/IOS-SFP-private-build"
BRANCH = "codex/visible2095-c-ax-diagnostics"
BASE = "https://api.github.com/repos/" + REPO
TOKEN = os.environ["IOS_BUILD_TOKEN"]
HEADERS = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json",
    "User-Agent": "IOS-SFP-AX-diagnostics",
    "X-GitHub-Api-Version": "2022-11-28",
}
PROXY = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}) if PROXY
    else urllib.request.ProxyHandler({})
)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--dry-run", action="store_true", help="report changed paths without creating Git objects or refs")
ARGS = parser.parse_args()
FILES = [
    "pccontrol/AccessibilityTree.xm",
    "pccontrol/AccessibilityTree.h",
    "pccontrol/Task.h",
    "pccontrol/Task.xm",
    "pccontrol/Visible2095Capture.inc",
    "layout/usr/share/zxtouch/python/zxtouch/automation.py",
    "layout/usr/share/zxtouch/python/zxtouch/ax.py",
    "layout/usr/share/zxtouch/python/zxtouch/client.py",
    "layout/usr/share/zxtouch/python/zxtouch/tasktypes.py",
    "layout/usr/share/zxtouch/python/zxtouch/deviceinfotasktypes.py",
    "tests/test_automation_helpers.py",
    "zxtouch/zxtouch/RemoteDashboardServer.m",
    "zxtouch/zxtouch/DashboardTools.inc",
    "zxtouch/zxtouch/http/index.html",
    "tests/test_ax_elements.py",
    "tests/test_dashboard_tools.py",
    "tests/test_visible2095_diagnostics.py",
    "API_REFERENCE.md",
    "AX_VISIBLE2095_DIAGNOSTICS.md",
    "readme.md",
    "build/prepare_ax_public_build.py",
    "build/fetch_public_ax_build_artifacts.py",
]


def request(path, payload=None, method=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(BASE + path, data=data, headers=HEADERS, method=method)
    try:
        with OPENER.open(req, timeout=45) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError("GitHub API {} {}: {}".format(exc.code, path, detail)) from exc


status, repo_data = request("")
if status != 200 or repo_data.get("private") is not False:
    raise RuntimeError("Target repository is not publicly visible")
_, main_ref = request("/git/ref/heads/main")
base_sha = main_ref["object"]["sha"]
_, base_commit = request("/git/commits/" + base_sha)
base_tree = base_commit["tree"]["sha"]
_, tree_data = request("/git/trees/" + base_tree + "?recursive=1")
entries = {entry["path"]: entry for entry in tree_data["tree"]}
if tree_data.get("truncated"):
    raise RuntimeError("Base repository tree response was truncated")

branch_path = "/git/ref/heads/" + urllib.parse.quote(BRANCH, safe="/")
branch_exists = True
try:
    _, existing_ref = request(branch_path)
except RuntimeError as exc:
    if "404" not in str(exc):
        raise
    branch_exists = False
    existing_ref = None
if branch_exists and existing_ref["object"]["sha"] != base_sha:
    raise RuntimeError("Diagnostic branch already exists and does not point to the verified main base")


def blob_for(path, content):
    encoded = base64.b64encode(content).decode("ascii")
    _, blob = request("/git/blobs", {"content": encoded, "encoding": "base64"}, "POST")
    return {"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]}


changed = []
for relative in FILES:
    local = ROOT / relative
    if not local.is_file():
        raise RuntimeError("Required local file is absent: " + relative)
    content = local.read_bytes()
    if entries.get(relative, {}).get("type") == "blob":
        current_sha = entries[relative]["sha"]
        _, current_blob = request("/git/blobs/" + current_sha)
        old = base64.b64decode(current_blob["content"])
        if old == content:
            continue
    changed.append({"path": relative, "content": content})

if not changed:
    raise RuntimeError("No AX files differ from public main")
if ARGS.dry_run:
    print(json.dumps({"repository": REPO, "visibility": "public", "base_sha": base_sha,
        "branch": BRANCH, "changed_paths": [item["path"] for item in changed]}, ensure_ascii=False), flush=True)
    raise SystemExit(0)
changed = [blob_for(item["path"], item["content"]) for item in changed]
_, new_tree = request("/git/trees", {"base_tree": base_tree, "tree": changed}, "POST")
message = "Add C AX 2095 capture diagnostics"
_, new_commit = request("/git/commits", {
    "message": message,
    "tree": new_tree["sha"],
    "parents": [base_sha],
}, "POST")
new_sha = new_commit["sha"]
try:
    _, ref = request("/git/refs", {"ref": "refs/heads/" + BRANCH, "sha": new_sha}, "POST")
except RuntimeError as exc:
    if "Reference already exists" not in str(exc) and "422" not in str(exc):
        raise
    _, ref = request("/git/refs/heads/" + urllib.parse.quote(BRANCH, safe="/"))
    if ref["object"]["sha"] != base_sha:
        raise RuntimeError("Target branch already exists at an unexpected commit")
    request("/git/refs/heads/" + urllib.parse.quote(BRANCH, safe="/"),
            {"sha": new_sha, "force": False}, "PATCH")

# Dispatch only after the isolated branch has the verified commit.
workflow_path = ".github/workflows/build.yml"
_, workflows = request("/actions/workflows")
workflow_id = next((item["id"] for item in workflows["workflows"] if item["path"] == workflow_path), None)
if workflow_id is None:
    raise RuntimeError("Build workflow id not found")
_, runs = request("/actions/runs?branch=" + urllib.parse.quote(BRANCH, safe="") + "&per_page=10")
existing = [run for run in runs["workflow_runs"] if run["head_sha"] == new_sha]
if not existing:
    request("/actions/workflows/{}/dispatches".format(workflow_id), {"ref": BRANCH}, "POST")
    existing = []
    for _ in range(12):
        time.sleep(5)
        _, runs = request("/actions/runs?branch=" + urllib.parse.quote(BRANCH, safe="") + "&per_page=10")
        existing = [run for run in runs["workflow_runs"] if run["head_sha"] == new_sha]
        if existing:
            break
if not existing:
    raise RuntimeError("Workflow dispatch returned without a matching run")
print(json.dumps({"repository": REPO, "visibility": "public", "base_sha": base_sha,
    "branch": BRANCH, "commit_sha": new_sha, "changed_paths": [item["path"] for item in changed],
    "run_id": existing[0]["id"], "run_url": existing[0]["html_url"]}, ensure_ascii=False), flush=True)
