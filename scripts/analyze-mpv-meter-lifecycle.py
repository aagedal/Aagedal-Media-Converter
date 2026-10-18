#!/usr/bin/env python3
"""Check isolated probe lifecycle observations; never certify presentation timing."""
import argparse
import importlib.util
import json
import lzma
import math
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "meter_history", Path(__file__).with_name("analyze-mpv-meter-history.py"))
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)


def identity(row):
    history = row.get("history")
    if isinstance(history, dict) and history.get("frames"):
        return history["instance"], history["epoch"]
    return None


def analyze(rows, replacement_start=None):
    rows = list(rows)
    history = HISTORY.analyze(rows)
    errors, commands, events = [], [], []
    checks = {}
    try:
        if history["errors"]:
            raise ValueError("invalid frame history; see history errors")
        declared = None
        for row in rows:
            if type(row.get("lifecycle-version")) is not int or row["lifecycle-version"] != 1:
                raise ValueError("missing/unsupported lifecycle evidence")
            start, end = row.get("read-start"), row.get("read-end")
            if not HISTORY.finite(start) or not HISTORY.finite(end) or not 0 <= start <= end:
                raise ValueError("invalid snapshot interval")
            if type(row.get("source-confirmed")) is not bool:
                raise ValueError("missing source confirmation")
            if type(row.get("replacement-requested")) is not bool or "requested-second-audio-id" not in row:
                raise ValueError("missing declared lifecycle scenario")
            target_audio = row["requested-second-audio-id"]
            if target_audio is not None and not HISTORY.integer(target_audio, 1):
                raise ValueError("invalid requested track")
            scenario = row["replacement-requested"], target_audio
            if declared is not None and declared != scenario:
                raise ValueError("changed declared lifecycle scenario")
            declared = scenario
            for key, previous, limit in (("commands", commands, 16), ("events", events, 128)):
                current = row.get(key)
                if not isinstance(current, list) or not len(previous) <= len(current) <= limit or current[:len(previous)] != previous:
                    raise ValueError("missing, changed or truncated cumulative " + key)
                prior_time = 0
                for index, record in enumerate(current, 1):
                    if not isinstance(record, dict) or type(record.get("id")) is not int or record["id"] != index:
                        raise ValueError("invalid " + key + " identity/order")
                    if not HISTORY.integer(record.get("action")):
                        raise ValueError("invalid " + key + " action")
                    first = record.get("start" if key == "commands" else "time")
                    last = record.get("end" if key == "commands" else "time")
                    if not HISTORY.finite(first) or not HISTORY.finite(last) or not prior_time <= first <= last <= start:
                        raise ValueError("invalid " + key + " interval/order")
                    prior_time = last
                    if key == "commands" and (type(record.get("result")) is not int or record["result"] != 0):
                        raise ValueError("failed/missing command result")
                    if key == "events" and (record.get("name") not in
                            ("start-file", "file-loaded", "seek", "playback-restart", "end-file") or
                            type(record.get("entry")) is not int):
                        raise ValueError("invalid/overflow event")
                previous[:] = current
            if not commands or row.get("action") != commands[-1]["action"]:
                raise ValueError("snapshot action disagrees with commands")
            generation = sum(c["name"] == "replace" for c in commands)
            if type(row.get("requested-generation")) is not int or row["requested-generation"] != generation:
                raise ValueError("snapshot requested generation disagrees with commands")
        names = [c.get("name") for c in commands]
        expected = ["load", "pause", "resume", "seek", "speed", "reinsert"]
        if declared is not None and declared[1] is not None:
            expected.append("track")
        if declared is not None and declared[0]:
            expected.append("replace")
        if names != expected or [c["action"] for c in commands] != list(range(len(commands))):
            raise ValueError("incomplete/unexpected lifecycle command sequence")
        if replacement_start is not None and "replace" not in names:
            raise ValueError("replacement start supplied without replacement command")

        for index, command in enumerate(commands):
            name = command["name"]
            until = commands[index + 1]["start"] if index + 1 < len(commands) else math.inf
            # Every observation must finish before the next command begins.
            phase = [r for r in rows if command["end"] <= r["read-start"] and r["read-end"] < until]
            phase_events = [e for e in events if command["end"] <= e["time"] < until]
            before = [r for r in rows if r["read-end"] <= command["start"] and identity(r)]
            old = identity(before[-1]) if before else None
            fresh = [r for r in phase if identity(r)]
            source = [r for r in fresh if r["source-confirmed"] and r.get("output-confirmed") is True]

            def event_chain(*wanted):
                cursor = iter(phase_events)
                return all(any(e["name"] == target for e in cursor) for target in wanted)

            def changed(row):
                new = identity(row)
                return old is not None and new is not None and (new[0] != old[0] or new[1] > old[1])

            def progressing(items):
                positions = [r["position"] for r in items if HISTORY.finite(r.get("position"))]
                return len(positions) >= 2 and positions[-1] - positions[0] >= 0.1

            if name == "load":
                passed = bool(source) and event_chain("start-file", "file-loaded", "playback-restart")
            elif name == "pause":
                paused = [r for r in source if r.get("paused") is True and HISTORY.finite(r.get("position"))]
                passed = (len(paused) >= 2 and paused[-1]["read-start"] - paused[0]["read-end"] >= 0.2 and
                          max(r["position"] for r in paused) - min(r["position"] for r in paused) <= 0.05)
            elif name == "resume":
                passed = progressing([r for r in source if r.get("paused") is False])
            elif name == "seek":
                restarted = [e["time"] for e in phase_events if e["name"] == "playback-restart"]
                settled = [r for r in source if restarted and r["read-start"] >= restarted[-1] and
                           r.get("seeking") is False and changed(r)]
                passed = event_chain("seek", "playback-restart") and any(
                    HISTORY.finite(r.get("position")) and abs(r["position"] - 8) <= 0.5 and
                    abs(json.loads(r["history"]["frames"][0]["frame"])["start"] - 8) <= 0.1
                    for r in settled)
            elif name == "speed":
                passed = progressing([r for r in source if r.get("speed") == 1.5 and r.get("paused") is False])
            elif name == "reinsert":
                passed = command.get("removal-confirmed") is True and old is not None and any(
                    identity(r)[0] != old[0] for r in source)
            elif name == "track":
                previous_id = before[-1].get("audio-id") if before else None
                passed = previous_id is not None and any(
                    r.get("audio-id") == declared[1] and r["audio-id"] != previous_id and changed(r) for r in source)
            else:  # Source replacement: requested generation alone proves nothing.
                starts = [e for e in phase_events if e["name"] == "start-file"]
                prior_entries = [e["entry"] for e in events if e["name"] == "start-file" and e["time"] < command["start"]]
                ready = [r for r in source if changed(r)]
                first_loaded = next((e["time"] for e in phase_events if e["name"] == "file-loaded"), math.inf)
                ready = [r for r in ready if r["read-start"] >= first_loaded]
                settled = [r for r in phase if ready and r["read-start"] >= ready[0]["read-start"]]
                passed = (event_chain("start-file", "file-loaded", "playback-restart") and bool(starts) and
                          starts[0]["entry"] >= 0 and starts[0]["entry"] not in prior_entries and bool(ready) and
                          bool(settled) and all(r["source-confirmed"] and r.get("output-confirmed") is True and changed(r)
                                                for r in settled))
                if replacement_start is not None:
                    passed = passed and bool(ready) and abs(
                        json.loads(ready[0]["history"]["frames"][0]["frame"])["start"] - replacement_start
                    ) <= 2e-6 + 1 / json.loads(ready[0]["history"]["frames"][0]["frame"])["sample-rate"]
            checks[name] = bool(passed)
    except (ValueError, TypeError, KeyError, IndexError, OverflowError) as error:
        errors.append(str(error))
    clean = not (history["errors"] or history["invalid_time_frames"] or history["sequence_gaps"] or
                 history["continuity_breaks"] or any(c["rejected"] for c in history["instance_counters"].values()))
    return {"passed": bool(checks) and all(checks.values()) and clean and not errors,
            "checks": checks, "errors": errors, "history": history,
            "alignment_qualified": False, "causal_event_attribution_verified": False,
            "loudness_reset_verified": False,
            "scope": "Observed API acceptance, event order, player state and history identity in scheduled command windows. "
                     "Events have no command IDs; unobserved reset boundaries, final frames and presentation timing remain uncertified."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--replacement-start", type=float)
    args = parser.parse_args()
    if args.replacement_start is not None and not math.isfinite(args.replacement_start):
        parser.error("replacement start must be finite")
    opener = lzma.open if args.input.suffix == ".xz" else open
    with opener(args.input, "rt") as source:
        result = analyze((json.loads(line) for line in source if line.strip()), args.replacement_start)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    if not result["passed"]:
        parser.exit(1, "Lifecycle observations failed acceptance; see report.\n")


if __name__ == "__main__":
    main()
