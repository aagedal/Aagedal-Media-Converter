# Audio metering and analysis

## First implementation

- [x] Independent source-channel sample peak and RMS readings in the preview meter.
- [x] Momentary (400 ms) and short-term (3 s) source LUFS at the playhead.
- [x] Selected-track metering, up to eight displayed channels; loudness uses the full track's original channel layout.
- [x] Bounded eight-second analysis windows, three-second pre-roll, neighboring-window cache, cancellation and security-scoped access.

The app's pinned MPVKit CoreAudio `.2` build omits `astats` and `ebur128`.
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

## Deferred improvements

- [ ] Enable `astats` and `ebur128` in the MPVKit fork; preserve the CoreAudio initialization and failed-unit cleanup patches. Produce versioned, checksummed artifacts and update provenance, notices and the exact package pin together.
- [ ] Probe actual filter availability in the packaged libavfilter and prototype `af-metadata/<label>` polling for MPV playback. Account for decoder/output buffering, channel conversion, pause, seeking, track changes and stale metadata before adopting it.
- [ ] Compare CPU use and synchronization against the windowed FFmpeg path. Keep a native-player metering path, and retain separate source-channel inspection in the stitching editor.
- [ ] If useful, add running integrated playback-session LUFS, clearly distinguish it from whole-program analysis, and reset it explicitly after seeking, changing source/track or restarting the measurement.
- [ ] Silence detection with navigable timeline markers and configurable thresholds/durations.
- [ ] Sample-peak/true-peak threshold markers and per-channel imbalance checks. Distinguish source sample peaks from intersample true peaks.
- [ ] Stereo phase/correlation analysis, with mono compatibility checks and a phase display.
- [ ] Expand channel-specific analysis/report exports while retaining EBU R128 channel weighting and LFE exclusion.
- [ ] Evaluate newer MPVKit/FFmpeg playback support, including ProRes RAW VideoToolbox acceleration and animated WebP. Confirm each component is actually enabled in the package and test representative files before advertising support.

## Validation

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
