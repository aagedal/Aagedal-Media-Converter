#!/usr/bin/env python3
"""Prepare the verified CoreAudio candidate as an MPVKit-GPL release asset.

MPVKit's isolated BuildMPV recipe enables GPL features but names its archive
Libmpv.xcframework.zip. The published GPL target expects the same internal
Libmpv.xcframework layout under the Libmpv-GPL.xcframework.zip asset name.
This prepares that asset without publishing or changing the application pin.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil


SCRIPT = Path(__file__).with_name("verify-mpv-candidate.py")
SPEC = importlib.util.spec_from_file_location("verify_mpv_candidate", SCRIPT)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def require_gpl_build(candidate):
    """Check the actual Meson configurations, not only the launcher arguments."""
    values = {}
    for arch in sorted(VERIFIER.ARCHITECTURES):
        path = candidate / "dist/libmpv/macos/scratch" / arch / "meson-info/intro-buildoptions.json"
        options = json.loads(path.read_text())
        gpl = [option.get("value") for option in options if option.get("name") == "gpl"]
        if gpl != [True]:
            raise ValueError(f"{arch} libmpv was not configured with GPL enabled")
        values[arch] = True
    return values


def prepare(candidate, evidence, output):
    candidate = candidate.resolve()
    if output.exists():
        raise ValueError("Output directory already exists")
    audit = VERIFIER.verify(candidate, json.loads(evidence.read_text()))
    gpl = require_gpl_build(candidate)
    output.mkdir(parents=True)
    source = candidate / VERIFIER.ARCHIVE
    asset = output / "Libmpv-GPL.xcframework.zip"
    shutil.copyfile(source, asset)
    with asset.open("rb") as stream:
        checksum = VERIFIER.digest(stream)
    with source.open("rb") as stream:
        source_checksum = VERIFIER.digest(stream)
    if checksum != source_checksum:
        raise ValueError("Prepared asset differs from verified candidate")
    result = {
        "status": "prepared_for_publication",
        "release_ready": False,
        "asset": asset.name,
        "sha256": checksum,
        "swiftpm_checksum": checksum,
        "meson_gpl": gpl,
        "candidate_audit": audit,
        "next_steps": [
            "Publish asset under a new versioned MPVKit release",
            "Update MPVKit's Libmpv-GPL URL and checksum and pin the app to its new revision",
            "Complete provenance, release-bundle, and affected-macOS CoreAudio validation",
        ],
    }
    (output / "release-preparation.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.candidate, args.evidence, args.output)
    except (ValueError, OSError, KeyError, RuntimeError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
