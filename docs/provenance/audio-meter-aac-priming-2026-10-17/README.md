# Isolated AAC priming regression

The pinned native AAC decoder emits a discarded 1,024-sample frame at PTS
−1,024, with explicit skip side data of 1,024 samples and codec delay 1,024.
The following decoded frame starts at zero and has no skip side data.
`native-decoder.json` records the exact static-framework compile/run, source,
fixture and executable hashes and output; `native-decoder-probe.c` is its source.
The probe sets manual skip handling as MPV's decoder bridge does.

The original `audio/decode/ad_lavc.c` discards that first frame before reading
its side data or completing initial preroll bookkeeping. Its next frame then
falls back to the codec delay and drops the first valid 1,024 samples.
The supplemental patch accounts for explicit initial skip data before discarding
that frame and consumes outstanding skip budgets on every discarded frame.
Its portable sanitizer regression includes a skip budget spanning two discarded
frames, missing/short/zero side data, later discard, and ordinary frames.

The arm64 and x86_64 build records retain both staged translation-unit commands
and source/patch hashes. The builder replaces two exact members in an isolated
copied archive; original sources, products, package pins and app behavior remain
unchanged. These are diagnostic builds, not distributable dependency packages.

`report-x86_64.json` and its original xz-compressed capture retain a successful
Rosetta null-output run of the nonperiodic AAC fixture with video selected using
`vo=null`. All startup, coverage, continuity, and per-channel peak/RMS oracle
checks pass. The first received interval starts at zero. The reference is decoded
with the bundled FFmpeg and explicitly recorded ffprobe. This checks media sample
identity at the filter boundary; presentation/device synchronization remains
unqualified. Parent matrix evidence provides the matched arm64 cases.
