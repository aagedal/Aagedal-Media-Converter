1. Add video player with trim and loop functionality
    1. ✅ Hover affordance: show a preview icon when hovering the list thumbnail (VideoFileRowView).
    2. ✅ Launch preview sheet: open a SwiftUI sheet hosting the preview player.
    3. ✅ Preview streaming: use `HLSPreviewSession` + resource loader to play FFmpeg-backed HLS.
    4. ✅ Trim UI: expose in/out handles and loop toggle in the preview sheet and persist in `VideoItem`.
    5. ✅ Conversion wiring: feed stored trim data into `ConversionManager` when launching ffmpeg.

2. Add support for audio formats, and render audio waveform using showwaves filter in ffmpeg if there is no video track in the input.
    1. ⬜ Track detection: extend `VideoFileUtils`/ffprobe helpers to flag `hasVideoTrack`.
    2. ⬜ Waveform thumbnail: run `showwavespic` to create a thumbnail when only audio is present.
    3. ⬜ Preset handling: adjust `FFMPEGConverter` to branch for audio-only inputs (skip video filters, map audio correctly).
    4. ⬜ Add toggle on item to activate audio-only mode.

3. Infrastructure for FFmpeg-backed HLS preview
    1. ✅ `HLSPreviewSession` helper to spin up ffmpeg, manage playlists, handle sandbox access.
    2. ✅ Custom `AVAssetResourceLoaderDelegate` to serve playlist/segments from disk (no HTTP server).
    3. ✅ `PreviewPlayerView` SwiftUI component using AVPlayer + loader delegate.
    4. ✅ Lifecycle management: tie session start/stop to sheet presentation and cleanup temp artifacts.

4. Enhanced trim timeline with filmstrip & waveform
    1. ✅ FFmpeg preview generator: produce 6 evenly spaced thumbnails and a 1000×90 waveform image per source, cache on disk.
    2. ✅ Preview data plumbing: expose cached asset URLs from `PreviewPlayerController` and surface loading state in SwiftUI.
    3. ✅ Build `TrimTimelineView`: custom layered control combining filmstrip, waveform, playhead, and draggable trim handles.
    4. ✅ Visual states: gray out regions outside trim bounds and keep keyboard/drag interactions consistent.


5. Fix scroll lag