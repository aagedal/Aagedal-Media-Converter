# Audio metering and analysis

## First implementation

- [x] Independent source-channel sample peak and RMS readings in the preview meter.
- [x] Momentary (400 ms) and short-term (3 s) source LUFS at the playhead.
- [x] Selected-track metering, up to eight displayed channels; loudness uses the full track's original channel layout.
- [x] Bounded eight-second analysis windows, three-second pre-roll, neighboring-window cache, cancellation and security-scoped access.

The first implementation used the MPVKit CoreAudio `.2` build, which omitted
`astats` and `ebur128`.
This implementation uses the already bundled FFmpeg, independently of the
playback engine. It decodes small windows ahead and displays timestamped source
measurements at the playhead. These are source measurements, unaffected by output
volume, mute, playback speed or speaker downmixing. They are not a measurement
of the final device signal. The white peak marker and filled RMS bar cover the
same 100 ms interval. LUFS includes three seconds of pre-roll across window
boundaries and seeks; unavailable startup history is shown as a dash.
Whole-program integrated LUFS, loudness range and true peak remain in Audio
Analysis. Window-local integrated values are deliberately not presented as
program measurements. This change does not update packaged binaries or licenses.

## Opt-in MPV playback metering — 2026-10-15

The app now pins MPVKit `68c8989362a0daedabcc1540b2b5f0e1fea4be1f`
(mpv 0.41.0 / FFmpeg n9.0.2), with versioned, checksummed universal macOS GPL
artifacts and the existing CoreAudio fixes. See
[dependency validation and provenance](mpvkit-1.1.0-update-2026-10-15.md).

MPV previews offer **Source / Playback** in the meter panel. Source remains the
default, works with both preview engines, and retains playhead-aligned source
inspection. Playback inserts only the application's uniquely labelled lavfi
filter, after checking actual `astats`/`ebur128` registration in the linked
libavfilter. It decodes the active track in MPV, with no additional FFmpeg
process or capture permission. Closing/hiding the panel or selecting Source
removes that filter and cancels polling.

Playback polls at 10 Hz with at most one asynchronous metadata request pending.
It copies event-owned maps before consuming another event, rejects obsolete
responses, displays up to eight decoded channels and measures loudness on the
filter's full layout. Decoded channel numbers deliberately do not reuse source
layout labels: MPV may negotiate a different layout. Volume and mute are applied
later. Pause, seek, track changes, source replacement, stop and EOF clear the
readings and reset loudness history; momentary and short-term LUFS require 0.4 s
and 3 s of fresh continuous media history. Integrated session loudness is not
exposed.

This is an opt-in decoder meter. Metadata can lead audible output because of
buffering, and polling can miss intermediate frames/brief transients. The panel
and help explain these limits. No claim of device-signal measurement or exact
audible synchronization is made. CPU/thermal and physical-device comparisons
remain required before considering it as the default meter.

## Deferred improvements

