"""Validate the benchmark's CPU accounting and signal-derived timing report."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "audio_meter_benchmark", Path(__file__).resolve().parents[1] / "benchmark-audio-meter.py")
BENCHMARK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCHMARK)


class AudioMeterBenchmarkReportTests(unittest.TestCase):
    def run_sample(self, readings):
        return {"fixture": "stereo", "round": 1, "mode": "source", "audioOutput": "coreaudio",
                "wallSeconds": 10, "hostCPUSeconds": 0.2, "childCPUSeconds": 0.3,
                "sourceWindows": 2, "readings": readings}

    def test_cpu_includes_children_and_uses_one_core_percentage(self):
        report = BENCHMARK.summarize([self.run_sample([])])[0]
        self.assertAlmostEqual(report["cpuPercentOfOneCore"], 5)
        self.assertIsNone(report["medianTransitionDelaySeconds"])
        self.assertNotIn("readings", report)

    def test_signal_changes_measure_both_lead_and_lag(self):
        readings = [{"playhead": 0.1, "peak": -6},
                    {"playhead": 1.7, "peak": -7.5},
                    {"playhead": 1.8, "peak": -7.5},
                    {"playhead": 4.1, "peak": -9}]
        report = BENCHMARK.summarize([self.run_sample(readings)])[0]
        self.assertEqual(len(report["transitions"]), 2)
        self.assertAlmostEqual(report["transitions"][0]["delaySeconds"], -0.3)
        self.assertAlmostEqual(report["transitions"][1]["delaySeconds"], 0.1)
        self.assertAlmostEqual(report["medianTransitionDelaySeconds"], -0.1)

    def test_history_ingest_latency_uses_finite_observations_and_nearest_rank_percentile(self):
        readings = [{"playhead": index, "historyIngestSeconds": index / 1000} for index in range(1, 21)]
        readings += [{"playhead": 30, "historyIngestSeconds": float("nan")},
                     {"playhead": 31, "historyIngestSeconds": -1}, {"playhead": 32}]
        report = BENCHMARK.summarize([self.run_sample(readings)])[0]
        self.assertEqual(report["historyIngestCount"], 20)
        self.assertAlmostEqual(report["medianHistoryIngestSeconds"], 0.0105)
        self.assertAlmostEqual(report["p95HistoryIngestSeconds"], 0.019)
        self.assertAlmostEqual(report["maxHistoryIngestSeconds"], 0.020)

    def test_initial_value_missing_and_mixed_frames_are_not_edges(self):
        readings = [{"playhead": 0.1}, {"playhead": 2.2, "peak": -7.5},
                    {"playhead": 2.3, "peak": None}, {"playhead": 3.9, "peak": -8.25},
                    {"playhead": 4.2, "peak": -9}]
        report = BENCHMARK.summarize([self.run_sample(readings)])[0]
        self.assertEqual(report["readingCount"], 3)
        self.assertEqual(len(report["transitions"]), 1)
        self.assertEqual(report["transitions"][0]["sourceSeconds"], 4)


if __name__ == "__main__":
    unittest.main()
