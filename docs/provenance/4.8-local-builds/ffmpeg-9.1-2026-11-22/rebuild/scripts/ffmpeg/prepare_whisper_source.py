#!/usr/bin/env python3
"""Apply/check the bounded af_whisper.c corrections against the attributed source."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ORIGINAL_SHA256 = "ebf55032923ab03d9d2e40c2604198883c3957fe18e089b9157d85105e747dea"
# Applied in order; each entry is the patch and the source hash it produces.
# A tree already carrying a prefix of the chain (an earlier Photo Agent build)
# receives only the remaining patches.
PATCHES = [
    (Path(__file__).with_name("af_whisper-canonical-json.patch"),
     "ffa3c2bc212623c44e3b97dbcba7bdd50bd266ae6ffef5c40845f6be4cdd7711"),
    (Path(__file__).with_name("af_whisper-word-details.patch"),
     "426d77efd5678d610d095b9f7552a097a39c7798367b4bbfdb0dcb2fe6d15ee4"),
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
