import contextlib
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "rebuild-mpv-meter-history.py"
SPEC = importlib.util.spec_from_file_location("rebuild_mpv_meter_history", SCRIPT)
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class CleanMPVBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.recipe = self.root / "recipe"
        self.source = self.root / "source"
        self.repository = self.root / "repository"
        self.output = self.root / "output"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        self.files = ["filters/f_lavfi.c", "audio/decode/ad_lavc.c", "audio/out/ao_coreaudio.c", "extra-a", "extra-b"]
        for name in self.files:
            self.write(self.source / name, "upstream\n")
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "Pinned fixture"], check=True)
        self.commit = subprocess.check_output(["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True).strip()
        subprocess.run(["git", "-C", str(self.source), "tag", "v0.41.0"], check=True)
        patch_root = self.recipe / "Sources/BuildScripts/patch/libmpv"
        for name, source in zip(BUILDER.STANDARD_PATCHES, self.files):
            self.write(patch_root / name, self.patch(source, "upstream\n", "standard\n"))
        build = self.recipe / "Sources/BuildScripts/XCFrameworkBuild"
        self.write(build / "main.swift", "do {\n    try BuildFFMPEG().buildALL()\n    try BuildMPV().buildALL()\n}\n")
        self.write(build / "base.swift", 'arguments: ["compile", "--verbose"]\n        task.environment = environment\n')
        self.write(self.recipe / "scripts/input.py", "# untouched recipe\n")
        self.write(self.recipe / "docs/Package.template.swift", "// untouched template\n")
        for arch in ("arm64", "x86_64"):
            thin = self.recipe / "dist/FFmpeg/macos/thin" / arch
            self.write(thin / "include/libavcodec/avcodec.h", "qualified headers\n")
            self.write(thin / "lib/libavcodec.a", "qualified archive\n")
            self.write(thin / "lib/pkgconfig/libavcodec.pc", "qualified pkg-config\n")
        self.write(self.recipe / "dist/libass/macos/thin/arm64/lib/libass.a", "auxiliary\n")
        for directory in ("libmpv", "release", ".build", "FFmpeg-old", "libmpv-v0.41.0"):
            self.write(self.recipe / "dist" / directory / "untouched", "original\n")
        extra = self.repository / "docs/dependency-patches"
        self.write(extra / BUILDER.EXTRA_INPUTS[0], self.patch(self.files[0], "standard\n", "history\n"))
        self.write(extra / BUILDER.EXTRA_INPUTS[1], "/* owned history header */\n")
        self.write(extra / BUILDER.EXTRA_INPUTS[2], self.patch(self.files[1], "standard\n", "priming\n"))
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)
        self.patches.enter_context(mock.patch.object(BUILDER, "ROOT", self.repository))
        self.patches.enter_context(mock.patch.object(BUILDER, "SOURCE_COMMIT", self.commit))
        self.patches.enter_context(mock.patch.object(BUILDER, "STANDARD_SOURCE_HASHES", {
            name: hashlib.sha256(b"standard\n").hexdigest() for name in self.files[:3]
        }))
        self.patches.enter_context(mock.patch.object(BUILDER, "preflight_tools", return_value={"git": {"version": "fixture"}}))

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    @staticmethod
    def patch(path, before, after):
        return "".join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
                                           fromfile="a/" + path, tofile="b/" + path))

    def testDirtyCacheExportsCommittedTreeAndNeverWritesInputs(self):
        self.write(self.source / self.files[0], "dirty working tree\n")
        (self.source / self.files[1]).unlink()
        self.write(self.source / "untracked-secret", "must not be exported\n")
        original_recipe = BUILDER.hash_tree(self.recipe)
        original_source = BUILDER.hash_tree(self.source)
        report = BUILDER.stage(self.recipe, self.source, self.output)
        prepared = self.output / "dist/libmpv-v0.41.0"
        self.assertEqual((prepared / self.files[0]).read_text(), "history\n")
        self.assertEqual((prepared / self.files[1]).read_text(), "priming\n")
        self.assertFalse((prepared / "untracked-secret").exists())
        self.assertEqual(BUILDER.hash_tree(self.source), original_source)
        self.assertEqual(BUILDER.hash_tree(self.recipe), original_recipe)
        self.assertEqual(report["status"], "staged-not-built")
        self.assertFalse(report["production_pin_changed"])
        self.assertEqual(report["source_commit"], self.commit)

    def testOnlyDependencyOutputsAreLinkedAndWritableRootsAreOwned(self):
        outside = self.root / "external-note"
        self.write(outside, "do not change\n")
        (self.recipe / "Sources/linked-note").symlink_to(outside)
        report = BUILDER.stage(self.recipe, self.source, self.output, jobs=3)
        for name in ("FFmpeg", "libass"):
            self.assertTrue((self.output / "dist" / name).is_symlink())
        for name in ("libmpv", "release", "libmpv-v0.41.0"):
            self.assertTrue((self.output / "dist" / name).is_dir())
            self.assertFalse((self.output / "dist" / name).is_symlink())
        for name in (".build", "FFmpeg-old"):
            self.assertFalse((self.output / "dist" / name).exists())
        note = self.output / "Sources/linked-note"
        self.assertFalse(note.is_symlink())
        note.write_text("safe local edit\n")
        self.assertEqual(outside.read_text(), "do not change\n")
        main = (self.output / "Sources/BuildScripts/XCFrameworkBuild/main.swift").read_text()
        base = (self.output / "Sources/BuildScripts/XCFrameworkBuild/base.swift").read_text()
        self.assertNotIn("try BuildFFMPEG().buildALL()", main)
        self.assertEqual(main.count("try BuildMPV().buildALL()"), 1)
        self.assertIn('["compile", "--verbose", "--jobs", "3"]', base)
        self.assertIn('for key in ["TMPDIR", "CLANG_MODULE_CACHE_PATH"]', base)
        self.assertIn("FFmpeg/macos/thin/arm64/lib/libavcodec.a", report["dependency_input_sha256"])
        self.assertIn("FFmpeg/macos/thin/x86_64/lib/pkgconfig/libavcodec.pc", report["dependency_pkgconfig_sha256"])

    def testExistingOutputAndCacheDescendantsAreRejectedWithoutChanges(self):
        self.write(self.output / "keep", "existing\n")
        before = BUILDER.hash_tree(self.output)
        with self.assertRaisesRegex(ValueError, "new directory"):
            BUILDER.stage(self.recipe, self.source, self.output)
        self.assertEqual(BUILDER.hash_tree(self.output), before)
        with self.assertRaisesRegex(ValueError, "outside"):
            BUILDER.stage(self.recipe, self.source, self.recipe / "new-output")
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "outside"):
            BUILDER.stage(self.recipe, self.source, alias / "new-output")

    def testWrongRevisionUnexpectedPatchSetAndUnsafeJobsFailBeforeStaging(self):
        with mock.patch.object(BUILDER, "SOURCE_COMMIT", "0" * 40):
            with self.assertRaisesRegex(ValueError, "exact pinned"):
                BUILDER.stage(self.recipe, self.source, self.output)
        self.assertFalse(self.output.exists())
        for jobs in (0, 33, True, 1.5):
            with self.assertRaisesRegex(ValueError, "Jobs"):
                BUILDER.stage(self.recipe, self.source, self.output, jobs=jobs)
        self.write(self.recipe / "Sources/BuildScripts/patch/libmpv/extra.patch", "unexpected\n")
        with self.assertRaisesRegex(ValueError, "patch set"):
            BUILDER.stage(self.recipe, self.source, self.output)
        self.assertFalse(self.output.exists())

    def testSourceHashMismatchLeavesReviewableFailureRecord(self):
        with mock.patch.object(BUILDER, "STANDARD_SOURCE_HASHES", {self.files[0]: "wrong"}):
            with self.assertRaisesRegex(ValueError, "hashes differ"):
                BUILDER.stage(self.recipe, self.source, self.output)
        report = json.loads((self.output / "staging.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertIn("hashes differ", report["error"])
        self.assertFalse((self.output / "build.log").exists())

    def testMockedBuildReceivesOnlyOwnedWorkingPathsAndRecordsExit(self):
        real_run = subprocess.run
        build_calls = []

        def run(command, **kwargs):
            if command[0] == "swift":
                build_calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 7)
            return real_run(command, **kwargs)

        with mock.patch.object(BUILDER.subprocess, "run", side_effect=run):
            report = BUILDER.stage(self.recipe, self.source, self.output, build=True)
        self.assertEqual(report["status"], "build-failed")
        self.assertEqual(report["build_exit_code"], 7)
        self.assertEqual(len(build_calls), 1)
        command, options = build_calls[0]
        self.assertEqual(options["cwd"], self.output.resolve())
        self.assertEqual(command[-2:], ["platform=macos", "enable-gpl"])
        for key in ("TMPDIR", "CLANG_MODULE_CACHE_PATH"):
            self.assertTrue(Path(options["env"][key]).is_relative_to(self.output.resolve()))
        self.assertEqual(json.loads((self.output / "staging.json").read_text())["build_exit_code"], 7)


if __name__ == "__main__":
    unittest.main()
