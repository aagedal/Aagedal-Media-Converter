"""Exercise production subtitle publication across actual processes on macOS."""
import fcntl
from pathlib import Path
import subprocess
import tempfile
import unittest


class SubtitleCoordinationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.publisher = cls.root / "publish"
        driver = cls.root / "main.swift"
        driver.write_text('''import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let staged = directory.appendingPathComponent(".staged.srt")
let reservation = SubtitleSRTNaming().reserve(
    directory: directory, sourceFile: directory.appendingPathComponent("clip.mov"), method: .whisper)
do {
    try reservation.publish(stagedURL: staged)
    print("published")
} catch {
    print("rejected")
    exit(1)
}
''')
        source = Path(__file__).parents[2] / "Aagedal Media Converter/Logic/Subtitles/SubtitleSRTNaming.swift"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(cls.root / "cache"),
                        str(source), str(driver), "-o", str(cls.publisher)],
                       check=True, capture_output=True, text=True)

    def publish(self, directory):
        return subprocess.run([str(self.publisher), str(directory)],
                              capture_output=True, text=True, timeout=10)

    def test_other_process_lock_preserves_staging_then_allows_retry(self):
        with tempfile.TemporaryDirectory() as path:
            directory = Path(path)
            staged = directory / ".staged.srt"
            staged.write_text("first subtitle")
            self.assertEqual(self.publish(directory).returncode, 0)
            destination = directory / "clip.srt"
            staged.write_text("replacement subtitle")
            # Parent holds the same directory inode that the app child opens.
            import os
            descriptor = os.open(directory, os.O_RDONLY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = self.publish(directory)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(destination.read_text(), "first subtitle")
                self.assertEqual(staged.read_text(), "replacement subtitle")
            finally:
                os.close(descriptor)
            self.assertEqual(self.publish(directory).returncode, 0)
            self.assertEqual(destination.read_text(), "replacement subtitle")

    def test_directory_alias_observes_other_process_lock(self):
        with tempfile.TemporaryDirectory() as path:
            directory = Path(path)
            output = directory / "output"
            output.mkdir()
            alias = directory / "alias"
            alias.symlink_to(output, target_is_directory=True)
            (output / ".staged.srt").write_text("subtitle")
            import os
            descriptor = os.open(output, os.O_RDONLY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(self.publish(alias).returncode, 1)
                self.assertFalse((output / "clip.srt").exists())
            finally:
                os.close(descriptor)


if __name__ == "__main__":
    unittest.main()
