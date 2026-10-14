#!/usr/bin/env python3
"""Compare AVM main and av2-enc using a common decoder and reconstructed quality.

Sequential runs avoid encoder contention. Default input is a synthetic motion
pattern; --input accepts footage for a more useful evaluation. Never installs
tools or changes app defaults. Requires the bundled FFmpeg and two AVM builds.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import time

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[1]
spec = spec_from_file_location("av2_validation", ROOT / "scripts/validate-av2-tools.py")
validation = module_from_spec(spec)
spec.loader.exec_module(validation)


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def run(command, log, timeout, input_path=None):
    start = time.monotonic()
    with log.open("wb") as output:
        if input_path:
            with input_path.open("rb") as source:
                subprocess.run(command, stdin=source, stdout=output, stderr=subprocess.STDOUT,
                               check=True, timeout=timeout)
        else:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
    return round(time.monotonic() - start, 3)


def metric_value(log, pattern):
    matches = re.findall(pattern, log.read_text())
    if not matches:
        raise ValueError(f"Missing quality summary in {log}")
    value = float(matches[-1])
    # JSON has no infinity: exact reconstructions are represented explicitly.
    return value if math.isfinite(value) else "infinity"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--frames", type=int, default=12)
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--depth", type=int, choices=(8, 10), default=8)
    parser.add_argument("--qp", type=int, nargs="+", default=[160])
    parser.add_argument("--speed", type=int, default=9)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--variants", nargs="+", choices=("good", "low-complexity", "realtime"),
                        default=["good", "low-complexity", "realtime"])
    args = parser.parse_args()
    if (min(args.width, args.height, args.frames, args.fps, args.threads,
            args.repeats, args.timeout) <= 0 or args.width % 2 or args.height % 2
            or not 0 <= args.speed <= 9 or any(not 0 <= qp <= 255 for qp in args.qp)):
        parser.error("Use positive counts, even dimensions, speed 0–9 and QP 0–255")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Preserve previous evidence and reject concurrent/repeated use of a run directory.
    with (output / "results.json").open("x") as report_file:
        report_file.write('{"status": "preparing"}\n')
    ffmpeg = str(ROOT / "Aagedal Media Converter/Binaries/ffmpeg")
    baseline = args.baseline_dir.resolve()
    candidate = args.candidate_dir.resolve()
    report = {"status": "running", "host": platform.platform(),
              "settings": {key: str(value) if isinstance(value, Path) else value
                           for key, value in vars(args).items()}, "tools": {}, "cases": []}

    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")

    try:
        for label, directory in (("baseline", baseline), ("candidate", candidate)):
            report["tools"][label] = {}
            for name in ("avmenc", "avmdec"):
                tool = directory / name
                log = output / f"{label}-{name}-help.log"
                run([str(tool), "--help"], log, args.timeout)
                report["tools"][label][name] = {"path": str(tool), "sha256": digest(tool),
                    "version": re.findall(r"AOMedia Project AV2[^\n]+", log.read_text())}
        source = output / "reference.y4m"
        inputs = (["-i", str(args.input.resolve())] if args.input else
                  ["-f", "lavfi", "-i", f"testsrc2=size={args.width}x{args.height}:rate={args.fps}"])
        run([ffmpeg, "-y", "-nostdin", "-v", "error", *inputs, "-map", "0:v:0", "-an",
             "-vf", f"scale={args.width}:{args.height},fps={args.fps}",
             "-frames:v", str(args.frames), "-pix_fmt", "yuv420p10le" if args.depth == 10 else "yuv420p",
             "-f", "yuv4mpegpipe", "-strict", "-1", str(source)], output / "generate.log", args.timeout)
        expected = validation.frame_count(source)
        if expected["nb_read_frames"] != args.frames:
            raise ValueError(f"Input shorter than requested: {expected}")
        report["reference"] = {**expected, "sha256": digest(source)}
        save()
        variants = [("main", baseline, [])]
        options = {"good": [], "low-complexity": ["--enable-low-complexity-decode=2"],
                   "realtime": ["--rt"]}
        variants += [(f"av2-enc-{variant}", candidate, options[variant]) for variant in args.variants]
        for qp in args.qp:
            for repeat in range(args.repeats):
                # Alternate order to reduce warm-cache and temperature bias.
                for label, directory, extra in (variants if repeat % 2 == 0 else variants[::-1]):
                    name = f"{label}-qp{qp}-run{repeat + 1}"
                    bitstream = output / f"{name}.ivf"
                    command = [str(directory / "avmenc"), "--ivf", "-w", str(args.width),
                        "-h", str(args.height), "-b", str(args.depth), f"--input-bit-depth={args.depth}",
                        "--i420", f"--fps={args.fps}/1", "--end-usage=q", f"--qp={qp}",
                        f"--cpu-used={args.speed}", "-t", str(args.threads), "--lag-in-frames=0",
                        f"--limit={args.frames}", *extra, "-o", str(bitstream), "-"]
                    print(f"Encoding {name}", flush=True)
                    encode_log = output / f"{name}-encode.log"
                    elapsed = run(command, encode_log, args.timeout, source)
                    if not re.search(r"POC:\s*\d+", encode_log.read_text()):
                        raise ValueError(f"Missing app progress markers: {encode_log}")
                    hashes = []
                    decode_times = {}
                    for decoder_label, decoder_dir in (("main", baseline), ("candidate", candidate)):
                        decoded = output / f"{name}-{decoder_label}.y4m"
                        decode_times[decoder_label] = run([str(decoder_dir / "avmdec"), "-o", str(decoded),
                            str(bitstream)], output / f"{name}-{decoder_label}-decode.log", args.timeout)
                        if validation.frame_count(decoded) != expected:
                            raise ValueError(f"Decoded geometry/depth/frame count changed: {decoded}")
                        hashes.append(digest(decoded))
                    if hashes[0] != hashes[1]:
                        raise ValueError(f"Decoder reconstructions differ: {name}")
                    quality = {}
                    for metric, pattern in (("psnr", r"average:([\d.]+|inf)"),
                                             ("ssim", r"All:([\d.]+)")):
                        log = output / f"{name}-{metric}.log"
                        # Both inputs have identical rate, geometry, depth and frame count.
                        run([ffmpeg, "-nostdin", "-hide_banner", "-i", str(output / f"{name}-main.y4m"),
                             "-i", str(source), "-lavfi", f"[0:v]setpts=PTS-STARTPTS[d];"
                             f"[1:v]setpts=PTS-STARTPTS[r];[d][r]{metric}",
                             "-f", "null", "-"], log, args.timeout)
                        quality[metric] = metric_value(log, pattern)
                    size = bitstream.stat().st_size
                    case = {"name": name, "variant": label, "qp": qp, "command": command,
                            "encodeSeconds": elapsed, "fps": round(args.frames / elapsed, 3),
                            "ivfBytes": size, "kbpsIncludingIVF": round(size * 8 * args.fps / args.frames / 1000, 3),
                            "decodeSeconds": decode_times, "decoderReconstructionsIdentical": True,
                            "decodedSHA256": hashes[0], **quality}
                    report["cases"].append(case)
                    save()
                    print(json.dumps(case), flush=True)
        report["status"] = "complete"
        save()
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        save()
        raise
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        save()
        raise


if __name__ == "__main__":
    main()
