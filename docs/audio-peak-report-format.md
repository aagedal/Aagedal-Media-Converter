# Audio peak and channel-balance JSON reports

Audio Analysis → Peaks and Channel Balance → Export JSON saves a completed scan
through the macOS save panel. Changing the selected presentation or either threshold
invalidates the report and disables export until another scan finishes. Cancelled
or failed scans cannot be exported. Cancelling the save panel keeps the completed
scan available. Repeated exports retain the same analysis timestamp.

Single-track reports retain schema version 1. Grouped stereo and 5.1 reports use
schema version 2, with an explicit ordered source mapping instead of a single
track index. The report contains:

- `schemaVersion`: `1` for a source track; `2` for grouped mono tracks.
- `analysis`: `source_sample_peaks_and_channel_balance`.
- `sourceFileName`: the source basename, including its extension. The source's
  absolute path is excluded.
- `audioRelativeTrackIndex`: zero-based audio-track order, as used by FFmpeg's
  `0:a:index` mapping. This is not an absolute container stream index. This field
  is present only in version 1; a grouped report never names one track as its source.
- `presentation`: the captured selection, with `type` (`track`, `stereo`, or
  `surround51`), `audioRelativeTrackIndices`, `channelLayout`, and `channelOrder`.
  Grouped reports always include it. Legacy version 1 reports may omit it.
- `timestamp`: completion of the scan, in ISO 8601 UTC, rather than time of export.
- `semantics`: stable, language-independent descriptions of units, channel
  numbering, timeline, windowing, weighting and nonfinite-value encoding.
- `result`: the complete scan's `settings`, `intervals`, `channels`, `duration`
  and, where applicable, `imbalanceDB`.

`settings.thresholdDBFS` is the inclusive sample-peak threshold;
`settings.imbalanceThresholdDB` is the advisory channel-difference threshold.
Every interval has `start`, `end`, `channel` and `peakDBFS`. Every channel has
`channel`, `peakDBFS` and `rmsDBFS`. Export retains all intervals, including those
beyond the chart's 1,000-interval display limit and offscreen list rows.

For a source track, channel numbers are one-based decoded order and the context
uses `channelLayout: "source_track_layout"` and
`channelOrder: ["all_source_track_channels_in_decoded_order"]`.
For grouped stereo, channels 1–2 mean `FL`, `FR`; for grouped 5.1(side), channels
1–6 mean `FL`, `FR`, `FC`, `LFE`, `SL`, `SR`. The ordered source indices correspond
to those roles. For example, `audioRelativeTrackIndices: [2, 3, 4, 7, 5, 6]`
assigns audio-relative source track 7 to LFE (channel 4), track 5 to SL (channel 5),
and track 6 to SR (channel 6). The indices are never sorted during export.
Channel IDs must be consecutive from 1 in presentation order, channel counts must
match the grouping, and every interval must refer to a reported channel.
Grouped selections require distinct nonnegative source indices and exactly two
or six mono source tracks. Invalid context or measurements fail export.

Times use file-relative seconds,
including any initial audio offset. `duration` is the end of decoded audio on
that timeline, not the audible duration after subtracting the initial offset or
the duration of a longer video stream. Intervals locate 4,800-source-sample
analysis windows and merge adjacent qualifying windows per channel. Window
duration therefore depends on source sample rate. The last window is unpadded;
the scanner neither resamples source audio nor fills timestamp gaps with silence.
Grouped scans additionally verify compatible sample rates, common initial offset,
matching decoded sample counts, and continuous per-track timing before combining channels.
Timestamp continuity allows up to 1 ms of rounding (at least one sample), to
accommodate coarse clocks such as Matroska millisecond ticks. This tolerance
can obscure sub-millisecond discontinuities, even in finer-clock containers.
The complete validation decode runs before grouped audition is enabled and again
when scanning, so long files take longer to prepare. Changing roles or closing
the panel cancels preparation.

Peaks and RMS use dBFS. Peaks are source sample peaks, not intersample true-peak
measurements or exact peak-sample positions. RMS is whole-presentation, unweighted linear
energy accumulated by actual sample count. `imbalanceDB` is the highest minus
lowest channel RMS, in dB. Surround and LFE differences may be intentional. These
measurements do not alter EBU R128 weighting or LFE exclusion in the separate
loudness report, and do not depend on playback volume/mute or conversion trims.

JSON numbers represent finite measurements. The string `"-Infinity"` represents
digital silence in channel peak/RMS levels; `"Infinity"` represents infinite
channel difference when both an active and a silent channel exist. `imbalanceDB`
is omitted for mono or entirely silent audio, where comparison is unavailable.
Readers must distinguish these cases from finite zero. Invalid/nonfinite time
values and NaN measurements fail export rather than publishing a partial report.

Exports use the presentation captured when analysis completed. A caller cannot
relabel a captured report as another track or flatten a group into one track.
The legacy API can still export an older result without captured context when an
explicit single-track index is supplied. The presentation-based API requires
captured context. The `result` object contains measurements only; the stable
presentation mapping lives at the report's top level.

The report is UTF-8 JSON with sorted keys and locale-independent numbers. No
media data or security-scoped bookmark is included. Writes are atomic to the
destination explicitly selected by the user; export does not start a conversion
or authorize automatic writes beside the source.
