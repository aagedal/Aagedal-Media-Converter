"""Independent sample oracle and diagnostic clock regressions."""
import importlib.util
import array
import json
import math
from pathlib import Path
import unittest
import tempfile
import hashlib
import subprocess

SPEC = importlib.util.spec_from_file_location(
    "history_benchmark", Path(__file__).resolve().parents[1] / "benchmark-mpv-meter-history.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def row(start=0.75, peak="-6.020599913"):
    frame = {"valid-time": True, "start": start, "end": start + 0.1, "samples": 4800,
             "sample-rate": 48000, "speed": 1,
             "metadata": {"lavfi.astats.1.Peak_level": peak, "lavfi.astats.2.Peak_level": "-inf"}}
    return {"paused": False, "seeking": False, "position": 0.5, "audio-pts": 0.4,
            "read-start": 1, "read-end": 1.002,
            "history": {"instance": 1, "epoch": 0,
                        "frames": [{"sequence": 1, "frame": json.dumps(frame)}]}}


class HistoryBenchmarkTests(unittest.TestCase):
    def test_nonperiodic_oracle_rejects_former_four_second_alias(self):
        samples = MODULE.signal_samples()
        levels = [max(abs(v) for v in samples[i * 9600:(i + 1) * 9600:2])
                  for i in range(300)]
        self.assertEqual(len(set(levels)), 300)
        ordered = sorted(20 * math.log10(v) for v in levels)
        self.assertGreater(min(b - a for a, b in zip(ordered, ordered[1:])), 0.1)
        item = row(start=0)
        frame = json.loads(item["history"]["frames"][0]["frame"])
        for channel in range(2):
            values = samples[channel:9600:2]
            peak = max(abs(v) for v in values)
            rms = math.sqrt(math.fsum(v * v for v in values) / len(values))
            for metric, value in (("Peak_level", peak), ("RMS_level", rms)):
                frame["metadata"][f"lavfi.astats.{channel + 1}.{metric}"] = str(
                    20 * math.log10(value) if value else -math.inf)
        item["history"]["frames"][0]["frame"] = json.dumps(frame)
        self.assertFalse(MODULE.signal_check([item], 0, samples, signal_version=2)["errors"])
        for offset in (0.1, 4, 8, 16, 24):
            with self.subTest(offset=offset):
                shifted = {**frame, "start": offset, "end": offset + 0.1}
                item["history"]["frames"][0]["frame"] = json.dumps(shifted)
                self.assertTrue(MODULE.signal_check([item], 0, samples, signal_version=2)["errors"])

    def test_rms_detects_wrong_energy_with_matching_peak(self):
        samples = array.array("f", [0.5, 0] * 4800)
        item = row()
        frame = json.loads(item["history"]["frames"][0]["frame"])
        frame["metadata"].update({"lavfi.astats.1.RMS_level": "-12",
                                  "lavfi.astats.2.RMS_level": "-inf"})
        item["history"]["frames"][0]["frame"] = json.dumps(frame)
        result = MODULE.signal_check([item], 0.75, samples, signal_version=2)
        self.assertEqual([error["metric"] for error in result["errors"]], ["RMS_level"])
        # Legacy captures continue to use their original peak-only oracle.
        self.assertFalse(MODULE.signal_check([item], 0.75, samples)["errors"])
        del frame["metadata"]["lavfi.astats.1.RMS_level"]
        item["history"]["frames"][0]["frame"] = json.dumps(frame)
        self.assertEqual(MODULE.signal_check([item], 0.75, samples, signal_version=2)["errors"][0]["error"],
                         "missing measurement")

    def test_generated_delay_survives_container_muxing(self):
        ffmpeg = MODULE.ROOT / "Aagedal Media Converter/Binaries/ffmpeg"
        with tempfile.TemporaryDirectory() as directory:
            paths = MODULE.fixtures(ffmpeg, Path(directory))
            self.assertNotEqual(MODULE.digest(paths["lossless"]), MODULE.digest(paths["delayed"]))
            result = subprocess.run(
                [str(ffmpeg), "-v", "info", "-copyts", "-i", str(paths["delayed"]),
                 "-map", "0:a:0", "-af", "ashowinfo", "-frames:a", "1", "-f", "null", "-"],
                capture_output=True, text=True, check=True, timeout=30)
            self.assertRegex(result.stderr, r"n:0 .*pts_time:0\.75(?: |$)")

    def test_reanalysis_rejects_changed_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture"
            path.write_bytes(b"original")
            expected = hashlib.sha256(b"original").hexdigest()
            MODULE.verify_digest(path, expected)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "Evidence hash mismatch"):
                MODULE.verify_digest(path, expected)

    def test_acceptance_requires_full_steady_coverage(self):
        item = row(start=0)
        base = json.loads(item["history"]["frames"][0]["frame"])
        item.update({"receipt": 17.8, "output-confirmed": True, "video-id": None})
        item["history"]["frames"] = [
            {"sequence": i + 1, "frame": json.dumps({**base, "start": i / 10, "end": (i + 1) / 10})}
            for i in range(170)]
        history = {"epochs": 1, "sequence_gaps": [], "errors": [], "invalid_time_frames": 0,
                   "continuity_breaks": [], "instance_counters": {"1": {"rejected": 0}}}
        signal = {"reference_start": 0, "frames_checked": 170, "errors": [],
                  "impulses_covered": list(range(9))}
        self.assertTrue(MODULE.acceptance([item], history, signal, 0, False, 0)["passed"])
        self.assertFalse(MODULE.acceptance([item], {**history, "epochs": 2}, signal, 0, False, 0)["passed"])
        self.assertFalse(MODULE.acceptance([item], history, {**signal, "impulses_covered": []}, 0, False, 0)["passed"])
        self.assertFalse(MODULE.acceptance([{**item, "video-id": 1}], history, signal, 0, False, 0)["passed"])
        self.assertFalse(MODULE.acceptance([{**item, "receipt": 1}], history, signal, 0, False, 0)["passed"])
        # AAC can expose a valid sequence beginning 1,024 samples after the
        # independent reference. Matching later peaks does not certify startup.
        for entry in item["history"]["frames"]:
            value = json.loads(entry["frame"])
            value["start"] += 1024 / 48000
            value["end"] += 1024 / 48000
            entry["frame"] = json.dumps(value)
        self.assertFalse(MODULE.acceptance([item], history, signal, 0, False, 0)["passed"])

    def test_overflow_requires_gap_localization_and_continuous_recovery(self):
        first = row(start=0)
        first.update({"receipt": 1, "output-confirmed": True})
        last = row(start=17)
        last.update({"receipt": 17.8, "output-confirmed": True})
        last["history"]["frames"][0]["sequence"] = 171
        history = {"epochs": 1, "sequence_gaps": [{"instance": 1, "epoch": 0, "first": 2, "last": 170}],
                   "errors": [], "invalid_time_frames": 0, "continuity_breaks": [],
                   "instance_counters": {"1": {"rejected": 0}}}
        signal = {"reference_start": 0, "frames_checked": 160, "errors": [], "impulses_covered": []}
        self.assertTrue(MODULE.acceptance([first, last], history, signal, 0, False, 14)["passed"])
        self.assertFalse(MODULE.acceptance([{**first, "receipt": 3}, last], history, signal, 0, False, 14)["passed"])
        self.assertFalse(MODULE.acceptance([first, last], {**history, "continuity_breaks": [1]},
                                           signal, 0, False, 14)["passed"])

    def test_delayed_audio_samples_dedup_and_silence(self):
        samples = array.array("f", [0.5, 0] * 4800)
        result = MODULE.signal_check([row(), row()], 0.75, samples)
        self.assertEqual(result["frames_checked"], 1)
        self.assertFalse(result["errors"])
        self.assertTrue(MODULE.signal_check([row(start=0)], 0.75, samples)["errors"])
        self.assertTrue(MODULE.signal_check([row(peak="-12")], 0.75, samples)["errors"])

    def test_impulse_is_detected_between_polls(self):
        samples = array.array("f", [0, 0] * 52800)
        samples[48000 * 2 + 1] = 0.5
        item = row(start=1, peak="-inf")
        value = json.loads(item["history"]["frames"][0]["frame"])
        value["metadata"]["lavfi.astats.2.Peak_level"] = "-6.020599913"
        item["history"]["frames"][0]["frame"] = json.dumps(value)
        result = MODULE.signal_check([item], 0, samples)
        self.assertFalse(result["errors"])
        self.assertEqual(result["impulses_covered"], [0])

    def test_clock_offsets_are_diagnostics_and_ignore_pause(self):
        result = MODULE.clock_diagnostics([row(), {**row(), "paused": True}])
        self.assertFalse(result["presentation_clock_selected"])
        self.assertEqual(result["newest_frame_start_minus_clock_seconds"]["position"]["count"], 1)
        self.assertAlmostEqual(result["newest_frame_start_minus_clock_seconds"]["position"]["median"], 0.25)
        self.assertAlmostEqual(result["property_read_span_seconds"]["maximum"], 0.002)


if __name__ == "__main__":
    unittest.main()
