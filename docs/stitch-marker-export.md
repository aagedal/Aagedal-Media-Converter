# Stitched clip markers

Stitched exports default to a Resolve marker EDL sidecar plus embedded chapters in MOV, MP4, M4V, and MKV. Disable this in Settings → Encoding → Stitched Exports. XML is not included.

Each clip gets a point marker prefixed `Cut: ` and named after its source file, including the first clip at the beginning. Order follows the encoding group. Offsets use the measured durations of the prepared clips, which can differ from requested trims with LongGOP Stream Copy. The same durations are supplied to the concat demuxer. EDL timecodes use the finished output's frame rate and start timecode.

When source clips already contain chapters, the app asks whether to keep existing chapters or replace them with clip boundaries. Keeping existing chapters is the default, including when no interactive window is available. Existing chapters are offset into the stitched timeline and clamped to retained clip ranges. If preparation removed chapter metadata, source chapter ranges are intersected with the retained interval. Notes are inserted into the retained chapters, splitting their ranges where needed. EDL markers include both cuts and notes regardless of that choice. Unreadable chapter/timing metadata produces a warning instead of silently replacing chapters.

The sidecar is written next to the actual output, including any collision-renamed output, as `name.cuts.edl`. Existing sidecars are never overwritten; subsequent files use `name.cuts-2.edl`, etc. Marker serialization or sidecar failures leave a successfully encoded media file successful and display a warning. Chapter metadata is muxed during the normal final encode, without a second media pass.

In the group editor, press **M** or click **Marker** to add a note without interrupting playback. Press M again at that frame, or click its yellow flag, to rename or delete it. Notes export as `Marked: <text>`. They follow their source clip when reordered; trimming hides excluded notes without deleting them. Notes are kept with the queued item for the current session. The final-frame position is used when adding a marker at the end of the sequence.

## Resolve compatibility and provenance

The EDL event layout, CRLF separators, escaping, drop-frame arithmetic, and rejection rules were adapted from Aagedal Media Player commit `0c56c2c`: `CompareReviewReportExporter.resolveMarkersEDL` and `TimecodeRate`. Import these as timeline markers in Resolve on a timeline with matching output rate and start timecode.

The retained 29.97 DF and 59.94 DF fixtures under `Aagedal Media ConverterTests/Fixtures/StitchMarkers` were copied from that repository's `docs/evidence/resolve-markers-20260919` and `docs/evidence/resolve-markers-5994-20260919`. The accompanying original READMEs and validation JSON describe their native Resolve validation scope. Some paths in those historical evidence files refer to the original test machine and repository; they are provenance, not executable instructions.

Converter's golden tests reproduce the Player EDL bytes using independent known frame positions and ranges, including drop-frame minute and ten-minute transitions. This reuses the existing native Resolve evidence; it does not claim a new Converter-to-Resolve manual roundtrip. Additional tests cover ordered measured durations, chapter range retention, actual FFmpeg chapter muxing, and non-overwriting sidecars.

EDL export rejects more than 999 markers, unsupported frame rates above 60 fps, invalid timecode, and events reaching the 24-hour timecode boundary. Coincident points are combined into one entry with both labels, including points rounded to the same output frame. These EDL limits do not prevent embedded chapters. Stream Copy cut accuracy remains subject to source keyframes; markers do not make arbitrary cuts frame accurate.
