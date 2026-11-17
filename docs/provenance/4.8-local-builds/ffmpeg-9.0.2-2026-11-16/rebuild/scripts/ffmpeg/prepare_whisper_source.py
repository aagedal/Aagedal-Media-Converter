#!/usr/bin/env python3
"""Apply/check the bounded af_whisper.c corrections against the attributed source."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ORIGINAL_SHA256 = "322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6"
# Applied in order; each entry is the patch and the source hash it produces.
# A tree already carrying a prefix of the chain (an earlier Photo Agent build)
# receives only the remaining patches.
PATCHES = [
    (Path(__file__).with_name("af_whisper-canonical-json.patch"),
     "eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71"),
    (Path(__file__).with_name("af_whisper-word-details.patch"),
     "d27e7b5c3c110f599b5d43c16752aec832ad858bc601096fe4db5e7de0362615"),
]
PATCHED_SHA256 = PATCHES[-1][1]


def patched_source(source: Path) -> bytes:
    original = source.read_bytes()
    actual = hashlib.sha256(original).hexdigest()
    chain = [ORIGINAL_SHA256] + [expected for _, expected in PATCHES]
    if actual not in chain:
        raise ValueError(f"source SHA-256 mismatch: expected one of {chain}, got {actual}")
    # Patch only an isolated copy, never the supplied source/archive/build tree.
    with tempfile.TemporaryDirectory(prefix="whisper-patch-") as directory:
        root = Path(directory)
        target = root / "libavfilter/af_whisper.c"
        target.parent.mkdir()
        target.write_bytes(original)
        for patch, expected in PATCHES[chain.index(actual):]:
            subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch.resolve())],
                           cwd=root, check=True, capture_output=True)
            result = hashlib.sha256(target.read_bytes()).hexdigest()
            if result != expected:
                raise ValueError(f"{patch.name} produced SHA-256 {result}, expected {expected}")
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
