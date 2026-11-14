# yt-dlp-rs 1.0.0-rc.1 validation — 2026-11-13

The bundled yt-dlp-rs moved from 0.9.0-beta.1 to 1.0.0-rc.1
(`scripts/update-ytdlp-rs.sh v1.0.0-rc.1`, archive SHA-256
`11f84cd93ebdc6e7ba4bda01d573b3e790babead2fd0e7b3f5dc508fc4c9520f`). The app passes
no new options; routing and version gates are unchanged.

## Method

Each recording ran the bundled binary with `YTDLPService.runDownload`'s arguments
(`--growing-file`, `--keep-partial-on-stop` unless `--live-from-start`, the JSON
progress template, `--embed-metadata …`, the bundled ffmpeg directory and the managed
deno) in its own process group, stopped with SIGINT to the group, as the app's Stop
does. Growing files were imported into DaVinci Resolve Studio 21.2.0.6 through its
scripting API while they were recorded. Streams: Al Jazeera English
(`gCNeDWCI0vo`, live since 2023-03-10) and Sky News (`umLWFz4izTM`).

## Results

| Case | Result |
| --- | --- |
| Growing file, live HLS (H.264 1080p30 + AAC) | One fragmented QuickTime `.mov` at its final name, `com.blackmagicdesign.metadata:recording` set, time-of-day timecode track. Stop: exit 0 within 0.2–3.2 s, tag removed, metadata embedded, video and audio equally long (2:04.96 / 2:05.08) |
| Resolve import while recording | Imported as H.264/AAC QuickTime with the recording's start timecode. The clip's duration grows by itself (39 s → 1:29 in 36 s) and every frame decodes up to the newest |
| Resolve after Stop, clip only in the media pool | Settles at the file's length and timecode (1:19:29 without `--embed-metadata`; 5:49 of 5:50 for a from-start recording with it) |
| Resolve after Stop, clip also on a timeline, with `--embed-metadata` (the app's arguments) | **Wrong** in both runs: 2:07:16 with the start timecode reset to 01:00:00 for a 2:05 recording, and 57:08:11 for a 1:10 recording. A fresh import of the same finished file is correct (2:04:29, 21:52:48:00) |
| Same, without `--embed-metadata` | Correct: 1:09:29 from 22:25:28:00 for a 1:09.98 file. So the cause is the metadata step, which rewrites the finished recording (`-movflags +faststart`) into a replacement file while Resolve still treats the clip as growing |
| Resolve scripting | `CreateTimelineFromClips` with a growing clip deadlocks Resolve 21.2 (main thread waiting on a recursive mutex in the Fairlight page) when the project already has a timeline made from another growing clip. The first such timeline in a project works. A Resolve issue, seen only through scripting |
| `--live-from-start`, stopped after 4 min (Sky News) | Merged in 1.7 s, exit 0; 12:54.99 video, 12:55.01 audio. The 0.10 fix ("end a stopped live-from-start merge at its last common fragment") removes the short-video problem seen up to 0.9 |
| `--live-from-start --growing-file` (Al Jazeera) | Writing starts after ~18 s, then the file grows at 4–5× real time while it catches up; Resolve shows it growing. Stop: exit 0 in 0.3 s, tag removed, streams equally long (5:50.00 / 5:50.11). **Timecode wrong** for a stream older than YouTube's 120-hour window: 01:37:12:00, the stream's 2023 start, while the first frame is from 120 hours ago (the channel's on-screen clock reads 21:00 GMT) |
| Stop when yt-dlp-rs starts with SIGINT ignored (shell `&` job) | ffmpeg still stops and the file is kept and untagged, but yt-dlp-rs reports `ERROR: ffmpeg exited with code 255`, exits 1 and skips metadata. The app is not affected: `SubprocessRunner` resets SIGINT to the default for children |
| `-x --audio-format best` without ffprobe | Still fails after the download (`filesystem error: No such file or directory (os error 2)`), with `--ffmpeg-location` as the directory or the binary, although the release notes say `-x` works without ffprobe. With `--ffprobe-location` it works. The app keeps routing audio-only downloads without ffprobe to yt-dlp |

## For yt-dlp-rs before 1.0.0

- With `--growing-file`, write the `--embed-metadata` tags into the recording itself
  (the info is known before ffmpeg starts) and skip the rewrite after a live
  recording; the rewrite breaks clips already edited into a Resolve timeline. The app
  cannot leave out `--embed-metadata` for live recordings alone, because it learns
  `live_status` only after the arguments are fixed.
- A from-start growing recording's timecode should come from the first downloaded
  fragment (or now − the available window), not `release_timestamp`.
- `-x` without ffprobe still fails.
- Optional: a stop that reaches ffmpeg while yt-dlp-rs itself ignores SIGINT is
  reported as an ffmpeg failure.

## Re-test with yt-dlp-rs PR #92 — 2026-11-13/14

The PR head (`0cf35bbf`), built locally with `cargo build --release --locked` without
`impersonate`, re-tested with the same harness and Resolve 21.2.0.6:

| Case | Result |
| --- | --- |
| Growing file with `--embed-metadata`, clip on a Resolve timeline, then Stop | Fixed. The tags are written by the recording itself (present while it grows). Only one FFmpeg call runs, and the file keeps its inode. Exit 0, tag removed, video/audio 1:09.96 / 1:10.07. Resolve settles at 00:01:09:29 from 23:56:58:00 |
| `--live-from-start --growing-file`, stream live since 2023 | Fixed. Timecode 23:58:49:00 for a recording started at 23:58:47 (120 hours back, same time of day), consistent with the channel's on-screen clock |
| Stop when started with SIGINT ignored | Fixed. Exit 0, `[ffmpeg] Interrupted by user`, tag removed, metadata kept |

`-x` without ffprobe is also fixed in #92 (per the readiness review; not re-tested here).

## 1.0.0-rc.2 — 2026-11-14

`scripts/update-ytdlp-rs.sh v1.0.0-rc.2` (archive SHA-256
`e40600e8d97a0f6d58ce4e1bbd0425b92db3f99b5a1f0761aaa43795d055f569`). PR #92 merged at
the head tested above; the tag adds only the version bump and changelog, so the
from-start timecode and ignored-SIGINT results carry over. Re-checked on the published
binary:

| Case | Result |
| --- | --- |
| Growing file with `--embed-metadata` (Al Jazeera), clip on a Resolve timeline while recording, then Stop | Exit 0 1.0 s after SIGINT, `[ffmpeg] Interrupted by user`, tag removed, same inode, title embedded, timecode 12:46:07:00; video 1:30.13, audio 1:30.00. Resolve settles at 00:01:30:04 (2,704 frames) from 12:46:07:00 |
| `-x --audio-format best --embed-metadata` without ffprobe | Works: exit 0, a 19 s Opus file with its title tag. Audio-only downloads now route to yt-dlp-rs (`ytdlpRSAudioWithoutFFprobeMinimumVersion`) |
