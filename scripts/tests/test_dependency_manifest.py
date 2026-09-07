"""Exercise license inventory and publication gating without running bundled tools."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("dependency_manifest", Path(__file__).parents[1] / "bundled-dependency-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class DependencyLicenseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "LICENSE").write_text("Application license\n")
        (self.root / "Licenses").mkdir()
        self.notice = self.root / "Licenses/component-LICENSE.txt"
        self.notice.write_text("Component license\n")
        replacement = patch.object(manifest, "REPOSITORY_ROOT", self.root)
        replacement.start()
        self.addCleanup(replacement.stop)

    def complete_manifest(self):
        return {
            "tools": [{"path": "Binaries/tool", "license": "MIT", "licenseFile": "Licenses/component-LICENSE.txt"}],
            "libraries": [],
            "licenseFiles": manifest.license_inventory(),
        }

    def test_inventory_includes_application_and_unassigned_notices(self):
        entries = manifest.license_inventory()
        self.assertEqual([entry["path"] for entry in entries], ["LICENSE", "Licenses/component-LICENSE.txt"])
        self.assertEqual(entries[1]["bytes"], len(self.notice.read_bytes()))
        self.assertEqual(entries[1]["sha256"], manifest.sha256(self.notice))

    def test_changed_license_changes_serialized_manifest(self):
        before = manifest.serialized(self.complete_manifest())
        self.notice.write_text("Changed license\n")
        self.assertNotEqual(before, manifest.serialized(self.complete_manifest()))

    def test_empty_notice_fails(self):
        self.notice.write_text(" \n")
        with self.assertRaisesRegex(RuntimeError, "License file is empty"):
            manifest.license_inventory()

    def test_missing_application_license_fails(self):
        (self.root / "LICENSE").unlink()
        with self.assertRaises(OSError):
            manifest.license_inventory()

    def test_external_notice_symlink_fails(self):
        self.notice.unlink()
        self.notice.symlink_to(Path(__file__).resolve())
        with self.assertRaisesRegex(RuntimeError, "escapes the repository"):
            manifest.license_inventory()

    def test_complete_attribution_passes(self):
        manifest.require_complete_licenses(self.complete_manifest())

    def test_missing_or_uninventoried_notice_fails(self):
        for notice in [None, "Licenses/missing-LICENSE.txt"]:
            with self.subTest(notice=notice):
                data = self.complete_manifest()
                data["tools"][0]["licenseFile"] = notice
                with self.assertRaisesRegex(RuntimeError, "incomplete for 1 dependencies"):
                    manifest.require_complete_licenses(data)

    def test_unknown_library_license_fails_even_with_notice(self):
        data = self.complete_manifest()
        data["libraries"] = [{"path": "Frameworks/library.dylib", "license": "NOASSERTION", "licenseFile": "Licenses/component-LICENSE.txt"}]
        with self.assertRaisesRegex(RuntimeError, "Frameworks/library.dylib"):
            manifest.require_complete_licenses(data)


if __name__ == "__main__":
    unittest.main()
