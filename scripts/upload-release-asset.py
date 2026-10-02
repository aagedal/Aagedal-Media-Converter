#!/usr/bin/env python3
# Aagedal Media Converter
# Copyright © 2026 Truls Aagedal
# SPDX-License-Identifier: GPL-3.0-or-later
"""Upload one GitHub release asset with curl's transfer progress bar."""
import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode


def upload_asset(repo: str, tag: str, path: Path) -> None:
    path = path.resolve(strict=True)
    size = path.stat().st_size
    print(f"==> Uploading {path.name} ({size / 1024 / 1024:.1f} MiB)", flush=True)
    print("    Transfer progress below; GitHub confirmation follows the upload.", flush=True)
    release = json.loads(subprocess.check_output([
        "gh", "release", "view", tag, "--repo", repo,
        "--json", "databaseId,assets",
    ], text=True))
    token = subprocess.check_output([
        "gh", "auth", "token", "--hostname", "github.com",
    ], text=True).strip()
    # Keep credentials out of command arguments, files, and printed errors.
    if not token or any(char in token for char in '\r\n"\\'):
        raise ValueError("GitHub returned an invalid authentication token")
    for asset in release["assets"]:
        if asset["name"] == path.name:
            print(f"    Replacing existing asset: {path.name}", flush=True)
            subprocess.run([
                "gh", "api", "--method", "DELETE",
                asset["apiUrl"],
            ], check=True)
    url = (f"https://uploads.github.com/repos/{repo}/releases/"
           f"{release['databaseId']}/assets?{urlencode({'name': path.name})}")
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="aagedal-upload-") as directory:
        response_path = Path(directory) / "response.json"
        result = subprocess.run([
            "curl", "--disable", "--config", "-", "--progress-bar",
            "--show-error", "--fail-with-body", "--connect-timeout", "30",
            "--request", "POST", "--upload-file", str(path),
            "--header", "Content-Type: application/octet-stream",
            "--header", "Accept: application/vnd.github+json",
            "--output", str(response_path), url,
        ], input=f'header = "Authorization: Bearer {token}"\n', text=True)
        print(flush=True)
        if result.returncode:
            raise RuntimeError(
                f"Upload failed for {path.name} (curl exit {result.returncode}). "
                "The release script will stop before publication."
            )
        response = json.loads(response_path.read_text())
        if response.get("state") != "uploaded" or response.get("size") != size:
            raise RuntimeError(f"GitHub did not confirm a complete upload of {path.name}")
    elapsed = time.monotonic() - started
    print(f"==> Uploaded {path.name} in {elapsed:.0f}s "
          f"({size / 1024 / 1024 / max(elapsed, 0.001):.1f} MiB/s)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        upload_asset(args.repo, args.tag, args.path)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"ERROR: {error}\n")


if __name__ == "__main__":
    main()
