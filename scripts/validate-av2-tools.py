#!/usr/bin/env python3
"""Encode/decode smoke checks and a small repeatable benchmark for bundled AVM.

Uses generated media and compiles the app's actual container helpers. Requires
macOS, Swift, and the bundled FFmpeg. Outputs logs and JSON in --output-dir.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, log, input_data=None):
    start = time.monotonic()
    with log.open("wb") as output:
        subprocess.run([str(a) for a in arguments], input=input_data,
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=300)
    return round(time.monotonic() - start, 3)


def frame_count(path):
    # Skip exact frame payload lengths; binary pixels may contain FRAME markers.
    with path.open("rb") as stream:
        header = stream.readline()
        assert header.startswith(b"YUV4MPEG2 "), header
        width = int(re.search(rb" W(\d+)", header)[1])
        height = int(re.search(rb" H(\d+)", header)[1])
        chroma = re.search(rb" C(\S+)", header)[1]
        assert chroma.startswith(b"420"), chroma
        depth = 10 if b"p10" in chroma else 8
        size = width * height * 3 // 2 * (2 if depth == 10 else 1)
        count = 0
        while marker := stream.readline():
            assert marker.startswith(b"FRAME") and marker.endswith(b"\n"), marker
            assert len(stream.read(size)) == size, "Truncated decoded frame"
            count += 1
        return {"nb_read_frames": count, "width": width, "height": height,
                "pix_fmt": "yuv420p10le" if depth == 10 else "yuv420p"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--baseline-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ffmpeg = ROOT / "Aagedal Media Converter/Binaries/ffmpeg"
    encoder = args.tools_dir.resolve() / "avmenc"
    decoder = args.tools_dir.resolve() / "avmdec"
    report = {"encoder": str(encoder), "cases": []}

    def encode(name, depth, mode="q", tool=encoder, extra=(), source=None, frames=12):
        source = source or output / f"input{depth}.y4m"
        arguments = [tool, "--ivf", "-w", "128", "-h", "96", "-b", str(depth),
                     f"--input-bit-depth={depth}", "--i420", "--fps=24/1",
                     f"--end-usage={mode}", "--qp=160" if mode == "q" else "--target-bitrate=100",
                     "--cpu-used=9", "-t", "2", "--lag-in-frames=0", f"--limit={frames}",
                     *extra, "-o", output / f"{name}.ivf", "-"]
        elapsed = run(arguments, output / f"{name}-encode.log", source.read_bytes())
        assert re.search(r"POC:\s*\d+", (output / f"{name}-encode.log").read_text()), "Progress output changed"
        return elapsed

    def decode(name, input_path, depth, frames=12, tool=decoder):
        y4m = output / f"{name}-decoded.y4m"
        run([tool, "-o", y4m, input_path], output / f"{name}-decode.log")
        info = frame_count(y4m)
        assert int(info["nb_read_frames"]) == frames, info
        assert (info["width"], info["height"]) == (128, 96), info
        assert info["pix_fmt"] == ("yuv420p10le" if depth == 10 else "yuv420p"), info
        return hashlib.sha256(y4m.read_bytes()).hexdigest()

    for depth in (8, 10):
        run([ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=24",
             "-frames:v", "12", "-pix_fmt", "yuv420p10le" if depth == 10 else "yuv420p",
             "-f", "yuv4mpegpipe", "-strict", "-1", output / f"input{depth}.y4m"],
            output / f"generate{depth}.log")
        for mode in ("q", "vbr"):
            name = f"new-{depth}-{mode}"
            elapsed = encode(name, depth, mode)
            decode(name, output / f"{name}.ivf", depth)
            report["cases"].append({"name": name, "seconds": elapsed,
                                    "bytes": (output / f"{name}.ivf").stat().st_size})
        if args.baseline_dir:
            baseline = args.baseline_dir.resolve()
            name = f"old-{depth}"
            elapsed = encode(name, depth, tool=baseline / "avmenc")
            expected = decode(name + "-old-decoder", output / f"{name}.ivf", depth, tool=baseline / "avmdec")
            actual = decode(name + "-new-decoder", output / f"{name}.ivf", depth)
            assert expected == actual, "Backward decoding changed reconstructed pixels"
            report["cases"].append({"name": name, "seconds": elapsed,
                                    "backwardDecodeIdentical": True})

    encode("lagged", 8, extra=("--lag-in-frames=19",))
    decode("lagged", output / "lagged.ivf", 8)
    for index in range(2):
        source = output / f"segment{index}.y4m"
        run([ffmpeg, "-y", "-v", "error", "-i", output / "input8.y4m", "-vf",
             f"trim=start_frame={index * 6}:end_frame={(index + 1) * 6},setpts=PTS-STARTPTS",
             "-f", "yuv4mpegpipe", source], output / f"segment{index}-generate.log")
        encode(f"segment{index}", 8, source=source, frames=6)
    run([encoder, "--webm", "-w", "128", "-h", "96", "-b", "8", "--input-bit-depth=8",
         "--i420", "--fps=24/1", "--end-usage=q", "--qp=110", "--cpu-used=9", "--limit=1",
         "-o", output / "probe.webm", output / "input8.y4m"], output / "webm-probe.log")
    # Verify the layout contract used by FFMPEGConverter.extractMatroskaCodecPrivate.
    data = (output / "probe.webm").read_bytes()
    start = data.index(b"V_AV2") + 5
    offset = data.index(b"\x63\xa2", start, start + 16) + 2
    first = data[offset]
    length = 1
    marker = 128
    while not first & marker:
        marker >>= 1
        length += 1
        assert marker, "Invalid CodecPrivate size"
    size = int.from_bytes(data[offset:offset + length], "big") & ((1 << (length * 7)) - 1)
    assert 0 < size < 256
    (output / "codec-private.bin").write_bytes(data[offset + length:offset + length + size])
    run([ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
         "-t", "0.5", "-c:a", "aac", "-f", "adts", output / "audio.aac"], output / "audio-generate.log")
    sources = ROOT / "Aagedal Media Converter/Logic/Conversion"
    driver = output / "container-smoke"
    run(["swiftc", "-module-cache-path", output / "swift-cache", "-o", driver,
         ROOT / "scripts/av2-container-smoke.swift",
         *[sources / f"{name}.swift" for name in ("IVFHeaderParser", "IVFConcatenator", "MatroskaMuxer", "AV2AACParser")]],
        output / "swift-build.log")
    run([driver, output], output / "container-smoke.log")
    decode("joined-ivf", output / "joined.ivf", 8)
    decode("joined-mkv", output / "joined.mkv", 8)
    run([ffmpeg, "-v", "error", "-i", output / "joined.mkv", "-map", "0:a:0",
         "-f", "null", "-"], output / "mkv-audio-decode.log")
    report["containerChecks"] = ["lagged IVF decode", "chunk concatenation", "CodecPrivate probe", "Matroska video decode", "AAC audio decode"]
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
