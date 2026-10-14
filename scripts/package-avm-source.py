#!/usr/bin/env python3
"""Retain the complete pinned AVM tree, integration patch and offline build recipe."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "docs/provenance/avm-2026-10-14-integrated"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    metadata = json.loads((PROVENANCE / "integration.json").read_text())
    revision = metadata["sourceRevision"]
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        parser.error("Source is not the pinned integration commit")
    subprocess.run(["git", "-C", str(source), "diff", "--quiet", "HEAD", "--"], check=True)
    version = (source / "build_arm64/config/avm_version.h").read_bytes()
    if revision[:9].encode() not in version:
        parser.error("Generated version header does not identify the pinned integration")
    destination = ROOT / "build/attribution/avm-2026-10-14-integrated-source.tar.gz"
    destination.parent.mkdir(parents=True, exist_ok=True)

    def add_bytes(archive, name, data, mode=0o644):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = mode
        archive.addfile(info, io.BytesIO(data))

    # Keep the previous reviewed archive intact if export/compression fails.
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging, \
            (Path(staging) / destination.name).open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="", compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|") as archive:
                with subprocess.Popen(["git", "-C", str(source), "archive", "--format=tar", "HEAD"],
                                      stdout=subprocess.PIPE) as process:
                    with tarfile.open(fileobj=process.stdout, mode="r|") as upstream:
                        for member in upstream:
                            member.name = "avm/" + member.name
                            member.mtime = member.uid = member.gid = 0
                            member.uname = member.gname = ""
                            member.pax_headers = {}
                            archive.addfile(member, upstream.extractfile(member) if member.isfile() else None)
                    if process.wait() != 0:
                        raise RuntimeError("git archive failed")
                add_bytes(archive, "avm/amc-source-revision.txt", (revision + "\n").encode())
                add_bytes(archive, "avm/amc-avm-version.h", version)
                for relative in ("scripts/build-avm-tools.sh", "scripts/prepare-avm-source.py",
                                 "docs/provenance/avm-2026-10-14-integrated/integration.json",
                                 "docs/provenance/avm-2026-10-14-integrated/main-fixes.patch"):
                    add_bytes(archive, relative, (ROOT / relative).read_bytes())
                add_bytes(archive, "README.md", b"""# AVM encoder integration source companion

The avm directory contains the complete reviewed merge of pinned av2-enc and
main, including dependency archives. The integration manifest identifies both
parents, the merged tree and commit, and the hash of the resolved patch.

Offline rebuild (macOS arm64, CMake, Apple Clang, Perl and Python required):

    bash scripts/build-avm-tools.sh "$PWD/avm" "$PWD/build_arm64"

The build recipe preserves the supplied version header when Git history is
absent. It does not install or sign binaries. To reconstruct the exact Git
commit from a clean upstream clone containing both parents:

    python3 scripts/prepare-avm-source.py /path/to/clean/avm-clone

The patch records all merge resolutions and transform API adaptations.
""")
        raw.flush()
        Path(raw.name).replace(destination)
    with destination.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    entry = {"component": "AVM av2-enc + main 2026-10-14", "path": str(destination.relative_to(ROOT)),
             "bytes": destination.stat().st_size, "sha256": digest}
    (PROVENANCE / "source-archive.json").write_text(json.dumps(entry, indent=2) + "\n")
    manifest_path = ROOT / "AttributionSources.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["archives"] = [entry if record["component"] in
                            ("AVM 2026-10-12", entry["component"]) else record
                            for record in manifest["archives"]]
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(entry, indent=2))


if __name__ == "__main__":
    main()
