"""Download and inspect the two DEBs from the public AX diagnostic build."""
import hashlib
import io
import json
import os
import struct
import tarfile
import urllib.parse
import urllib.request
import zipfile
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_ID = int(os.environ["IOS_AX_RUN_ID"])
SHA = os.environ["IOS_AX_BUILD_SHA"]
BASE = "https://api.github.com/repos/ssoftwarepp/IOS-SFP-private-build"
OUTPUT = ROOT / "build" / ("public_ax_artifacts_" + str(RUN_ID))
TOKEN = os.environ["IOS_BUILD_TOKEN"]
HEADERS = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "User-Agent": "IOS-SFP-build",
    "X-GitHub-Api-Version": "2022-11-28",
}


class RemoveCrossHostAuthorization(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None and urllib.parse.urlparse(request.full_url).netloc != urllib.parse.urlparse(new_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


PROXY = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}) if PROXY
    else urllib.request.ProxyHandler({}),
    RemoveCrossHostAuthorization(),
)


def get(path):
    with OPENER.open(urllib.request.Request(BASE + path, headers=HEADERS), timeout=40) as response:
        return json.load(response)


def get_artifact(artifact_id, path):
    request = urllib.request.Request(BASE + path, headers=HEADERS)
    with OPENER.open(request, timeout=60) as response:
        return response.read()


def ar_payload(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("DEB is not an ar archive")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("Invalid ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        start = offset + 60
        if start + size > len(data):
            raise ValueError("Truncated ar member")
        if name.startswith("data.tar"):
            return data[start:start + size]
        offset = start + size + size % 2
    raise ValueError("No DEB data payload")


def inspect_package(path):
    data = path.read_bytes()
    with tarfile.open(fileobj=io.BytesIO(ar_payload(data)), mode="r:*") as archive:
        members = {member.name.lstrip("./"): member for member in archive.getmembers()}
        worker_suffix = "usr/libexec/zxtouch/zxtouch-ocr-worker"
        prefixes = [prefix for prefix in ("", "var/jb/") if prefix + worker_suffix in members]
        if len(prefixes) != 1:
            raise ValueError("Missing or duplicated OCR worker")
        prefix = prefixes[0]
        worker = members[prefix + worker_suffix]
        if not worker.isfile() or not worker.mode & 0o111:
            raise ValueError("OCR worker is not executable")
        worker_header = archive.extractfile(worker).read(32)
        if len(worker_header) != 32 or struct.unpack("<IIII", worker_header[:16]) != (0xFEEDFACF, 0x0100000C, 0, 2):
            raise ValueError("OCR worker is not an arm64 executable")
        model_root = prefix + "usr/share/zxtouch/paddleocr/"
        manifest = json.load(archive.extractfile(members[model_root + "sha256.json"]))
        for name in ("det.onnx", "rec.onnx", "dictionary.json"):
            digest = hashlib.sha256(archive.extractfile(members[model_root + name]).read()).hexdigest()
            if digest != manifest[name]:
                raise ValueError("OCR resource digest mismatch: " + name)
        dylibs = [member for name, member in members.items() if name.endswith("/pccontrol.dylib")]
        if len(dylibs) != 1:
            raise ValueError("Missing or duplicated pccontrol dylib")
        dylib_data = archive.extractfile(dylibs[0]).read()
        for marker in (b"runtime-load", b"symbol-create", b"application-create", b"visible-copy-2095",
                       b"attributeStats", b"errorCode=%ld", b"Visible2095Capture"):
            if marker not in dylib_data:
                raise ValueError("Diagnostic marker missing: " + marker.decode())
        app_binaries = [name for name in members if name.endswith("/Applications/zxtouch.app/zxtouch") or name == "Applications/zxtouch.app/zxtouch"]
        if len(app_binaries) != 1:
            raise ValueError("Missing or duplicated zxtouch app")
    return {"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "ocr_models_verified": True, "ax_diagnostic_markers_verified": True, "app_present": True}


def main():
    run = get("/actions/runs/" + str(RUN_ID))
    if run["status"] != "completed" or run["conclusion"] != "success" or run["head_sha"] != SHA:
        raise RuntimeError("The expected build has not succeeded")
    artifacts = get("/actions/runs/" + str(RUN_ID) + "/artifacts?per_page=100")["artifacts"]
    OUTPUT.mkdir(parents=True, exist_ok=True)
    receipts = []
    for expected_name in ("IOS-SFP-rootless-deb", "IOS-SFP-roothide-deb"):
        matches = [artifact for artifact in artifacts if artifact["name"] == expected_name and not artifact["expired"]]
        if len(matches) != 1:
            raise RuntimeError("Missing or duplicated artifact: " + expected_name)
        artifact = matches[0]
        archive_path = OUTPUT / (expected_name + ".zip")
        data = get_artifact(artifact["id"], "/actions/artifacts/" + str(artifact["id"]) + "/zip")
        archive_path.write_bytes(data)
        digest = "sha256:" + hashlib.sha256(archive_path.read_bytes()).hexdigest()
        if artifact.get("digest") and digest != artifact["digest"]:
            raise ValueError("Artifact digest mismatch: " + expected_name)
        with zipfile.ZipFile(archive_path) as archive:
            debs = [entry for entry in archive.infolist() if entry.filename.endswith(".deb") and not entry.is_dir()]
            if len(debs) != 1:
                raise ValueError("Expected exactly one DEB in " + expected_name)
            entry = debs[0]
            target = OUTPUT / Path(entry.filename).name
            target.write_bytes(archive.read(entry))
        receipt = inspect_package(target)
        receipt["artifact_id"] = artifact["id"]
        receipt["artifact_name"] = expected_name
        receipt["artifact_sha256"] = digest
        receipts.append(receipt)
        print(json.dumps(receipt, ensure_ascii=False), flush=True)
    result = {"run_id": RUN_ID, "commit": SHA, "packages": receipts}
    receipt_path = OUTPUT / "verification.json"
    receipt_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("receipt=" + str(receipt_path), flush=True)


if __name__ == "__main__":
    main()
