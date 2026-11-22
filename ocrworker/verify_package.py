#!/usr/bin/env python3
"""Verify the actual IOS-SFP deb contains the OCR worker and intact resources."""
import argparse
import hashlib
import json
import struct
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER = "usr/libexec/zxtouch/zxtouch-ocr-worker"
MODELS = "usr/share/zxtouch/paddleocr/"


def inspect_deb(package, manifest):
    names = subprocess.check_output(["ar", "t", str(package)], text=True).splitlines()
    archive = next((name for name in names if name.startswith("data.tar.")), None)
    if not archive:
        raise ValueError("deb has no data.tar archive")
    payload = subprocess.check_output(["ar", "p", str(package), archive])
    import io
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as tar:
        members = {entry.name.lstrip("./"): entry for entry in tar.getmembers()}
        candidates = [prefix for prefix in ("", "var/jb/") if prefix + WORKER in members]
        if len(candidates) != 1:
            raise ValueError("OCR worker missing or duplicated across package roots")
        prefix = candidates[0]
        worker = members[prefix + WORKER]
        if not worker.isfile() or not worker.mode & 0o111:
            raise ValueError("executable OCR worker missing from deb")
        stream = tar.extractfile(worker)
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError("OCR worker has a truncated Mach-O header")
        magic, cpu, subtype, filetype, ncmds, command_bytes, _, _ = struct.unpack("<IIIIIIII", header)
        if (magic, cpu, subtype, filetype) != (0xFEEDFACF, 0x0100000C, 0, 2):
            raise ValueError("OCR worker is not a thin arm64 Mach-O executable")
        if not ncmds or ncmds > 1024 or command_bytes > 2 * 1024 * 1024 or command_bytes > worker.size - 32:
            raise ValueError("OCR worker load commands are invalid")
        commands = stream.read(command_bytes)
        if len(commands) != command_bytes:
            raise ValueError("OCR worker load commands are truncated")
        offset, ios_platform = 0, False
        for _ in range(ncmds):
            if offset + 8 > len(commands):
                raise ValueError("OCR worker load commands are truncated")
            kind, size = struct.unpack_from("<II", commands, offset)
            if size < 8 or offset + size > len(commands):
                raise ValueError("OCR worker load command has an invalid size")
            if kind == 0x32 and size >= 24:
                platform = struct.unpack_from("<I", commands, offset + 8)[0]
                ios_platform = platform == 2
            elif kind == 0x25 and size >= 16:
                ios_platform = True
            offset += size
        if offset != command_bytes or not ios_platform:
            raise ValueError("OCR worker is not built for iOS")
        for name in ("det.onnx", "rec.onnx", "dictionary.json", "sha256.json"):
            entry = members.get(prefix + MODELS + name)
            if not entry or not entry.isfile():
                raise ValueError("missing package resource: " + name)
            data = tar.extractfile(entry).read()
            if name == "sha256.json":
                if json.loads(data) != manifest:
                    raise ValueError("package model manifest differs from repository")
            elif hashlib.sha256(data).hexdigest() != manifest[name]:
                raise ValueError("package resource checksum mismatch: " + name)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("deb", type=Path)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "third_party/paddleocr/models/sha256.json").read_text())
    inspect_deb(args.deb, manifest)
    print("PASS", args.deb, "worker and four model resources")


if __name__ == "__main__":
    main()
