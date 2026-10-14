# Integrated AV2 encoder and main fixes — 2026-10-14

The bundled `avmenc` and `avmdec` now use a reviewed local merge of upstream
`av2-enc` and `main`. Normal good-quality encoding remains the default; saved
quality, speed, threading, chunking, bit-depth, container and audio settings
retain their meanings in the app. Realtime and low-complexity modes are not
enabled automatically.

This supersedes the decision to keep the unmodified reference encoder in the
[initial evaluation](av2-enc-evaluation-2026-10-14.md). That evaluation measured
the encoder branch before integration; its timings must not be presented as
measurements of this merged build.

## Pinned sources and merge review

- Encoder parent: `b38429d1ea69a3d0e17d4b8ae2495ff0b30b40a0`.
- Main parent: `0da4c36474f8d1952bbc54e3ccf833d5f0d2280c`.
- Integrated commit: `14342caad234d23f717dfd058fc17bcfb502a244`.
- Tool version: `1.0.0-445-g14342caad`.

The integrated commit is local to this application, not an upstream release.
Both upstream parents are ancestors of it. The full resolved patch, merged
tree hash, commit identity and parent revisions are retained in
[`provenance/avm-2026-10-14-integrated/`](provenance/avm-2026-10-14-integrated/).

All 14 commits present only on main are included: filter pointer handling,
symbol-count calculation, layer-ID validation, partial-superblock partition
trees, subsampling rounding, memory-extension fixes and ARM transform/neighbor
optimizations, plus the accompanying tests and development-tool changes.

Merge conflicts were resolved as follows:

- Retain the encoder branch's vectorized trellis loop and main's separate NEON
  neighbor-update implementation, registering both in the runtime dispatcher.
- Retain main's optimized C best-path implementation and removal of its obsolete
  AVX2 dispatcher, while keeping the branch's separate AVX2 trellis-loop path.
- Include main's new forward-transform NEON files. Adapt their transform-type
  field to the branch's `PRIMARY_TX_TYPE` representation and remove the 64-point
  dispatch case absent from the branch's C implementation and transform sizes.
- Preserve both sets of secondary-transform tests, renaming the branch's test
  classes to avoid duplicate GoogleTest suite identities. Adapt main's forward
  pipeline tests to the branch's transform parameter representation.

## Reproduction and source companion

From a clean upstream clone containing both parent commits:

```sh
git clone https://github.com/AOMediaCodec/avm.git /tmp/avm-integrated
python3 scripts/prepare-avm-source.py /tmp/avm-integrated
bash scripts/build-avm-tools.sh /tmp/avm-integrated /tmp/avm-integrated/build_arm64
```

The preparation script verifies the patch, reconstructs the reviewed tree, and
recreates the exact commit with fixed metadata. It was exercised against a
separate clean clone and reproduced the pinned commit exactly.

The build recipe produces arm64 Release tools targeting macOS 14. The app
requires macOS 15. Both tools retain TensorFlow Lite, WebM and multithreading;
runtime links remain CoreFoundation, libSystem and libc++. Build configuration,
compiler identity, version header, link commands and binary hashes are retained.

`scripts/package-avm-source.py` creates the complete integrated source companion
at `build/attribution/avm-2026-10-14-integrated-source.tar.gz`, including dependency
archives, the exact patch and manifest, source preparation script, offline build
recipe, revision marker and generated version header. Its size and hash are
recorded in `AttributionSources.json`. This ignored archive must accompany
release source artifacts.

An offline rebuild from that archive succeeded, retained the exact version
string, and passed encoder and decoder smoke checks. Its decoder reconstructed
the tested 10-bit stream identically. Rebuild hashes are recorded separately;
byte-for-byte binary reproduction is not claimed.

The Eigen companion was regenerated with the same hash. All 1,744 historical
compiler-referenced dependency inputs match byte-for-byte, with no additional
or missing dependency inputs in the shipping build. Existing 277 file-level
notices therefore remain applicable; `Licenses/avm-LICENSE.txt` now identifies
the integrated commit. Historical reference-build evidence remains in place.

The bundled helpers carry ad-hoc hardened-runtime signatures, verified with
`codesign --verify --strict`. The existing Xcode helper-signing phase applies
the configured distribution identity when packaging a signed app. These local
signatures do not establish Developer ID signing or notarization.

## Validation

At the app's default QP 110 and cpu-used 9, the final integrated build encoded
the 8-frame 640×360 8-bit synthetic clip in 25.983 seconds versus 84.941 seconds
for the reference build (3.27× faster). Both runs used two threads, lag 0 and no
tiles, sequentially after compilation finished. IVF sizes were 28,550 versus
32,650 bytes; PSNR was 51.990 versus 52.719 dB and SSIM 0.998818 versus 0.999004.
Both decoders reconstructed each stream identically. Equal QP is not equal
quality or bitrate, and this short synthetic sample does not establish
sustained real-world throughput. Exact commands and tool hashes are in
`benchmark.json` in the integration provenance directory.

- 10,391 selected upstream transform, trellis and assertion tests passed.
- All 13 selected encoder/decoder API and small-dimension tests passed, including
  odd dimensions, multithreaded narrow/short frames, speed 0 and the 1×1 reproducer.
- CQ and VBR stdin encoding passed at 8 and 10 bits, with POC progress markers.
- The integrated decoder reconstructs June reference-encoder files identically
  to the previous decoder at both depths.
- Lagged IVF, independently encoded chunk concatenation, timestamp/keyframe
  checks, the CodecPrivate probe and app-muxed Matroska video/audio passed.
- The final bundled decoder's stdout piped into FFmpeg preserved all 12 native
  10-bit frames and their dimensions without forcing a pixel format.
- All 32 dependency/source-manifest and evidence regression tests passed.
- The Release app build passed. Both packaged helper hashes exactly match the
  checked-in binaries, and their strict signature verification passed.
- All 1,304 app unit tests passed with no failures or skips.

Manual Release-app inspection confirmed launch and AV2 Matroska import, with
128×96 / 24 fps queue metadata and an audio waveform in the trim sheet. AV2
video preview remains unsupported; this Matroska fixture showed a blank video
surface. The manual app conversion check could not be completed because the
computer-use service timed out while confirming the temporary output folder
and again while attempting to dismiss the dialog. No GUI conversion success or
complete sandbox/bookmark round-trip is claimed. The separate codec/container
and native decoder-pipe checks above passed.

The upstream tests use Release library objects; the explicit reconstruction and
container checks exercise the final shipping build. Generated clips establish
compatibility on the tested cases, not comprehensive AV2 conformance or quality.

The missing release source inputs were subsequently restored from reviewed
archives in an existing local checkout. All 89 restored archives match the
unchanged manifest's sizes and SHA-256 hashes. Both the complete 91-archive
source check and the strict dependency/license gate now pass. The release source
companion was built and its copied archive bytes verified. Its name, size and
SHA-256 are recorded in `release-attribution.json` in the integration provenance
directory. No public release was performed.
