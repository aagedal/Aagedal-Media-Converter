#!/usr/bin/env python3
"""Reproduce the pinned AVM integration commit in a clean upstream clone."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "docs/provenance/avm-2026-10-14-integrated"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    integration = json.loads((PROVENANCE / "integration.json").read_text())
    patch = (PROVENANCE / "main-fixes.patch").read_bytes()
    if hashlib.sha256(patch).hexdigest() != integration["patchSHA256"]:
        parser.error("Integration patch differs from the pinned manifest")

    def git(*arguments, **kwargs):
        return subprocess.check_output(["git", "-C", str(source), *arguments], **kwargs)

    if git("status", "--porcelain", "--untracked-files=normal").strip():
        parser.error("Use a clean clone without untracked files")
    for revision in (integration["encoderRevision"], integration["mainRevision"]):
        git("cat-file", "-e", revision + "^{commit}")
    git("checkout", "--detach", integration["encoderRevision"])
    git("apply", "--check", "--index", "-", input=patch)
    git("apply", "--index", "-", input=patch)
    tree = git("write-tree").decode().strip()
    if tree != integration["sourceTree"]:
        raise ValueError("Reconstructed tree differs from reviewed integration")
    identity = integration["commitIdentity"]
    environment = dict(os.environ)
    for role in ("AUTHOR", "COMMITTER"):
        environment[f"GIT_{role}_NAME"] = identity["name"]
        environment[f"GIT_{role}_EMAIL"] = identity["email"]
        environment[f"GIT_{role}_DATE"] = identity["date"]
    revision = git("-c", "commit.gpgsign=false", "commit-tree", tree,
                   "-p", integration["encoderRevision"], "-p", integration["mainRevision"],
                   input=integration["commitMessage"].encode(), env=environment).decode().strip()
    if revision != integration["sourceRevision"]:
        raise ValueError("Reconstructed commit differs from pinned integration")
    git("checkout", "--detach", revision)
    print(f"Prepared AVM integration {revision}")


if __name__ == "__main__":
    main()
