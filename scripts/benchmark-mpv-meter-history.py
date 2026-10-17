#!/usr/bin/env python3
"""Run isolated timestamp-history diagnostics; never qualify device alignment."""
import argparse
import array
import gzip
import lzma
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("history", ROOT / "scripts/analyze-mpv-meter-history.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_digest(path, expected):
    if digest(path) != expected:
        raise ValueError(f"Evidence hash mismatch: {path}")


def run(command, **kwargs):
    return subprocess.run([str(p) for p in command], check=True, timeout=90, **kwargs)


def fixtures(ffmpeg, output):
    # Distinct channels: alternating sustained level, and 1 ms impulses every 2 s.
    # PCM keeps the reference independent of codec reconstruction.
    raw = output / "signal.f32"
    samples = array.array("f")
    for n in range(30 * 48000):
        t = n / 48000
        samples.extend(((0.05 if int(t / 2) % 2 == 0 else 0.2) * math.sin(2 * math.pi * 1000 * t),
                        0.5 if n % 96000 in range(48000, 48048) else 0))
    if sys.byteorder != "little":
        samples.byteswap()
    raw.write_bytes(samples.tobytes())
    paths = {}
    for name, delay, codec in (("lossless", 0, "pcm_f32le"),
                               ("delayed", 0.75, "pcm_f32le"), ("aac", 0, "aac")):
        path = output / (name + ".mov")
        run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=160x90:r=25:d=31",
             "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", raw,
             "-map", "0:v", "-map", "1:a", "-af", f"asetpts=PTS+{delay}/TB", "-c:v", "mpeg4", "-q:v", "8", "-c:a", codec, path])
        paths[name] = path
    return paths


