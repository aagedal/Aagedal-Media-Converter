# Audio peak and channel-balance JSON reports

Audio Analysis → Peaks and Channel Balance → Export JSON saves a completed scan
through the macOS save panel. Changing the selected presentation or any measurement/threshold
invalidates the report and disables export until another scan finishes. Cancelled
or failed scans cannot be exported. Cancelling the save panel keeps the completed
scan available. Repeated exports retain the same analysis timestamp.

Single-track reports retain schema version 1. Grouped stereo and 5.1 reports use
schema version 2, with an explicit ordered source mapping instead of a single
track index. Opt-in estimated true-peak scans use schema version 3 for either
presentation. The report contains:

- `schemaVersion`: `1` for sample-only source tracks; `2` for sample-only grouped mono tracks; `3` when estimated true peaks are included.
- `analysis`: `source_sample_peaks_and_channel_balance`.
- `sourceFileName`: the source basename, including its extension. The source's
  absolute path is excluded.
- `audioRelativeTrackIndex`: zero-based audio-track order, as used by FFmpeg's
  `0:a:index` mapping. This is not an absolute container stream index. This field
  is present for single-track reports; a grouped report never names one track as its source.
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
the sample-peak pass neither resamples source audio nor fills timestamp gaps with silence.
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

## Version 3: estimated true-peak markers

Choose **Peak markers → Estimated true peak** and a dBTP threshold before scanning.
The report retains the original `intervals`, `channels`, sample threshold, RMS and
channel balance, and adds `settings.truePeakThresholdDBTP` and `result.truePeaks`:

- `thresholdDBTP`: the inclusive reconstructed-peak threshold.
- `sourceSampleRate`, `measurementSampleRate`: decoded rate and four times that rate.
- `windowSourceSamples`: 4,800 (19,200 interpolated samples per complete window).
- `method`: `estimated_4x_libswresample_swr_filter64_cutoff0.97_no_certification`.
- `channels`: ordered `{channel, peakDBTP}` values for every selected channel.
- `intervals`: every `{start, end, channel, peakDBTP}` marker, merged per channel
  across adjacent qualifying windows. This array is independent of sample markers.

`semantics.peakUnit` remains `dBFS`; the new `truePeakUnit` is `dBTP`.
These values estimate reconstructed source peaks using continuous 4× interpolation
with bundled FFmpeg/libswresample (double precision, 64-tap SWR filter, 0.97 cutoff,
phase shift 10, no linear phase interpolation). They are not a certified BS.1770
conformance measurement. Filter response and edge policy affect estimates, especially
near Nyquist or an abrupt boundary. Separate whole-program EBU R128 analysis is unchanged.

The scanner validates raw decoded timestamps before reframing. Rates up to 192 kHz
are supported, including 4× interpolation of 96/192 kHz sources. Discontinuities
beyond the raw validation's 1 ms container-rounding allowance fail. The reframed
source and interpolated windows must additionally be contiguous to within half
a sample. Thus some coarse-clock files may be rejected conservatively. Neither
resampling timestamp compensation nor synthesized gap silence is used.

Both edges receive 64 zero source samples of interpolation context; that context
is trimmed before measurement, and original file timestamps are restored. The
resampler drains at EOF, including one-sample clips. Exactly four times the decoded
source sample count, the same channel count, and unchanged initial/end times are
required. Markers cover windows containing an estimated excursion, not its exact
sample position. Source RMS is measured before interpolation and remains unweighted.
True-peak mode requires a validation decode plus separate source and interpolation
decodes, so it takes longer than sample-only scanning. Cancellation drains the
active subprocess and publishes no partial combined report.

The result's settings, channel topology, rates, method, thresholds and interval
times are validated before export. Sample-only reports retain schema versions 1/2.

Implementation references: FFmpeg's [EBU R128 filter source](https://ffmpeg.org/doxygen/trunk/f__ebur128_8c_source.html)
exports cumulative per-channel true-peak metadata, which cannot locate individual
threshold windows. The separate interpolation pass instead uses the documented
[resampler controls](https://ffmpeg.org/ffmpeg-resampler.html) and the
[aresample EOF flush](https://ffmpeg.org/doxygen/trunk/af__aresample_8c_source.html).
