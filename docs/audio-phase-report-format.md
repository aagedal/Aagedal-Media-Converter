# Source stereo phase report — schema 1

Audio Analysis → Stereo Phase measures a complete stereo source track or two
assigned mono tracks. It provides a correlation timeline, a whole-source mid/side
density display, unweighted mid/side RMS, paused window navigation and JSON export.
Only stereo tracks and distinct mono pairs are supported. A surround track is
never implicitly downmixed. Separate EBU R128 loudness analysis is unchanged.

## Measurements

Every window contains 4,800 native-rate sample frames, except the unpadded final
window. At 48 kHz this is 100 ms. Original source amplitudes are decoded to double
precision without gain, sample-rate conversion or DC removal. The following sums
are calculated for each window and the complete selected presentation:

- `leftEnergy = ΣL²`, `rightEnergy = ΣR²`, `crossProduct = ΣLR`.
- `midEnergy = Σ((L + R)/2)²`, `sideEnergy = Σ((L − R)/2)²`.
- `correlation = ΣLR / sqrt(ΣL² × ΣR²)`, clamped to [−1, +1] for rounding.
- `monoFoldDownDeltaDB = 10 log10(midEnergy / ((leftEnergy + rightEnergy)/2))`.
- `midRMS = sqrt(midEnergy / sampleCount)` and the equivalent side RMS, in linear
  full-scale units. The panel converts these RMS values to dBFS for display.

Correlation is an uncentered normalized cross-product, not Pearson correlation
with the DC mean removed. +1 indicates positively proportional signals, −1
negatively proportional signals, and 0 no linear correlation under this definition.
Either zero-energy channel makes correlation `null`. Both silent channels make
mono delta `null`; exact cancellation of active channels is the string
`"-Infinity"`. Identical channels give 0 dB mono delta; equal-energy uncorrelated
signals give approximately −3.01 dB. A silent channel beside an active channel
also gives −3.01 dB, with unavailable correlation. These metrics are advisory;
negative correlation may be intentional. Whole-source totals combine sample-energy
sums rather than averaging window correlations and can conceal local cancellation.

The measurements do not apply EBU R128 weighting/gating, predict subjective mono
loudness, identify a frequency-dependent phase shift, or measure the output device.
Volume, mute, conversion trims and preview routing have no effect on the report.

## Density display

`result.scope` contains a fixed 33 × 33 grid. For every source sample frame,
`x = (L − R)/2` and `y = (L + R)/2` are mapped from [−1, +1] to the nearest bin.
Indices are row-major `y * 33 + x`, with increasing y displayed upward. Values
outside either axis are clamped to the edge and counted once in
`clippedSampleCount`. Counts include the final partial window and silent samples.
The bins sum to the total sample count. There is no automatic gain normalization;
quiet signals concentrate near the center. Dot opacity uses logarithmic density.
This whole-source summary does not represent a live playback oscilloscope.

Matching channels form a vertical line; opposite polarity forms a horizontal line.
One-sided audio forms a diagonal. The correlation chart shows the first 2,000
windows, with an explicit disclosure for longer reports. All windows are retained
in the scrollable list and JSON. A 100,000-window service limit fails explicitly
rather than returning an incomplete report (about 2 h 46 min at 48 kHz).

## Timeline, grouping and lifecycle

Window `start`/`end` are seconds on the file timeline, including initial audio
offsets. `duration` is the end of decoded audio, not its elapsed sample duration.
The raw decoded timestamps are checked before reframing, with a 1 ms rounding
tolerance (at least one source sample). Reframed windows must be exactly
continuous in sample units. Coarse-clock files can therefore fail conservatively;
sub-millisecond discontinuities may fit the raw container tolerance. Gaps are
never filled with artificial samples. Missing timestamps, layout/rate changes,
missing samples and incomplete/failed decodes reject the report.

Mono pairs use the existing full decoded-timeline preflight before audition and
repeat validation for scanning: both tracks must be mono with matching sample
rates, decoded starts and exact sample counts. Role order and source gains are
preserved. Analysis owns scoped source access through subprocess cleanup;
preview owns a separate lease. Cancelling/dismissing publishes no partial result.
Presentation/role changes invalidate results and exports. Navigation seeks and
pauses in MPV; its final playable-position guard does not alter report EOF.
Source timing does not establish physical-device playback alignment.

## JSON envelope and saving

The locale-independent envelope contains `schemaVersion: 1`,
`analysis: "source_stereo_phase_analysis"`, `sourceFileName`, ISO-8601 analysis
completion `timestamp`, `presentation`, `semantics` and `result`. Only the source
basename is exported. `presentation.type` is `track` or `stereo`, with zero-based
`audioRelativeTrackIndices` matching `0:a:N` and `channelOrder: ["L", "R"]`.
The result also preserves Swift's captured presentation encoding, sample rate,
window size, every window, totals and scope. Each measurement includes raw sums,
sample count and explicit derived values; unavailable derived values are JSON null.

The exporter rejects invalid/nonfinite energies, inconsistent energy identities,
invalid timelines/counts, totals differing from their windows, and invalid scope
counts. The macOS save panel retains security-scoped destination access for atomic
writes. Cancellation preserves the report; failed saves can be retried. Repeated
exports preserve the analysis timestamp. No dependencies, binaries or licenses
change as part of this feature.
