import hashlib
import importlib.util
import io
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location("mpv_candidate", Path(__file__).parents[1] / "verify-mpv-candidate.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MPVCandidateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payloads = {MODULE.FRAMEWORK: b"universal framework"}
        for arch in MODULE.ARCHITECTURES:
            self.payloads[f"dist/libmpv/macos/thin/{arch}/lib/libmpv.a"] = arch.encode()
        self.library = {"LibraryIdentifier": "macos-arm64_x86_64", "BinaryPath": "Libmpv.framework/Versions/A/Libmpv",
                        "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64", "x86_64"]}
        self.make_archives()

    def make_archives(self, framework=None, duplicate=False):
        for archive in (MODULE.ARCHIVE, MODULE.STATIC_ARCHIVE):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as bundle:
                if archive == MODULE.ARCHIVE:
                    bundle.writestr(MODULE.PREFIX + "Info.plist", plistlib.dumps({"AvailableLibraries": [self.library]}))
                    member = MODULE.PREFIX + self.library["LibraryIdentifier"] + "/" + self.library["BinaryPath"]
                    bundle.writestr(member, framework or self.payloads[MODULE.FRAMEWORK])
                    if duplicate:
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore", UserWarning)
                            bundle.writestr(member, b"duplicate")
                else:
                    for arch in MODULE.ARCHITECTURES:
                        bundle.writestr(f"lib/macos/thin/{arch}/lib/libmpv.a", arch.encode())
            self.payloads[archive] = stream.getvalue()
        self.evidence = {"status": "build_succeeded", "exit_code": 0, "candidate_binaries": [], "candidate_archives": []}
        for name, data in self.payloads.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            key = "candidate_archives" if name.endswith(".zip") else "candidate_binaries"
            self.evidence[key].append({"path": name, "sha256": hashlib.sha256(data).hexdigest()})

    def verify(self, architectures=("arm64", "x86_64")):
        return MODULE.verify(self.root, self.evidence, lambda _: architectures)

    def test_corresponding_candidate_passes_without_claiming_release_ready(self):
        self.assertFalse(self.verify()["release_ready"])

    def test_changed_payload_fails(self):
        (self.root / MODULE.FRAMEWORK).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.verify()

    def test_archive_with_valid_hash_but_different_binary_fails(self):
        self.make_archives(framework=b"different")
        with self.assertRaisesRegex(ValueError, "differs"):
            self.verify()

    def test_incorrect_actual_architecture_fails(self):
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.verify(("arm64",))

    def test_incorrect_declared_platform_fails(self):
        self.library["SupportedPlatform"] = "ios"
        self.make_archives()
        with self.assertRaisesRegex(ValueError, "platform"):
            self.verify()

    def test_duplicate_zip_members_fail(self):
        self.make_archives(duplicate=True)
        with self.assertRaisesRegex(ValueError, "Duplicate ZIP"):
            self.verify()

    def test_missing_evidence_fails(self):
        self.evidence["candidate_binaries"] = []
        with self.assertRaisesRegex(ValueError, "missing required"):
            self.verify()

    def test_failed_build_fails(self):
        self.evidence["exit_code"] = 1
        with self.assertRaisesRegex(ValueError, "successful"):
            self.verify()

    def test_escaping_symlink_fails(self):
        path = self.root / MODULE.FRAMEWORK
        path.unlink()
        path.symlink_to(self.root.parent / "outside")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.verify()

    def test_parent_paths_fail(self):
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            MODULE.contained(self.root, "../outside")


if __name__ == "__main__":
    unittest.main()
