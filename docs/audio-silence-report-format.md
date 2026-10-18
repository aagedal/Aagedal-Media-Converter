# Source silence report JSON (version 1)

Audio Analysis → Detect Silence → Export JSON writes the complete successful
scan, including an empty interval list when no silence qualifies. The default
filename ends in `_audio_silence.json`. The save panel selects the destination;
cancelling preserves the scan and failed saves can be retried. Track, threshold,
minimum-duration changes and new scans invalidate the previous report.

The locale-independent envelope contains:

- `schemaVersion`: `1`.
- `analysis`: `source_sample_silence`.
- `sourceFileName`: the source basename, without its absolute path.
- `timestamp`: the analysis completion time in ISO 8601 UTC, retained across saves.
- `presentation`: explicit presentation type, zero-based audio-relative track
  indices (matching `0:a:N`), layout and channel order.
- `semantics`: measurement units, channel aggregation and timeline conventions.
- `result`: captured presentation, settings (`thresholdDBFS` and
  `minimumDuration` in seconds), and every interval's `start`, `end` and
  `duration` in seconds.

Intervals locate continuous decoded source samples below the dBFS sample-amplitude
threshold across every selected channel together. These are not RMS, LUFS or
intersample true-peak readings. Volume, mute and conversion trims do not affect
the scan. All channels participate, including LFE; this is distinct from the
separate EBU R128 loudness analysis and its weighting/exclusions.

Times are relative to the file timeline, including delayed audio. An initial
audio offset is not synthesized as silence. `duration` is `end - start` for each
interval; the report does not infer whole-file duration from the last silence
interval. A trailing interval can end at the filter-reported end of audio.

The UI selects one audio track with its source layout, a custom mono pair, or
six mono tracks assigned to 5.1 roles. Stereo maps to FL/FR and 5.1(side) maps to
FL/FR/FC/LFE/SL/SR in the stated track order. Selection, grouped preview and export
retain that order. Grouped scans decode every selected source stream before
scanning and require matching sample rates, decoded start times and sample
counts, with continuous timestamps (within 1 ms container timestamp precision).
Unequal lengths and later discontinuities fail before scanning. The merged
measurement must preserve the preflight sample count, rate and start time;
a successful process and closed silence interval alone do not prove complete
analysis. Groups target continuous, synchronized recordings. A track report does not claim
a measured channel count or layout name that the silence detector does not return.

The exporter rejects invalid settings, track topology, non-finite timestamps and
invalid, unordered or overlapping intervals. JSON is written atomically while
the save handler retains security-scoped access to the destination. These access
calls alone do not establish sandbox enforcement: the current project disables
App Sandbox in Debug and Release.
