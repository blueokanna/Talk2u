#!/usr/bin/env python3
"""Verify a MOSS-TTS-Nano QNN deployment package against its manifest.

The application refuses to import a package unless every file declared in
``moss-qnn-deployment.json`` exists with the declared size and SHA-256. This tool
performs the same audit ahead of time, directly on a directory or on the
``moss-qnn-v81-streaming.zip`` archive, so a missing or truncated download is
reported by name instead of surfacing as a generic import failure on the phone.

Usage:
    python tools/check_moss_package.py model/TTS/moss-qnn-v81-streaming
    python tools/check_moss_package.py C:/Downloads/moss-qnn-v81-streaming.zip
    python tools/check_moss_package.py <package> --json
    python tools/check_moss_package.py <stale.zip> --rewrite-manifest \\
        model/TTS/moss-qnn-v81-streaming/moss-qnn-deployment.json \\
        --output build/moss-qnn-v81-streaming.zip

Exit codes: 0 complete, 1 usage error, 2 incomplete or invalid.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile

MANIFEST_NAMES = ("moss-qnn-deployment.json", "moss-qqn-deployment.json")
CHUNK_BYTES = 1024 * 1024


class ManifestError(ValueError):
    """The package or its manifest is unusable."""


def _safe_relative(path: str) -> PurePosixPath:
    """Normalizes a manifest/archive path and rejects anything that escapes root."""
    normalized = str(path).replace("\\", "/").strip()
    pure = PurePosixPath(normalized)
    if not normalized or pure.is_absolute() or ".." in pure.parts:
        raise ManifestError(f"unsafe path in package: {path!r}")
    return pure


def _validate_manifest(manifest: object, label: str) -> dict:
    if not isinstance(manifest, dict):
        raise ManifestError(f"{label} is not a JSON object")
    if manifest.get("schemaVersion") != 1:
        raise ManifestError(f"{label} has an unsupported schemaVersion")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise ManifestError(f"{label} declares no files")
    seen = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ManifestError(f"{label} file entries must be objects")
        path = _safe_relative(entry.get("path", ""))
        if path in seen:
            raise ManifestError(f"{label} declares {path} twice")
        seen.add(path)
        if not isinstance(entry.get("size"), int) or entry["size"] <= 0:
            raise ManifestError(f"{label} has an invalid size for {path}")
        digest = str(entry.get("sha256", "")).lower()
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ManifestError(f"{label} has an invalid sha256 for {path}")
    return manifest


def load_manifest(manifest_path: Path) -> dict:
    try:
        payload = manifest_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ManifestError(f"cannot read {manifest_path}: {error}") from error
    try:
        manifest = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ManifestError(f"{manifest_path} is not valid JSON: {error}") from error
    return _validate_manifest(manifest, str(manifest_path))


def _new_report(package: Path, manifest: str) -> dict:
    return {
        "package": str(package),
        "manifest": manifest,
        "ok": False,
        "declared_files": 0,
        "declared_bytes": 0,
        "missing": [],
        "size_mismatch": [],
        "hash_mismatch": [],
        "errors": [],
    }


def _digest(stream) -> tuple[int, str]:
    """Streams a file-like object and returns its size and SHA-256."""
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = stream.read(CHUNK_BYTES)
        if not chunk:
            break
        size += len(chunk)
        digest.update(chunk)
    return size, digest.hexdigest()


def _audit_entries(report: dict, files: list, open_reader, verify_hashes: bool):
    """Probes every declared file with ``open_reader(path) -> stream | None``."""
    for entry in files:
        relative = _safe_relative(entry["path"])
        expected_size = entry["size"]
        stream = open_reader(relative)
        if stream is None:
            report["missing"].append(str(relative))
            continue
        with stream:
            size, digest = _digest(stream)
        if size != expected_size:
            report["size_mismatch"].append(
                f"{relative} ({size} of {expected_size} bytes)"
            )
            continue
        if verify_hashes and digest != entry["sha256"]:
            report["hash_mismatch"].append(str(relative))
    report["ok"] = not (
        report["missing"]
        or report["size_mismatch"]
        or report["hash_mismatch"]
        or report["errors"]
    )
    return report


def audit_directory(
    package: Path,
    manifest_path: Path | None = None,
    *,
    verify_hashes: bool = True,
) -> dict:
    root = package.resolve()
    manifest_file = manifest_path or root / MANIFEST_NAMES[0]
    report = _new_report(package, str(manifest_file))
    try:
        manifest = load_manifest(manifest_file)
    except ManifestError as error:
        report["errors"].append(str(error))
        return report

    files = manifest["files"]
    report["declared_files"] = len(files)
    report["declared_bytes"] = sum(entry["size"] for entry in files)

    def open_reader(relative: PurePosixPath):
        target = (root.joinpath(*relative.parts)).resolve()
        if target != root and root not in target.parents:
            report["errors"].append(f"{relative} escapes the package directory")
            return None
        if target.is_symlink() or not target.is_file():
            return None
        return target.open("rb")

    return _audit_entries(report, files, open_reader, verify_hashes)


def _zip_manifest(source: zipfile.ZipFile, names: dict) -> tuple[dict, PurePosixPath]:
    """Reads the embedded manifest and returns it with its wrapper prefix."""
    candidates = [path for path in names if path.name in MANIFEST_NAMES]
    if not candidates:
        raise ManifestError(
            "the archive contains no "
            f"{' or '.join(MANIFEST_NAMES)} deployment manifest"
        )
    if len({path.parent for path in candidates}) > 1:
        raise ManifestError("the archive contains more than one deployment manifest")
    embedded = candidates[0]
    with source.open(names[embedded]) as handle:
        payload = handle.read().decode("utf-8", errors="strict")
    try:
        manifest = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ManifestError(f"{embedded} is not valid JSON: {error}") from error
    return _validate_manifest(manifest, str(embedded)), embedded.parent


def _detect_prefix(names: dict, files: list) -> PurePosixPath:
    """Finds the wrapper directory that the manifest paths are relative to.

    Archives are commonly packed as ``moss-qnn-v81-streaming/<file>``, so an
    external manifest has to be matched against the prefix that contains the most
    declared files instead of assuming the archive root.
    """
    declared = [_safe_relative(entry["path"]) for entry in files]
    prefixes = {PurePosixPath()}
    for path in names:
        for depth in range(1, min(len(path.parts), 3)):
            prefixes.add(PurePosixPath(*path.parts[:depth]))
    return max(
        prefixes,
        key=lambda prefix: sum(
            PurePosixPath(*prefix.parts, *path.parts) in names for path in declared
        ),
    )


def audit_zip(
    archive: Path,
    manifest_path: Path | None = None,
    *,
    verify_hashes: bool = True,
) -> dict:
    report = _new_report(archive, str(manifest_path or archive))
    try:
        with zipfile.ZipFile(archive) as source:
            names = {}
            for info in source.infolist():
                if info.is_dir():
                    continue
                try:
                    names[_safe_relative(info.filename)] = info
                except ManifestError:
                    report["errors"].append(
                        f"archive entry has an unsafe name: {info.filename!r}"
                    )

            if manifest_path is not None:
                manifest = load_manifest(manifest_path)
                prefix = _detect_prefix(names, manifest["files"])
            else:
                manifest, prefix = _zip_manifest(source, names)
            files = manifest["files"]
            report["manifest"] = str(manifest_path or f"{archive}!/{prefix or '.'}")
            report["declared_files"] = len(files)
            report["declared_bytes"] = sum(entry["size"] for entry in files)

            def open_reader(relative: PurePosixPath):
                info = names.get(PurePosixPath(*prefix.parts, *relative.parts))
                return None if info is None else source.open(info)

            return _audit_entries(report, files, open_reader, verify_hashes)
    except zipfile.BadZipFile as error:
        report["errors"].append(f"{archive} is not a readable ZIP: {error}")
        return report
    except ManifestError as error:
        report["errors"].append(str(error))
        return report


def audit(
    package: Path,
    manifest_path: Path | None = None,
    *,
    verify_hashes: bool = True,
) -> dict:
    if package.is_dir():
        return audit_directory(package, manifest_path, verify_hashes=verify_hashes)
    if package.is_file() and zipfile.is_zipfile(package):
        return audit_zip(package, manifest_path, verify_hashes=verify_hashes)
    raise ManifestError(f"{package} is neither a directory nor a ZIP archive")


def describe(report: dict) -> str:
    lines = []
    if report["errors"]:
        lines.append("Manifest errors:")
        lines.extend(f"  - {message}" for message in report["errors"])
    if report["missing"]:
        lines.append("Missing files:")
        lines.extend(f"  - {path}" for path in report["missing"])
    if report["size_mismatch"]:
        lines.append("Wrong size (truncated or partially copied):")
        lines.extend(f"  - {path}" for path in report["size_mismatch"])
    if report["hash_mismatch"]:
        lines.append("SHA-256 mismatch:")
        lines.extend(f"  - {path}" for path in report["hash_mismatch"])
    if report["ok"]:
        lines.append(
            f"OK: {report['declared_files']} files, "
            f"{report['declared_bytes'] / 1024 / 1024:.1f} MiB verified"
        )
    else:
        lines.append(
            "Package is NOT importable. Fetch the complete "
            "moss-qnn-v81-streaming package, or repair a stale manifest with "
            "--rewrite-manifest, then re-run this check."
        )
    return "\n".join(lines)


def rewrite_zip_manifest(
    archive: Path,
    manifest_path: Path,
    output: Path,
    *,
    verify_hashes: bool = True,
) -> dict:
    """Writes a copy of ``archive`` whose embedded manifest is ``manifest_path``.

    A package rebuilt from a fixed manifest is common: the runtime files are
    correct while the manifest that travelled with them is stale. Nothing is
    written unless every file already matches the replacement manifest, so a
    repair can never launder a corrupt package into an "accepted" one.
    """
    if archive.resolve() == output.resolve():
        raise ManifestError("refusing to overwrite the source archive; pass another --output")
    manifest = load_manifest(manifest_path)
    payload = json.dumps(manifest, indent=2).encode("utf-8")
    with zipfile.ZipFile(archive) as source:
        names = {}
        for info in source.infolist():
            if info.is_dir():
                continue
            try:
                names[_safe_relative(info.filename)] = info
            except ManifestError as error:
                raise ManifestError(str(error)) from error
        manifest_entries = [path for path in names if path.name in MANIFEST_NAMES]
        if len(manifest_entries) != 1:
            raise ManifestError("the archive must contain exactly one deployment manifest")

        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as target:
            for info in source.infolist():
                if info.is_dir():
                    continue
                if _safe_relative(info.filename) in manifest_entries:
                    target.writestr(info.filename, payload)
                else:
                    with source.open(info) as handle, target.open(info, "w") as sink:
                        while True:
                            chunk = handle.read(CHUNK_BYTES)
                            if not chunk:
                                break
                            sink.write(chunk)

    report = audit_zip(output, manifest_path, verify_hashes=verify_hashes)
    if not report["ok"]:
        output.unlink(missing_ok=True)
        raise ManifestError(
            "the archive does not match the supplied manifest; "
            + describe(report)
        )
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("package", type=Path, help="deployment directory or ZIP archive")
    parser.add_argument(
        "--manifest",
        type=Path,
        help="manifest to compare against (default: the package's own manifest)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print the machine-readable report instead of a summary",
    )
    parser.add_argument(
        "--no-hashes",
        action="store_true",
        help="skip SHA-256 verification (size-only pre-check)",
    )
    parser.add_argument(
        "--rewrite-manifest",
        type=Path,
        metavar="MANIFEST",
        help="rewrite a ZIP so its embedded manifest equals MANIFEST",
    )
    parser.add_argument(
        "--output",
        type=Path,
        metavar="ZIP",
        help="destination for --rewrite-manifest",
    )
    args = parser.parse_args(argv)
    if args.rewrite_manifest is not None:
        if args.output is None:
            parser.error("--rewrite-manifest requires --output")
        try:
            report = rewrite_zip_manifest(
                args.package,
                args.rewrite_manifest,
                args.output,
                verify_hashes=not args.no_hashes,
            )
        except ManifestError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        print(describe(report))
        return 0
    try:
        report = audit(args.package, args.manifest, verify_hashes=not args.no_hashes)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2) if args.json else describe(report))
    return 0 if report["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
