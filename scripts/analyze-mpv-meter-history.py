#!/usr/bin/env python3
"""Validate received experimental filter-history snapshots, not device alignment."""
import argparse
import json
import math
from pathlib import Path


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def analyze(rows):
    errors, seen, epochs, counters, actions, speeds = [], {}, {}, {}, set(), set()
    playback_speeds, audio_ids, paused_values, seeking_values, requested_outputs = (set() for _ in range(5))
    output_unconfirmed = 0
    latest_instance, last_receipt = None, None
    closed_instances, latest_states = set(), {}
    snapshots = missing = invalid = 0
    observed_seek = observed_restart = False
    for number, row in enumerate(rows, 1):
        snapshots += 1
        try:
            if not isinstance(row, dict) or not integer(row.get("action")):
                raise ValueError("invalid capture row/action")
            action = row["action"]
            actions.add(action)
            for name in ("position", "audio-pts"):
                if row.get(name) is not None and not finite(row[name]):
                    raise ValueError("invalid player clock " + name)
            if "read-start" in row or "read-end" in row:
                start, end = row.get("read-start"), row.get("read-end")
                if not finite(start) or not finite(end) or start < 0 or end < start:
                    raise ValueError("invalid property read interval")
            if "receipt" in row:
                receipt = row["receipt"]
                if not finite(receipt) or receipt < 0 or (last_receipt is not None and receipt < last_receipt):
                    raise ValueError("invalid/regressing monotonic receipt time")
                last_receipt = receipt
            if "output-confirmed" in row:
                if type(row["output-confirmed"]) is not bool:
                    raise ValueError("invalid output confirmation")
                output_unconfirmed += not row["output-confirmed"]
            if row.get("requested-output") is not None:
                if not isinstance(row["requested-output"], str):
                    raise ValueError("invalid requested output")
                requested_outputs.add(row["requested-output"])
            if row.get("speed") is not None:
                if not finite(row["speed"]) or row["speed"] <= 0:
                    raise ValueError("invalid playback speed")
                playback_speeds.add(row["speed"])
            if row.get("audio-id") is not None:
                if not integer(row["audio-id"]):
                    raise ValueError("invalid audio track ID")
                audio_ids.add(row["audio-id"])
            for name, values in (("paused", paused_values), ("seeking", seeking_values)):
                if row.get(name) is not None:
                    if type(row[name]) is not bool:
                        raise ValueError("invalid playback " + name)
                    values.add(row[name])
            history = row.get("history")
            if history is None:
                missing += 1
                continue
            if not isinstance(history, dict) or type(history.get("schema-version")) is not int or history["schema-version"] != 1:
                raise ValueError("unsupported history schema")
            for key in ("instance", "epoch", "last-sequence", "evicted", "rejected"):
                if not integer(history.get(key)):
                    raise ValueError("invalid history " + key)
            if history.get("capacity") != 128 or type(history.get("capacity")) is not int:
                raise ValueError("invalid history capacity")
            frames = history.get("frames")
            if not isinstance(frames, list) or len(frames) > 128:
                raise ValueError("invalid history frame count")
            instance, epoch = history["instance"], history["epoch"]
            if instance in closed_instances:
                raise ValueError("filter instance recurred after replacement")
            prior = latest_states.get(instance)
            if prior is not None:
                for name in ("epoch", "last-sequence", "evicted", "rejected"):
                    if history[name] < prior[name]:
                        raise ValueError("regressing history " + name)
            if latest_instance is not None and latest_instance != instance:
                closed_instances.add(latest_instance)
            latest_instance = instance
            latest_states[instance] = {name: history[name] for name in
                                       ("epoch", "last-sequence", "evicted", "rejected")}
            key = (instance, epoch)
            if instance not in counters:
                if counters and action == 5:
                    observed_restart = True
                counters[instance] = {"evicted": 0, "rejected": 0}
            if key not in epochs:
                if any(i == instance and e != epoch for i, e in epochs) and action >= 3:
                    observed_seek = True
                epochs[key] = {"frames": {}, "last-sequence": history["last-sequence"]}
            state = epochs[key]
            state["last-sequence"] = max(state["last-sequence"], history["last-sequence"])
            for name in ("evicted", "rejected"):
                counters[instance][name] = max(counters[instance][name], history[name])
            previous = 0
            for entry in frames:
                if not isinstance(entry, dict) or not integer(entry.get("sequence"), 1):
                    raise ValueError("invalid frame sequence")
                sequence = entry["sequence"]
                if sequence <= previous or sequence > history["last-sequence"]:
                    raise ValueError("unordered/out-of-range frame sequence")
                previous = sequence
                if not isinstance(entry.get("frame"), str):
                    raise ValueError("frame must contain JSON text")
                frame = json.loads(entry["frame"])
                identity = (instance, epoch, sequence)
                if identity in seen:
                    if seen[identity] != frame:
                        raise ValueError("changed duplicate frame identity")
                    continue
                if not isinstance(frame, dict) or type(frame.get("valid-time")) is not bool:
                    raise ValueError("invalid frame time flag")
                if not integer(frame.get("samples"), 1) or not integer(frame.get("sample-rate"), 1):
                    raise ValueError("invalid sample count/rate")
                if not isinstance(frame.get("layout"), str) or not frame["layout"]:
                    raise ValueError("invalid channel layout")
                metadata = frame.get("metadata")
                if not isinstance(metadata, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in metadata.items()):
                    raise ValueError("invalid frame metadata")
                if frame["valid-time"]:
                    for name in ("start", "end", "effective-rate", "speed"):
                        if not finite(frame.get(name)):
                            raise ValueError("nonfinite/missing frame " + name)
                    rate, speed = frame["effective-rate"], frame["speed"]
                    if rate <= 0 or speed <= 0 or frame["end"] <= frame["start"]:
                        raise ValueError("invalid time interval/rate/speed")
                    if not math.isclose(rate, frame["sample-rate"] / speed, rel_tol=1e-6, abs_tol=2e-6):
                        raise ValueError("inconsistent effective sample rate")
                    if abs(frame["end"] - frame["start"] - frame["samples"] / rate) > 2e-6 + 0.5 / rate:
                        raise ValueError("inconsistent frame duration")
                    speeds.add(speed)
                else:
                    invalid += 1
                seen[identity] = frame
                state["frames"][sequence] = frame
        except (ValueError, TypeError, OverflowError) as error:
            errors.append({"row": number, "error": str(error)})

    gaps, breaks = [], []
    for (instance, epoch), state in sorted(epochs.items()):
        ordered = sorted(state["frames"].items())
        previous_sequence = 0 if epoch == 0 else None
        previous_frame = None
        for sequence, frame in ordered:
            if previous_sequence is not None and sequence != previous_sequence + 1:
                gaps.append({"instance": instance, "epoch": epoch,
                             "first": previous_sequence + 1, "last": sequence - 1})
            if (previous_frame and sequence == previous_sequence + 1 and
                    previous_frame["valid-time"] and frame["valid-time"]):
                tolerance = 2e-6 + 0.5 / frame["effective-rate"]
                if (abs(frame["start"] - previous_frame["end"]) > tolerance or
                        frame["sample-rate"] != previous_frame["sample-rate"] or
                        frame["layout"] != previous_frame["layout"]):
                    breaks.append({"instance": instance, "epoch": epoch, "sequence": sequence})
            previous_sequence, previous_frame = sequence, frame
        if previous_sequence is not None and previous_sequence < state["last-sequence"]:
            gaps.append({"instance": instance, "epoch": epoch,
                         "first": previous_sequence + 1, "last": state["last-sequence"]})
    missing_actions = sorted(set(range(6)) - actions)
    complete = bool(seen) and not (errors or missing or invalid or gaps or breaks or missing_actions or output_unconfirmed or
                                   any(c["rejected"] for c in counters.values())) and observed_seek and observed_restart
    uncertain = [{"instance": instance, "epoch": epoch,
                  "first_received_sequence": min(state["frames"], default=None)}
                 for (instance, epoch), state in sorted(epochs.items()) if epoch != 0]
    return {"alignment_qualified": False, "reset_boundary_coverage_unknown": uncertain, "observed_history_complete": complete,
            "coverage": "Received snapshots and observed epochs only; unobserved epoch boundaries and final frames are not certified.",
            "snapshots": snapshots, "missing_history_snapshots": missing,
            "unique_frames": len(seen), "epochs": len(epochs), "invalid_time_frames": invalid,
            "actions": sorted(actions), "missing_actions": missing_actions,
            "post_seek_epoch_observed": observed_seek, "post_reinsert_instance_observed": observed_restart,
            "frame_speed_values": sorted(speeds), "speed_change_verified": False,
            "playback_speed_values": sorted(playback_speeds), "audio_track_ids": sorted(audio_ids),
            "paused_values": sorted(paused_values), "seeking_values": sorted(seeking_values),
            "requested_outputs": sorted(requested_outputs), "output_unconfirmed_snapshots": output_unconfirmed,
            "instance_counters": {str(k): v for k, v in sorted(counters.items())},
            "sequence_gaps": gaps, "continuity_breaks": breaks, "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with args.input.open() as source:
        result = analyze(json.loads(line) for line in source if line.strip())
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    if result["errors"] or result["sequence_gaps"] or result["continuity_breaks"] or result["invalid_time_frames"]:
        parser.exit(1, "Invalid or incomplete received frame history; see the analysis report.\n")


if __name__ == "__main__":
    main()
