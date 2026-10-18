# Isolated lifecycle/source-replacement evidence

See the [validation record](../../audio-playback-lifecycle-validation-2026-10-18.md)
for acceptance criteria and limits. No app integration or audible alignment is
qualified. Source remains the default meter.

- `arm64-null/`: final lossless/AAC null-output captures and report.
- `arm64-hardware/`: final lossless/AAC CoreAudio/AVFoundation captures and report,
  obtained with login-session audio access after sandboxed initialization failed.
- `x86_64-null/`: final lossless/AAC captures through Rosetta.
- `build-arm64.json` and `build-x86_64.json`: isolated builder compile/link
  commands and hashes for pinned source, patches, input library and probe.
- `track-null-arm64.jsonl.xz` and `report-track-arm64.json`: separate two-track
  selection plus source-replacement capture, fixture/probe command and hashes,
  lifecycle checks and independent original/second-track/replacement signal checks.

The matrix reports preserve compressed-capture hashes, fixture/tool/build-record
hashes, original commands, probe exit/stderr, current analyzer hashes and full
acceptance results. All eight matrix cases and the additional track case pass.
Signals are the existing nonperiodic version-2 fixtures. The matrix runner records
per-generation peak/RMS checks; the separate track report additionally splits
generation zero at the explicit track-change action. Its fixture command muxes
lossless video/audio plus delayed PCM as a second audio track with stream copy.

Generated fixtures, independent raw reference samples, executables and copied
frameworks remain outside the repository. Reanalysis requires those files and
the exact recorded tools/build inputs; verify their hashes first. The standard
runner's `--reanalyze` performs those checks and records the current analysis
source hashes, which may differ from an earlier analysis. Both builds replace
only isolated archive members and are not distributable packages. Video uses
`vo=null`; outputs are muted. Physical-device timing, Intel hardware, app-renderer
integration and loudness accumulator reset behavior remain unverified.
