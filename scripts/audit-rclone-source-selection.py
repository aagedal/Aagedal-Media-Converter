#!/usr/bin/env python3
"""Record a reproducible offline source graph; this does not certify attribution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
EVIDENCE = REPO / 'docs/provenance/4.4-local-builds/rclone-sources'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def json_stream(data):
    decoder = json.JSONDecoder()
    while data.strip():
        data = data.lstrip()
        value, end = decoder.raw_decode(data)
        yield value
        data = data[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', required=True, type=Path)
    parser.add_argument('--go-root', required=True, type=Path)
    parser.add_argument('--module-cache', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    binary = (REPO / 'Aagedal Media Converter/Binaries/rclone').read_bytes()
    binary_evidence = json.loads((EVIDENCE.parent / 'rclone-source-recovery.json').read_text())
    require(sha256(binary) == binary_evidence['binarySHA256'], 'Bundled binary changed')
    recovery = json.loads((EVIDENCE / 'source-recovery.json').read_text())
    require(sha256(args.source_archive.read_bytes()) == recovery['mainArchiveSHA256'], 'Main archive hash mismatch')
    modules = json.loads((EVIDENCE / 'modules.json').read_text())['modules']
    expected = {m['Path']: (m['Version'], m['Sum']) for m in modules}
    expected_zip_hashes = {m['Path']: m['sourceZipSHA256'] for m in modules}
    with tempfile.TemporaryDirectory(prefix='rclone-selection-') as temporary:
        root = Path(temporary)
        with tarfile.open(args.source_archive) as archive:
            archive.extractall(root, filter='data')
        source = next(p for p in root.iterdir() if p.is_dir())
        env = dict(os.environ, GOROOT=str(args.go_root.resolve()), GOPATH=str(root / 'gopath'),
                   GOMODCACHE=str(args.module_cache.resolve()), GOCACHE=str(root / 'cache'),
                   GOTOOLCHAIN='local', GOWORK='off', GOPROXY='off', GOSUMDB='off',
                   GONOPROXY='none', GOPRIVATE='',
                   CGO_ENABLED='0', GOOS='darwin', GOARCH='arm64', GOARM64='v8.0',
                   GOFLAGS='', GOENV='off', GOEXPERIMENT='', GO111MODULE='on')
        go = str(args.go_root.resolve() / 'bin/go')
        version = subprocess.check_output([go, 'version'], env=env, text=True).strip()
        require('go1.26.2 ' in version, 'Use the recorded Go 1.26.2 toolchain')
        packages = list(json_stream(subprocess.check_output([go, 'list', '-mod=readonly', '-deps', '-json', '.'], cwd=source, env=env, text=True)))
        downloads = list(json_stream(subprocess.check_output(
            [go, 'mod', 'download', '-json'] + [f"{path}@{version}" for path, (version, _) in expected.items()],
            cwd=root, env=env, text=True)))
        zips = {}
        for download in downloads:
            require(not download.get('Error'), download)
            path = download['Path']
            require((download['Version'], download['Sum']) == expected[path], path)
            zip_path = Path(download['Zip'])
            require(sha256(zip_path.read_bytes()) == expected_zip_hashes[path], path)
            zips[path] = zip_path
        require(set(zips) == set(expected), 'Incomplete cached module downloads')
        selected = {}
        embeds = []
        package_records = []
        for package in packages:
            module = package.get('Module', {})
            if module and not module.get('Main'):
                require(not module.get('Replace'), 'Unexpected module replacement')
                selected[module['Path']] = (module['Version'], module.get('Sum'))
            record = {'importPath': package['ImportPath'], 'standard': package.get('Standard', False)}
            if module:
                record['module'] = module['Path']
            record['sourceFiles'] = sorted(package.get('GoFiles', []) + package.get('SFiles', []) + package.get('CgoFiles', []))
            package_records.append(record)
            if module and not module.get('Main'):
                with zipfile.ZipFile(zips[module['Path']]) as archive:
                    for filename in record['sourceFiles'] + package.get('EmbedFiles', []):
                        local = Path(package['Dir']) / filename
                        relative = local.relative_to(module['Dir']).as_posix()
                        archived = archive.read(f"{module['Path']}@{module['Version']}/{relative}")
                        require(local.read_bytes() == archived, f'Modified cached source: {local}')
            for filename in package.get('EmbedFiles', []):
                data = (Path(package['Dir']) / filename).read_bytes()
                embeds.append({'package': package['ImportPath'], 'path': filename, 'bytes': len(data), 'sha256': sha256(data), 'verbatimBytesFoundInBinary': data in binary})
        require(selected == expected, f'Module graph mismatch: missing={set(expected)-set(selected)}, extra={set(selected)-set(expected)}')
        selections = []
        for filename in ['rclone.go', 'backend/all/all.go', 'cmd/all/all.go']:
            data = (source / filename).read_bytes()
            selections.append({'path': filename, 'sha256': sha256(data), 'content': data.decode()})
        report = {
            'scope': 'Source graph selected by recorded target settings, not a reproduced binary, proof of linker retention, or completed notice review.',
            'binarySHA256': sha256(binary),
            'sourceArchiveSHA256': recovery['mainArchiveSHA256'],
            'goVersion': version,
            'settings': {key: env[key] for key in ['CGO_ENABLED', 'GOOS', 'GOARCH', 'GOARM64', 'GOFLAGS']},
            'command': 'go list -mod=readonly -deps -json .',
            'selectionFiles': selections,
            'packageCount': len(packages),
            'dependencyModuleCount': len(selected),
            'allEmbeddedModuleVersionsAndSumsMatch': True,
            'selectedModuleSourcesAndEmbedsMatchRecordedZips': True,
            'embeddedFiles': sorted(embeds, key=lambda item: (item['package'], item['path'])),
            'packages': sorted(package_records, key=lambda item: item['importPath']),
        }
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(f'Recorded {len(packages)} packages, {len(selected)} exact modules and {len(embeds)} embed inputs in {args.output}')


if __name__ == '__main__':
    main()
