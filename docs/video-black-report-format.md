# Source black frame report JSON (version 1)

Media Analysis → Video → Detect Black Frames → Export JSON writes the complete
successful scan, including an empty interval list when no black qualifies. The
default filename ends in `_video_black.json`. The save panel selects the
destination; cancelling preserves the scan and failed saves can be retried.
Setting changes and new scans invalidate the previous report.

The scan runs the bundled FFmpeg on the first video stream that is not an
attached picture (`0:V:0`):

```
ffmpeg -hide_banner -nostdin -nostats -xerror -progress pipe:1 -i <source> \
  -filter_complex "[0:V:0]blackdetect=d=<minimumDuration>:pic_th=<pictureBlackRatio>:pix_th=<pixelThreshold>[black]" \
  -map "[black]" -f null -
```

Defaults are `d=0.5`, `pic_th=0.98` and `pix_th=0.10`, the FFmpeg defaults
apart from the minimum duration (FFmpeg defaults to 2 s).

The locale-independent envelope contains:

- `schemaVersion`: `1`.
- `analysis`: `source_video_black`.
- `sourceFileName`: the source basename, without its absolute path.
- `timestamp`: the analysis completion time in ISO 8601 UTC, retained across saves.
- `semantics`: detector, stream selection, units and timeline conventions.
- `result`: captured settings (`minimumDuration` in seconds, `pictureBlackRatio`
  and `pixelThreshold` as fractions from 0 to 1) and every interval's `start`,
  `end` and `duration` in seconds.

A picture is black when at least `pictureBlackRatio` of its pixels have luma at
or below `pixelThreshold` of the luma range. An interval starts at the first
black picture and ends at the first following non-black picture. Runs shorter
than `minimumDuration` are not reported. When the video ends black, FFmpeg
closes the interval at the last frame's presentation time, so the final frame's
own duration is not included.

Times are relative to the file timeline, as FFmpeg reports them after removing
the container start time; they match the preview's position. `duration` is
`end - start`. Trims, crops and other conversion settings do not affect the scan.

Progress comes from FFmpeg's `-progress` `out_time_us` against the queue item's
duration. A report is only accepted when FFmpeg exits successfully, reports
`progress=end`, decoded video (`out_time_us` greater than zero), and every
`blackdetect` line parses to an ordered, non-overlapping interval whose reported
duration matches its end minus start. Cancelling terminates FFmpeg and publishes
nothing.

## Resolve EDL markers

Export Black as EDL Markers writes one duration marker per interval, titled
`Black N • <duration> s`, using the stitching timeline's Resolve marker EDL
writer (see [stitched clip markers](stitch-marker-export.md)). Marker timecodes
use the source file's frame rate and start timecode (00:00:00:00 when it has
none) and assume the video starts at file time zero. The EDL limits apply:
at most 999 markers, at most 60 fps and no events reaching 24 hours.
