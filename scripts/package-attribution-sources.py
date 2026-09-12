#!/usr/bin/env python3
"""Validate retained source material and package the release's source companion."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def verify_sources(root: Path, manifest: dict) -> list[tuple[dict, Path]]:
    archives = manifest.get("archives", [])
    if not archives:
        raise ValueError("No attribution source archives are recorded")
    result = []
    names = {"AttributionSources.json", "README.md"}
    for entry in archives:
        path = root / entry["path"]
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Source archive escapes repository: {entry['path']}")
        if path.name in names:
            raise ValueError(f"Duplicate source archive name: {path.name}")
        names.add(path.name)
        if not path.is_file():
            raise ValueError(f"Missing source archive: {entry['path']}; see docs/attribution-sources.md")
        with path.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        if path.stat().st_size != entry["bytes"] or digest != entry["sha256"]:
            raise ValueError(f"Source archive differs from reviewed material: {entry['path']}")
        result.append((entry, path))
    return result


def package_sources(root: Path, manifest: dict, output: Path) -> None:
    sources = verify_sources(root, manifest)
    if output.resolve() in {path.resolve() for _, path in sources}:
        raise ValueError("Output would overwrite an attribution source archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Inner source archives are already compressed. A plain tar avoids spending
    # time recompressing them and retains exact reviewed source bytes.
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".tar", delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with tarfile.open(temporary_path, "w", dereference=True) as archive:
            packaged_manifest = {**manifest, "archives": [{**entry, "path": path.name} for entry, path in sources]}
            metadata = json.dumps(packaged_manifest, indent=2).encode() + b"\n"
            info = tarfile.TarInfo("AttributionSources.json")
            info.size = len(metadata)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(metadata))
            for entry, path in sources:
                archive.add(path, arcname=path.name, recursive=False)
            archive.add(root / "docs/attribution-sources.md", arcname="README.md")
        # Check the actual copied bytes, so a concurrent source change cannot
        # publish material different from what was reviewed before packaging.
        with tarfile.open(temporary_path) as archive:
            for entry, path in sources:
                with archive.extractfile(path.name) as member:
                    if hashlib.file_digest(member, "sha256").hexdigest() != entry["sha256"]:
                        raise ValueError(f"Source changed during packaging: {entry['path']}")
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads((ROOT / "AttributionSources.json").read_text())
        if args.output:
            package_sources(ROOT, manifest, args.output)
            print(f"Packaged source companion: {args.output}")
        else:
            print(f"Verified {len(verify_sources(ROOT, manifest))} attribution source archives")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"ERROR: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
