#!/usr/bin/env python3
"""Benchmark packaged preview metering serially; retain raw XCTest evidence.

Requires Xcode and resolved project dependencies. Uses muted playback through the
host's actual MPV audio output. Results measure software playhead timing, not
physical speaker latency or SwiftUI rendering cost. Sustained runs (--seconds)
also report CPU per minute and the process thermal state.
"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# The fixture's nine levels (epochs 0-8, two seconds each) repeat every 18 s.
CYCLE_SECONDS = 18
THERMAL_STATES = ["nominal", "fair", "serious", "critical"]


def cpu_per_minute(readings, wall_seconds):
    """One-core CPU percentage per complete minute from cumulative readings."""
    points = [(index * 0.1, item["cpuSeconds"]) for index, item in enumerate(readings)
              if isinstance(item.get("cpuSeconds"), (int, float))]
    if not points or wall_seconds < 120:
        return []
    # Readings are about 100 ms apart; derive each one's time from the run's wall clock.
    step = wall_seconds / max(1, len(readings))
    points = [(index * step, cpu) for index, (_, cpu) in enumerate(points)]
    result = []
    for minute in range(int(wall_seconds // 60)):
        window = [cpu for time, cpu in points if minute * 60 <= time < (minute + 1) * 60]
        if len(window) >= 2:
            result.append(100 * (window[-1] - window[0]) / 60)
    return result


def summarize(runs):
    result = []
    for run in runs:
        transitions = []
        previous = None
        for reading in run["readings"]:
            peak = reading.get("peak")
            if peak is None:
                continue
            epoch = round((-peak - 6) / 1.5)
            if abs(peak - (-6 - 1.5 * epoch)) > 0.35:
                continue
            if previous is not None and epoch > previous and 1 <= epoch <= 8:
                cycle = round((reading["playhead"] - 2 * epoch) / CYCLE_SECONDS)
                source = cycle * CYCLE_SECONDS + 2 * epoch
                transitions.append({"sourceSeconds": source,
                                    "observedPlayhead": reading["playhead"],
                                    "delaySeconds": reading["playhead"] - source})
            previous = epoch
        delays = [entry["delaySeconds"] for entry in transitions]
        ingest = sorted(item["historyIngestSeconds"] for item in run["readings"]
                        if isinstance(item.get("historyIngestSeconds"), (int, float))
                        and math.isfinite(item["historyIngestSeconds"]) and item["historyIngestSeconds"] >= 0)
        thermal = [item["thermalState"] for item in run["readings"]
                   if isinstance(item.get("thermalState"), int) and 0 <= item["thermalState"] < len(THERMAL_STATES)]
        minutes = cpu_per_minute(run["readings"], run["wallSeconds"])
        result.append({key: value for key, value in run.items() if key != "readings"} | {
            "cpuPercentOfOneCore": 100 * (run["hostCPUSeconds"] + run["childCPUSeconds"]) / run["wallSeconds"],
            "readingCount": sum(item.get("peak") is not None for item in run["readings"]),
            "transitions": transitions,
            "medianTransitionDelaySeconds": statistics.median(delays) if delays else None,
            "historyIngestCount": len(ingest),
            "medianHistoryIngestSeconds": statistics.median(ingest) if ingest else None,
            "p95HistoryIngestSeconds": ingest[math.ceil(0.95 * len(ingest)) - 1] if ingest else None,
            "maxHistoryIngestSeconds": max(ingest) if ingest else None,
            "cpuPercentPerMinute": minutes,
            "maxThermalState": THERMAL_STATES[max(thermal)] if thermal else None,
            "readingsAboveNominalThermal": sum(state > 0 for state in thermal),
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--rounds", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--without-building", action="store_true")
    parser.add_argument("--modes", nargs="+", choices=["off", "source", "playback"], default=["off", "source", "playback"])
    parser.add_argument("--seconds", type=int, default=17, help="Playback per run; above 60 uses 1080p H.264 video")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug",
                        help="Release adds ENABLE_TESTABILITY=YES so the test target can import the app")
    parser.add_argument("--workspace", type=Path, help="Workspace with a local MPVKit package override")
    args = parser.parse_args()
    if not 17 <= args.seconds <= 1800:
        parser.error("--seconds must be from 17 to 1800")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    result_bundle = output / "benchmark.xcresult"
    container = (["-workspace", str(args.workspace.resolve())] if args.workspace
                 else ["-project", str(ROOT / "Aagedal Media Converter.xcodeproj")])
    command = ["xcodebuild", "test-without-building" if args.without_building else "test", *container,
               "-scheme", "Aagedal Media Converter Unit Tests", "-configuration", args.configuration,
               "-destination", "platform=macOS", "-derivedDataPath", str(args.derived_data.resolve()),
               "-parallel-testing-enabled", "NO",
               "-only-testing:Aagedal Media ConverterTests/AudioMeterBenchmarkTests",
               "-resultBundlePath", str(result_bundle), "CODE_SIGN_IDENTITY=-"]
    if args.configuration == "Release":
        command.append("ENABLE_TESTABILITY=YES")
    if args.packages:
        command += ["-clonedSourcePackagesDirPath", str(args.packages.resolve()),
                    "-disableAutomaticPackageResolution"]
    environment = os.environ | {"TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK": "1",
                                "TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK_ROUNDS": str(args.rounds),
                                "TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK_MODES": ",".join(args.modes),
                                "TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK_SECONDS": str(args.seconds)}
    with (output / "xcodebuild.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True,
                       timeout=900 + args.rounds * 2 * len(args.modes) * (args.seconds + 60))
    attachments = output / "attachments"
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle),
                    "--output-path", str(attachments)], check=True, timeout=60)
    runs = []
    for path in attachments.rglob("*"):
        if not path.is_file():
            continue
        try:
            value = json.loads(path.read_text())
        except (UnicodeError, ValueError):
            continue
        if isinstance(value, list) and value and isinstance(value[0], dict) and "hostCPUSeconds" in value[0]:
            runs.extend(value)
    expected = args.rounds * 2 * len(args.modes)
    if len(runs) != expected:
        raise RuntimeError(f"Expected {expected} benchmark runs; found {len(runs)}. Inspect {output / 'xcodebuild.log'}")
    summaries = summarize(runs)
    for run in summaries:
        if run["mode"] != "off" and len({edge["sourceSeconds"] for edge in run["transitions"]}) < 5:
            raise RuntimeError(f"Insufficient signal transitions in {run['fixture']} / {run['mode']}")
    report = {"platform": platform.platform(), "architecture": platform.machine(),
              "configuration": f"{args.configuration}, ad hoc signed; serial muted MPV playback",
              "rounds": args.rounds, "secondsPerRun": args.seconds,
              "thermal": "ProcessInfo.thermalState sampled with every reading; no sensor temperatures or fan speeds",
              "timing": "Observed level-change playhead minus known source edge; negative means readings lead playback. Includes 100 ms measurement and polling granularity.",
              "cpu": "Host plus reaped FFmpeg child user/system CPU; 100 percent means one core. Includes cold meter setup and source lookahead, excludes fixture generation and file load.",
              "limitations": ["No physical device latency measurement", "Thermal state is the OS summary level, not temperature", "No SwiftUI view rendering cost", "Short generated local clips; filesystem/decoder caches may be warm", "Source uses fresh analysis cache each run; sourceWindows counts window changes, not subprocesses"],
              "runs": summaries}
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(output / "report.json")


if __name__ == "__main__":
    main()
