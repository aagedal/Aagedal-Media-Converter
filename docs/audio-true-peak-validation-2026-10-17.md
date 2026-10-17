# Estimated true-peak marker validation — 2026-10-17

## Behavior

Audio Analysis → Peaks and Channel Balance now offers estimated true-peak markers
in dBTP, with continuous 4× interpolation, per-channel maxima, paused interval
navigation and complete schema-v3 JSON. Original dBFS sample peaks, whole-track
unweighted RMS and channel balance remain in the report. Single-track, reordered
mono-pair and 5.1 selections share the captured source-channel mapping.

The [schema and measurement method](audio-peak-report-format.md#version-3-estimated-true-peak-markers)
record the source/measurement rates, window size, edge context, threshold and
estimation limitations. This is not certified BS.1770 conformance. Separate EBU
R128 loudness behavior is unchanged. No dependencies, binaries or licenses changed.

## Focused checks

All 53 final focused tests pass: 25 peak-analysis/report, 10 grouped peak and 18
silence-analysis/report tests. Generated-media checks include:

- Phase-offset quarter-rate sine waves whose sample maxima fall below the
  threshold while reconstructed peaks exceed it, at 44.1/48/96/192 kHz.
- Quiet windows following loud windows, asymmetric stereo and unchanged source
  sample/RMS values.
- Delayed audio with 1, 17 and 4,801 decoded samples and exact source EOF retention.
- Reordered two-track and six-track mono assignments with preserved levels/roles.
- A 100 ms decoded gap inside a single 960-sample window, rejected before reframing
  can conceal the gap.
- Interpolation failure and cancellation after successful validation/source passes,
  requiring cleanup and no partial report.
- Complete schema-v3 export/roundtrip and malformed rate/channel/threshold/time/
  nonfinite-measurement rejection. Existing schema-v1/v2 exports still pass.

Log: `/private/tmp/amc-truepeak-direct-focused.log`.
The direct XCTest fallback used the final fresh-built app's test bundle and
frameworks, with process-only `-ffmpegBinarySource custom -customFFmpegPath` pointing
to this checkout's bundled FFmpeg. It changed no persistent preferences.

## UI and visual checks

Both new UI tests pass in `/private/tmp/amc-truepeak-ui-retry.xcresult`:
`testEstimatedTruePeakNavigationExportAndSettingsInvalidation` and
`testEstimatedTruePeakNorwegianControlsAndReport`.
They select estimated peaks, scan, navigate both interval boundaries, verify
settings/measurement changes invalidate export, and return to sample-only analysis.
The English test saves JSON through the native panel and reads back schema 3,
dBTP semantics, thresholds, complete true-peak intervals and retained source fields.

Both [English](images/audio-true-peaks-en.png) and
[Norwegian](images/audio-true-peaks-nb.png) captures were visually inspected.
Controls, units, channel rows, interval navigation and preview/timeline are readable.
Six-channel service routing is covered by generated-media tests; new six-channel
true-peak UI scrolling was not independently captured in this batch.

## Build and test infrastructure

Ad-hoc-signed Debug builds and fresh `build-for-testing` pass. Initial package
resolution required permitted network/cache access. The first focused run caught
a test assertion comparing exported measurements to the top-level presentation;
the corrected assertion accounts for the established separate context field.
The 49 focused tests then passed before the final timing refinement. Independent
review reproduced the hidden-gap issue and confirmed the symmetric-padding fix;
the final 53-test run includes both refinements.

The initial UI launch and subsequent full-unit attempt stalled in XCTest session
setup with `XPC connection for control was invalidated`. Those task-owned attempts
were interrupted; no shared test service or unrelated process was restarted.
Direct XCTest supplied focused verification while fresh products were prepared.
The fresh UI retry passed. Normal full-suite validation from those products then
passed all 1,402 unit tests with zero failures and one intentional opt-in benchmark
skip, in `/private/tmp/amc-truepeak-final-unit.xcresult`. Screenshot export also
required permitted access to xcresulttool's cache.

Seven localization-script tests and the 1,898-entry catalog audit pass. Translations
outside English/Norwegian await review. Release/device and sandbox enforcement
qualification remain open; the project currently disables App Sandbox in both
configurations. Physical playback alignment is separate from source marker timing.
