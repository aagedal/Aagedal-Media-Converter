#!/usr/bin/env python3
"""Link a separate CoreAudio fault probe against Xcode's resolved MPV products."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True, help='Xcode Build/Products/Debug or Release')
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--libmpv', type=Path, help='Override only libmpv with a local candidate archive')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    args = parser.parse_args()
    products = args.products.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    source = Path(__file__).with_name('mpv-coreaudio-probe.c')
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    swift = Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx'
    binary = output / 'probe'
    command = ['xcrun', 'clang', str(source), '-I' + str(products / 'Libmpv.framework/Headers'),
               '-F' + str(products), '-L' + str(products), '-L' + str(swift), '-o', str(binary)]
    for framework in sorted(products.glob('*.framework')):
        if framework.stem != 'Sparkle':
            if framework.stem == 'Libmpv' and args.libmpv:
                command += [str(args.libmpv.resolve())]
            else:
                command += ['-framework', framework.stem]
    for name in ('AVFoundation', 'CoreAudio', 'AudioToolbox', 'CoreVideo', 'CoreFoundation',
                 'CoreMedia', 'Metal', 'VideoToolbox', 'AppKit'):
        command += ['-framework', name]
    command += ['-lMoltenVK', '-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2', '-lz', '-lc++',
                '-Wl,-rpath,' + str(products), '-Wl,-rpath,/usr/lib/swift']
    with (output / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    tone = output / 'tone.wav'
    subprocess.run([str(args.ffmpeg.resolve()), '-nostdin', '-hide_banner', '-loglevel', 'error',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
                    '-c:a', 'pcm_s16le', '-ac', '2', str(tone)], check=True, timeout=30)
    # Do not inherit injection settings from the caller.
    environment = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
    results = []
    for mode in ('normal', 'notify', 'fail-init', 'fail-format'):
        try:
            result = subprocess.run([str(binary), mode, str(tone)], text=True, capture_output=True,
                                    env=environment, timeout=60)
            stdout, stderr, exit_code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout = (error.stdout or b'').decode(errors='replace')
            stderr = (error.stderr or b'').decode(errors='replace') + '\nProbe timed out\n'
            exit_code = 124
        (output / f'{mode}.log').write_text(stdout + stderr)
        lines = [line for line in stdout.splitlines() if line.startswith('{')]
        results.append({'mode': mode, 'exit_code': exit_code,
                        'observations': json.loads(lines[-1]) if lines else None})
    library = args.libmpv.resolve() if args.libmpv else products / 'Libmpv.framework/Libmpv'
    report = {'products': str(products), 'libmpv': str(library), 'libmpv_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
              'probe_source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'system': subprocess.check_output(['sw_vers'], text=True).strip(),
              'results': results, 'passed': all(item['exit_code'] == 0 for item in results),
              'scope': 'Isolated binary probe; injected failures, no physical device change or app signing validation'}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
