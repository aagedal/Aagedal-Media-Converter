#!/usr/bin/env python3
"""Preserve corrected full FFmpeg sources; retain the existing dependency archives."""
from pathlib import Path
import argparse
import hashlib
import json
import tarfile

repo = Path(__file__).resolve().parents[4]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=Path, required=True)
workspace = parser.parse_args().workspace.resolve()
evidence = Path(__file__).resolve().parent
archive = repo / 'build/attribution/ffmpeg-9.0.2-metal-source.tar.gz'
archive.parent.mkdir(parents=True, exist_ok=True)
excluded = {'.git', '.libs', '.deps', 'autom4te.cache', '__pycache__'}
compiled_suffixes = {'.o', '.a', '.lo', '.la', '.d', '.dylib', '.so', '.air', '.metallib', '.pyc'}
files = []
with tarfile.open(archive, 'w:gz', compresslevel=6) as tar:
    for path in sorted((workspace / 'sources/ffmpeg-9.0.2').rglob('*')):
        rel = path.relative_to(workspace)
        if not path.is_file() or excluded.intersection(rel.parts) or path.suffix in compiled_suffixes:
            continue
        if not path.resolve().is_relative_to(workspace):
            raise ValueError(f'External source symlink: {path}')
        with path.open('rb') as handle:
            magic = handle.read(4)
        if magic in [bytes.fromhex(x) for x in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', '7f454c46']]:
            continue
        digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
        files.append({'path': rel.as_posix(), 'sha256': digest})
        tar.add(path, arcname=rel.as_posix(), recursive=False)
    # Overlay these exact recipes onto the dependency source companion before
    # invoking its rebuild.sh. The full recipe checks and retains the YADIF patch.
    for path in sorted((evidence / 'recipe').rglob('*')):
        if path.is_file():
            tar.add(path, arcname=path.relative_to(evidence / 'recipe').as_posix(), recursive=False)
    tar.add(evidence / 'README-source.md', arcname='README-metal-source.md')
    for path in sorted(evidence.iterdir()):
        if path.is_file() and path.name != 'source-archive.json':
            tar.add(path, arcname='metal-build-evidence/' + path.name, recursive=False)
    tar.add(repo / 'Licenses/ffmpeg-LICENSE.txt', arcname='LICENSES.txt')
metadata = {
    'component': 'FFmpeg 9.0.2 Metal correction',
    'path': archive.relative_to(repo).as_posix(),
    'bytes': archive.stat().st_size,
    'sha256': hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest(),
}
(evidence / 'source-archive.json').write_text(json.dumps({'archive': metadata, 'files': files}, indent=2) + '\n')
print(json.dumps(metadata))
