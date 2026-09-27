import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "mpv_gpl_release", Path(__file__).parents[1] / "prepare-mpv-gpl-release.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MPVGPLReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write_options(self, arch, gpl):
        path = (self.root / "dist/libmpv/macos/scratch" / arch
                / "meson-info/intro-buildoptions.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps([{"name": "gpl", "value": gpl}]))

    def test_both_architectures_must_have_gpl_enabled(self):
        self.write_options("arm64", True)
        self.write_options("x86_64", False)
        with self.assertRaisesRegex(ValueError, "x86_64.*GPL"):
            MODULE.require_gpl_build(self.root)
        self.write_options("x86_64", True)
        self.assertEqual(MODULE.require_gpl_build(self.root),
                         {"arm64": True, "x86_64": True})

    def test_missing_gpl_option_fails(self):
        self.write_options("arm64", True)
        self.write_options("x86_64", True)
        self.write_options("arm64", None)
        with self.assertRaisesRegex(ValueError, "arm64.*GPL"):
            MODULE.require_gpl_build(self.root)
