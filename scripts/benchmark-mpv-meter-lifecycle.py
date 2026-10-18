#!/usr/bin/env python3
"""Capture and reanalyze isolated lifecycle/source-replacement observations."""
import argparse
import importlib.util
import json
import lzma
from pathlib import Path
import subprocess


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


BENCHMARK = module("history_benchmark", "benchmark-mpv-meter-history.py")
LIFECYCLE = module("lifecycle_analysis", "analyze-mpv-meter-lifecycle.py")
ROOT = Path(__file__).resolve().parents[1]


def evaluate(rows, references):
    lifecycle = LIFECYCLE.analyze(rows, references["delayed"][0])
    signals = {}
    for generation, name in ((0, "original"), (1, "delayed")):
        selected = [r for r in rows if isinstance(r, dict) and r.get("requested-generation") == generation]
        signals[name] = (BENCHMARK.signal_check(selected, *references[name], signal_version=2)
                         if not lifecycle["history"]["errors"] else
                         {"frames_checked": 0, "errors": ["invalid frame history"]})
    return {"passed": lifecycle["passed"] and all(s["frames_checked"] > 0 and not s["errors"] for s in signals.values()),
            "lifecycle": lifecycle, "signal": signals}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--build-record", required=True, type=Path)
    parser.add_argument("--ffprobe", required=True, type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=ROOT / "Aagedal Media Converter/Binaries/ffmpeg")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--drivers", nargs="+", choices=("null", "coreaudio", "avfoundation"), default=["null"])
    parser.add_argument("--reanalyze", action="store_true")
    args = parser.parse_args()
    for name in ("probe", "build_record", "ffprobe", "ffmpeg", "output"):
        setattr(args, name, getattr(args, name).resolve())
    if not args.reanalyze and args.output.exists():
        parser.error("output must be a new directory")
    build = json.loads(args.build_record.read_text())
    BENCHMARK.verify_digest(args.probe, build["probe_sha256"])
    BENCHMARK.verify_digest(ROOT / "scripts/probe-mpv-meter-history.c", build["probe_source_sha256"])
    if args.reanalyze:
        report = json.loads((args.output / "report.json").read_text())
        for name in ("probe", "ffmpeg", "ffprobe", "build_record"):
            BENCHMARK.verify_digest(getattr(args, name), report[name + "_sha256"])
        paths = {name: args.output / (name + ".mov") for name in report["fixtures"]}
        for name, path in paths.items():
            BENCHMARK.verify_digest(path, report["fixtures"][name]["sha256"])
    else:
        args.output.mkdir(parents=True)
        paths = BENCHMARK.fixtures(args.ffmpeg, args.output)
        report = {name + "_sha256": BENCHMARK.digest(getattr(args, name))
                  for name in ("probe", "ffmpeg", "ffprobe", "build_record")}
        report.update({"fixtures": {name: {"sha256": BENCHMARK.digest(path)} for name, path in paths.items()},
                       "runs": [], "alignment_qualified": False, "app_integration_tested": False})
        for driver in dict.fromkeys(args.drivers):
            for name in ("lossless", "aac"):
                case = name + "-" + driver
                command = [str(args.probe), str(paths[name]), driver, "--video", "--replacement", str(paths["delayed"])]
                result = subprocess.run(command, capture_output=True, text=True, timeout=45)
                capture = args.output / (case + ".jsonl.xz")
                with lzma.open(capture, "wt") as target:
                    target.write(result.stdout)
                report["runs"].append({"case": case, "source": name, "command": command,
                                       "exit_code": result.returncode, "stderr": result.stderr,
                                       "capture_sha256": BENCHMARK.digest(capture)})
    references = {name: BENCHMARK.reference(args.ffmpeg, args.ffprobe, path) for name, path in paths.items()}
    if abs(references["delayed"][0] - 0.75) > 1e-6:
        raise ValueError("replacement fixture must start at 750 ms")
    for run in report["runs"]:
        capture = args.output / (run["case"] + ".jsonl.xz")
        BENCHMARK.verify_digest(capture, run["capture_sha256"])
        with lzma.open(capture, "rt") as source:
            rows = [json.loads(line) for line in source if line.strip()]
        run.update(evaluate(rows, {"original": references[run["source"]], "delayed": references["delayed"]}))
        run["passed"] = run["passed"] and run["exit_code"] == 0
    report.update({"analyzer_sha256": BENCHMARK.digest(ROOT / "scripts/analyze-mpv-meter-lifecycle.py"),
                   "runner_sha256": BENCHMARK.digest(Path(__file__)),
                   "history_analyzer_sha256": BENCHMARK.digest(ROOT / "scripts/analyze-mpv-meter-history.py"),
                   "signal_oracle_sha256": BENCHMARK.digest(ROOT / "scripts/benchmark-mpv-meter-history.py"),
                   "passed": bool(report["runs"]) and all(r["passed"] for r in report["runs"])})
    (args.output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"passed": report["passed"], "runs": len(report["runs"])}))
    if not report["passed"]:
        parser.exit(1, "Lifecycle matrix failed acceptance; see report.\n")


if __name__ == "__main__":
    main()
