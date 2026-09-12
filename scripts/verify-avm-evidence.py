#!/usr/bin/env python3
"""Check retained AVM evidence integrity; this does not approve attribution."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


DEFAULT_EVIDENCE = Path(__file__).resolve().parents[1] / 'docs/provenance/4.4-local-builds/avm-dependencies'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(records):
    # The original inventory sorted pathlib paths, by component, not raw strings.
    return sha256(''.join(f'{path}\t{digest}\n' for path, digest in
                          sorted(records, key=lambda row: Path(row[0]))).encode())


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError(f'Path escapes evidence/source root: {relative}')
    return path


def verify(evidence, source_root=None):
    inventory = json.loads((evidence / 'inventory.json').read_text())
    errors = []
    snapshots = 0
    for component in inventory['components']:
        for record in component['retainedFiles']:
            snapshots += 1
            snapshot = contained(evidence, record['snapshotPath'])
            data = snapshot.read_bytes()
            if len(data) != record['bytes'] or sha256(data) != record['sha256']:
                errors.append(f'Snapshot changed: {record["snapshotPath"]}')
            if source_root is not None:
                source = contained(source_root, record['sourcePath'])
                if not source.is_file() or source.read_bytes() != data:
                    errors.append(f'Source differs from snapshot: {record["sourcePath"]}')

    references = json.loads((evidence / 'compiler-inputs.json').read_text())
    if references['schemaVersion'] != 1:
        raise ValueError('Unsupported compiler-inputs schema version')
    for component in inventory['components']:
        rows = references['components'][component['directory']]
        if len(rows) != component['compilerReferencedFileCount'] or fingerprint(rows.items()) != component['compilerReferencedFilesSHA256']:
            errors.append(f'Compiler input index differs from inventory: {component["directory"]}')
        if source_root is not None:
            for relative, expected in rows.items():
                path = contained(source_root, relative)
                if not path.is_file() or sha256(path.read_bytes()) != expected:
                    errors.append(f'Compiler input changed or missing: {relative}')

    if source_root is not None:
        records = sorted((source_root / 'build_arm64').rglob('*.o.d'))
        rows = [(str(p.relative_to(source_root)), sha256(p.read_bytes())) for p in records]
        if len(records) != inventory['compilerDependencyFileCount'] or fingerprint(rows) != inventory['compilerDependencyRecordSetSHA256']:
            errors.append('Compiler dependency record set changed')
    return snapshots, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir', type=Path, default=DEFAULT_EVIDENCE)
    parser.add_argument('--source-root', type=Path, help='Also compare retained AVM source/build bytes')
    args = parser.parse_args()
    try:
        snapshots, errors = verify(args.evidence_dir, args.source_root)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'AVM evidence check failed: {exc}', file=sys.stderr)
        return 1
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'AVM evidence integrity passed: {snapshots} snapshots and compiler input index'
          + ('; retained source/build bytes match.' if args.source_root else '.'))
    print('Evidence integrity does not establish source authenticity or complete attribution.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
