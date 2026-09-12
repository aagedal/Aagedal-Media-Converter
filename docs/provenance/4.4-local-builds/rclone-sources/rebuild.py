#!/usr/bin/env python3
"""Rebuild the 4.4 rclone helper offline from its source companion archive.

Run from an extracted rclone-4.4-source directory with Python 3.12+ on arm64 macOS.
After the first build, edit work/module-cache (including LGPL sddl sources), then
use --build-only to relink the helper with your modified library.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'source-manifest.json').read_text())
    for item in manifest['inputs']:
        path = root / item['path']
        if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            raise ValueError(f'Changed archive input: {path}')
    work = root / 'work'
    work.mkdir(exist_ok=True)
    source = work / 'rclone-c441cac8089c7d5314a37673291fdb8236900884'
    if not args.build_only:
        if source.exists():
            raise ValueError('Source already extracted; use --build-only to preserve edits')
        for archive_name in ['rclone-source.tar.gz', 'go1.26.2.darwin-arm64.tar.gz']:
            with tarfile.open(root / archive_name) as archive:
                archive.extractall(work, filter='data')
        selection = source / 'cmd/all/all.go'
        original = selection.read_text()
        excluded = '\t_ "github.com/rclone/rclone/cmd/serve/s3"\n'
        if original.count(excluded) != 1:
            raise ValueError('Source does not match reviewed command selection')
        selection.write_text(original.replace(excluded, ''))
    env = dict(os.environ, GOROOT=str(work / 'go'), GOPATH=str(work / 'gopath'),
               GOMODCACHE=str(work / 'module-cache'), GOCACHE=str(work / 'build-cache'),
               GOTOOLCHAIN='local', GOWORK='off', GOENV='off', GOFLAGS='',
               GOEXPERIMENT='', GO111MODULE='on', GOPROXY=(root / 'proxy').as_uri(),
               GOSUMDB='off', GOPRIVATE='', GONOPROXY='none',
               CGO_ENABLED='0', GOOS='darwin', GOARCH='arm64', GOARM64='v8.0')
    command = [str(work / 'go/bin/go'), 'build', '-mod=readonly', '-trimpath',
               '-buildvcs=false', '-ldflags',
               '-s -w -X github.com/rclone/rclone/fs.Version=v1.74.0-DEV-aagedal-4.4',
               '-o', str(work / 'rclone'), '.']
    subprocess.run(command, cwd=source, env=env, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(work / 'rclone')], check=True)
    subprocess.run([str(work / 'rclone'), 'version'], check=True)
    print(f'Rebuilt helper: {work / "rclone"}')


if __name__ == '__main__':
    main()
