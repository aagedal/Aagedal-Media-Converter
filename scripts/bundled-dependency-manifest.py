#!/usr/bin/env python3
"""Generate or verify the checked-in bundled dependency manifest.

The manifest deliberately records unresolved license attribution instead of
guessing.  That makes the remaining release work machine-readable while still
giving every shipped Mach-O a stable checksum, architecture, size, and install
name/dependency inventory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
APP_ROOT = REPOSITORY_ROOT / "Aagedal Media Converter"
MANIFEST_PATH = REPOSITORY_ROOT / "BundledDependencies.json"

TOOL_METADATA: dict[str, dict[str, Any]] = {
    "asdcp-wrap": {
        "component": "asdcplib",
        "license": "BSD-3-Clause",
        "licenseFile": "Licenses/asdcplib-LICENSE.txt",
        "versionArguments": ["-V"],
        "versionPattern": r"asdcp-wrap \(asdcplib ([^)]+)\)",
    },
    "avmdec": {
        "component": "Alliance for Open Media reference tools",
        "license": "BSD-3-Clause-Clear",
        "licenseFile": "Licenses/avm-LICENSE.txt",
        "requiredSourceComponents": ["AVM Eigen"],
    },
    "avmenc": {
        "component": "Alliance for Open Media reference tools",
        "license": "BSD-3-Clause-Clear",
        "licenseFile": "Licenses/avm-LICENSE.txt",
        "requiredSourceComponents": ["AVM Eigen"],
    },
    "bmxparse": {
        "component": "BBC BMX",
        "license": "BSD-3-Clause",
        "licenseFile": "Licenses/bmx-LICENSE.txt",
        "versionArguments": ["--version"],
        "versionPattern": r"bmx v([^,]+)",
    },
    "bmxtranswrap": {
        "component": "BBC BMX",
        "license": "BSD-3-Clause",
        "licenseFile": "Licenses/bmx-LICENSE.txt",
        "versionArguments": ["--version"],
        "versionPattern": r"bmx v([^,]+)",
    },
    "ffmpeg": {
        "component": "FFmpeg",
        "license": "GPL-3.0-or-later",
        "licenseFile": "Licenses/ffmpeg-LICENSE.txt",
        "requiredSourceComponents": ["FFmpeg 9.0.1 build", "FFmpeg generated inputs"],
        "versionArguments": ["-version"],
        "versionPattern": r"ffmpeg version ([^ ]+)",
    },
    "mxf2raw": {
        "component": "BBC BMX",
        "license": "BSD-3-Clause",
        "licenseFile": "Licenses/bmx-LICENSE.txt",
        "versionArguments": ["--version"],
        "versionPattern": r"bmx v([^,]+)",
    },
    "raw2bmx": {
        "component": "BBC BMX",
        "license": "BSD-3-Clause",
        "licenseFile": "Licenses/bmx-LICENSE.txt",
        "versionArguments": ["--version"],
        "versionPattern": r"bmx v([^,]+)",
    },
    "rclone": {
        "component": "rclone",
        "license": "MIT AND LGPL-3.0-only AND MPL-2.0",
        "licenseFile": "Licenses/rclone-LICENSE.txt",
        "requiredSourceComponents": ["rclone"],
        "versionArguments": ["version"],
        "versionPattern": r"rclone (v[^\s]+)",
    },
    "tesseract": {
        "component": "Tesseract OCR",
        "license": "Apache-2.0",
        "licenseFile": "Licenses/tesseract-LICENSE.txt",
        "versionArguments": ["--version"],
        "versionPattern": r"tesseract ([^\s]+)",
    },
}


def command_output(arguments: list[str], *, environment: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        arguments,
        cwd=REPOSITORY_ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        diagnostic = result.stdout.strip().splitlines()[-1:] or ["no diagnostic output"]
        raise RuntimeError(
            f"{' '.join(arguments)} exited {result.returncode}: {diagnostic[0]}"
        )
    return result.stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def license_inventory() -> list[dict[str, Any]]:
    """Track notice contents as well as binaries, including unassigned notices."""
    entries = []
    for path in [REPOSITORY_ROOT / "LICENSE", *sorted((REPOSITORY_ROOT / "Licenses").glob("*-LICENSE.txt"))]:
        if not path.resolve().is_relative_to(REPOSITORY_ROOT.resolve()):
            raise RuntimeError(f"License file escapes the repository: {path}")
        if not path.read_text(encoding="utf-8").strip():
            raise RuntimeError(f"License file is empty: {path}")
        entries.append({
            "path": path.relative_to(REPOSITORY_ROOT).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        })
    return entries


def require_complete_licenses(manifest: dict[str, Any]) -> None:
    notices = {entry["path"] for entry in manifest["licenseFiles"]}
    unresolved = sorted(
        entry["path"] for entry in [*manifest["tools"], *manifest["libraries"], *manifest.get("packages", [])]
        if not entry.get("license") or entry["license"] == "NOASSERTION"
        or entry.get("licenseFile") not in notices
    )
    problems = []
    if unresolved:
        problems.append(
            f"License attribution is incomplete for {len(unresolved)} dependencies:\n  "
            + "\n  ".join(unresolved)
        )
    for entry in [*manifest["tools"], *manifest["libraries"], *manifest.get("packages", [])]:
        if entry.get("pendingAttribution"):
            problems.append(
                f"{entry['path']}: attribution review remains incomplete:\n  "
                + "\n  ".join(entry["pendingAttribution"])
            )
    for entry in manifest["tools"]:
        reported = entry.get("reportedLicense")
        if reported is None:
            continue
        if reported != entry.get("license"):
            problems.append(f"{entry['path']}: binary reports {reported}, manifest declares {entry.get('license')}")
        notice = entry.get("licenseFile")
        if notice in notices and reported.startswith("GPL-"):
            version = reported.split("-")[1].split(".")[0]
            content = (REPOSITORY_ROOT / notice).read_text(encoding="utf-8")
            if not re.search(rf"GNU GENERAL PUBLIC LICENSE\s+Version {version},", content):
                problems.append(f"{entry['path']}: notice {notice} does not contain the reported GPL version {version} text")
    required_sources = {
        component for entry in [*manifest["tools"], *manifest["libraries"], *manifest.get("packages", [])]
        for component in entry.get("requiredSourceComponents", [])
    }
    recorded_sources = {entry["component"] for entry in manifest.get("sourceArchives", [])}
    if required_sources - recorded_sources:
        problems.append("Missing required source material: " + ", ".join(sorted(required_sources - recorded_sources)))
    if manifest.get("sourceArchives"):
        try:
            verifier = runpy.run_path(str(REPOSITORY_ROOT / "scripts/package-attribution-sources.py"))["verify_sources"]
            verifier(REPOSITORY_ROOT, {"archives": manifest["sourceArchives"]})
        except (OSError, ValueError, KeyError) as error:
            problems.append(str(error))
    if problems:
        raise RuntimeError("\n".join(problems) + "\nSee docs/bundled-dependency-licenses.md before publishing.")


def package_inventory() -> list[dict[str, Any]]:
    """Bind reviewed package attribution to exactly the checked-in source pins."""
    records = json.loads((REPOSITORY_ROOT / "PackageAttributions.json").read_text())["packages"]
    resolved = REPOSITORY_ROOT / "Aagedal Media Converter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = {pin["identity"]: pin for pin in json.loads(resolved.read_text())["pins"]}
    if len(records) != len(pins) or {entry["identity"] for entry in records} != pins.keys():
        raise RuntimeError("Swift package attribution does not cover the resolved package set")
    for entry in records:
        pin = pins[entry["identity"]]
        if entry["revision"] != pin["state"]["revision"] or entry["sourceURL"] != pin["location"]:
            raise RuntimeError(f"Swift package attribution is stale: {entry['identity']}")
    return records


def ffmpeg_reported_license(path: Path) -> str:
    """Record the executable's own license, independently of reviewed attribution."""
    output = command_output([str(path), "-L"])
    match = re.search(r"GNU (Lesser )?General Public License.*?version (\d+)(?:\.\d+)? of the License.*?any later version", output, re.DOTALL)
    if not match:
        raise RuntimeError(f"Unable to identify reported FFmpeg license: {path}")
    family = "LGPL" if match.group(1) else "GPL"
    # LGPL FFmpeg builds use version 2.1, while GPL builds use integer versions.
    version = re.search(r"version (\d+(?:\.\d+)?) of the License", match.group(0)).group(1)
    if "." not in version:
        version += ".0"
    return f"{family}-{version}-or-later"


