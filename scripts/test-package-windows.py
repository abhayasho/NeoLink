#!/usr/bin/env python3
"""Portable archive-layout checks; this does not execute Windows software."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_windows", Path(__file__).with_name("package-windows.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def test_resources_are_next_to_executable_and_failures_preserve_prior_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            editor = root / "Resources/Editor"
            editor.mkdir(parents=True)
            (editor / "neolink.lua").write_text("-- fixture")
            (root / "Resources/AppIcon.png").write_bytes(b"icon fixture")
            (root / "LICENSE").write_text("license fixture")
            binary = root / "app.exe"
            binary.write_bytes(b"MZ-layout-fixture-not-an-executable")
            output = root / "dist/app.zip"
            packager.package(binary, root, output)
            before = output.read_bytes()
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read("NeoLink/NeoLink.exe"), binary.read_bytes())
                self.assertEqual(archive.read("NeoLink/Resources/Editor/neolink.lua"), b"-- fixture")
                self.assertIn("NeoLink/README.txt", archive.namelist())
                self.assertIsNone(archive.testzip())
            digest, name = (output.parent / "app.zip.sha256").read_text().split()
            self.assertEqual(name, "app.zip")
            self.assertEqual(digest, __import__("hashlib").sha256(output.read_bytes()).hexdigest())
            (editor / "neolink.lua").unlink()
            with self.assertRaisesRegex(ValueError, "Missing"):
                packager.package(binary, root, output)
            self.assertEqual(output.read_bytes(), before)
            binary.write_bytes(b"not a Windows binary")
            with self.assertRaisesRegex(ValueError, "Windows PE"):
                packager.package(binary, root, output)


if __name__ == "__main__":
    unittest.main()
