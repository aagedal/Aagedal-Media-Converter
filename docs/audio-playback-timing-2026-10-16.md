# Playback meter timestamp investigation — 2026-10-16

Keep Source as the default. The existing Playback metadata does not identify the
measured frame, so buffering readings in Swift or substituting `audio-pts` for
`time-pos` cannot establish playhead alignment. The next implementation needs
timestamped, sequenced measurements from the filter boundary and a way to retain
all of them while decoding runs ahead.

This is a source/API investigation and reinspection of existing benchmark
evidence. No new playback benchmark, build, physical-device synchronization,
Release performance or thermal validation was performed.

The [2026-10-17 isolated prototype](audio-playback-timestamp-prototype-2026-10-17.md)
now implements dependency timestamp/history capture and diagnostic state polling.
It does not change the production app or establish playback alignment.

## Evidence in the app

- `Logic/MPV/MPVPlayer.swift`, `pollPlaybackMeterLocked()`, inserts
  `ebur128=metadata=1` followed by `astats=metadata=1:reset=1` and polls
  `af-metadata/amc_playback_meter` at 10 Hz with one request pending.
- `receivePlaybackMeterLocked()` copies the returned dictionary, then separately
  reads `time-pos` and assigns that time to `PlaybackAudioMeterSample.seconds`.
  The value is a receipt-time playhead label, not a measured-frame timestamp.
  Its startup-history gate also uses playhead elapsed time, rather than the
  filter's measured continuous history. The existing generation checks are still
  necessary to reject stale lifecycle responses.
- `Logic/Previews/SourceAudioMeter.swift`, `MPVAudioMeterMetadata.sample()`,
  accepts caller-supplied seconds/history; no timestamp comes from its metadata.
- `Aagedal Media ConverterTests/AudioMeterBenchmarkTests.swift` intentionally
  compares known signal edges against `player.timePos`, rather than trusting
  sample seconds. `scripts/benchmark-audio-meter.py` preserves the sign of that
  difference.

The checked-in [comparison](audio-meter-comparison-2026-10-15.md) and
[raw report](provenance/audio-meter-2026-10-15/report.json) already show the
failure: stereo AAC/video with AVFoundation led by a median 3.417 seconds in both
rounds; 5.1 FLAC/CoreAudio medians were 0.132 and 0.040 seconds early. The AAC
decoder had passed the first level transition before the first numeric poll.
An app queue cannot recover metadata that was overwritten before polling.
The experiment changes codec, layout, video and output together; it does not
identify a single cause or justify a constant delay correction.

## Dependency/API limits

The exact corresponding-source companion referenced by
[dependency provenance](mpvkit-1.1.0-update-2026-10-15.md) was inspected locally:
`/private/tmp/amc-mpvkit-n9-complete-sources.tar`, nested member
`mpvkit-n9.0.2-sources.tar.gz`. Paths and line numbers below refer to that nested
archive, which includes fork modifications and therefore differs in line numbers
from upstream.

In `build/dist/libmpv-v0.41.0/filters/f_lavfi.c`, line 718 copies an output
frame's metadata dictionary; line 828 returns the latest copied tags. There is
no timestamp envelope or historical queue in this response. The frame conversion
and possible timestamp remapping happen separately (lines 720–726). A new
timestamp must use the final MPV media timeline, including the `fix-pts` path,
rather than blindly exposing raw filter-local PTS. The same architecture is
visible in [upstream mpv 0.41.0](https://github.com/mpv-player/mpv/blob/v0.41.0/filters/f_lavfi.c).

For reproducibility, that exact fork file has SHA-256
`064f23b34cdf424a583d35d2d12d9a3760aff901f5ae15c82e30faa0cffcc80b`.

Both `build/provenance/ffmpeg-arm64-config_components.h` and the x86_64 equivalent
declare `CONFIG_AMETADATA_FILTER=0` and `CONFIG_ASHOWINFO_FILTER=0`;
`ASTATS`, `EBUR128` and `ASETNSAMPLES` are enabled. Thus adding an
`ametadata=print` graph to the current packaged app is not available. In FFmpeg,
[ametadata printing](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavfilter/f_metadata.c)
can emit frame PTS beside metadata, but enabling it would require rebuilding the
dependency; log/file transport would also need completeness and timeline checks.

The [mpv property documentation](https://github.com/mpv-player/mpv/blob/v0.41.0/DOCS/man/input.rst)
defines `af-metadata` as audio-filter metadata. `audio-pts` represents current
audio playback position and includes driver delay; it is useful as another
diagnostic clock, not the identity of an earlier metadata frame. Demuxer cache
duration measures another buffering stage and cannot substitute for this identity.

The exact fork's `audio/out/ao_avfoundation.m` requests 100 ms chunks (line 71),
passes synchronizer scheduling times to `ao_read_data` (line 80), enqueues audio,
and advances its queued end time (line 131). Its readiness callback drives further
feeding (line 149). [Upstream output code](https://github.com/mpv-player/mpv/blob/v0.41.0/audio/out/ao_avfoundation.m)
shows the same arrangement. This supports investigating queued output as a
possible contributor; it does not establish that it caused the measured lead or
measure physical presentation time.

## Next implementation and acceptance criteria

1. Prototype dependency instrumentation before changing production meter timing.
   At the labelled filter's output, emit the final media start/end timestamps,
   sample count/rate, channel layout, sequence number and metadata together.
   Reset an epoch on seek, track/source changes, filter restart and discontinuity.
   Publish a bounded queue/batch with explicit overflow reporting, so decoding
   several seconds ahead cannot overwrite unconsumed 100 ms measurements.
2. Record those frames alongside monotonic receipt time, `time-pos`, `audio-pts`,
   speed, pause/seeking state, actual output and any available queue diagnostics.
   Derive loudness history from continuous measured media intervals. Detect gaps,
   duplicated sequences, missing timestamps and nonfinite data explicitly.
3. Extend the opt-in benchmark with matched media under forced AVFoundation and
   CoreAudio where supported. Hold codec/layout/video constant when comparing
   outputs; then change each separately. Include startup, nonzero seeks, pause,
   track changes, delayed audio and speed changes. Preserve failed/unavailable
   combinations as evidence instead of silently substituting an output.
4. Only after validating timestamp mapping, retain future frames until the
   chosen presentation clock reaches their interval. Discard obsolete epochs and
   clear on overflow/discontinuity; never stamp decoder frames with poll time or
   apply the AAC result as a universal offset. Keep the signal-transition check
   independent of the new timestamps, including brief impulses that expose lost
   frames. Report residual timing distributions per output and condition.

Even a successful software result only qualifies alignment to the player's
clock. Physical loopback/device tests and longer Release CPU/thermal runs remain
separate requirements before considering Playback as the default.
