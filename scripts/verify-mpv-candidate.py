#!/usr/bin/env python3
"""Verify retained MPV candidate hashes and archive/framework correspondence.

This read-only audit does not establish signing, source provenance, or runtime safety.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import zipfile

ARCHITECTURES = {"arm64", "x86_64"}
FRAMEWORK = "dist/libmpv/macos/Libmpv.framework/Versions/A/Libmpv"
ARCHIVE = "dist/release/Libmpv.xcframework.zip"
STATIC_ARCHIVE = "dist/release/libmpv-all.zip"
PREFIX = "Libmpv.xcframework/"


def digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()


def contained(root, name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Unsafe candidate path: {name}")
    result = (root / path).resolve()
    if not result.is_relative_to(root.resolve()):
        raise ValueError(f"Candidate path escapes staging directory: {name}")
    return result


def verify(root, evidence, architecture_reader=None):
    if evidence.get("status") != "build_succeeded" or evidence.get("exit_code") != 0:
        raise ValueError("Evidence does not describe a successful build")
    rows = evidence.get("candidate_archives", []) + evidence.get("candidate_binaries", [])
    expected = {}
    for row in rows:
        name = row["path"]
        if name in expected:
            raise ValueError(f"Duplicate evidence path: {name}")
        expected[name] = row["sha256"]
        with contained(root, name).open("rb") as stream:
            if digest(stream) != row["sha256"]:
                raise ValueError(f"Candidate hash mismatch: {name}")
    required = {FRAMEWORK, ARCHIVE, STATIC_ARCHIVE} | {
        f"dist/libmpv/macos/thin/{arch}/lib/libmpv.a" for arch in ARCHITECTURES
    }
    if not required.issubset(expected):
        raise ValueError("Evidence is missing required candidate artifacts")
    if architecture_reader is None:
        architecture_reader = lambda path: subprocess.check_output(
            ["lipo", "-archs", str(path)], text=True).split()
    if set(architecture_reader(contained(root, FRAMEWORK))) != ARCHITECTURES:
        raise ValueError("Framework must contain exactly arm64 and x86_64")
    for archive in (ARCHIVE, STATIC_ARCHIVE):
        with zipfile.ZipFile(contained(root, archive)) as bundle:
            names = bundle.namelist()
            if len(names) != len(set(names)):
                raise ValueError(f"Duplicate ZIP members: {archive}")
            if archive == ARCHIVE:
                info = plistlib.loads(bundle.read(PREFIX + "Info.plist"))
                libraries = info.get("AvailableLibraries", [])
                if len(libraries) != 1:
                    raise ValueError("Expected one macOS XCFramework slice")
                library = libraries[0]
                if (library.get("SupportedPlatform") != "macos"
                        or library.get("SupportedPlatformVariant") is not None
                        or set(library.get("SupportedArchitectures", [])) != ARCHITECTURES):
                    raise ValueError("Unexpected XCFramework platform or architectures")
                member = PREFIX + library["LibraryIdentifier"] + "/" + library["BinaryPath"]
                comparisons = {member: FRAMEWORK}
            else:
                comparisons = {f"lib/macos/thin/{arch}/lib/libmpv.a":
                    f"dist/libmpv/macos/thin/{arch}/lib/libmpv.a" for arch in ARCHITECTURES}
            for member, candidate in comparisons.items():
                with bundle.open(member) as stream:
                    if digest(stream) != expected[candidate]:
                        raise ValueError(f"Archive binary differs from candidate: {member}")
    return {"status": "verified", "artifact_count": len(expected),
            "framework_architectures": sorted(ARCHITECTURES),
            "archive_binary_correspondence": True, "release_ready": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.candidate, json.loads(args.evidence.read_text()))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException,
            subprocess.CalledProcessError) as error:
        parser.exit(1, f"Candidate verification failed: {error}\n")
    text = json.dumps(result, indent=2) + "\n"
    if args.report:
        args.report.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
