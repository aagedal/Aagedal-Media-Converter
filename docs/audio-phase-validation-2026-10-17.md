# Stereo phase and mono compatibility validation — 2026-10-17

## Behavior and scope

Audio Analysis → Stereo Phase supports one stereo track or two distinct mono
tracks. It shows source correlation, mono fold-down delta, mid/side RMS,
a complete-source mid/side density display, correlation history and paused window
navigation. Versioned JSON retains the captured roles, completion time, native
sample rate, every window, raw energy sums, derived measurements and density bins.
The [report format](audio-phase-report-format.md) defines the method and limits.
Separate EBU R128 loudness behavior is unchanged. No dependencies, bundled binaries
or licenses changed.

## Service and report regressions

All 23 focused phase/grouped-peak tests pass, comprising 13 new phase tests and
10 existing grouped-peak regressions. Generated signals cover:

- Identical polarity, exact inversion, quadrature, a known phase offset,
  wholly silent audio and one silent channel.
- 44.1/48/96 kHz source rates, common delayed starts, 4,800-sample windows and
  exact one-sample tails with no padding or rate conversion.
- Reversed mono-pair roles and preserved channel energy; unequal rates and
  decoded lengths; rejection of mono/multichannel tracks and concealed gaps.
- Arbitrary stdout/stderr chunk boundaries, malformed/truncated reports,
  nonfinite samples, excessive window counts and extreme timestamp overflow.
- Cancelled runner cleanup, nonzero decoder exit despite complete-looking output,
  and an internally complete combined decode that drops one preflight sample.
- Density orientation for matching/inverted/one-sided samples, silent-center
  counts, fixed coordinates and edge-clamping counts including EOF.
- Complete JSON, explicit null/infinity semantics, role order, original analysis
  time, repeated atomic saves, destination errors and invalid timeline/energy/
  totals/density rejection.

The grouped preflight now returns its immutable validated timing summary. Existing
callers may discard it; phase scanning uses it to reject any combined-stream tail
loss even if the output's own timestamps and sample counts agree internally.
An initial focused run exposed exact-equality assertions differing by about
2 × 10⁻¹⁶; corrected floating-point tolerances pass. The service also rejects an
extreme Int64 source-timestamp overflow rather than trapping.

## Build and UI validation

Ad-hoc-signed Debug app/test builds pass with Xcode 27. Initial sandboxed package
resolution could not write compiler/package caches; permitted builds pass. Source
registration was corrected before the first successful build. No shared XCTest
services or unrelated applications were restarted.

The initial English UI check passes, including native save cancellation, JSON
save/readback, paused source navigation, mono-pair selection/validation, duplicate
rejection and result/export invalidation. The initial Norwegian run reached the
paused navigation assertion but expected the English Play label; the assertion
now checks the existing Norwegian label, “Spill av”.

Both final rebuilt English/Norwegian UI checks pass in
`/private/tmp/amc-phase-final-all.xcresult`, alongside the complete unit suite.
The earlier focused result, `/private/tmp/amc-phase-final-focused.xcresult`,
also passes all 23 phase/grouped-peak checks and both bilingual UI checks.
The tests verify source and mono-pair analysis, duplicate-role rejection, result
invalidation, paused navigation and real schema-v1 JSON save/readback with matching
and inverted windows. All four [stereo English](images/audio-phase-stereo-en.png),
[mono pair English](images/audio-phase-mono-pair-en.png),
[stereo Norwegian](images/audio-phase-stereo-nb.png) and
[mono pair Norwegian](images/audio-phase-mono-pair-nb.png) captures were visually
inspected. Controls, readings, density display, chart and scrollable intervals fit.
An initial English paused preview after regrouping showed the existing intermittent
MPEG-4 artifact. The final UI tests also navigate to a grouped window boundary,
and both final grouped captures show correct video. These checks qualify source
analysis and navigation, not frame-accurate video reconfiguration.

All seven localization-script tests and the 1,917-entry catalog audit pass.
The final rebuilt full unit suite executes 1,415 tests with zero failures and
one intentional opt-in benchmark skip in `/private/tmp/amc-phase-final-all.xcresult`.
The earlier complete unit run also passes in `/private/tmp/amc-phase-full-unit.xcresult`.
Final review also confirms that mono-only files omit the unavailable stereo-track
choice and export accepts the same positive native sample rates as the scanner.

## Practical limits

Source window timing does not qualify physical-device playback alignment.
The whole-source phase display is a fixed-density summary, not a live oscilloscope.
Coarse-clock container timestamps can fail conservatively after reframing;
sub-millisecond discontinuities can fit the raw timestamp tolerance. Measurements
are unweighted advisory checks, not frequency-dependent phase analysis or a
subjective loudness prediction. The complete-source average can hide local
cancellation, so the report retains all windows.

Release/device and sandbox enforcement qualification remain open; the project
currently disables App Sandbox in both configurations. Translations outside
English/Norwegian await language review.


## Paused preview continuation — 2026-10-18

A later native decoded-pixel test independently reproduces the MPEG-4 artifact
noted above (0.410028 normalized RGB error after a mono-pair selection). The shared
MPV selection lifecycle now waits for an exact scheduled refresh and decoded
restart while preserving pause, current/newer seek targets and source ownership.
The first corrected run preserves identical image pixels across all four
mono-pair/5.1/single-track/reselection transitions. See the
[current method and validation](AUDIO-METERING-PLAN.md#paused-grouped-preview-refresh--2026-10-18).
All four final native UI checks pass in
`/private/tmp/amc-regrouping-final-ui.xcresult`, including grouped peak, grouped
silence and stereo phase. This does not qualify physical audio/video synchronization.