def architectures(path: Path) -> list[str]:
    output = command_output(["/usr/bin/lipo", "-archs", str(path)]).strip()
    return output.split() if output else []


def linked_libraries(path: Path) -> list[str]:
    lines = command_output(["/usr/bin/otool", "-L", str(path)]).splitlines()[1:]
    return sorted(line.strip().split(" (", 1)[0] for line in lines if line.strip())


def dylib_install_name(path: Path) -> str | None:
    lines = command_output(["/usr/bin/otool", "-D", str(path)]).splitlines()[1:]
    return lines[0].strip() if lines else None


def tool_version(path: Path, metadata: dict[str, Any]) -> str | None:
    arguments = metadata.get("versionArguments")
    pattern = metadata.get("versionPattern")
    if not arguments or not pattern:
        return None
    output = command_output([str(path), *arguments])
    match = re.search(pattern, output)
    return match.group(1).strip() if match else None


def common_entry(path: Path) -> dict[str, Any]:
    stat = path.stat()
    return {
        "path": path.relative_to(REPOSITORY_ROOT).as_posix(),
        "bytes": stat.st_size,
        "sha256": sha256(path),
        "mode": f"{stat.st_mode & 0o777:04o}",
        "architectures": architectures(path),
        "linkedLibraries": linked_libraries(path),
    }


