"""Reject incomplete or stale lifecycle evidence without claiming device timing."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "meter_lifecycle", Path(__file__).resolve().parents[1] / "analyze-mpv-meter-lifecycle.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
RUNNER_SPEC = importlib.util.spec_from_file_location(
    "lifecycle_runner", Path(__file__).resolve().parents[1] / "benchmark-mpv-meter-lifecycle.py")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)


def capture(track=False):
    commands, events, rows = [], [], []
    phases = [("load", 0, 1, 0, 0), ("pause", 2, 1, 0, 0),
              ("resume", 3, 1, 0, 0), ("seek", 4, 1, 1, 8),
              ("speed", 6, 1, 1, 8), ("reinsert", 8, 2, 0, 13),
              ("replace", 12, 3, 0, 0.75)]
    if track:
        phases.insert(-1, ("track", 10, 3, 0, 16))
        phases[-1] = ("replace", 12, 4, 0, 0.75)
    for action, (name, time, instance, epoch, frame_start) in enumerate(phases):
        commands.append({"id": action + 1, "name": name, "action": action,
                         "start": time, "end": time + 0.001, "result": 0,
                         "removal-confirmed": name == "reinsert"})
        event_names = {"load": ["start-file", "file-loaded", "playback-restart"],
                       "seek": ["seek", "playback-restart"],
                       "replace": ["start-file", "file-loaded", "playback-restart"]}.get(name, [])
        for index, event in enumerate(event_names):
            events.append({"id": len(events) + 1, "name": event, "action": action,
                           "time": time + 0.01 * (index + 1),
                           "entry": (2 if name == "replace" else 1) if event == "start-file" else -1})
        frame = {"valid-time": True, "start": frame_start, "end": frame_start + 0.1,
                 "samples": 4800, "sample-rate": 48000, "effective-rate": 48000,
                 "speed": 1, "layout": "stereo", "metadata": {}}
        for offset in (0.1, 0.4):
            position = (2 if name == "pause" else 8 + offset if name == "seek" else time + offset)
            rows.append({"action": action, "receipt": time + offset, "read-start": time + offset,
                         "read-end": time + offset + 0.001, "lifecycle-version": 1,
                         "replacement-requested": True, "requested-second-audio-id": 2 if track else None,
                         "commands": copy.deepcopy(commands), "events": copy.deepcopy(events),
                         "source-confirmed": True, "output-confirmed": True,
                         "requested-generation": int(name == "replace"),
                         "paused": name == "pause", "seeking": False, "position": position,
                         "speed": 1 if action < 4 else 1.5, "audio-id": 2 if name == "track" else 1,
                         "history": {"schema-version": 1, "instance": instance, "epoch": epoch,
                                     "capacity": 128, "last-sequence": 2 if epoch else 1,
                                     "evicted": 0, "rejected": 0,
                                     "frames": [{"sequence": 2 if epoch else 1, "frame": json.dumps(frame)}]}})
    return rows


def change_records(rows, kind, matching_name, **updates):
    for row in rows:
        for record in row[kind]:
            if record["name"] == matching_name:
                record.update(updates)


class MeterLifecycleTests(unittest.TestCase):
    def test_complete_observations_retain_limits(self):
        result = MODULE.analyze(capture(), 0.75)
        self.assertTrue(result["passed"], result)
        self.assertEqual(len(result["checks"]), 7)
        for key in ("alignment_qualified", "causal_event_attribution_verified", "loudness_reset_verified"):
            self.assertFalse(result[key])
        self.assertEqual(result["history"]["frame_speed_values"], [1])

    def test_legacy_and_incomplete_capture_fail(self):
        for rows in ([], [{"action": 0, "history": None}], capture()[:2], capture()[:-2]):
            self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_declared_scenario_cannot_change(self):
        rows = capture()
        rows[-1]["replacement-requested"] = False
        self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_track_switch_requires_requested_id_and_fresh_history(self):
        self.assertTrue(MODULE.analyze(capture(track=True))["passed"])
        for target in (1, 3):
            rows = capture(track=True)
            for row in rows:
                if row["action"] == 6:
                    row["audio-id"] = target
            self.assertFalse(MODULE.analyze(rows)["checks"]["track"])

    def test_command_failures_and_corrupted_cumulative_evidence_fail(self):
        for mutate in (
            lambda rows: change_records(rows, "commands", "seek", result=-1),
            lambda rows: rows[-1]["commands"].pop(),
            lambda rows: rows[-1]["events"][0].update(time=99),
            lambda rows: rows[-1]["commands"][0].update(result=True),
            lambda rows: rows[-1].update(**{"requested-generation": 0}),
            lambda rows: change_records(rows, "events", "seek", name="queue-overflow"),
        ):
            rows = capture()
            mutate(rows)
            self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_stale_or_reordered_seek_events_fail(self):
        for event, time in (("seek", 0.04), ("seek", 4.03), ("playback-restart", 0.04)):
            rows = capture()
            for row in rows:
                for record in row["events"]:
                    if record["action"] == 3 and record["name"] == event:
                        record["time"] = time
                row["events"].sort(key=lambda e: e["time"])
                for index, record in enumerate(row["events"], 1):
                    record["id"] = index
            self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_each_required_state_transition_is_checked(self):
        for action, update in ((1, {"paused": False}), (2, {"position": 2}),
                               (3, {"position": 0}), (3, {"seeking": True}),
                               (4, {"speed": 1}), (6, {"source-confirmed": False})):
            rows = capture()
            for row in rows:
                if row["action"] == action:
                    row.update(update)
            result = MODULE.analyze(rows)
            self.assertFalse(result["passed"], (action, update, result))

    def test_reinsertion_requires_removed_metadata_and_new_instance(self):
        rows = capture()
        change_records(rows, "commands", "reinsert", **{"removal-confirmed": False})
        self.assertFalse(MODULE.analyze(rows)["passed"])
        for row in rows:
            if row["action"] == 5:
                row["history"]["instance"] = 1
        change_records(rows, "commands", "reinsert", **{"removal-confirmed": True})
        self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_replacement_requires_new_playlist_and_initial_sample(self):
        rows = capture()
        self.assertFalse(MODULE.analyze(rows, 0)["checks"]["replace"])
        for row in rows:
            for record in row["events"]:
                if record["action"] == 6 and record["name"] == "start-file":
                    record["entry"] = 1
        self.assertFalse(MODULE.analyze(rows, 0.75)["checks"]["replace"])

    def test_old_history_returning_after_replacement_fails(self):
        rows = capture()
        rows[-1]["history"] = copy.deepcopy(rows[-3]["history"])
        self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_missing_history_after_last_command_fails(self):
        rows = capture()
        for row in rows:
            if row["action"] == 6:
                row["history"] = None
        self.assertFalse(MODULE.analyze(rows)["checks"]["replace"])

    def test_history_loss_after_replacement_readiness_fails(self):
        rows = capture()
        rows[-1]["history"] = None
        self.assertFalse(MODULE.analyze(rows)["checks"]["replace"])

    def test_malformed_history_and_unconfirmed_output_fail(self):
        for update in ({"history": "bad"}, {"history": {"schema-version": 99}},
                       {"output-confirmed": False}):
            rows = capture()
            for row in rows:
                row.update(update)
            self.assertFalse(MODULE.analyze(rows)["passed"])

    def test_runner_requires_both_lifecycle_and_per_generation_signal(self):
        rows = capture()
        samples = RUNNER.BENCHMARK.signal_samples()
        references = {"original": (0, samples), "delayed": (0.75, samples)}
        for row in rows:
            entry = row["history"]["frames"][0]
            frame = json.loads(entry["frame"])
            first = round((frame["start"] - (0.75 if row["requested-generation"] else 0)) * 48000)
            for channel in range(2):
                values = samples[first * 2 + channel:(first + 4800) * 2:2]
                for metric, amplitude in (("Peak_level", max(abs(v) for v in values)),
                                          ("RMS_level", math.sqrt(math.fsum(v * v for v in values) / len(values)))):
                    frame["metadata"][f"lavfi.astats.{channel + 1}.{metric}"] = str(
                        20 * math.log10(amplitude) if amplitude else -math.inf)
            entry["frame"] = json.dumps(frame)
        self.assertTrue(RUNNER.evaluate(rows, references)["passed"])
        # Matching sample values cannot rescue missing lifecycle observations.
        broken = copy.deepcopy(rows)
        change_records(broken, "commands", "reinsert", **{"removal-confirmed": False})
        self.assertFalse(RUNNER.evaluate(broken, references)["passed"])
        # Correct lifecycle identities cannot rescue a wrong signal after replacement.
        for row in rows[-2:]:
            entry = row["history"]["frames"][0]
            frame = json.loads(entry["frame"])
            frame["metadata"]["lavfi.astats.1.RMS_level"] = "-100"
            entry["frame"] = json.dumps(frame)
        result = RUNNER.evaluate(rows, references)
        self.assertTrue(result["lifecycle"]["passed"])
        self.assertFalse(result["passed"])

    def test_runner_rejects_missing_generation_and_malformed_history(self):
        rows = capture()
        rows[-1]["history"] = "bad"
        self.assertFalse(RUNNER.evaluate(rows, {"original": (0, []), "delayed": (0.75, [])})["passed"])


if __name__ == "__main__":
    unittest.main()
