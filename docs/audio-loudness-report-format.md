# Whole-program loudness JSON (version 1)

Audio Analysis → Analyze Audio → Export JSON writes every completed selected
presentation to `_loudness.json`. PDF and JSON retain the analysis start time
across repeated saves. Changing the selected file or audio configuration clears
old results. Cancellation preserves already completed presentations; export is
available once active measurements have drained.

The locale-independent envelope contains `schemaVersion` (`1`), `analysis`
(`whole_program_loudness`), the selected file's basename in `sourceFileName`, an
ISO 8601 UTC `timestamp`, explicit measurement `semantics`, and ordered `results`.
The file can be either the source or its encoded output; no absolute path is
included.

Each result has an explicit `presentation` with its type, zero-based
audio-relative stream indices matching `0:a:N`, and channel order. A track uses
all decoded channels. Stereo maps selected mono streams to FL/FR. Surround maps
them to FL/FR/FC/LFE/SL/SR, preserving the user's role assignments.

`integratedLUFS` is the gated whole-program measurement, not an average of graph
readings. Values at or below -70 indicate no loudness above the gate.
`loudnessRangeLU` is in LU and is not considered stable below one minute.
`maximumTruePeakDBTP` measures across selected channels and is null when
unavailable. `samples` contains every full-resolution reading, without the
chart's decimation. Its `seconds` starts at the selected presentation's audio
start; it does not retain an initial audio offset on the container timeline.

Readings arrive in nominal 100 ms windows, with an unpadded partial final window. `momentaryLUFS` uses 400 ms and
`shortTermLUFS` uses three seconds. `peakDBFS` and `rmsDBFS` are unweighted window
levels across selected channels. A null reading represents below-gate loudness,
silent levels, or an incomplete window; it never means zero. Conversion trims,
volume and mute do not affect measurements.

The exporter rejects empty report batches, duplicate or malformed presentations,
non-finite summaries, negative loudness ranges, and invalid or non-increasing
sample timestamps. It writes atomically while the save handler holds scoped
access to the chosen destination. An individual valid result may contain no
100 ms samples for a sufficiently short program.

Grouped loudness scans decode every selected mono source before measurement and
require matching sample rates, starts and decoded lengths, with continuous
source timestamps within 1 ms container rounding. Explicit role mapping and
unpadded merging preserve all preflight samples; the merged decode must match
the exact source count and start before a report is accepted.

True peak uses a separate named FFmpeg `ebur128` branch with 100 ms of zero
context at each edge. This drains interpolation at EOF, including a final
single-sample impulse. Only that branch receives context; integrated loudness,
loudness range and exported timeline readings use the original unpadded audio.
This remains FFmpeg's true-peak estimate, without an independent conformance
certification or playback-alignment claim.
