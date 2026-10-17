# AV2 encoder branch evaluation — 2026-10-14

Follow-up: the [integrated encoder implementation](av2-integrated-encoder-2026-10-14.md)
combines this branch with all pinned main fixes and replaces the bundled tools.
The measurements below describe the original unmodified branch.

`av2-enc` is an upstream AVM development branch, not a separate executable:
it still builds `avmenc` and `avmdec`. The app's current Y4M pipe and POC progress
contract work with it. The branch is a promising optional encoder backend, but
these experiments do not justify replacing the bundled reference tools yet.

## Source and build

Upstream references were checked with `git ls-remote` on October 14:

- `main`: `0da4c36474f8d1952bbc54e3ccf833d5f0d2280c` (currently bundled).
- `av2-enc`: `b38429d1ea69a3d0e17d4b8ae2495ff0b30b40a0`.
- Merge base: `8e89428e47563ebab09cf2cbbb4420709a0dc99a`.

Source: https://github.com/AOMediaCodec/avm/tree/av2-enc.
The retained candidate build from the previous update was reused, with a clean
tracked source tree. It is arm64 Release, targets macOS 14, and uses Apple
`/usr/bin/cc` and `/usr/bin/c++`. No binaries, licenses, app settings, or
release manifests were changed by this evaluation.

To rebuild the candidate separately (the existing `build-avm-tools.sh` remains
pinned to the shipping `main` revision):

```sh
git clone https://github.com/AOMediaCodec/avm.git /tmp/avm-encoder-evaluation
git -C /tmp/avm-encoder-evaluation checkout --detach b38429d1ea69a3d0e17d4b8ae2495ff0b30b40a0
cmake -S /tmp/avm-encoder-evaluation -B /tmp/avm-encoder-evaluation/build_arm64 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF
cmake --build /tmp/avm-encoder-evaluation/build_arm64 --target avmenc avmdec -j 8
```

## Repeatable comparisons

New `scripts/benchmark-av2-enc.py` compares bundled `main` with candidate good
quality, low-complexity level 2, and realtime modes. It records tool hashes and
version output, exact arguments, source hash, wall time, output size, PSNR,
SSIM, and decode times. Every output must decode with **both** decoders to
identical Y4M, with the expected dimensions, bit depth and frame count. Each
encoder must emit the POC markers used by the app's progress parser.

Runs are sequential; `--repeats` alternates variant order on successive runs.
Reports are checkpointed after each completed case and record failures. A run
directory cannot be reused, protecting previous results from accidental overwrite.

```sh
python3 scripts/benchmark-av2-enc.py \
  --baseline-dir 'Aagedal Media Converter/Binaries' \
  --candidate-dir /tmp/avm-encoder-evaluation/build_arm64 \
  --output-dir /tmp/av2-encoder-comparison \
  --width 640 --height 360 --frames 8 --qp 160 200
```

For representative footage, add `--input /path/to/clip.mov`, increase the frame
count, and repeat at several QPs. The supplied input is scaled to the requested
dimensions and resampled to `--fps` (default 24). Use matching aspect ratios.
Default synthetic `testsrc2` motion is useful for compatibility checks, but
does not represent natural textures, camera noise, scene changes or HDR. The
10-bit synthetic input is converted from the generator's 8-bit pattern; it
exercises the 10-bit pipeline, not native 10-bit source fidelity.

All cases use CQ, cpu-used 9, two threads, no tiles and lag 0, matching the
app's Matroska requirement of one IVF record per displayed frame. They do not
measure the app's parallel chunks, tile auto-selection, VBR or lagged IVF.
The existing `validate-av2-tools.py` separately exercises VBR, chunk assembly
and Matroska/audio compatibility; see the previous update's results.

## Findings

On the 8-frame 640×360 8-bit synthetic sample at QP 160, normal `av2-enc`
took 15.230 seconds versus 71.671 seconds for `main` (4.71× faster). Its IVF
was 12,921 versus 15,351 bytes. PSNR was 40.840 versus 41.007 dB, and SSIM
was 0.989935 versus 0.990431. At QP 200, the speedup was 2.64×, with PSNR
34.752 versus 36.023 dB and smaller output again. Equal QP does not mean equal
quality or bitrate; these points are not a rate-distortion comparison.

On the 4-frame 1280×720 10-bit sample at QP 160, normal candidate mode took
27.424 seconds versus 114.340 seconds (4.17× faster). IVF sizes were almost
equal: 19,198 versus 19,161 bytes. PSNR was 41.261 versus 41.442 dB and SSIM
was 0.991473 versus 0.991924. These very short samples include a keyframe and
do not establish sustained throughput on longer footage. The first 720p run
was interrupted when the machine stopped; its timings were discarded and the
entire comparison restarted in a fresh directory.

Low-complexity level 2 only slightly reduced encode time on the 360p sample and
produced larger files with lower PSNR/SSIM than normal candidate mode. Decode
times were very short and include process startup; repeated longer samples are
needed before making a decoder-performance claim.

Realtime mode took 0.205 seconds at QP 160, but produced 39,912 bytes versus
12,921 bytes for candidate good quality. Its higher reconstructed quality and
larger size show that QP behaves differently across modes. It should be exposed
as a separate operating mode only after quality-matched bitrate comparisons,
not silently substituted for ordinary AV2 exports. Low-complexity decode is
supported only in good-quality mode upstream and must not be combined with RT.

## Integration recommendation

Keep the bundled `main` decoder and current default encoder for now. The
candidate branch lacks main-only fixes including `0da4c3647` (filter pointer
handling), `3c7086bfd` (maximum symbol count), `732ed4e6a` (layer-ID validation),
`59e14d0b2` (partial-superblock partition trees), and recent ARM optimizations.
A newer branch timestamp does not imply these fixes are present.

Before offering the candidate in Settings, evaluate a revision incorporating
those fixes, run natural HD/4K clips across several quality points and scene
changes, and repeat the container/audio and backward-decoding suite. A separate
bundled candidate encoder would need its own pinned source/build provenance,
notices, source companion and signing. The backend choice must be captured in
`AV2Settings` so queued and shared conversions retain their chosen behavior.

## Evidence and validation

Full per-case measurements, commands, tool hashes and source hashes are saved
in [the evaluation provenance directory](provenance/av2-enc-2026-10-14/).
All 12 cases passed dual-decoder reconstruction, geometry/depth/frame-count
and progress-marker checks: eight 360p/8-bit cases and four 720p/10-bit cases.
`branch-audit.json` records the build configuration and all main-only commits.
The benchmark's working directories also retain encoded clips, reconstructed
Y4M and FFmpeg/AVM logs under `/private/tmp/amc-av2-enc-360-evaluation` and
`/private/tmp/amc-av2-enc-720-10bit-evaluation-restart` until temporary files
are cleaned up.

Additional script checks covered finite/infinite PSNR, SSIM and missing-metric
parsing; failed-run reporting; rejection of odd dimensions; and preserving an
existing report when its output directory is reused. Syntax and JSON evidence
were checked as well.

This change adds evaluation tooling and evidence only. App build and XCTest
were not rerun because no Swift, project or bundled-tool files changed.