def build_manifest() -> dict[str, Any]:
    license_files = license_inventory()
    known_license_files = {entry["path"] for entry in license_files}
    tools: list[dict[str, Any]] = []
    for path in sorted((APP_ROOT / "Binaries").iterdir()):
        if not path.is_file():
            continue
        metadata = TOOL_METADATA.get(path.name)
        if metadata is None:
            raise RuntimeError(f"Missing tool metadata for {path.relative_to(REPOSITORY_ROOT)}")
        if not os.access(path, os.X_OK):
            raise RuntimeError(f"Bundled tool is not executable: {path.relative_to(REPOSITORY_ROOT)}")
        license_file = metadata["licenseFile"]
        if license_file is not None and license_file not in known_license_files:
            raise RuntimeError(
                f"Missing declared license file for {path.name}: {license_file}"
            )
        entry = common_entry(path)
        entry.update(
            {
                "component": metadata["component"],
                "version": tool_version(path, metadata),
                "license": metadata["license"],
                "licenseFile": license_file,
            }
        )
        if path.name == "ffmpeg":
            entry["reportedLicense"] = ffmpeg_reported_license(path)
        if metadata.get("requiredSourceComponents"):
            entry["requiredSourceComponents"] = metadata["requiredSourceComponents"]
        if metadata.get("pendingAttribution"):
            entry["pendingAttribution"] = metadata["pendingAttribution"]
        tools.append(entry)

    libraries: list[dict[str, Any]] = []
    for path in sorted((APP_ROOT / "Frameworks").glob("*.dylib")):
        entry = common_entry(path)
        entry.update(
            {
                "installName": dylib_install_name(path),
                "license": "NOASSERTION",
                "licenseFile": None,
            }
        )
        libraries.append(entry)

    missing_license_files = sorted(
        entry["path"]
        for entry in [*tools, *libraries]
        if entry["licenseFile"] is None
    )
    return {
        "schemaVersion": 3,
        "scope": "Source-tree tools/libraries, resolved Swift packages, and required source accompaniment",
        "packages": package_inventory(),
        "sourceArchives": json.loads((REPOSITORY_ROOT / "AttributionSources.json").read_text())["archives"],
        "tools": tools,
        "libraries": libraries,
        "licenseFiles": license_files,
        "summary": {
            "toolCount": len(tools),
            "libraryCount": len(libraries),
            "totalBytes": sum(entry["bytes"] for entry in [*tools, *libraries]),
            "entriesMissingLocalLicenseFile": missing_license_files,
        },
    }


def serialized(manifest: dict[str, Any]) -> str:
    return json.dumps(manifest, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when BundledDependencies.json does not match the bundled files",
    )
    parser.add_argument(
        "--require-complete-licenses",
        action="store_true",
        help="fail when any dependency has unresolved license attribution (required for publishing)",
    )
    args = parser.parse_args()

    try:
        manifest = build_manifest()
        if args.require_complete_licenses:
            require_complete_licenses(manifest)
        expected = serialized(manifest)
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f"ERROR: unable to inventory bundled dependencies: {error}", file=sys.stderr)
        return 1

    if args.check:
        try:
            actual = MANIFEST_PATH.read_text(encoding="utf-8")
        except OSError as error:
            print(f"ERROR: unable to read {MANIFEST_PATH.name}: {error}", file=sys.stderr)
            return 1
        if actual != expected:
            print(
                "ERROR: BundledDependencies.json is stale; run "
                "scripts/bundled-dependency-manifest.py and commit the result.",
                file=sys.stderr,
            )
            return 1
        print("Bundled dependency manifest is current.")
        return 0

    MANIFEST_PATH.write_text(expected, encoding="utf-8")
    manifest = json.loads(expected)
    summary = manifest["summary"]
    print(
        f"Wrote {MANIFEST_PATH.name}: {summary['toolCount']} tools, "
        f"{summary['libraryCount']} libraries, {summary['totalBytes']} bytes."
    )
    missing = summary["entriesMissingLocalLicenseFile"]
    if missing:
        print(f"License follow-up remains for {len(missing)} entries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
