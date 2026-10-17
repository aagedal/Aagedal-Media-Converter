"""Compile and exercise the experimental meter queue under ASan and UBSan."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MPVMeterHistoryTests(unittest.TestCase):
    def test_portable_history_queue(self):
        compiler = shutil.which("clang")
        self.assertIsNotNone(compiler, "clang is required for the meter queue sanitizer checks")
        with tempfile.TemporaryDirectory(prefix="amc-meter-history-") as temporary:
            executable = Path(temporary) / "meter-history-test"
            compiled = subprocess.run([
                compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                "-fno-omit-frame-pointer", "-g",
                "-I", str(ROOT / "docs/dependency-patches"),
                str(ROOT / "scripts/tests/mpv_meter_history_test.c"),
                "-o", str(executable),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Meter history queue checks passed.", result.stdout)


if __name__ == "__main__":
    unittest.main()
