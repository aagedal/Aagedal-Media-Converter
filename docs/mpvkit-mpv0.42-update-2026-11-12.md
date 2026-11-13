# MPVKit mpv 0.42 update — 2026-11-12

Media Converter now pins the aagedal MPVKit fork at
`1802ca65fd03742c664f049a66fb714eba1d61f9` (release
[`aagedal-1.1.0-n9.0.2-mpv0.42.1`](https://github.com/aagedal/MPVKit/releases/tag/aagedal-1.1.0-n9.0.2-mpv0.42.1)),
replacing `d2680851a5a56dafb6be8df79989d69817dac891` (`history.1`).

## Change

- **mpv 0.42.0** with the fork's patches 0001–0011, including the meter
  history (0010) and AAC priming (0011) patches the Playback meter relies on.
- **Apple Silicon only.** The app already excludes x86_64.
- **All nine GPL frameworks rebuilt** from the same FFmpeg n9.0.2 source, now
  with every decoder/demuxer, x264, the editor filters/muxers and a new
  `Libx264-GPL` target linked into the app.
- **Libplacebo 7.387.0** from `aagedal/libplacebo-build` (was `mpvkit` 7.360.1).

mpv 0.42's breaking changes do not affect the app: it never reads `time-start`,
sets `hwdec=videotoolbox` explicitly instead of `auto-safe`, and does not use
`aagedal-scopes`. `--tls-verify` is now on, which matters for yt-dlp clip
previews streamed over HTTPS. FFmpeg uses GnuTLS here, and a temporary test
through the app's libmpv confirmed it finds the macOS trust store: Apple's HLS
sample and a GitHub file load, and `expired.badssl.com` is rejected with "Peer
certificate failed verification".
Every option, property and command name the app passes to libmpv is present in
the 0.42 binary. `ytdl=no` was already rejected by the Lua-free 0.41 build and
still is; it has no effect.

## Verification

- `scripts/ci-local.sh --release` passes: manifest, script tests (183),
  localization audit, Debug build, unit tests (1,825: 1,822 passed, 3 skipped
  for opt-in benchmark/fixtures, 106 of them MPV, meter and audio routing
  tests), Release build and the arm64 bundle check (61 Mach-O images).
- MPV UI tests pass: preview seek/screenshot/reopen (3 of 3 on a quiet machine),
  stitching sequence playback/replay and pause/dismiss during loading, cold seek
  and rapid scrub, Source/Playback meters, Playback meter history timing and
  audio regrouping pixels. One earlier run of the preview test failed while
  another session's Aagedal Media Player test suite was launching its app on the
  same Mac; it did not recur once that run had finished.
- `bundled-dependency-manifest.py --check --require-complete-licenses` and
  `package-attribution-sources.py --check` pass with all 88 archives present.

## Sources

New archives (git-ignored, under `build/attribution/mpvkit/`):

- `mpvkit-n9.0.2-mpv0.42.1-sources.tar.gz` — the release source archive
  (patched mpv, FFmpeg and x264 sources plus configurations); matches the
  release `SHA256SUMS.txt`. It replaces the resize.1 and history.1 archives.
- `MPVKit-1.1.0-mpv0.42.1-pinned-source.tar.gz` — `git archive --format=tar
  <rev> | gzip -9n` of the pinned wrapper commit. This method reproduces the
  recorded resize.1 and history.1 wrapper archives byte for byte.
- `libplacebo-7.387.0-source.tar.gz`, `libplacebo-Vulkan-Headers-74d8a6cb-source.tar.gz`
  and `libplacebo-build-aagedal-7.387.0.tar.gz` — codeload archives of libplacebo
  v7.387.0, its Vulkan-Headers submodule and the build recipe. Codeload is
  stable: repeated downloads and the recorded 7.360.1 archive reproduce. The
  other libplacebo submodules are unchanged.

## Notices

`scripts/collect-source-notices.py` collects the named license files plus
leading comment blocks with permissive grants. On libplacebo 7.360.1 it
reproduces the retained 4.4 collection exactly; on the 4.4 mpv tree it finds
the retained notices plus `af_scaletempo2_internals.h` (BSD, Chromium) and
`console.lua` (ISC), which the 4.4 collection lacked. The new collections in
`docs/provenance/4.7-local-builds/mpvkit-mpv0.42.1/` cover mpv 0.42.0, x264,
libplacebo 7.387.0 and its Vulkan-Headers (license files only, as before).
`current-targets.json` records the reviewed archive checksums of `Libmpv-GPL`,
`Libx264-GPL` and `Libplacebo`, which `generate-mpvkit-notices.py` checks.

The FFmpeg n9.0.2 collection from 4.5 is kept. A scan of the rebuilt tree finds
the same notices except for x86/MIPS assembly, checkasm test and CI files,
none of which are in the arm64 libraries.
