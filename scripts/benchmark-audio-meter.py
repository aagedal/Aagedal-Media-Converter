#!/usr/bin/env python3
"""Benchmark packaged preview metering serially; retain raw XCTest evidence.

Requires Xcode and resolved project dependencies. Uses muted playback through the
host's actual MPV audio output. Results measure software playhead timing, not
physical speaker latency, thermal behavior, or SwiftUI rendering cost.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]


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
                transitions.append({"sourceSeconds": 2 * epoch,
                                    "observedPlayhead": reading["playhead"],
                                    "delaySeconds": reading["playhead"] - 2 * epoch})
            previous = epoch
        delays = [entry["delaySeconds"] for entry in transitions]
        result.append({key: value for key, value in run.items() if key != "readings"} | {
            "cpuPercentOfOneCore": 100 * (run["hostCPUSeconds"] + run["childCPUSeconds"]) / run["wallSeconds"],
            "readingCount": sum(item.get("peak") is not None for item in run["readings"]),
            "transitions": transitions,
            "medianTransitionDelaySeconds": statistics.median(delays) if delays else None,
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--rounds", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--without-building", action="store_true")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    result_bundle = output / "benchmark.xcresult"
    command = ["xcodebuild", "test-without-building" if args.without_building else "test",
               "-project", str(ROOT / "Aagedal Media Converter.xcodeproj"),
               "-scheme", "Aagedal Media Converter Unit Tests", "-configuration", "Debug",
               "-destination", "platform=macOS", "-derivedDataPath", str(args.derived_data.resolve()),
               "-parallel-testing-enabled", "NO",
               "-only-testing:Aagedal Media ConverterTests/AudioMeterBenchmarkTests",
               "-resultBundlePath", str(result_bundle), "CODE_SIGN_IDENTITY=-"]
    if args.packages:
        command += ["-clonedSourcePackagesDirPath", str(args.packages.resolve()),
                    "-disableAutomaticPackageResolution"]
    environment = os.environ | {"TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK": "1",
                                "TEST_RUNNER_AMC_AUDIO_METER_BENCHMARK_ROUNDS": str(args.rounds)}
    with (output / "xcodebuild.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=900 + args.rounds * 150)
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
    expected = args.rounds * 2 * 3
    if len(runs) != expected:
        raise RuntimeError(f"Expected {expected} benchmark runs; found {len(runs)}. Inspect {output / 'xcodebuild.log'}")
    summaries = summarize(runs)
    for run in summaries:
        if run["mode"] != "off" and len({edge["sourceSeconds"] for edge in run["transitions"]}) < 5:
            raise RuntimeError(f"Insufficient signal transitions in {run['fixture']} / {run['mode']}")
    report = {"platform": platform.platform(), "architecture": platform.machine(),
              "configuration": "Debug, ad hoc signed; serial muted MPV playback",
              "rounds": args.rounds,
              "timing": "Observed level-change playhead minus known source edge; negative means readings lead playback. Includes 100 ms measurement and polling granularity.",
              "cpu": "Host plus reaped FFmpeg child user/system CPU; 100 percent means one core. Includes cold meter setup and source lookahead, excludes fixture generation and file load.",
              "limitations": ["No physical device latency or thermal measurement", "No SwiftUI view rendering cost", "Short generated local clips; filesystem/decoder caches may be warm", "Source uses fresh analysis cache each run; sourceWindows counts window changes, not subprocesses"],
              "runs": summaries}
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(output / "report.json")


if __name__ == "__main__":
    main()
