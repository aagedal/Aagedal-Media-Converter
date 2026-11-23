#!/usr/bin/env python3
"""Check that the MOV muxer writes fiel for H.264 and the MP4 muxer does not.

Encodes 1 s top-first, bottom-first and progressive H.264 with libx264 as raw
Annex B, so the field order comes from the bitstream, plus top-first AVC-Intra
100 in MXF like a Panasonic P2 clip. Stream copies each to .mov (and .mp4 for
the raw streams) and reads the H.264 sample entry's child atoms.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

INTERLACED = ["-flags", "+ilme+ildct"]
# name: (source, filters, x264 params, ffmpeg flags, targets, sample entry,
#        MOV fiel, ffprobe field_order)
CASES = {
    "tff": ("h264", "setfield=tff", "tff=1", INTERLACED, ("mov", "mp4"),
            "avc1", 0x0201, "tt"),
    "bff": ("h264", "setfield=bff", "bff=1", INTERLACED, ("mov", "mp4"),
            "avc1", 0x0206, "bb"),
    "progressive": ("h264", "setfield=prog", "", [], ("mov", "mp4"),
                    "avc1", 0x0100, "progressive"),
    "avci100-tff": ("mxf", "setfield=tff,format=yuv422p10le",
                    "avcintra-class=100:interlaced=1:tff=1", INTERLACED, ("mov",),
                    "ai15", 0x0201, "tt"),
}
CONTAINERS = ["moov", "trak", "mdia", "minf", "stbl"]


def check(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}{result.stderr}")
    return result.stdout


def atoms(data, start, end):
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start:start + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[start + 8:start + 16])[0]
            header = 16
        elif size == 0:
            size = end - start
        if size < header or start + size > end:
            raise ValueError(f"Malformed atom {kind!r} at {start}")
        yield kind.decode("latin-1"), start + header, start + size
        start += size


def child(data, start, end, name):
    for kind, body, stop in atoms(data, start, end):
        if kind == name:
            return body, stop
    raise ValueError(f"Missing {name} atom")


def sample_entry(path):
    """Return the first video track's sample entry fourcc and {fourcc: payload}."""
    data = path.read_bytes()
    start, end = 0, len(data)
    for name in CONTAINERS:
        if name == "trak":
            for kind, body, stop in atoms(data, start, end):
                if kind == "trak" and b"vide" in data[body:stop]:
                    start, end = body, stop
                    break
            else:
                raise ValueError("Missing video trak")
        else:
            start, end = child(data, start, end, name)
    start, end = child(data, start, end, "stsd")
    kind, body, stop = next(atoms(data, start + 8, end))  # skip version/flags and count
    # VisualSampleEntry fields occupy 78 bytes before the child atoms.
    return kind, {name: data[b:s] for name, b, s in atoms(data, body + 78, stop)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path)
    args = parser.parse_args()
    ffprobe = args.ffprobe or args.ffmpeg.with_name("ffprobe")
    failures = []
    with tempfile.TemporaryDirectory(prefix="movenc-fiel-") as directory:
        work = Path(directory)
        for name, (container, filters, params, flags, targets, entry, expected,
                   order) in CASES.items():
            source = work / f"{name}.{container}"
            x264 = ["-x264-params", params] if params else []
            check([str(args.ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                   "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=25", "-vf", filters,
                   "-c:v", "libx264", *flags, *x264, "-t", "1", str(source)])
            for extension in targets:
                target = work / f"{name}.{extension}"
                check([str(args.ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                       "-i", str(source), "-c", "copy", str(target)])
                kind, children = sample_entry(target)
                fiel = children.get("fiel")
                if extension == "mp4":
                    if fiel is not None:
                        failures.append(f"{name}.mp4: unexpected fiel {fiel.hex()}")
                    else:
                        print(f"PASS: {name}.mp4 has no fiel")
                    continue
                if kind != entry:
                    failures.append(f"{name}.mov: sample entry {kind}, expected {entry}")
                    continue
                if fiel is None or len(fiel) != 2 or int.from_bytes(fiel, "big") != expected:
                    got = "none" if fiel is None else fiel.hex()
                    failures.append(f"{name}.mov: fiel {got}, expected {expected:04x}")
                    continue
                probe = json.loads(check([str(ffprobe), "-v", "error", "-select_streams", "v:0",
                                          "-show_entries", "stream=field_order", "-of", "json",
                                          str(target)]))
                reported = probe["streams"][0].get("field_order")
                if reported != order:
                    failures.append(f"{name}.mov: ffprobe field_order {reported}, expected {order}")
                    continue
                print(f"PASS: {name}.mov {kind} fiel {expected:04x}, ffprobe field_order {reported}")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
