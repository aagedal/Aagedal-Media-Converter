# AAC startup and nonperiodic timestamp checks — 2026-10-17

This continues the [timestamp-history matrix](audio-playback-history-matrix-2026-10-17.md)
in an isolated dependency build. The AAC startup gap is a decoder priming bug,
not a fixed presentation delay. Source remains the default meter. These checks
do not select a presentation clock or establish audible synchronization.

## Cause and isolated correction

The pinned MPV decoder bridge enables FFmpeg's manual sample skipping. In the
generated AAC MOV, FFmpeg returns a discarded 1,024-sample priming frame at
−0.021333 seconds with an explicit 1,024-sample skip budget. MPV drops that frame
before reading its skip side data. The next frame starts at zero without skip
side data; MPV's initial codec-delay fallback then skips another 1,024 samples.
The original history consequently begins at 0.021333 seconds.

The [supplemental patch](dependency-patches/mpv-0.41.0-aac-discard-priming.patch)
remembers an explicit positive initial skip budget before discarding the frame,
marks initial preroll handled and consumes pending skip against every discarded
frame's samples. A residual budget survives for subsequent frames. Missing,
zero and undersized initial side data preserve existing fallback behavior;
later side data does not reinitialize initial priming. Seek reset still clears
both skip and preroll state. Independent review caught and corrected an initial
implementation that consumed only the first of multiple discarded frames.

The [native decoder diagnostic](provenance/audio-meter-aac-priming-2026-10-17/native-decoder.json)
records actual packet/frame flags, skip data and codec delay from the pinned
static frameworks, with its [source](provenance/audio-meter-aac-priming-2026-10-17/native-decoder-probe.c).
The portable regression compiles the patch's actual bookkeeping block under
ASan/UBSan; it does not replace full decoder integration testing.

The [prototype builder](../scripts/prototype-mpv-meter-history.py) stages both
`f_lavfi.c` and `ad_lavc.c`, requires their exact original hashes and replaces
only their corresponding members in an isolated thin archive. Original source
and products are unchanged. Both arm64 and x86_64 candidates build. Diagnostic probe compilation uses
`-Wall -Wextra -Werror`; the staged dependency translation units retain their
recorded upstream compiler flags. Retained build records include decoder source/patch,
compile command and probe hashes. This is not a clean dependency rebuild or a
redistributable package; the app/package pin and notices remain unchanged.

## Stronger signal oracle

New captures record `signal_version: 2`. The 30-second left-channel tone uses
300 distinct 100 ms amplitude levels, permuted by `(137 * index + 53) % 300`.
Sorted levels differ by approximately 0.103 dB, more than twice the 0.05 dB oracle
tolerance. The right channel retains independently located 1 ms impulses at odd
seconds. The fixture has no repeated tone-level cycle within its duration.

The oracle independently decodes each MOV and compares both per-channel sample
peak and RMS over each received frame's recorded sample interval. AAC uses its
reconstructed samples. Regressions reject the previous four-second alias and
other whole-window offsets, missing RMS and wrong energy with a matching peak.
Peak/RMS agreement still cannot exclude every sub-window timestamp error.
Delayed fixtures must actually decode from 750 ms; polling stalls retain the
previous complete-recovery/overflow criteria. Initial coverage remains exact
within one sample plus timestamp serialization rounding.

Reports without a signal version retain the original periodic peak-only oracle.
A complete legacy CLI reanalysis reproduces six passing lossless cases and the
two original failing AAC startup cases. Existing retained evidence is unchanged.

## Verification and remaining work

The [baseline null matrix](provenance/audio-meter-aac-startup-matrix-2026-10-17/baseline-null/report.json)
reproduces the startup failure in both AAC cases while all six lossless cases
pass. All received frames match the stronger peak/RMS oracle, including the
frames after the omitted AAC prefix. No timestamp correction or startup
tolerance relaxation is applied.

All 24 final arm64 cases pass the [fixed matrix](provenance/audio-meter-aac-startup-matrix-2026-10-17/fixed/report.json):
lossless, delayed and AAC video-on/off under null, CoreAudio and AVFoundation,
plus short/long polling stalls on each output. Each case checks 168–213 unique
frames against independent peak/RMS samples. All six AAC combinations begin at
zero; every delayed case begins at 750 ms. No rejected/invalid records or
adjacent-sequence timestamp discontinuities appear. Four-second stalls recover
all sequences and expected impulses. Fourteen-second stalls lose 12 records
under null/CoreAudio and 17 under AVFoundation, localized to withheld reads,
with continuous history afterward. These overflow passes explicitly include
missing measurement coverage. Final CLI reanalysis passes all 24 cases.

The separate [x86_64 AAC/video run](provenance/audio-meter-aac-priming-2026-10-17/report-x86_64.json)
passes every check: 183 frames spanning 0–18.3 seconds with matching peak/RMS.
This uses Rosetta on Apple Silicon, not physical Intel hardware. The
[arm64 lifecycle regressions](provenance/audio-meter-aac-priming-2026-10-17/report-lifecycle-arm64.json)
cover lossless and AAC with video, pause/resume, seek, a requested/player-observed
1.5× speed and filter reinsertion. Frame speed remains 1; propagation of playback
speed to the measurement boundary is unverified. Both finish successfully without
invalid/rejected frames, received
sequence gaps or adjacent-frame continuity failures. Unknown reset boundaries
and final coverage remain uncertified; reset attribution remains heuristic.

All 154 Python script tests pass with local endpoint access, including 47 focused
MPV tests and the portable sanitizer checks. The initial sandboxed full run's
four existing MCP endpoint failures pass with the required access. Legacy CLI
reanalysis intentionally exits nonzero for its two retained AAC failures. No
Swift or app behavior changed, so the app build/UI suite was not rerun.

Application-renderer integration, lifecycle acknowledgments/source replacement,
presentation-clock selection, future-frame buffering, continuous loudness
readiness/reset, longer Release CPU/thermal checks and physical loopback/device
synchronization remain open. The isolated fix must go through full dependency
packaging/provenance and application qualification before adoption.
