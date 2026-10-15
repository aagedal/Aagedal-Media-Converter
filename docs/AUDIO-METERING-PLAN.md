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
- [ ] Investigate timestamped decoder measurements and buffering before claiming playhead alignment for Playback; the generated AAC/video benchmark observed readings about 3.4 seconds ahead. Do not infer measurement time from the current playhead or apply one fixed correction across outputs. [Source/API investigation](audio-playback-timing-2026-10-16.md) identifies the missing timestamp/history transport and the dependency instrumentation needed next; alignment remains unqualified.
- [ ] Qualify Release CPU/thermal behavior and physical-device synchronization on longer representative media before considering Playback as the default.
- [ ] If useful, add running integrated playback-session LUFS, clearly distinguish it from whole-program analysis, and reset it explicitly after seeking, changing source/track or restarting the measurement.
- [x] Silence detection with navigable timeline markers and configurable thresholds/durations. Audio Analysis → Detect Silence scans a complete selected track, includes every channel, and retains file-relative timestamps for delayed audio. Threshold choices span −30 to −80 dBFS; minimum durations span 0.1–5 seconds. Intervals offer paused start/end navigation and a clickable timeline. This first UI supports one track at a time; multi-mono presentation scanning is covered in the service tests but is not exposed as grouped audition.
- [ ] Sample-peak/true-peak threshold markers and per-channel imbalance checks. Distinguish source sample peaks from intersample true peaks.
- [ ] Stereo phase/correlation analysis, with mono compatibility checks and a phase display.
- [ ] Expand channel-specific analysis/report exports while retaining EBU R128 channel weighting and LFE exclusion.
- [ ] Evaluate newer MPVKit/FFmpeg playback support, including ProRes RAW VideoToolbox acceleration and animated WebP. Confirm each component is actually enabled in the package and test representative files before advertising support.

## Validation

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
