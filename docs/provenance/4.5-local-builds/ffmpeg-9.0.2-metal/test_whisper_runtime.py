#!/usr/bin/env python3
"""Qualify the Photo Agent candidate using explicit real speech and VAD models.

Retains commands, logs, output and SHA-256 identities in --output. No downloads.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import time
import wave


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--vad-model', type=Path, required=True)
    p.add_argument('--audio', type=Path, required=True, help='16 kHz mono WAV with intelligible speech')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    binary, model, vad, audio, out = [x.resolve() for x in
        (args.binary, args.model, args.vad_model, args.audio, args.output)]
    out.mkdir(parents=True, exist_ok=True)
    results = []
    with wave.open(str(audio)) as w:
        duration = w.getnframes() * 1000 // w.getframerate()
        assert w.getnchannels() == 1 and w.getframerate() == 16000
    silence = out / 'silence.wav'
    with wave.open(str(silence), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(bytes(5 * 16000 * 2))

    def command(source, destination, gpu=0, fmt='json', extra='', loop=False, queue=30):
        options = f'whisper=model={model}:language=en:queue={queue}:use_gpu={gpu}:format={fmt}:destination={destination}'
        return [str(binary), '-nostdin', '-hide_banner', '-loglevel', 'debug',
                *(['-stream_loop', '-1'] if loop else []), '-i', str(source),
                '-af', options + extra, '-f', 'null', '-']

    def run(label, cmd, success=True):
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        (out / f'{label}.log').write_text(r.stderr)
        results.append({'case': label, 'command': cmd, 'returncode': r.returncode})
        (out / 'report.json').write_text(json.dumps({'results': results}, indent=2))
        if success:
            assert r.returncode == 0, f'{label}: {r.stderr[-2000:]}'
        else:
            assert r.returncode > 0, f'{label}: expected controlled failure, got {r.returncode}'
        print(f'PASS: {label}', flush=True)
        return r

    def validate(target, fmt, bound, speech):
        text = target.read_text()
        if fmt == 'json':
            rows = [json.loads(line) for line in text.splitlines()]
            assert all(set(row) == {'start', 'end', 'text'} for row in rows)
            assert all(isinstance(row['text'], str) and
                       0 <= row['start'] <= row['end'] <= bound for row in rows), rows
            if speech:
                assert any(re.search(r'[A-Za-z]{3}', row['text'].replace('[BLANK_AUDIO]', '')) for row in rows), rows
        elif fmt == 'srt':
            for h, m, s, ms in re.findall(r'(\d+):(\d+):(\d+),(\d+)', text):
                stamp = ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(ms)
                assert 0 <= stamp <= bound, (stamp, bound)
            if speech:
                assert '-->' in text and re.search(r'[A-Za-z]{3}', text)
        elif speech:
            assert re.search(r'[A-Za-z]{3}', text)

    for gpu in (0, 1):
        for kind, source, bound in [('speech', audio, duration), ('silence', silence, 5000)]:
            for fmt in ('json', 'text', 'srt'):
                label = f'{"metal" if gpu else "cpu"}-{kind}-{fmt}'
                target = out / f'{label}.{fmt}'
                r = run(label, command(source, target, gpu, fmt))
                validate(target, fmt, bound, kind == 'speech')
                if gpu:
                    assert re.search(r'whisper_backend_init_gpu: using MTL\d+ backend', r.stderr), 'No active Metal backend evidence'
            label = f'{"metal" if gpu else "cpu"}-{kind}-vad'
            target = out / f'{label}.json'
            run(label, command(source, target, gpu, extra=f':vad_model={vad}', queue=3))
            validate(target, 'json', bound, kind == 'speech')

    target = out / 'cpu-speech-short-queue.json'
    run('cpu-speech-short-queue', command(audio, target, queue=3))
    validate(target, 'json', duration, True)
    for label, invalid in [('missing-model', out / 'missing-model.bin'),
                           ('malformed-model', out / 'malformed-model.bin')]:
        if label == 'malformed-model':
            invalid.write_bytes(b'not a whisper model')
        cmd = command(audio, out / f'{label}.json')
        cmd[cmd.index('-af') + 1] = cmd[cmd.index('-af') + 1].replace(str(model), str(invalid))
        r = run(label, cmd, False)
        assert 'Failed to initialize whisper context' in r.stderr

    r = run('output-directory', command(audio, out), False)
    assert 'Error' in r.stderr or 'error' in r.stderr
    # /dev/full does not exist on macOS. A file-size limit with SIGXFSZ ignored
    # forces a real AVIO write/flush failure after destination open succeeds.
    import resource
    def limited_file():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))
    cmd = command(audio, out / 'limited.json')
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180, preexec_fn=limited_file)
    (out / 'output-file-limit.log').write_text(r.stderr)
    assert r.returncode > 0 and 'File too large' in r.stderr, r.stderr[-2000:]
    results.append({'case': 'output-file-limit', 'command': cmd, 'returncode': r.returncode})
    print('PASS: output-file-limit', flush=True)

    # Whisper destination '-' writes to stdout; close the parent's read end
    # before inference so real AVIO flush returns EPIPE, without FIFO open races.
    cmd = command(audio, '-')
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    proc.stdout.close()
    proc.stdout = None
    try:
        _, stderr = proc.communicate(timeout=180)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    (out / 'output-closed-pipe.log').write_text(stderr)
    assert proc.returncode > 0 and 'Broken pipe' in stderr, stderr[-2000:]
    results.append({'case': 'output-closed-pipe', 'command': cmd, 'returncode': proc.returncode})
    print('PASS: output-closed-pipe', flush=True)

    cmd = command(audio, out / 'cancelled.json', loop=True)
    with (out / 'cancellation.log').open('w') as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if 'run transcription at' in (out / 'cancellation.log').read_text():
                    break
                assert proc.poll() is None, 'Process ended before cancellation'
                time.sleep(0.1)
            else:
                raise AssertionError('Inference did not start before cancellation')
            proc.send_signal(signal.SIGINT)
            code = proc.wait(timeout=60)
            assert code > 0, f'Cancellation reported success/crash: {code}'
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    results.append({'case': 'cancellation', 'command': cmd, 'returncode': code})
    print('PASS: cancellation', flush=True)
    report = {'binary': {'path': str(binary), 'sha256': sha(binary)},
              'model': {'path': str(model), 'sha256': sha(model)},
              'vad_model': {'path': str(vad), 'sha256': sha(vad)},
              'audio': {'path': str(audio), 'sha256': sha(audio), 'duration_ms': duration},
              'results': results}
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(results)} real-process checks; evidence: {out}', flush=True)


if __name__ == '__main__':
    main()
