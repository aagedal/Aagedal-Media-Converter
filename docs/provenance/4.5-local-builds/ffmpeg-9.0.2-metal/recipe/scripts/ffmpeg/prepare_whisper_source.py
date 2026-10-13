#!/usr/bin/env python3
"""Apply/check the bounded af_whisper.c correction against the attributed source."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ORIGINAL_SHA256 = "322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6"
PATCH = Path(__file__).with_name("af_whisper-canonical-json.patch")


def patched_source(source: Path) -> bytes:
    original = source.read_bytes()
    actual = hashlib.sha256(original).hexdigest()
    if actual != ORIGINAL_SHA256:
        raise ValueError(f"source SHA-256 mismatch: expected {ORIGINAL_SHA256}, got {actual}")
    # Patch only an isolated copy, never the supplied source/archive/build tree.
    with tempfile.TemporaryDirectory(prefix="whisper-patch-") as directory:
        root = Path(directory)
        target = root / "libavfilter/af_whisper.c"
        target.parent.mkdir()
        target.write_bytes(original)
        subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(PATCH.resolve())],
                       cwd=root, check=True, capture_output=True)
        return target.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="original attributed libavfilter/af_whisper.c")
    parser.add_argument("--output", type=Path, help="new output file (must not exist); omit to verify only")
    args = parser.parse_args()
    try:
        result = patched_source(args.source)
        if args.output:
            with args.output.open("xb") as output:
                output.write(result)
        print(f"Verified patch; patched source SHA-256: {hashlib.sha256(result).hexdigest()}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot prepare Whisper source: {error}\n")


if __name__ == "__main__":
    main()
