"""Regression cases for ELF/ZIP validation; no Android SDK required."""
import struct
import tempfile
import unittest
from pathlib import Path
import zipfile

from verify_android_native import PAGE_SIZE, audit, inspect_elf


def elf(align=PAGE_SIZE, machine=183, bits=64, endian="<", offset=0, vaddr=0):
    ident = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1 if endian == "<" else 2, 1]) + bytes(9)
    size, phsize = (64, 56) if bits == 64 else (52, 32)
    header = struct.pack(endian + ("HHIQQQIHHHHHH" if bits == 64 else "HHIIIIIHHHHHH"),
                         3, machine, 1, 0, size, 0, 0, size, phsize, 1, 0, 0, 0)
    if bits == 64:
        ph = struct.pack(endian + "IIQQQQQQ", 1, 5, offset, vaddr, 0, size + phsize, size + phsize, align)
    else:
        ph = struct.pack(endian + "IIIIIIII", 1, offset, vaddr, 0, size + phsize, size + phsize, 5, align)
    return ident + header + ph


class NativeAuditTests(unittest.TestCase):
    def test_valid_host_formats(self):
        for bits, machine in [(64, 183), (64, 62), (32, 40), (32, 3)]:
            for endian in ["<", ">"]:
                with self.subTest(bits=bits, machine=machine, endian=endian):
                    self.assertFalse(inspect_elf(elf(bits=bits, machine=machine, endian=endian), "lib.so")["errors"])

    def test_rejects_4k_and_bad_congruence(self):
        self.assertTrue(inspect_elf(elf(align=4096), "lib.so")["errors"])
        self.assertTrue(inspect_elf(elf(vaddr=4096), "lib.so")["errors"])
        self.assertTrue(inspect_elf(elf(align=24576), "lib.so")["errors"])

    def test_bad_elf_fails_closed(self):
        for data in [b"", b"not ELF", elf()[:80], elf(machine=999)]:
            self.assertTrue(inspect_elf(data, "lib.so")["errors"])

    def test_machine_must_match_packaged_abi(self):
        self.assertTrue(inspect_elf(elf(machine=62), "x.apk!lib/arm64-v8a/lib.so")["errors"])

    def test_dsp_is_explicitly_separate(self):
        result = inspect_elf(elf(machine=164, align=4096), "libQnnHtpV81Skel.so")
        self.assertFalse(result["errors"])
        self.assertIn("DSP", result["scope"])
        self.assertNotIn("load_segments", result)

    def test_missing_and_empty_inputs_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(audit([directory])["ok"])
            self.assertFalse(audit([Path(directory) / "missing.apk"])["ok"])

    def test_apk_zip_alignment_and_compression(self):
        with tempfile.TemporaryDirectory() as directory:
            for compressed, aligned, expected in [(False, False, False), (False, True, True), (True, False, True)]:
                with self.subTest(compressed=compressed, aligned=aligned):
                    target = Path(directory) / "app.apk"
                    entry = zipfile.ZipInfo("lib/arm64-v8a/libtest.so")
                    entry.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
                    if aligned:
                        padding = PAGE_SIZE - 30 - len(entry.filename.encode())
                        entry.extra = struct.pack("<HH", 0xffff, padding - 4) + bytes(padding - 4)
                    with zipfile.ZipFile(target, "w") as archive:
                        archive.writestr(entry, elf())
                    self.assertEqual(audit([target])["ok"], expected)

    def test_aab_checks_elf_not_zip_alignment(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "app.aab"
            with zipfile.ZipFile(target, "w") as archive:
                archive.writestr("base/lib/arm64-v8a/libtest.so", elf())
            self.assertTrue(audit([target])["ok"])

    def test_compression_never_hides_bad_elf(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "app.apk"
            with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("lib/arm64-v8a/libtest.so", elf(align=4096))
            self.assertFalse(audit([target])["ok"])

    def test_elf_asset_without_so_extension_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "vendor.aar"
            with zipfile.ZipFile(target, "w") as archive:
                archive.writestr("assets/plugin.bin", elf(align=4096))
            self.assertFalse(audit([target])["ok"])


if __name__ == "__main__":
    unittest.main()