def reference(ffmpeg, ffprobe, path):
    result = run([ffprobe, "-v", "error", "-select_streams", "a:0", "-show_frames",
                  "-show_entries", "frame=best_effort_timestamp_time,sample_rate",
                  "-of", "json", path], capture_output=True, text=True)
    frames = json.loads(result.stdout)["frames"]
    start = float(frames[0]["best_effort_timestamp_time"])
    result = run([ffmpeg, "-v", "error", "-i", path, "-map", "0:a:0", "-f", "f32le",
                  "-acodec", "pcm_f32le", "-"], capture_output=True)
    samples = array.array("f")
    samples.frombytes(result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    return start, samples


def signal_check(rows, start, samples, tolerance_db=0.05):
    seen, errors, checked, impulses = set(), [], 0, set()
    for row in rows:
        h = row.get("history")
        if not h:
            continue
        for entry in h["frames"]:
            identity = (h["instance"], h["epoch"], entry["sequence"])
            if identity in seen:
                continue
            seen.add(identity)
            frame = json.loads(entry["frame"])
            if not frame["valid-time"] or frame["sample-rate"] != 48000 or frame["speed"] != 1:
                errors.append({"identity": identity, "error": "unsupported reference timing"})
                continue
            first = round((frame["start"] - start) * 48000)
            end = first + frame["samples"]
            if first < 0 or end * 2 > len(samples):
                errors.append({"identity": identity, "error": "frame outside reference"})
                continue
            for channel in range(2):
                peak = max(abs(v) for v in samples[first * 2 + channel:end * 2:2])
                expected = 20 * math.log10(peak) if peak else -math.inf
                key = f"lavfi.astats.{channel + 1}.Peak_level"
                try:
                    actual = float(frame["metadata"][key])
                except (KeyError, ValueError):
                    errors.append({"identity": identity, "error": "missing peak", "channel": channel + 1})
                    continue
                if not (actual == expected or
                        (math.isfinite(actual) and math.isfinite(expected) and abs(actual - expected) <= tolerance_db)):
                    errors.append({"identity": identity, "channel": channel + 1,
                                   "expected": expected if math.isfinite(expected) else "-inf",
                                   "actual": actual if math.isfinite(actual) else str(actual)})
                if channel == 1 and peak >= 0.49:
                    # Record independently known impulse sample locations covered by this frame.
                    impulses.update(n // 96000 for n in range(first, end)
                                    if n % 96000 in range(48000, 48048))
            checked += 1
    return {"frames_checked": checked, "tolerance_db": tolerance_db,
            "reference_start": start, "impulses_covered": sorted(impulses), "errors": errors}


def acceptance(rows, analysis, signal, exit_code, video, stall):
    """Require sustained coverage; expected overflow is confined to the actual stall."""
    frames = {}
    receipts = {}
    for row in rows:
        h = row.get("history")
        if not h:
            continue
        for entry in h["frames"]:
            key = (h["instance"], h["epoch"], entry["sequence"])
            frames[key] = json.loads(entry["frame"])
            receipts.setdefault(key, row["receipt"])
    valid = [f for f in frames.values() if f["valid-time"]]
    start = min((f["start"] for f in valid), default=math.inf)
    end = max((f["end"] for f in valid), default=-math.inf)
    expected_impulses = [i for i in range(15)
                         if start <= signal["reference_start"] + 2 * i + 1 < end]
    gaps = analysis["sequence_gaps"]
    localized = all(
        receipts.get((g["instance"], g["epoch"], g["first"] - 1), math.inf) <= 2.2 and
        receipts.get((g["instance"], g["epoch"], g["last"] + 1), -math.inf) >= 15.9
        for g in gaps)
    checks = {
        "probe_succeeded": exit_code == 0,
        "sustained_media_coverage": abs(start - signal["reference_start"]) <= 1 / 48000 + 2e-6 and end - start >= 16,
        "final_receipt_observed": max((r["receipt"] for r in rows), default=0) >= 17.5,
        "sample_oracle_matches": signal["frames_checked"] >= 150 and not signal["errors"],
        "history_valid": analysis["epochs"] == 1 and not (analysis["errors"] or analysis["invalid_time_frames"] or
                              analysis["continuity_breaks"] or
                              any(c["rejected"] for c in analysis["instance_counters"].values())),
        "expected_gap_behavior": bool(gaps) == (stall == 14) and localized,
        "impulses_received": stall == 14 or set(expected_impulses) <= set(signal["impulses_covered"]),
        "output_confirmed": any(r.get("output-confirmed") for r in rows),
        "video_selected": (any((r.get("video-id") or 0) > 0 for r in rows) if video
                           else all(not r.get("video-id") for r in rows)),
    }
    return {"passed": all(checks.values()), "checks": checks,
            "received_media_start": start if math.isfinite(start) else None,
            "received_media_end": end if math.isfinite(end) else None,
            "expected_impulses_in_received_span": expected_impulses,
            "periodic_signal_limits": "Signal repeats every four seconds; matching peaks cannot exclude a whole-period timestamp error."}


def clock_diagnostics(rows):
    values = {"position": [], "audio-pts": []}
    read_spans = []
    for row in rows:
        h = row.get("history")
        if row.get("paused") is not False or row.get("seeking") is not False or not h or not h["frames"]:
            continue
        newest = json.loads(h["frames"][-1]["frame"])
        if not newest["valid-time"]:
            continue
        for name in values:
            clock = row.get(name)
            if type(clock) in (int, float) and math.isfinite(clock):
                values[name].append(newest["start"] - clock)
        if "read-start" in row and "read-end" in row:
            read_spans.append(row["read-end"] - row["read-start"])
    def stats(items):
        ordered = sorted(items)
        return {"count": len(items), "minimum": min(items), "median": ordered[len(items) // 2],
                "maximum": max(items)} if items else {"count": 0}
    return {"newest_frame_start_minus_clock_seconds": {k: stats(v) for k, v in values.items()},
            "property_read_span_seconds": stats(read_spans), "presentation_clock_selected": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, default=ROOT / "Aagedal Media Converter/Binaries/ffmpeg")
    parser.add_argument("--ffprobe", type=Path, required=True, help="Explicit matching timestamp reference tool")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--drivers", nargs="+", choices=["null", "coreaudio", "avfoundation"], default=["null"])
    parser.add_argument("--reanalyze", action="store_true", help="Recheck retained captures without playing media")
    parser.add_argument("--cases", nargs="+", choices=["lossless", "delayed", "aac"], default=["lossless", "delayed", "aac"])
    args = parser.parse_args()
    if args.reanalyze:
        report = json.loads((args.output / "report.json").read_text())
        verify_digest(args.ffmpeg, report["ffmpeg_sha256"])
        verify_digest(args.ffprobe, report["ffprobe_sha256"])
        for name, fixture in report["fixtures"].items():
            verify_digest(args.output / (name + ".mov"), fixture["sha256"])
        references = {name: reference(args.ffmpeg, args.ffprobe, args.output / (name + ".mov"))
                      for name in report["fixtures"]}
        for item in report["runs"]:
            capture = args.output / (item["case"] + ".jsonl.xz")
            if not capture.exists():
                capture = args.output / (item["case"] + ".jsonl.gz")
            verify_digest(capture, item["capture_sha256"])
            opener = lzma.open if capture.suffix == ".xz" else gzip.open
            with opener(capture, "rt") as source:
                rows = [json.loads(line) for line in source if line.strip()]
            name = item["case"].split("-")[0]
            video = "--video" in item["command"]
            stall = 14 if "--stall" in item["command"] else 4 if "--short-stall" in item["command"] else 0
            item["capture_sha256"] = digest(capture)
            item["history"] = HISTORY.analyze(rows)
            item["signal"] = signal_check(rows, *references[name])
            item["clocks"] = clock_diagnostics(rows)
            item["acceptance"] = acceptance(rows, item["history"], item["signal"], item["exit_code"], video, stall)
            item["passed"] = item["acceptance"]["passed"]
        report["analysis_source_sha256"] = digest(ROOT / "scripts/analyze-mpv-meter-history.py")
        report["benchmark_source_sha256"] = digest(Path(__file__))
        (args.output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        for item in report["runs"]:
            print(item["case"], item["acceptance"], flush=True)
        return 0 if all(r["passed"] for r in report["runs"]) else 1
    args.output.mkdir(parents=True, exist_ok=False)
    paths = fixtures(args.ffmpeg, args.output)
    references = {name: reference(args.ffmpeg, args.ffprobe, path) for name, path in paths.items()}
    for name, (start, _) in references.items():
        expected = 0.75 if name == "delayed" else 0
        if abs(start - expected) > 1 / 48000:
            raise ValueError(f"Fixture {name} starts at {start}, expected {expected}")
    report = {"analysis_source_sha256": digest(ROOT / "scripts/analyze-mpv-meter-history.py"),
              "benchmark_source_sha256": digest(Path(__file__)),
              "alignment_qualified": False, "app_integration_tested": False,
              "probe_sha256": digest(args.probe), "probe_source_sha256": digest(ROOT / "scripts/probe-mpv-meter-history.c"),
              "ffmpeg_sha256": digest(args.ffmpeg), "ffprobe_sha256": digest(args.ffprobe),
              "fixtures": {name: {"sha256": digest(path), "reference_start": references[name][0]}
                           for name, path in paths.items()}, "runs": []}
    for driver in args.drivers:
        cases = [(name, video, stall) for name in args.cases for video in (False, True) for stall in (0,)]
        if "lossless" in args.cases:
            cases += [("lossless", False, stall) for stall in (4, 14)]
        for name, video, stall in cases:
            key = f"{name}-{driver}-video{int(video)}-stall{stall}"
            command = [args.probe, paths[name], driver, "--steady"]
            if video:
                command.append("--video")
            if stall:
                command.append("--short-stall" if stall == 4 else "--stall")
            result = subprocess.run([str(c) for c in command], capture_output=True, text=True, timeout=30)
            capture = args.output / (key + ".jsonl.xz")
            with lzma.open(capture, "wt") as target:
                target.write(result.stdout)
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            analysis = HISTORY.analyze(rows)
            signal = signal_check(rows, *references[name])
            expected_loss = stall == 14
            accepted = acceptance(rows, analysis, signal, result.returncode, video, stall)
            passed = accepted["passed"]
            item = {"case": key, "command": [str(c) for c in command], "exit_code": result.returncode,
                    "stderr": result.stderr, "capture_sha256": digest(capture), "passed": passed,
                    "expected_missing_coverage": expected_loss, "acceptance": accepted, "history": analysis, "signal": signal,
                    "clocks": clock_diagnostics(rows)}
            report["runs"].append(item)
            (args.output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
            print(key, "PASS" if passed else "FAIL", flush=True)
    return 0 if all(r["passed"] for r in report["runs"]) else 1


if __name__ == "__main__":
    sys.exit(main())
