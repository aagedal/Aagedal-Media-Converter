#!/usr/bin/env python3
"""Package the complete rclone source and offline relinking recipe for release."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
EVIDENCE = REPO / 'docs/provenance/4.4-local-builds/rclone-sources'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def escaped(value):
    return ''.join('!' + c.lower() if c.isupper() else c for c in value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', required=True, type=Path)
    parser.add_argument('--toolchain-archive', required=True, type=Path)
    parser.add_argument('--module-cache', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=REPO / 'build/attribution/rclone-4.4-source.tar.gz')
    args = parser.parse_args()
    recovery = json.loads((EVIDENCE / 'source-recovery.json').read_text())
    review = json.loads((EVIDENCE / 'release-review.json').read_text())
    modules = json.loads((EVIDENCE / 'modules.json').read_text())['modules']
    if sha(args.source_archive) != recovery['mainArchiveSHA256']:
        raise ValueError('Main source archive mismatch')
    if sha(args.toolchain_archive) != recovery['goToolchain']['sha256']:
        raise ValueError('Go toolchain archive mismatch')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rclone-source-companion-') as temp:
        root = Path(temp) / 'rclone-4.4-source'
        root.mkdir()
        shutil.copyfile(args.source_archive, root / 'rclone-source.tar.gz')
        shutil.copyfile(args.toolchain_archive, root / recovery['goToolchain']['filename'])
        shutil.copyfile(EVIDENCE / 'rebuild.py', root / 'rebuild.py')
        shutil.copyfile(EVIDENCE / 'release.patch', root / 'release.patch')
        shutil.copyfile(REPO / 'Licenses/rclone-LICENSE.txt', root / 'NOTICES.txt')
        shutil.copyfile(EVIDENCE / 'additional-notices/public-suffix-list.dat', root / 'public-suffix-list.dat')
        downloads = args.module_cache / 'cache/download'
        for module in modules:
            if module['Path'] not in review['activeModules']:
                continue
            relative = Path(escaped(module['Path'])) / '@v' / (escaped(module['Version']) + '.zip')
            source = downloads / relative
            if sha(source) != module['sourceZipSHA256']:
                raise ValueError(f'Module ZIP mismatch: {module["Path"]}')
            dest = root / 'proxy' / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
        # Lazy module graph loading may also read metadata for modules whose
        # packages are not selected. No extra module code is added here.
        for suffix in ['*.mod', '*.info']:
            for source in sorted(downloads.rglob(suffix)):
                relative = source.relative_to(downloads)
                if relative.parts[0] == 'sumdb':
                    continue
                dest = root / 'proxy' / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, dest)
        (root / 'README.txt').write_text(
            'Rclone 4.4 source companion\n\n'
            'Run python3 rebuild.py on macOS arm64 (Python 3.12+). No network is used.\n'
            'The Go 1.26.2 toolchain archive includes its complete source.\n'
            'Source ZIPs in proxy contain the complete 139 selected modules, including\n'
            'LGPL-3.0 cloudsoda/sddl and MPL-2.0 HashiCorp libraries.\n'
            'The main source archive is the exact upstream revision recorded below.\n'
            'The only source patch removes the cmd/serve/s3 import in cmd/all/all.go;\n'
            'the recipe records it directly. The S3 storage backend stays enabled.\n\n'
            'After initial extraction/build, edit sources in work/module-cache or\n'
            'work/rclone-c441cac8089c7d5314a37673291fdb8236900884, then run\n'
            'python3 rebuild.py --build-only to relink your changes. Go module-cache\n'
            'files are read-only by default: chmod u+w the files you want to edit.\n'
            'Do not remove the work directory when rebuilding a modified library.\n'
            'NOTICES.txt contains license terms and debugging/relinking information.\n\n'
            + json.dumps({'mainSourceURL': recovery['mainSourceURL'],
                          'goToolchainURL': 'https://go.dev/dl/' + recovery['goToolchain']['filename'],
                          'goToolchainChecksumSource': recovery['goToolchainChecksumSource']}, indent=2) + '\n')
        manifest = {'mainRevision': review['mainRevision'], 'activeModules': review['activeModules'],
                    'inputs': [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size,
                                'sha256': sha(p)} for p in sorted(root.rglob('*')) if p.is_file()]}
        (root / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        with args.output.open('wb') as raw:
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
                with tarfile.open(mode='w', fileobj=compressed) as archive:
                    for path in sorted(root.rglob('*')):
                        if not path.is_file():
                            continue
                        info = archive.gettarinfo(str(path), arcname='rclone-4.4-source/' + path.relative_to(root).as_posix())
                        info.uid = info.gid = info.mtime = 0
                        info.uname = info.gname = ''
                        info.mode = 0o644
                        with path.open('rb') as stream:
                            archive.addfile(info, stream)
    print(json.dumps({'component': 'rclone', 'path': str(args.output.relative_to(REPO)) if args.output.is_relative_to(REPO) else str(args.output),
                      'bytes': args.output.stat().st_size, 'sha256': sha(args.output)}, indent=2))


if __name__ == '__main__':
    main()
