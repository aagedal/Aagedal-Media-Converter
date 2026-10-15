# Source and MPV playback meter comparison — 2026-10-15

The repeatable comparison is `scripts/benchmark-audio-meter.py`. It runs the
packaged application's real `MPVPlayer`, `PlaybackAudioMeterCache` and source
analysis decoder in a serial, opt-in XCTest. Normal unit runs skip this benchmark.
No playback default or packaged dependency changes as part of this comparison.

## Reproduce

```sh
python3 scripts/benchmark-audio-meter.py \
  --output-dir /private/tmp/audio-meter-comparison \
  --derived-data /private/tmp/audio-meter-comparison-build \
  --packages /path/to/resolved/SourcePackages \
  --rounds 3
```

Use a new output directory for each invocation; the script preserves existing
evidence. Omit `--packages` to let Xcode resolve dependencies normally. After a
successful build, `--without-building` can reuse it. Keep the host idle and do
not run other tests in the same app process. The opt-in uses Xcode's
`TEST_RUNNER_` environment forwarding, not persistent application preferences.

## Method

- Generate 32-second fixtures: stereo AAC with 640×360, 24 fps MPEG-4 video;
  and 5.1 FLAC audio. Every source channel contains a 1 kHz sine whose sample
  peak starts at −6 dBFS and drops 1.5 dB every two seconds.
- Measure 17 seconds each of metering Off, Source, and Playback, with fresh
  players and fresh source analysis caches. Rotate mode order between rounds.
  Load the file paused before measurement, then include play/meter startup.
- Source loads the current eight-second analysis window plus one adjacent
  window, matching preview lookahead. It retains the production three-second
  LUFS pre-roll and cache behavior. Native preview and stitching source-channel
  inspection remain available through their existing implementations.
- Sample at 10 Hz. Infer each level transition from the signal value and compare
  its observed playhead with the known source edge. Do not infer latency from
  `PlaybackAudioMeterSample.seconds`: MPV currently stamps decoder metadata with
  its current playhead, which does not identify the measured audio frame.
- Sum host and reaped child-process user/system CPU, using `getrusage` around
  each run. Source analysis subprocess work and lookahead are included; fixture
  generation and initial file loading are excluded. A CPU percentage of 100 is
  one core. Compare each mode with its fixture's Off baseline.
- Preserve every reading and CPU counter as a JSON XCTest attachment, the entire
  `.xcresult`, build/test log, and summarized `report.json`. The report names the
  actual MPV audio output. Missing signal data or stalled playback fails the
  benchmark; CPU/latency values have no machine-dependent pass/fail threshold.

## Limits and adoption decision

This is a short, generated-media, Debug-build software comparison. It excludes
SwiftUI rendering cost and does not measure physical speaker latency, thermal
behavior, energy use, release-optimized performance, remote files, long playback,
or all codecs/layouts. Filesystem and decoder caches can be warm even with a new
analysis cache. Source prefetch does work for audio beyond the observed interval;
this is deliberately included because the preview panel does that work too.

Timing includes the filters' 100 ms measurement bins, 100 ms polling and the
player clock's update granularity. Negative transition delay means a reading
appeared before the corresponding source edge reached the reported playhead.
It does not establish physical output synchronization. Silence/transient capture
and seek/track/source resets remain covered separately by the existing tests.

Source remains the default. MPV Playback remains opt-in pending physical-device,
longer real-media, Release CPU/thermal and buffering/latency qualification.

## Results

The signed Debug build and the opt-in benchmark passed on macOS 27.0.1 arm64.
Two rounds produced 12 serial runs, each approximately 17 seconds. The build
included XCTest coverage instrumentation; these CPU figures must not be treated
as Release performance or energy measurements.

CPU figures below are the median percentage of one core across two rounds,
including host and child CPU. Timing is the range of the two per-run median
transition delays; negative values mean the displayed reading led the playhead.

| Fixture and observed audio output | Off CPU | Source CPU | Playback CPU | Source transition delay | Playback transition delay |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stereo AAC video / AVFoundation | 2.12% | 3.32% | 2.50% | +208 to +250 ms | −3,417 ms in both rounds |
| 5.1 FLAC audio / CoreAudio | 1.54% | 4.43% | 2.41% | +138 to +159 ms | −132 to −40 ms |

The source meter observed all eight expected transitions per run. Playback
observed seven for AAC and eight for FLAC. The first AAC playback reading already
corresponded to the second level segment; the first transition had passed through
the decoder before polling produced a reading. Subsequent AAC transitions
consistently appeared 3.375–3.458 seconds ahead of the playhead. Across all
surround Playback transitions the observed range was −175 to +13 ms. Source
transition ranges were +125 to +292 ms for AAC and +120 to +226 ms for FLAC,
consistent with measurement bins and polling rather than instantaneous edges.

Playback used less CPU than Source in these runs, but its timing varied greatly
between the two fixture/output combinations. The experiment changes codec,
video presence, layout and output together; it does **not** isolate which of
those caused the difference. Decoder/output buffering is a plausible explanation,
not an independently established cause. Applying one fixed delay would not be
justified by these results. Source remains the default, and no physical-device
latency claim follows from this evidence.

Checked-in evidence:

- [Summarized runs and signal transitions](provenance/audio-meter-2026-10-15/report.json).
- [Every raw playhead/peak reading and CPU counter](provenance/audio-meter-2026-10-15/readings.json).
- Complete local result bundle:
  `/private/tmp/amc-meter-comparison-20261015-final/benchmark.xcresult`.
- Focused regressions: 51 tests passed, zero failures. The separate benchmark
  intentionally skipped in that ordinary run, verifying opt-in behavior:
  `/private/tmp/amc-meter-comparison-regression.xcresult`.
- Three benchmark-report tests passed, covering child CPU inclusion, timing sign,
  repeated/missing values and mixed transition frames. Diff whitespace checks pass.

The initial fixture-generation attempt failed because its FFmpeg expression
contained unquoted commas. Quoting the expression fixed it before the completed
measurement; no failed-attempt readings are included.
