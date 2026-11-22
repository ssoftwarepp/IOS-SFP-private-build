import hashlib
import io
import json
import re
import struct
import tarfile
import unittest
from pathlib import Path
from unittest.mock import patch

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parent.parent


class PaddlePackageLayoutTests(unittest.TestCase):
    def test_models_match_manifest(self):
        models = ROOT / "third_party/paddleocr/models"
        manifest = json.loads((models / "sha256.json").read_text(encoding="utf-8"))
        for name in ("det.onnx", "rec.onnx", "dictionary.json"):
            self.assertEqual(hashlib.sha256((models / name).read_bytes()).hexdigest(), manifest[name])

    def test_deb_payload_inspection(self):
        spec = spec_from_file_location("verify_package", ROOT / "ocrworker/verify_package.py")
        verifier = module_from_spec(spec)
        spec.loader.exec_module(verifier)
        source = ROOT / "third_party/paddleocr/models"
        manifest = json.loads((source / "sha256.json").read_text(encoding="utf-8"))

        def payload(include_worker=True, corrupt=False, prefix="", cpu=0x0100000C,
                    filetype=2, platform=2):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as tar:
                if include_worker:
                    worker = tarfile.TarInfo("./" + prefix + verifier.WORKER)
                    worker.mode = 0o755
                    command = struct.pack("<IIIIII", 0x32, 24, platform, 0x000D0000, 0x000D0000, 0)
                    binary = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, filetype,
                                         1, len(command), 0, 0) + command
                    worker.size = len(binary)
                    tar.addfile(worker, io.BytesIO(binary))
                for name in ("det.onnx", "rec.onnx", "dictionary.json", "sha256.json"):
                    data = (source / name).read_bytes()
                    if corrupt and name == "rec.onnx":
                        data = b"invalid"
                    entry = tarfile.TarInfo("./" + prefix + verifier.MODELS + name)
                    entry.size = len(data)
                    tar.addfile(entry, io.BytesIO(data))
            return output.getvalue()

        for prefix in ("", "var/jb/"):
            with self.subTest(prefix=prefix):
                with patch.object(verifier.subprocess, "check_output", side_effect=lambda args, **kwargs:
                                  "data.tar.gz\n" if args[1] == "t" else payload(prefix=prefix)):
                    self.assertTrue(verifier.inspect_deb("synthetic.deb", manifest))
        for worker, bad in ((False, False), (True, True)):
            with self.subTest(worker=worker, corrupt=bad):
                with patch.object(verifier.subprocess, "check_output", side_effect=lambda args, **kwargs:
                                  "data.tar.gz\n" if args[1] == "t" else payload(worker, bad)):
                    with self.assertRaises(ValueError):
                        verifier.inspect_deb("synthetic.deb", manifest)
        for cpu, filetype, platform in ((0x01000007, 2, 2), (0x0100000C, 6, 2),
                                        (0x0100000C, 2, 1)):
            with self.subTest(cpu=cpu, filetype=filetype, platform=platform):
                with patch.object(verifier.subprocess, "check_output", side_effect=lambda args, **kwargs:
                                  "data.tar.gz\n" if args[1] == "t" else payload(cpu=cpu, filetype=filetype, platform=platform)):
                    with self.assertRaises(ValueError):
                        verifier.inspect_deb("synthetic.deb", manifest)

    def test_ci_checks_both_actual_package_archives(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        self.assertIn("test -s third_party/paddleocr/runtime/ios/lib/libonnxruntime.a", workflow)
        self.assertEqual(workflow.count('python3 ocrworker/verify_package.py "$DEB"'), 2)
        self.assertLess(workflow.index('python3 ocrworker/verify_package.py "$DEB"'),
                        workflow.index('name: Upload Rootless deb'))

    def test_worker_and_models_enter_package(self):
        root_make = (ROOT / "Makefile").read_text(encoding="utf-8")
        worker_make = (ROOT / "ocrworker/Makefile").read_text(encoding="utf-8")
        self.assertIn("SUBPROJECTS += ocrworker", root_make)
        self.assertIn('$(THEOS_STAGING_DIR)/usr/share/zxtouch/paddleocr', root_make)
        for name in ("det.onnx", "rec.onnx", "dictionary.json", "sha256.json"):
            self.assertIn("third_party/paddleocr/models/" + name, root_make)
        self.assertIn("../third_party/paddleocr/clipper/clipper.cpp", worker_make)
        self.assertIn("zxtouch-ocr-worker_INSTALL_PATH = /usr/libexec/zxtouch", worker_make)
        self.assertTrue((ROOT / "third_party/paddleocr/clipper/clipper.cpp").is_file())
        for library in re.findall(r"\$\(PADDLE_DEPS\)(/[^\s]+\.a)", worker_make):
            self.assertTrue((ROOT / "third_party/paddleocr/runtime/ios" / library.lstrip("/")).is_file())


if __name__ == "__main__":
    unittest.main()
