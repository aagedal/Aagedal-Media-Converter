"""Compile small real Mach-O graphs to exercise release validation with Apple tools."""
import hashlib
import json
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_bundle", Path(__file__).parents[1] / "verify-release-bundle.py")
validator = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Test App.app"
        self.macos = self.app / "Contents/MacOS"
        self.frameworks = self.app / "Contents/Frameworks"
        self.macos.mkdir(parents=True)
        self.frameworks.mkdir()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture"}))
        self.main = self.macos / "Fixture"
        self.source = self.root / "fixture.c"

    def compile(self, target, source, *flags, architecture="arm64"):
        self.source.write_text(source)
        subprocess.run(["xcrun", "clang", "-arch", architecture, str(self.source), "-o", str(target), *flags],
                       check=True, capture_output=True, text=True)

    def library(self, name="libFixture.dylib", install_name=None, *flags):
        path = self.frameworks / name
        self.compile(path, "int fixture(void) { return 0; }", "-dynamiclib", "-install_name",
                     install_name or "@rpath/" + name, *flags)
        return path

    def executable(self, library=None, *flags):
        source = "int main(void) { return 0; }" if library is None else "int fixture(void); int main(void) { return fixture(); }"
        self.compile(self.main, source, *([str(library)] if library else []), *flags)

    def test_system_paths_are_lexical_shared_cache_locations(self):
        self.assertTrue(validator.is_system("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"))
        self.assertTrue(validator.is_system("/usr/lib/libSystem.B.dylib"))
        self.assertFalse(validator.is_system("/usr/lib/../../opt/homebrew/lib/example.dylib"))

    def test_owner_execute_permission_is_required(self):
        self.executable()
        self.main.chmod(0o645)
        with self.assertRaisesRegex(ValueError, "no execute permission"):
            validator.verify(self.app)

    def test_system_only_executable(self):
        self.executable()
        self.assertEqual(validator.verify(self.app), 1)

    def test_rpath_library_and_framework_symlink(self):
        library = self.library()
        self.executable(library, "-Wl,-rpath,@executable_path/../Frameworks")
        (self.frameworks / "alias.dylib").symlink_to(library.name)
        self.assertEqual(validator.verify(self.app), 2)

    def test_loader_relative_library(self):
        library = self.library(install_name="@loader_path/../Frameworks/libFixture.dylib")
        self.executable(library)
        self.assertEqual(validator.verify(self.app), 2)

    def test_transitive_library_inherits_executable_rpath(self):
        leaf = self.library("libLeaf.dylib")
        middle = self.frameworks / "libMiddle.dylib"
        self.compile(middle, "int fixture(void); int middle(void) { return fixture(); }", "-dynamiclib",
                     "-install_name", "@rpath/libMiddle.dylib", str(leaf))
        self.compile(self.main, "int middle(void); int main(void) { return middle(); }", str(middle),
                     "-Wl,-rpath,@executable_path/../Frameworks")
        self.assertEqual(validator.verify(self.app), 3)

    def test_missing_dependency_fails(self):
        library = self.library()
        self.executable(library, "-Wl,-rpath,@executable_path/../Frameworks")
        library.unlink()
        with self.assertRaisesRegex(ValueError, "unresolved dependency"):
            validator.verify(self.app)

    def test_dependency_needs_actual_rpath(self):
        self.executable(self.library())
        with self.assertRaisesRegex(ValueError, "unresolved dependency"):
            validator.verify(self.app)

    def test_developer_machine_dependency_fails(self):
        self.executable(self.library(install_name="/opt/homebrew/lib/libFixture.dylib"))
        with self.assertRaisesRegex(ValueError, "outside the bundle"):
            validator.verify(self.app)

    def test_non_macho_dependency_fails(self):
        library = self.library()
        self.executable(library, "-Wl,-rpath,@executable_path/../Frameworks")
        library.write_text("not a library")
        with self.assertRaisesRegex(ValueError, "not a Mach-O image"):
            validator.verify(self.app)

    def test_wrong_architecture_in_unreferenced_helper_fails(self):
        self.executable()
        self.compile(self.macos / "helper", "int main(void) { return 0; }", architecture="x86_64")
        with self.assertRaisesRegex(ValueError, "missing required arm64"):
            validator.verify(self.app)

    def test_execute_permission_fails(self):
        self.executable()
        self.main.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "no execute permission"):
            validator.verify(self.app)

    def test_symlink_escape_fails(self):
        self.executable()
        (self.frameworks / "outside").symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            validator.verify(self.app)

    def test_helper_uses_own_executable_path(self):
        library = self.library(install_name="@executable_path/../Frameworks/libFixture.dylib")
        self.executable(library)
        helper = self.app / "Contents/Helpers/Nested/helper"
        helper.parent.mkdir(parents=True)
        self.compile(helper, "int fixture(void); int main(void) { return fixture(); }", str(library))
        with self.assertRaisesRegex(ValueError, "unresolved dependency"):
            validator.verify(self.app)


class ReleaseNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Test App.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        self.notice = self.resources / "fixture-LICENSE.txt"
        self.notice.write_bytes(b"A complete fixture notice.\n")
        contents = self.notice.read_bytes()
        self.entry = {"path": "Licenses/fixture-LICENSE.txt", "bytes": len(contents),
                      "sha256": hashlib.sha256(contents).hexdigest()}
        self.manifest = self.root / "manifest.json"
        self.write_manifest([self.entry])

    def write_manifest(self, entries):
        self.manifest.write_text(json.dumps({"licenseFiles": entries}))

    def test_packaged_notice_matches_manifest(self):
        self.assertEqual(validator.verify_notices(self.app, self.manifest), 1)

    def test_missing_notice_is_rejected(self):
        self.notice.unlink()
        with self.assertRaisesRegex(ValueError, "missing packaged license"):
            validator.verify_notices(self.app, self.manifest)

    def test_modified_notice_with_same_size_is_rejected(self):
        self.notice.write_bytes(b"X" * self.entry["bytes"])
        with self.assertRaisesRegex(ValueError, "differs from"):
            validator.verify_notices(self.app, self.manifest)

    def test_escaping_notice_symlink_is_rejected(self):
        outside = self.root / "outside.txt"
        self.notice.rename(outside)
        self.notice.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes the app bundle"):
            validator.verify_notices(self.app, self.manifest)

    def test_duplicate_flat_resource_names_are_rejected(self):
        self.write_manifest([self.entry, {**self.entry, "path": "Other/fixture-LICENSE.txt"}])
        with self.assertRaisesRegex(ValueError, "Duplicate packaged"):
            validator.verify_notices(self.app, self.manifest)

    def test_empty_manifest_is_rejected(self):
        self.write_manifest([])
        with self.assertRaisesRegex(ValueError, "no license notices"):
            validator.verify_notices(self.app, self.manifest)


if __name__ == "__main__":
    unittest.main()
