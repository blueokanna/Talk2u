#!/usr/bin/env python3
"""Audit actual Android ELF files and APK ZIP offsets using only Python 3 stdlib.

AAB/AAR checks prove ELF properties only. Check bundletool-generated APKs too.
Hexagon DSP ELF (e_machine=164) is inventoried, not treated as Android host code.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import zipfile

PAGE_SIZE = 16384
HOST_MACHINES = {3: "x86", 40: "armeabi-v7a", 62: "x86_64", 183: "arm64-v8a"}


def inspect_elf(data, name):
    result = {"file": name, "sha256": hashlib.sha256(data).hexdigest(), "errors": []}
    errors = result["errors"]
    try:
        if data[:4] != b"\x7fELF":
            raise ValueError("native library is not an ELF file")
        if len(data) < 16 or data[4] not in (1, 2) or data[5] not in (1, 2):
            raise ValueError("invalid ELF identification")
        endian = "<" if data[5] == 1 else ">"
        bits = 64 if data[4] == 2 else 32
        header = struct.Struct(endian + ("HHIQQQIHHHHHH" if bits == 64 else "HHIIIIIHHHHHH"))
        fields = header.unpack_from(data, 16)
        kind, machine, version, _, phoff, _, _, ehsize, phentsize, phnum, *_ = fields
        result.update(bits=bits, machine=machine, abi=HOST_MACHINES.get(machine, "other"))
        if version != 1 or ehsize < 16 + header.size:
            raise ValueError("invalid ELF header")
        if machine == 164:
            result["scope"] = "Hexagon DSP firmware; Android host page-size rule does not apply"
            return result
        if machine not in HOST_MACHINES:
            raise ValueError(f"unrecognized host ELF machine {machine}; requires explicit review")
        if kind not in (2, 3):
            raise ValueError(f"ELF type {kind} is not a loadable executable/shared library")
        if phnum == 0 or phnum == 0xffff:
            raise ValueError("missing or unsupported extended program header table")
        ph = struct.Struct(endian + ("IIQQQQQQ" if bits == 64 else "IIIIIIII"))
        if phentsize < ph.size or phoff + phentsize * phnum > len(data):
            raise ValueError("truncated/invalid ELF program header table")
        segments = []
        for index in range(phnum):
            values = ph.unpack_from(data, phoff + index * phentsize)
            if bits == 64:
                ptype, flags, offset, vaddr, _, filesz, memsz, align = values
            else:
                ptype, offset, vaddr, _, filesz, memsz, flags, align = values
            if ptype != 1:  # PT_LOAD
                continue
            segments.append(dict(offset=offset, vaddr=vaddr, filesz=filesz,
                                 memsz=memsz, align=align, flags=flags))
            if align < PAGE_SIZE or align & (align - 1):
                errors.append(f"PT_LOAD[{index}] p_align=0x{align:x}; requires power-of-two >= 0x4000")
            if (vaddr - offset) % PAGE_SIZE:
                errors.append(f"PT_LOAD[{index}] offset/vaddr are not congruent modulo 16384")
            if align > 1 and (vaddr - offset) % align:
                errors.append(f"PT_LOAD[{index}] offset/vaddr violate p_align")
            if filesz > memsz or offset + filesz > len(data):
                errors.append(f"PT_LOAD[{index}] invalid file/memory size")
        result["load_segments"] = segments
        if not segments:
            errors.append("ELF has no PT_LOAD segments")
        # A wrong ABI in lib/ or jni/ is also an invalid Android package.
        parts = name.replace("!", "/").replace("\\", "/").split("/")
        for marker in ("lib", "jni", "jniLibs"):
            for index, part in enumerate(parts[:-1]):
                if part == marker and parts[index + 1] in HOST_MACHINES.values():
                    if parts[index + 1] != result["abi"]:
                        errors.append(f"ELF machine does not match packaged ABI {parts[index + 1]}")
    except (ValueError, struct.error) as error:
        errors.append(str(error))
    return result


def inspect_archive(path, records, errors):
    apk = path.suffix.lower() == ".apk"
    with zipfile.ZipFile(path) as archive, path.open("rb") as raw:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            name = f"{path}!{entry.filename}"
            with archive.open(entry) as stream:
                prefix = stream.read(4)
                if prefix != b"\x7fELF" and not entry.filename.endswith(".so"):
                    continue
                data = prefix + stream.read()
            record = inspect_elf(data, name)
            record["compressed"] = entry.compress_type != zipfile.ZIP_STORED
            if apk and entry.filename.startswith("lib/") and entry.filename.endswith(".so"):
                raw.seek(entry.header_offset)
                header = raw.read(30)
                if len(header) != 30 or header[:4] != b"PK\x03\x04":
                    record["errors"].append("invalid ZIP local file header")
                else:
                    filename_size, extra_size = struct.unpack_from("<HH", header, 26)
                    offset = entry.header_offset + 30 + filename_size + extra_size
                    record["zip_data_offset"] = offset
                    if entry.compress_type == zipfile.ZIP_STORED and offset % PAGE_SIZE:
                        record["errors"].append(f"uncompressed APK library ZIP offset {offset} is not 16KB aligned")
            records.append(record)


def audit(paths):
    records, errors = [], []
    seen = set()
    for requested in paths:
        root = Path(requested)
        if not root.exists():
            errors.append(f"missing input: {root}")
            continue
        files = sorted(root.rglob("*")) if root.is_dir() else [root]
        for path in files:
            if not path.is_file() or path.resolve() in seen:
                continue
            seen.add(path.resolve())
            try:
                if path.suffix.lower() in (".aar", ".apk", ".aab", ".zip"):
                    inspect_archive(path, records, errors)
                else:
                    with path.open("rb") as stream:
                        prefix = stream.read(4)
                        if prefix == b"\x7fELF" or path.suffix == ".so":
                            records.append(inspect_elf(prefix + stream.read(), str(path)))
            except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
                errors.append(f"{path}: {error}")
    hosts = sum("load_segments" in record for record in records)
    if hosts == 0:
        errors.append("no Android host ELF files checked; refusing an empty success")
    return {"page_size": PAGE_SIZE, "host_elf_count": hosts, "records": records,
            "errors": errors, "ok": not errors and not any(r["errors"] for r in records)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="ELF files, directories, APKs, AABs or AARs")
    parser.add_argument("--report", type=Path, help="write complete JSON inventory including SHA-256")
    args = parser.parse_args()
    report = audit(args.paths)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for record in report["records"]:
        status = "FAIL" if record["errors"] else "DSP" if record.get("machine") == 164 else "PASS"
        print(f"{status} {record['file']}")
        for error in record["errors"]:
            print(f"  {error}")
    for error in report["errors"]:
        print(f"FAIL {error}")
    print(f"Checked {report['host_elf_count']} host ELFs, {len(report['records'])} total ELF/native entries")
    print("AAB/AAR: ELF check only. Verify generated APKs and run on a 16384-byte-page device before claiming compatibility.")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
