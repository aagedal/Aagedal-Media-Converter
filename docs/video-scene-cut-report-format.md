# Source scene cut report JSON (version 1)

Media Analysis → Video → Detect Scene Cuts → Export JSON writes the complete
successful scan, including an empty cut list when no cut qualifies. The default
filename ends in `_video_scene_cuts.json`. The save panel selects the
destination; cancelling preserves the scan and failed saves can be retried.
Threshold changes and new scans invalidate the previous report.

The scan runs the bundled FFmpeg's `scdet` filter on the first video stream that
is not an attached picture (`0:V:0`). The same pass writes a small JPEG of the
first frame after each cut to a temporary folder, which is deleted when the
window closes or the report is invalidated:

```
ffmpeg -hide_banner -nostdin -nostats -xerror -progress pipe:1 -i <source> \
  -filter_complex "[0:V:0]scdet=threshold=<threshold>,split=3[cuts][first][marked];\
[first]trim=end_frame=1[opening];\
[marked]metadata=mode=select:key=lavfi.scd.time[selected];\
[opening][selected]interleave=nb_inputs=2,scale=w='trunc(iw*sar/2)*2':h=ih,setsar=1,\
scale=w=320:h=180:force_original_aspect_ratio=decrease:force_divisible_by=2[thumbnails]" \
  -map "[cuts]" -f null - \
  -map "[thumbnails]" -fps_mode passthrough -q:v 4 -f image2 <temporary folder>/cut_%05d.jpg
```

The opening frame is included so the JPEG encoder always receives a frame (a
file without cuts otherwise fails); it is discarded afterwards. Thumbnails are
optional: if their count does not match the cuts, the report is kept without them.

The default threshold is 10, the `scdet` default. Scores run from 0 to 100.

## Why scdet

`scdet` and `select='gt(scene,X)'` with `metadata=print` were compared on real
material with the bundled FFmpeg 9.0.2. On a 28-second phone news clip both
found the same seven cuts at identical frame times (scdet 13.7–30.4, select
0.35–0.78). `scdet` logs one line per cut with its score and time, so no
per-frame metadata printing is needed, and its threshold applies directly. On
dark HDR (PQ) material real cuts scored roughly 7–20, so the threshold can be
lowered in the window. A flash or a one-frame transition can produce two cuts
on consecutive frames; both are reported.

## Report

The locale-independent envelope contains:

- `schemaVersion`: `1`.
- `analysis`: `source_video_scene_cuts`.
- `sourceFileName`: the source basename, without its absolute path.
- `timestamp`: the analysis completion time in ISO 8601 UTC, retained across saves.
- `semantics`: detector, stream selection, units and timeline conventions.
- `result`: captured settings (`threshold`) and every cut's `time` in seconds
  and `score`.

A cut's `time` is the presentation time of the first frame after the cut, from
`lavfi.scd.time`. A frame is reported when its score is greater than or equal to
the threshold. Times are relative to the file timeline, as FFmpeg reports them
after removing the container start time; they match the preview's position.
Trims, crops and other conversion settings do not affect the scan.

Progress comes from FFmpeg's `-progress` `out_time_us` against the queue item's
duration. A report is only accepted when FFmpeg exits successfully, reports
`progress=end`, decoded video (`out_time_us` greater than zero), and every
`scdet` line parses to a finite, non-negative score and a strictly increasing
time. Cancelling terminates FFmpeg, removes any thumbnails written and publishes
nothing.

## Resolve EDL markers

Export Cuts as EDL Markers writes one point marker per cut, titled
`Cut N • score S`, using the stitching timeline's Resolve marker EDL writer (see
[stitched clip markers](stitch-marker-export.md)). Cuts that round to the same
frame share one marker with both titles, because Resolve keeps only one marker
per frame. Marker timecodes use the source file's frame rate and start timecode
(00:00:00:00 when it has none) and assume the video starts at file time zero.
The EDL limits apply: at most 999 markers, at most 60 fps and no events reaching
24 hours.
