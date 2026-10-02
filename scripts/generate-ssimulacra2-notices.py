#!/usr/bin/env python3
"""Audit the locked helper closure and retain its dependency license notices."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
PROVENANCE = REPOSITORY / 'docs/provenance/ssimulacra2'
UPSTREAM_COMMIT = '05f2b4e216059c5d735f9665a51648a37d684e70'
# SPDX expressions verified for the pinned image-only macOS build. A change
# requires review instead of silently licensing a new dependency.
REVIEWED_LICENSES = {
    '(MIT OR Apache-2.0) AND Unicode-3.0', '0BSD OR MIT OR Apache-2.0',
    'Apache-2.0 OR MIT', 'Apache-2.0/MIT', 'BSD-2-Clause',
    'BSD-2-Clause OR Apache-2.0 OR MIT', 'BSD-3-Clause',
    'BSD-3-Clause OR Apache-2.0', 'CC0-1.0 OR MIT-0 OR Apache-2.0',
    'MIT', 'MIT OR Apache-2.0', 'MIT OR Apache-2.0 OR Zlib',
    'MIT OR Zlib OR Apache-2.0', 'MIT/Apache-2.0', 'Unlicense OR MIT',
    'Zlib OR Apache-2.0 OR MIT',
}

class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def handle_starttag(self, tag, attrs):
        if tag in {'p', 'div', 'h1', 'h2', 'h3', 'li', 'pre', 'br'}:
            self.parts.append('\n')

    def handle_endtag(self, tag):
        if tag in {'p', 'div', 'h1', 'h2', 'h3', 'li', 'pre'}:
            self.parts.append('\n')


def generate(metadata, rust_notice):
    packages = {p['id']: p for p in metadata['packages']}
    nodes = {n['id']: n for n in metadata['resolve']['nodes']}
    root = next(p['id'] for p in packages.values() if p['name'] == 'ssimulacra2_rs')
    selected = set()

    def visit(package_id):
        if package_id in selected:
            return
        selected.add(package_id)
        for dependency in nodes[package_id]['deps']:
            if any(kind['kind'] != 'dev' for kind in dependency['dep_kinds']):
                visit(dependency['pkg'])

    visit(root)
    notices = ['SSIMULACRA2 image-comparison helper and dependencies\n\n'
               'CLI 0.5.2, metric 0.5.1, Rust 1.89.0, aarch64-apple-darwin.\n'
               'Upstream: https://github.com/rust-av/ssimulacra2\n'
               f'Source revision: {UPSTREAM_COMMIT}\n'
               'Image-only build, with statically linked Little CMS.\n'
               'Normal and build dependency notices are retained below.\n'
               'The app remains GPL-3.0-or-later; upstream terms remain intact.\n']
    inventory = []
    for package in sorted((packages[i] for i in selected), key=lambda p: (p['name'], p['version'])):
        if package['license'] not in REVIEWED_LICENSES:
            raise ValueError(f"Unreviewed license: {package['name']} {package['license']}")
        directory = Path(package['manifest_path']).parent
        files = sorted(f for f in directory.rglob('*') if f.is_file() and
                       f.name.lower().startswith(('license', 'licence', 'copying', 'copyright', 'notice')))
        if not files:
            files = sorted((PROVENANCE / 'supplemental-notices').glob(f"{package['name']}-LICENSE*.txt"))
        if not files:
            raise ValueError(f"Missing upstream license notice: {package['name']}")
        item = {key: package[key] for key in ['name', 'version', 'license', 'repository', 'source']}
        item['features'] = nodes[package['id']]['features']
        item['notice_files'] = []
        notices.append('\n' + '=' * 72 + '\n' + package['name'] + ' ' + package['version'] + '\n'
                       + (package['repository'] or f"https://crates.io/crates/{package['name']}") + '\n'
                       + 'License: ' + package['license'] + '\n' + '=' * 72 + '\n')
        for file in files:
            relative = file.relative_to(directory) if file.is_relative_to(directory) else file.name
            item['notice_files'].append(str(relative))
            notices.append('\n' + str(relative) + '\n\n' + file.read_text(encoding='utf-8'))
        inventory.append(item)
    parser = PlainHTML()
    parser.feed(rust_notice.read_text(encoding='utf-8'))
    notices.append('\n' + '=' * 72 + '\nRust 1.89.0 standard library notices\n' + '=' * 72 + '\n'
                   + ''.join(parser.parts))
    (REPOSITORY / 'Licenses/ssimulacra2-LICENSE.txt').write_text('\n'.join(notices), encoding='utf-8')
    (PROVENANCE / 'dependencies.json').write_text(json.dumps(inventory, indent=2) + '\n', encoding='utf-8')
    print(f'Retained notices for {len(inventory)} reviewed packages and the Rust standard library.')

if __name__ == '__main__':
    arguments = argparse.ArgumentParser()
    arguments.add_argument('metadata', type=Path)
    arguments.add_argument('rust_notice', type=Path)
    options = arguments.parse_args()
    generate(json.loads(options.metadata.read_text()), options.rust_notice)
