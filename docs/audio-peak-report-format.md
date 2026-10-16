# Audio peak and channel-balance JSON reports

Audio Analysis → Peaks and Channel Balance → Export JSON saves a completed scan
through the macOS save panel. Changing the selected track or either threshold
invalidates the report and disables export until another scan finishes. Cancelled
or failed scans cannot be exported. Cancelling the save panel keeps the completed
scan available. Repeated exports retain the same analysis timestamp.

The version 1 report contains:

- `schemaVersion`: `1`.
- `analysis`: `source_sample_peaks_and_channel_balance`.
- `sourceFileName`: the source basename, including its extension. The source's
  absolute path is excluded.
- `audioRelativeTrackIndex`: zero-based audio-track order, as used by FFmpeg's
  `0:a:index` mapping. This is not an absolute container stream index.
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

Channel numbers are one-based decoded order. Times use file-relative seconds,
including any initial audio offset. `duration` is the end of decoded audio on
that timeline, not the audible duration after subtracting the initial offset or
the duration of a longer video stream. Intervals locate 4,800-source-sample
analysis windows and merge adjacent qualifying windows per channel. Window
duration therefore depends on source sample rate. The last window is unpadded;
the scanner neither resamples source audio nor fills timestamp gaps with silence.

Peaks and RMS use dBFS. Peaks are source sample peaks, not intersample true-peak
measurements or exact peak-sample positions. RMS is whole-track, unweighted linear
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

The report is UTF-8 JSON with sorted keys and locale-independent numbers. No
media data or security-scoped bookmark is included. Writes are atomic to the
destination explicitly selected by the user; export does not start a conversion
or authorize automatic writes beside the source.