- [x] Enable `astats` and `ebur128` in the MPVKit fork; preserve the CoreAudio initialization and failed-unit cleanup patches. Produce versioned, checksummed artifacts and update provenance, notices and the exact package pin together.
- [x] Probe actual filter availability in the packaged libavfilter and prototype `af-metadata/<label>` polling for MPV playback. Account for decoder/output buffering, channel conversion, pause, seeking, track changes and stale metadata before adopting it.
- [x] Add a repeatable software CPU and signal-transition comparison against the windowed FFmpeg path, including source lookahead and child-process CPU. See [method and evidence](audio-meter-comparison-2026-10-15.md). Native-player metering and stitching source-channel inspection remain available.
- [ ] Investigate timestamped decoder measurements and buffering before claiming playhead alignment for Playback; the generated AAC/video benchmark observed readings about 3.4 seconds ahead. Do not infer measurement time from the current playhead or apply one fixed correction across outputs. [Source/API investigation](audio-playback-timing-2026-10-16.md) identifies the missing timestamp/history transport and the dependency instrumentation needed next; alignment remains unqualified. The [isolated timestamp/history prototype](audio-playback-timestamp-prototype-2026-10-17.md) now implements bounded, sequenced dependency capture and diagnostic player-state telemetry, with arm64/x86_64 builds and matched audio-only output checks. App/video/offset/impulse benchmarks, presentation-clock buffering and loudness continuity remain open.
- [ ] Qualify Release CPU/thermal behavior and physical-device synchronization on longer representative media before considering Playback as the default.
- [ ] If useful, add running integrated playback-session LUFS, clearly distinguish it from whole-program analysis, and reset it explicitly after seeking, changing source/track or restarting the measurement.
- [x] Silence detection with navigable timeline markers and configurable thresholds/durations. Audio Analysis → Detect Silence scans a complete selected track, includes every channel, and retains file-relative timestamps for delayed audio. Threshold choices span −30 to −80 dBFS; minimum durations span 0.1–5 seconds. Intervals offer paused start/end navigation and a clickable timeline. The UI supports one track, a custom mono pair or six mono tracks assigned to 5.1 roles. Grouped scans and preview require matching sample rates and decoded start times.
- [x] Source sample-peak threshold intervals and per-channel imbalance checks, with paused preview navigation and whole-track unweighted RMS levels.
- [x] Estimated intersample true-peak threshold markers with continuous 4× oversampling, dBTP navigation and schema-v3 JSON. Source dBFS/RMS remain separate; this is not a certified BS.1770 meter. Whole-program maximum true peak remains available in the loudness report.
- [x] Stereo phase/correlation analysis for stereo tracks and custom mono pairs, with source mono fold-down checks, a bounded whole-source mid/side density display, correlation history, paused window navigation and complete schema-v1 JSON. See [measurement/report semantics](audio-phase-report-format.md).
- [x] Export complete source sample-peak/channel-balance reports as versioned JSON, including selected audio track, thresholds, every interval and whole-track per-channel levels. See [report format](audio-peak-report-format.md).
- [x] Export complete source silence reports as versioned JSON, with selected presentation, thresholds and every file-relative interval. See [report format](audio-silence-report-format.md).
- [x] Expose custom mono-pair and 5.1 selection, grouped audition and JSON export in Detect Silence. Reject duplicate/non-mono inputs and unequal decoded start times.
- [x] Extend grouped selection/audition to peak/channel-balance reports. Full decoded-timeline validation rejects unequal decoded lengths, sample rates, starts and discontinuities beyond a 1 ms rounding tolerance before grouped audition or scanning. Reordered roles, common delayed starts and one-sample final FLAC frames retain source gains/timing. Separate loudness reports retain EBU R128 channel weighting and LFE exclusion.
- [ ] Evaluate newer MPVKit/FFmpeg playback support, including ProRes RAW VideoToolbox acceleration and animated WebP. Confirm each component is actually enabled in the package and test representative files before advertising support.

## Validation

### Stereo phase and mono compatibility — 2026-10-17

Audio Analysis → Stereo Phase supports stereo tracks and distinct mono pairs.
The full source decode accumulates unweighted energy/cross-product statistics in
4,800-native-sample windows, retaining unpadded EOF and initial audio offsets.
The panel shows normalized correlation, mono fold-down delta, mid/side RMS,
a whole-source 33 × 33 mid/side density display and paused window navigation.
The density grid has fixed full-scale axes and explicit edge-clamping counts;
no gain normalization or playback timing is implied. Reports retain every window
and explicit null/cancellation semantics. Changing presentations/roles invalidates
measurements and export. The [schema and method](audio-phase-report-format.md)
record mono reference energy, whole-source aggregation, timeline tolerances,
window limits and the distinction from EBU R128/frequency-dependent phase.
No dependencies, bundled binaries or licenses changed.

