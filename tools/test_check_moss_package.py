"""Regression cases for the MOSS deployment package auditor; no device needed."""
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from check_moss_package import (
    ManifestError,
    audit,
    describe,
    main,
    rewrite_zip_manifest,
)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _manifest(entries) -> dict:
    return {
        "schemaVersion": 1,
        "files": [
            {"path": path, "size": len(data), "sha256": _sha(data)}
            for path, data in entries
        ],
    }


def _write_package(root: Path, entries, *, manifest: dict | None = None) -> Path:
    for path, data in entries:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (root / "moss-qnn-deployment.json").write_text(
        json.dumps(manifest or _manifest(entries)),
        encoding="utf-8",
    )
    return root


def _entries():
    return [
        ("MOSS-TTS-Nano-100M-ONNX/moss_tts_global_shared.data", b"weights" * 100),
        ("MOSS-TTS-Nano-100M-ONNX/tokenizer.model", b"tokenizer"),
        ("MOSS-Audio-Tokenizer-Nano-ONNX/codec.qnn.onnx", b"codec"),
    ]


class DirectoryAuditTests(unittest.TestCase):
    def test_complete_package_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            package = _write_package(Path(directory), _entries())
            report = audit(package)
            self.assertTrue(report["ok"], report)
            self.assertEqual(report["declared_files"], 3)
            self.assertIn("OK", describe(report))

    def test_names_every_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = _entries()
            package = _write_package(root, entries)
            (root / entries[1][0]).unlink()
            report = audit(package)
            self.assertFalse(report["ok"])
            self.assertEqual(report["missing"], [entries[1][0]])
            self.assertIn(entries[1][0], describe(report))

    def test_detects_truncated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = _entries()
            package = _write_package(root, entries)
            (root / entries[0][0]).write_bytes(b"weights" * 10)
            report = audit(package)
            self.assertFalse(report["ok"])
            self.assertEqual(len(report["size_mismatch"]), 1)
            self.assertEqual(report["hash_mismatch"], [])

    def test_detects_corrupt_payload_and_hash_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = _entries()
            package = _write_package(root, entries)
            (root / entries[2][0]).write_bytes(b"codeX")
            self.assertEqual(audit(package)["hash_mismatch"], [entries[2][0]])
            self.assertTrue(audit(package, verify_hashes=False)["ok"])

    def test_rejects_escaping_manifest_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _manifest(_entries()) | {
                "files": [{"path": "../escape.bin", "size": 1, "sha256": "0" * 64}]
            }
            package = _write_package(root, [], manifest=manifest)
            report = audit(package)
            self.assertFalse(report["ok"])
            self.assertTrue(report["errors"])

    def test_missing_manifest_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            report = audit(Path(directory))
            self.assertFalse(report["ok"])
            self.assertIn("cannot read", report["errors"][0])

    def test_rejects_unknown_input(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "package.bin"
            target.write_bytes(b"not a zip")
            with self.assertRaises(ManifestError):
                audit(target)


class ZipAuditTests(unittest.TestCase):
    def _build_zip(self, path: Path, entries, prefix: str = "moss-qnn-v81-streaming/"):
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in entries:
                archive.writestr(prefix + name, data)
            archive.writestr(
                prefix + "moss-qnn-deployment.json",
                json.dumps(_manifest(_entries())),
            )
        return path

    def test_wrapped_zip_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self._build_zip(Path(directory) / "pkg.zip", _entries())
            report = audit(archive)
            self.assertTrue(report["ok"], report)
            self.assertEqual(report["declared_files"], 3)

    def test_zip_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            entries = _entries()[:2]
            archive = self._build_zip(Path(directory) / "pkg.zip", entries)
            report = audit(archive)
            self.assertFalse(report["ok"])
            self.assertEqual(report["missing"], [_entries()[2][0]])

    def test_zip_without_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pkg.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("model.onnx", b"data")
            report = audit(path)
            self.assertFalse(report["ok"])
            self.assertIn("deployment manifest", report["errors"][0])

    def test_zip_with_escaping_entry_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pkg.zip"
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in _entries():
                    archive.writestr(name, data)
                archive.writestr("../evil.bin", b"x")
                archive.writestr(
                    "moss-qnn-deployment.json",
                    json.dumps(_manifest(_entries())),
                )
            report = audit(path)
            self.assertFalse(report["ok"])
            self.assertTrue(any("unsafe" in error for error in report["errors"]))


class RewriteTests(unittest.TestCase):
    def _stale_zip(self, directory: Path, stale_manifest: dict) -> Path:
        path = directory / "stale.zip"
        prefix = "moss-qnn-v81-streaming/"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in _entries():
                archive.writestr(prefix + name, data)
            archive.writestr(prefix + "moss-qnn-deployment.json", json.dumps(stale_manifest))
        return path

    def test_repairs_a_stale_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = _entries()
            stale = _manifest(entries)
            stale["files"][0]["size"] += 5
            archive = self._stale_zip(root, stale)
            correct = root / "correct.json"
            correct.write_text(json.dumps(_manifest(entries)), encoding="utf-8")
            output = root / "fixed.zip"

            self.assertFalse(audit(archive)["ok"])
            report = rewrite_zip_manifest(archive, correct, output)
            self.assertTrue(report["ok"], report)
            self.assertTrue(audit(output)["ok"])

    def test_refuses_a_manifest_that_does_not_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self._stale_zip(root, _manifest(_entries()))
            wrong = _manifest([("MOSS-TTS-Nano-100M-ONNX/tokenizer.model", b"different")])
            manifest = root / "wrong.json"
            manifest.write_text(json.dumps(wrong), encoding="utf-8")
            output = root / "fixed.zip"
            with self.assertRaises(ManifestError):
                rewrite_zip_manifest(archive, manifest, output)
            self.assertFalse(output.exists())

    def test_refuses_to_overwrite_the_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self._stale_zip(root, _manifest(_entries()))
            with self.assertRaises(ManifestError):
                rewrite_zip_manifest(archive, root / "stale.zip", archive)


class CommandLineTests(unittest.TestCase):
    def test_exit_codes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write_package(root, _entries())
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(main([str(root), "--json"]), 0)
            self.assertTrue(json.loads(out.getvalue())["ok"])

            (root / _entries()[0][0]).unlink()
            with redirect_stdout(out):
                self.assertEqual(main([str(root)]), 2)

            with redirect_stderr(io.StringIO()):
                self.assertEqual(main([str(root / "missing")]), 1)
            self.assertFalse((root / "missing").exists())

    def test_real_repository_manifest_is_valid(self):
        manifest = Path("model/TTS/moss-qnn-v81-streaming/moss-qnn-deployment.json")
        if not manifest.is_file():
            self.skipTest("repository manifest is not available")
        report = audit(Path("model/TTS/moss-qnn-v81-streaming"))
        # The weights are intentionally not committed, so the audit must fail
        # while still parsing the manifest successfully.
        self.assertEqual(report["declared_files"], 13)
        self.assertGreater(report["declared_bytes"], 650 * 1024 * 1024)
        self.assertTrue(report["missing"])


if __name__ == "__main__":
    unittest.main()
