"""Exercise capture completeness checks using synthetic received snapshots."""
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "meter_history_analysis", Path(__file__).resolve().parents[1] / "analyze-mpv-meter-history.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def frame(start=0):
    return {"valid-time": True, "start": start, "end": start + 0.1,
            "samples": 4800, "sample-rate": 48000, "effective-rate": 48000,
            "speed": 1, "layout": "stereo", "metadata": {"peak": "-inf"}}


def row(action, instance=1, epoch=0, sequence=1, value=None):
    return {"action": action, "position": 0, "history": {
        "schema-version": 1, "instance": instance, "epoch": epoch,
        "last-sequence": sequence, "evicted": 0, "rejected": 0, "capacity": 128,
        "frames": [{"sequence": sequence, "frame": json.dumps(value or frame())}]}}


def good():
    return [row(0), row(1), row(2), row(3, epoch=1, sequence=4, value=frame(8)),
            row(4, epoch=1, sequence=4, value=frame(8)), row(5, instance=2)]


class MeterHistoryAnalysisTests(unittest.TestCase):
    def test_good_reset_restart_and_duplicates(self):
        result = MODULE.analyze(good())
        self.assertTrue(result["observed_history_complete"])
        self.assertFalse(result["alignment_qualified"])
        self.assertFalse(result["speed_change_verified"])
        self.assertEqual(result["unique_frames"], 3)
        self.assertEqual(result["epochs"], 3)

    def test_missing_history_or_actions_is_incomplete(self):
        for rows in ([], [{"action": 0, "history": None}], good()[:-1]):
            self.assertFalse(MODULE.analyze(rows)["observed_history_complete"])

    def test_sequence_gap_and_changed_duplicate(self):
        rows = good()
        rows.insert(1, row(0, sequence=3, value=frame(0.2)))
        result = MODULE.analyze(rows)
        self.assertFalse(result["observed_history_complete"])
        self.assertEqual(result["sequence_gaps"][0]["first"], 2)
        rows = good()
        rows[1]["history"]["frames"][0]["frame"] = json.dumps(frame(1))
        result = MODULE.analyze(rows)
        self.assertFalse(result["observed_history_complete"])
        self.assertIn("changed duplicate", result["errors"][0]["error"])

    def test_invalid_time_and_nonfinite(self):
        for invalid in ({**frame(), "valid-time": False}, {**frame(), "start": float("nan")}):
            rows = good()
            rows[0] = row(0, value=invalid)
            self.assertFalse(MODULE.analyze(rows)["observed_history_complete"])
        rows = good()
        for item in rows[:3]:
            item["history"]["frames"][0]["frame"] = json.dumps({**frame(), "valid-time": False})
        self.assertEqual(MODULE.analyze(rows)["invalid_time_frames"], 1)

    def test_rate_duration_and_schema_validation(self):
        for update in ({"samples": 0}, {"sample-rate": True}, {"effective-rate": 24000},
                       {"end": 0.11}, {"speed": 0}, {"metadata": {"peak": -1}}):
            rows = good()
            rows[0] = row(0, value={**frame(), **update})
            result = MODULE.analyze(rows)
            self.assertFalse(result["observed_history_complete"])
            self.assertTrue(result["errors"])
        rows = good()
        rows[0]["history"]["schema-version"] = 2
        self.assertTrue(MODULE.analyze(rows)["errors"])

    def test_continuity_and_observed_evictions(self):
        rows = good()
        rows.insert(1, row(0, sequence=2, value=frame(0.3)))
        self.assertTrue(MODULE.analyze(rows)["continuity_breaks"])
        rows = good()
        for item in rows[2:5]:
            item["history"]["evicted"] = 1
        result = MODULE.analyze(rows)
        self.assertTrue(result["observed_history_complete"])
        self.assertEqual(result["instance_counters"]["1"]["evicted"], 1)
        for item in rows[2:5]:
            item["history"]["rejected"] = 1
        self.assertFalse(MODULE.analyze(rows)["observed_history_complete"])

    def test_snapshot_order_bounds_and_missing_lifecycle(self):
        rows = good()
        rows[0]["history"]["frames"] *= 129
        self.assertTrue(MODULE.analyze(rows)["errors"])
        rows = good()
        rows[0]["history"]["frames"] *= 2
        self.assertTrue(MODULE.analyze(rows)["errors"])
        rows = [row(i) for i in range(6)]
        result = MODULE.analyze(rows)
        self.assertFalse(result["observed_history_complete"])
        self.assertFalse(result["post_seek_epoch_observed"])
        self.assertFalse(result["post_reinsert_instance_observed"])

    def test_optional_driver_and_playback_state(self):
        rows = good()
        rows.append({**row(6, instance=2), "speed": 1.5, "audio-id": 2,
                     "paused": False, "seeking": False, "requested-output": "null",
                     "output-confirmed": True})
        result = MODULE.analyze(rows)
        self.assertTrue(result["observed_history_complete"])
        self.assertEqual(result["audio_track_ids"], [2])
        self.assertEqual(result["playback_speed_values"], [1.5])
        self.assertEqual(result["frame_speed_values"], [1])
        rows[-1]["output-confirmed"] = False
        self.assertFalse(MODULE.analyze(rows)["observed_history_complete"])

    def test_regressing_counters_sequence_epoch_and_reappearing_instance(self):
        for name in ("evicted", "rejected", "last-sequence", "epoch"):
            first = row(0, epoch=1, sequence=4)
            second = row(1, epoch=1, sequence=4)
            first["history"][name] += 1
            result = MODULE.analyze([first, second])
            self.assertTrue(any("regressing history " + name in e["error"] for e in result["errors"]))
        result = MODULE.analyze(good() + [row(6)])
        self.assertTrue(any("recurred" in e["error"] for e in result["errors"]))

    def test_receipt_validation_and_paused_repeated_snapshots(self):
        for receipt in (-1, float("inf"), float("nan"), True):
            self.assertTrue(MODULE.analyze([{**row(0), "receipt": receipt}])["errors"])
        self.assertTrue(MODULE.analyze([{**row(0), "receipt": 2},
                                       {**row(1), "receipt": 1}])["errors"])
        rows = good()
        for index, item in enumerate(rows):
            item["receipt"] = index // 2
        result = MODULE.analyze(rows)
        self.assertFalse(result["errors"])
        self.assertTrue(result["observed_history_complete"])


if __name__ == "__main__":
    unittest.main()