The final rebuilt full unit suite executes 1,415 tests with zero failures and
one intentional opt-in benchmark skip. All 23 focused phase/grouped-peak tests
and both English/Norwegian UI checks pass; four captures were visually inspected.
Seven localization tests and the 1,917-entry catalog audit pass. See
[the phase validation record](audio-phase-validation-2026-10-17.md).
Release/device and sandbox qualification remain open; translations outside
English/Norwegian await review.

### Estimated true-peak markers — 2026-10-17

Peaks and Channel Balance now offers Sample peak / Estimated true peak. Opt-in
true-peak scans retain original source sample peaks/RMS while adding per-channel
estimated reconstructed maxima and navigable dBTP threshold windows. Single tracks,
custom mono pairs and 5.1 share the same presentation mapping. Changed measurement,
thresholds or roles invalidate results. Schema-v3 JSON retains both complete interval
sets, method/rates, ordered channels and thresholds. Sample-only schemas stay 1/2.

A complete raw decode checks timing before reframing, with the existing 1 ms
container-rounding tolerance. A separate continuous four-times-rate interpolation
pass uses bundled SWR, explicit zero extension at both edges, and trimming back to
exactly the source sample count/timeline. Subprocess EOF is drained. One-sample
clips receive context without reporting artificial padding. Reframed timing must
also be continuous within half a sample, so coarse-clock files may fail conservatively.
The [report format](audio-peak-report-format.md#version-3-estimated-true-peak-markers)
details method, edge effects, timing and scope. This is an estimated peak meter,
not certified BS.1770 conformance; separate EBU R128 behavior is unchanged.
No dependencies, bundled binaries or licenses changed.

The final full unit suite executes 1,402 tests with zero failures and one intentional
benchmark skip. All 53 final focused peak/grouped/silence tests and both bilingual UI checks pass.
The English UI test saves and reads back a real schema-v3 report. Both
[English](images/audio-true-peaks-en.png) and [Norwegian](images/audio-true-peaks-nb.png)
captures were visually inspected. Seven localization tests and the 1,898-entry
catalog audit pass. [Validation details](audio-true-peak-validation-2026-10-17.md)
record generated fixtures, timing/EOF safeguards and test-runner recovery.
Release/device and sandbox qualification remain open; translations outside
English/Norwegian await review.

### Grouped peak/channel-balance analysis — 2026-10-17

Peaks and Channel Balance now offers Audio track, Mono pair and 5.1 multi-mono
with distinct source-track assignments. The completed scan captures role order;
channel labels, grouped MPV audition and schema-v2 JSON all retain that order.
Single-track JSON remains version 1. Presentation/role changes invalidate results
and exports. The shared audition graph preserves source gains before device
conversion and returns to ordinary selection when a single track is selected.

A complete streamed decode validates every assigned mono track before grouped
audition is enabled. Scans independently repeat validation before joining. Matching
sample rates, exact initial sample timestamps and total decoded sample counts are
required. Per-frame timing allows up to 1 ms of rounding (at least one sample),
which accommodates Matroska clocks but can hide sub-millisecond discontinuities.
Unequal lengths, deliberately different starts and larger midstream gaps fail
explicitly; missing samples are never synthesized. Combined output must preserve
the validated sample count and EOF, including an unpadded one-sample final frame.
Full preparation takes longer on long files; role changes and dismissal cancel it.
Grouped analysis normalizes each mono channel label, concatenates channels with
`amerge`, then explicitly maps channel roles. Repeated time-varying six-track
fixtures exposed an intermittent `join` EOF loss: scans could omit one complete
4,800-sample window. The peak scanner's expected-sample guard rejected these
reports. The same filter issue shortened grouped silence reports at EOF; both
scanners now use the concatenation graph, with repeated regression coverage.
A shell comparison preserved all samples in 100/100 replacement-graph scans.
Separate EBU R128 loudness measurements are unchanged. No dependencies, bundled
binaries or licenses changed.

The ad-hoc-signed Debug app builds. All 46 focused peak/silence scanner/report tests pass,
including generated 44.1/48/96 kHz stereo, reordered six-channel levels, common
delayed starts, unequal lengths/offsets/rates, midstream gaps, cancellation drain,
decoder failures and a 96,001-sample six-track FLAC fixture with differing codec
block sizes and a single nonzero EOF sample. The complete unit suite executes
1,387 tests with zero failures and one intentional opt-in benchmark skip in
`/private/tmp/amc-grouped-peaks-final-full.xcresult`. The focused result is
`/private/tmp/amc-grouped-peaks-merge-confirmed.xcresult`.

Both final English/Norwegian grouped UI checks pass in
`/private/tmp/amc-grouped-peaks-ui-verified.xcresult`, covering stereo and 5.1
selection, duplicate rejection, paused interval navigation, role/report invalidation,
return to a single track, and both grouped JSON exports with actual save/readback.
The existing single-track navigation/settings/save/cancel flow passed in
`/private/tmp/amc-grouped-peaks-ui.xcresult`. Six captures were visually inspected:
[stereo English](images/audio-grouped-peaks-stereo-en.png),
[stereo Norwegian](images/audio-grouped-peaks-stereo-nb.png),
[5.1 levels English](images/audio-grouped-peaks-surround-levels-en.png),
[5.1 levels Norwegian](images/audio-grouped-peaks-surround-levels-nb.png),
[5.1 navigation English](images/audio-grouped-peaks-surround-navigation-en.png) and
[5.1 navigation Norwegian](images/audio-grouped-peaks-surround-navigation-nb.png).
Controls and chart labels fit; the channel report scrolls to reach interval buttons.
One paused Norwegian capture after audio regrouping shows an MPEG-4 video artifact;
the subsequent interval seek redraws correctly. These checks qualify source/audio
analysis and navigation, not frame-accurate video reconfiguration.

Initial UI attempts exposed lazy interval/summary rows outside the viewport;
tests now scroll explicitly and wait for export readiness after scans. The UI
runs also exposed the intermittent EOF loss that motivated the concatenation fix.
The repeated tone test originally assumed ideal sine-wave amplitude; it now checks
actual discrete source-track peak/RMS values independently. Initial Xcode runs
needed permitted package-cache access, and the new test file needed explicit
registration in the project. Seven localization script tests, the 1,890-entry
catalog audit and whitespace check pass. Translations outside English/Norwegian
await review. Release/device and sandbox enforcement remain unverified; the
project currently disables App Sandbox in both configurations.

### Grouped silence selection and audition — 2026-10-16

Detect Silence now offers Audio track, Mono pair and 5.1 multi-mono. Each group
assigns distinct mono tracks to explicit channel roles, including LFE. Changing
roles or presentation invalidates the previous result and export. The same
captured presentation feeds source detection and the complete JSON report.

MPV audition maps audio-relative selections to actual MPV track IDs. The pinned
library lacks `join`; available `pan` filters route disjoint channel positions
before `amix` with normalization disabled. Decoder measurements verify channel
order and preserved source gains before output/device conversion. Failed selections
stay paused with controls disabled. Returning to a single track removes the graph;
loading another file or stopping restores automatic audio selection for owned
analysis selections. This follows MPV's [documented labelled complex graphs](https://mpv.io/manual/stable/#options-lavfi-complex).

Group filters combine sample positions rather than independently synchronizing
source timestamps. A bounded, cancellable FFmpeg first-frame preflight therefore
requires mono inputs with matching sample rates and decoded starts before grouped
scanning or preview. Unequal/unknown starts or differing sample rates fail explicitly.
Single-track detection retains its delayed-audio file timeline. Unequal durations and midstream discontinuities
remain unqualified; this increment targets continuous, synchronized multi-mono
recordings. Detection includes every assigned channel, including LFE, independently
of preview volume, mute and device downmixing. Group inputs use equal-sized
unpadded frames to retain the final samples when codec packet sizes differ.
Separate EBU R128 measurements are unchanged. No dependencies, bundled binaries or licenses changed.

The ad-hoc-signed Debug app builds. The final complete unit suite executes 1,372
tests with zero failures and one intentional opt-in benchmark skip in
`/private/tmp/amc-grouped-final-unit.xcresult`; all 43 focused scanner/player tests
also pass.
Three UI checks pass in `/private/tmp/amc-grouped-ui-fresh.xcresult`: English and
Norwegian grouped selection/navigation, duplicate rejection, stereo report save
and readback, plus the existing single-track save/cancel/settings flow. All four
[stereo English](images/audio-grouped-silence-stereo-en.png),
[stereo Norwegian](images/audio-grouped-silence-stereo-nb.png),
[5.1 English](images/audio-grouped-silence-surround-en.png) and
[5.1 Norwegian](images/audio-grouped-silence-surround-nb.png) captures were visually
inspected for readable controls, intervals and preview without clipping.

An initial graph test had an incorrect expected MPV ID; corrected role indexing
passes. The first full run caught the FLAC tail loss, now covered by a 96,001-sample
six-track fixture with an exact one-sample final frame. Combined/cached UI runs
timed out launching a background app before reaching assertions; fresh build
products pass all three checks. Seven localization script tests and the 1,887-entry
catalog audit pass. New translations outside English/Norwegian await review.
Release/device qualification and sandbox enforcement remain unverified; the
project currently disables App Sandbox in both configurations.


### Silence report export — 2026-10-16

Detect Silence now offers Export JSON with immutable analysis completion time,
selected presentation, captured thresholds and every interval. The save panel
retains completed results on cancellation or failure; changed settings/tracks and
new scans invalidate them. Reports explicitly identify source sample amplitude,
all-channel silence detection and file-relative timestamps, including initial
audio offsets. The exporter retains service-level stereo/5.1 grouping context;
the UI continues to select one track. See [schema](audio-silence-report-format.md).

Validation: the ad-hoc-signed Debug app builds, and the full unit suite executes
1,367 tests with no failures and one intentional opt-in benchmark skip. All 14
silence scanner/report tests pass, including complete interval retention, track
and grouped layout context, empty results, invalid-data rejection, repeated writes
and destination errors. English/Norwegian UI checks pass: export is disabled
before analysis and after changed settings, save cancellation preserves the
report, and a real exported JSON file retains the selected track, threshold and
2–4 second interval. Both captured screens were visually inspected. Seven
localization script tests, the 1,876-entry catalog audit and whitespace check
pass. Release/device qualification remains open. The current Debug and Release
configurations disable App Sandbox; these checks do not qualify sandbox enforcement.

Results: `/private/tmp/amc-silence-export-full-unit.xcresult` and
`/private/tmp/amc-silence-export-ui.xcresult`. The
[English](images/audio-silence-export-en.png) and
[Norwegian](images/audio-silence-export-nb.png) captures show readable controls,
intervals and preview/timeline without clipping. Existing localized labels are
reused; no dependencies, packaged binaries or licenses changed.


### Peak/channel report export — 2026-10-16

Audio Analysis → Peaks and Channel Balance now offers Export JSON after a
successful scan. The save panel selects an explicit destination; writes are
atomic and retain security-scoped access through completion. A failed save leaves
the completed report available for retry, a successful save clears earlier export
errors, and cancelling the panel preserves the scan. Changed tracks/settings and
new scans invalidate export. Repeated saves retain the analysis completion time.

The versioned, locale-independent report includes the source basename rather
than its absolute path, audio-relative selected-track index, thresholds, all
channels and every interval, including those outside the chart's display limit.
It distinguishes digital silence, infinite channel difference and unavailable
comparison. Its semantics explicitly identify dBFS sample peaks, source-sample
windows, file-relative timestamps and unweighted whole-track RMS. It does not
change the separate EBU R128 loudness analysis. NaN measurements and invalid time
values fail export. See [the schema and measurement semantics](audio-peak-report-format.md).

The ad-hoc-signed Debug app builds. The complete unit suite executes 1,363 tests
with no failures and one intentional opt-in benchmark skip in
`/private/tmp/amc-channel-export-full-unit.xcresult`.
The 14 focused scanner/report tests also pass, including full interval retention,
locale-independent JSON with quoted/non-ASCII filenames, delayed file timelines,
digital silence, infinite/unavailable channel differences, repeat writes,
destination errors and invalid measurements. English/Norwegian UI checks pass
in `/private/tmp/amc-channel-export-ui-confirmed.xcresult`. The English flow checks
export disabled before analysis and after threshold changes, save cancellation,
then writes through the native save panel and reads back the expected track,
threshold and interval. Both [English](images/audio-peaks-export-en.png) and
[Norwegian](images/audio-peaks-export-nb.png) screenshots were visually inspected
for control fit and readability. Seven localization script tests, the 1,876-entry
catalog audit and whitespace check pass. The new failure label's translations
outside English/Norwegian await review.

Initial UI attempts selected a Touch Bar Cancel button, assumed a combo-box
folder field, and hit an existing threshold-menu focus race. Escape cancellation,
the captured save-panel/PathTextField identifiers, and explicit activation/menu
waiting resolve these in the final rebuilt run. Xcode initially needed a permitted
rerun to write package caches. The project currently disables App Sandbox in both
configurations; these checks establish the save-panel workflow, not sandbox
enforcement. Release signing, packaging and physical-device tests were not run.

True-peak markers, phase/correlation, silence report export, grouped multi-mono
reports and playback alignment remain open. No dependencies, bundled binaries or
licenses changed.

### Sample peaks and channel balance — 2026-10-16

Audio Analysis → Peaks and Channel Balance scans one complete selected source
track with bundled FFmpeg. Markers cover 4,800-sample windows (100 ms at 48 kHz),
merged per channel when adjacent windows meet or exceed the configured sample-peak
threshold. Source samples are neither resampled nor padded at EOF. The actual
sample rate/count and file-timeline timestamps determine interval boundaries,
including delayed audio. A marker locates an analysis window containing a peak,
not the exact sample or an intersample true-peak excursion.

The panel shows every decoded channel's maximum sample peak and unweighted
whole-track RMS. RMS accumulates linear energy weighted by each window's actual
sample count; timeline gaps are not synthesized as silence. Channel difference is
the highest minus lowest RMS level, compared with a configurable threshold.
Mono and wholly silent tracks have no comparison; a silent channel beside an
active channel has infinite difference. Surround and LFE level differences may
be intentional. These checks do not change EBU R128 weighting or LFE exclusion
in the separate loudness report.

Click interval boundaries or the timeline to seek and pause in MPV. Track or
threshold changes clear prior results. Volume, mute and conversion trims do not
affect these source measurements. The service retains scoped access through
subprocess cleanup, rejects incomplete/failed reports and publishes no cancelled
results. Line storage is bounded; exceeding 100,000 intervals fails explicitly.
The chart displays the first 1,000 intervals with a disclosure; the lazy list
retains all intervals. Sample-rate/layout changes and overlapping frame timestamps
fail instead of mixing incompatible measurements.

Validation: the ad-hoc-signed Debug build passed. All 1,359 unit tests executed
with zero failures and one intentional opt-in benchmark skip in
`/private/tmp/amc-peaks-final.xcresult`. The 10 new scanner tests cover chunked
reports, sample-weighted RMS, silence, inclusive thresholds, gaps, marker limits,
malformed/truncated reports, failure/cancellation, selected tracks, 44.1/48/96 kHz,
and delayed audio with a one-sample final window. The 20 combined peak/silence
scanner regressions and initial English navigation check also passed in
`/private/tmp/amc-peaks-focused.xcresult`.

Final English/Norwegian UI checks passed in
`/private/tmp/amc-peaks-bilingual.xcresult`, after resizing the sheet to fit the
host display. Both exported screenshots under
`/private/tmp/amc-peaks-bilingual-screenshots/` were visually inspected for
clipping, channel levels and marker/preview agreement. The English test navigates
both boundaries and verifies changed thresholds invalidate prior results; the
Norwegian test checks translated report/balance controls. The full-suite combined
run encountered an accessibility snapshot failure before opening the English
panel; the separate final rebuilt UI run passes both tests. Seven localization
script tests, the 1,875-entry localization audit and whitespace check pass.
Translations outside English/Norwegian await review.

Verified UI screenshots: [English](images/audio-peaks-en.png) and
[Norwegian](images/audio-peaks-nb.png).

True-peak interval markers, grouped multi-mono analysis, phase/correlation and
report export remain outside this increment. Release packaging and physical-device
qualification were not performed. No dependencies, bundled binaries or licenses
changed.

### Silence detection — 2026-10-16

The new Audio Analysis action uses bundled FFmpeg `silencedetect` on complete
selected-track PCM, independently of preview volume/mute and conversion trims.
It streams interval events beyond the diagnostic-tail limit and requires a
successful decoder exit, final progress, decoded audio and paired interval
boundaries. Cancelled/failed/truncated scans never publish partial intervals.
The scanner holds its own security-scoped lease; preview holds a separate lease
until dismissal. Closing the panel cancels the scan and stops playback.

Generated-media checks cover all-channel silence in asymmetric multi-mono
stereo, delayed-track file timestamps, exact silence through EOF and configurable
threshold/minimum duration. Parser checks cover chunk boundaries, malformed and
nonfinite events, ordering, empty output and incomplete reports. A cancellation
test verifies that analysis waits for runner cleanup.

Preview navigation seeks and pauses on the file timeline. MPV retains its
existing 50 ms guard at the final playable position; the measured EOF interval
boundary/duration stays exact in the report. This is sample-threshold silence,
not a perceptual loudness gate or a true-peak measurement. Track gaps before the
first decoded audio sample are not synthesized as silence. Grouped audition,
silence-report export, physical-device tests and distribution signing are not
part of this continuation. No dependencies, bundled binaries or licenses changed.

Validation: the ad-hoc-signed Debug app built successfully. The complete unit
suite executed 1,349 tests with no failures and one intentional opt-in benchmark
skip. All 124 Python script tests passed, and the 1,857-entry localization audit
and whitespace check passed. The complete-suite result is
`/private/tmp/amc-silence-final.xcresult`. The standalone English navigation UI
test also passed in `/private/tmp/amc-silence-ui-serial.xcresult`; its exported
screenshot was visually checked for clipping, readable controls and marker/preview
agreement. Tests navigate both interval boundaries, invalidate changed settings,
then rescan with a longer minimum duration and verify no intervals remain.
The final rebuilt scanner regressions (10 tests) and English/Norwegian UI checks
(two tests) pass in `/private/tmp/amc-silence-bilingual-final.xcresult` after the
source-capture, accessibility and EOF navigation refinements.
Exported final screenshots are in
`/private/tmp/amc-silence-bilingual-screenshots/`.

Initial sandboxed runs could not write Xcode package caches or create local MCP
test endpoints; the permitted reruns passed. The first UI assertion read the
empty macOS static-text label instead of its value, and was corrected. An
overlapping broad test attempt interrupted UI setup and was discarded; the
complete-suite run and subsequent UI validation use serial execution.

Use generated asymmetric stereo tones to check independent peak/RMS levels,
silence/nonfinite metadata to check empty readings, window-boundary and seek
comparisons to check LUFS pre-roll, and LFE-only surround audio to check weighting.
Check native and MPV playback, pause/resume, mute/volume, track/source changes,
hiding/closing the meter, EOF, sandbox access and unsupported inputs manually.

### Results — 2026-10-15

- Debug build passed.
- All 48 focused tests passed across `PlaybackAudioMeterTests`,
  `SourceAudioMeterTests`, `AudioRoutingPlanTests`, and
  `MPVPreviewObservationTests`. The new generated-media checks cover asymmetric
  stereo peak/RMS, momentary/short-term LUFS, window-boundary pre-roll, delayed
  audio, and LFE exclusion. Parser checks cover startup history, nonfinite
  readings, future-frame rejection, and stale readings after EOF.
- The new UI test passed in both AVPlayer/MP4 and MPV/MKV previews: seek to four
  seconds, show the meter, wait for numeric momentary/short-term LUFS, capture a
  screenshot, hide the meter, and close preview. The test uses local ad-hoc
  signing; the unsigned runner could not bootstrap on this machine.
- Exported native and MPV screenshots were inspected. Physical audio-device
  testing and a distribution-signed build were not performed for this change.

### MPV playback validation — 2026-10-15

- Signed Debug build and all 51 focused unit tests passed (zero skipped), across
  `PlaybackAudioMeterTests`, `SourceAudioMeterTests`, `AudioRoutingPlanTests` and
  `MPVPreviewObservationTests`. Clean final result:
  `/private/tmp/amc-playback-meter-unit-verified.xcresult`.
- The real packaged-MPV test uses asymmetric stereo FLAC with two different
  tracks. Peak/RMS match known amplitudes and LUFS agrees with independent
  windowed source analysis. It checks mute/volume independence, pause, seek,
  track replacement, disabling/re-enabling, source reload, stop and EOF. Reload
  coverage also exposed and fixed a stale playing flag; paused scrubbing passes.
- A packaged-player AAC/mono video test verifies finite, calibrated peak/RMS and
  momentary/short-term LUFS. Parser coverage rejects nonfinite values and missing
  history. Actual filter registration is checked in the linked libavfilter.
- The native/MPV UI check passed against the final built app. It checks Source
  mode, selecting Playback, finite spoken peak/RMS plus numeric momentary and
  short-term LUFS, pause clearing, hiding and closing. Result:
  `/private/tmp/amc-playback-meter-channel-ui.xcresult`. Exported native/MPV
  screenshots under `/private/tmp/amc-playback-meter-final-screenshots/` were
  visually inspected. Channel readings are explicit view data so stable labels
  refresh with new samples; the spoken label carries measurements because macOS
  group elements do not expose a separate accessibility value.
- All eight resolved Debug framework payloads match the previously qualified
  release hashes. The 26 attribution/manifest tests and offline notice-generation
  check pass. No standalone bundled binary was replaced; the MPVKit package,
  corresponding-source references, notices and exact pin were updated together.
- The earlier dependency update's Release/signing and architecture evidence is
  retained in the linked dependency validation document. This continuation was
  validated in Debug; physical-device latency, CPU/thermal comparison, physical
  Intel hardware and a new distribution-signed build remain unverified.

### Software comparison — 2026-10-15

The new opt-in benchmark passed 12 serial, 17-second runs across stereo AAC
video and 5.1 FLAC audio, with two rounds per mode. Playback used less CPU than
Source in this instrumented Debug sample, but AAC/AVFoundation readings led the
playhead by about 3.4 seconds; FLAC/CoreAudio timing was much closer. The test
does not isolate output from codec/video/layout effects. Source stays the default.
[Method, results and raw evidence](audio-meter-comparison-2026-10-15.md) record
the limits and remaining qualification. All 51 focused regressions and three
report tests passed; the benchmark skips intentionally outside an opted-in run.
