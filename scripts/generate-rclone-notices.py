#!/usr/bin/env python3
"""Assemble reviewed rclone notices from the retained source-selection evidence."""
import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EVIDENCE = REPO / 'docs/provenance/4.4-local-builds/rclone-sources'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    review = json.loads((EVIDENCE / 'release-review.json').read_text())
    parts = [review['packagedIntroduction'].rstrip()]
    for entry in review['noticeInputs']:
        data = (EVIDENCE / entry['path']).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError(f"Changed notice input: {entry['path']}")
        # Keep original input bytes/hash in evidence; normalize only viewer text.
        decoded = data.decode(entry.get('encoding', 'utf-8'))
        normalized = '\n'.join(line.rstrip() for line in decoded.splitlines()).rstrip()
        parts.append('=' * 78 + '\n' + entry['label'] + '\n' + '=' * 78 + '\n\n' + normalized)
    data = ('\n\n'.join(parts) + '\n').encode('utf-8')
    output = REPO / 'Licenses/rclone-LICENSE.txt'
    if args.check:
        if output.read_bytes() != data:
            raise ValueError('Packaged rclone attribution differs from reviewed inputs')
        print(f'Verified {len(review["noticeInputs"])} notice inputs and {len(data):,} packaged bytes')
    else:
        output.write_bytes(data)
        print(f'Wrote {len(data):,} bytes to {output}')


if __name__ == '__main__':
    main()
