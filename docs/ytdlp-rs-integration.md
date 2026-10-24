# yt-dlp-rs integration (site list + fallback)

Audited against yt-dlp-rs `a812a8f` (README, `src/main.rs` clap options,
`docs/COMPATIBILITY.md`) and the `v0.3.0-beta.1` aarch64 binary, 2026-10-24.
Code: `Logic/YTDLP/YTDLPEngineRouter.swift` (routing, session failure memory,
cleanup) and `YTDLPService.withEngineFallback`.

## Routing

yt-dlp-rs is used only when `YTDLPUpdateService.resolveYTDLPRSPath()` returns a
binary, the URL's host is on the site list, the site has not failed
`sessionFailureLimit` (2) times this session, and no option below forces yt-dlp.

Site list (host suffix match on label boundaries, so `www.`, `m.`, `music.`,
`vm.`, `old.` … match; `notyoutube.com` does not):

| Site | Hosts | Listings (`--flat-playlist`) |
| --- | --- | --- |
| YouTube | youtube.com, youtu.be, youtube-nocookie.com | yes |
| Instagram | instagram.com (not `/p/` posts, see below) | no |
| TikTok | tiktok.com | yes (users, collections) |
| X/Twitter | x.com, twitter.com, t.co | no (post listing yes) |
| Facebook | facebook.com, fb.watch | no |
| Reddit | reddit.com, redd.it (not v.redd.it) | no |
| Vimeo | vimeo.com | no |
| Twitch | twitch.tv | yes (channel lists) |
| Bluesky | bsky.app | no |
| SoundCloud | soundcloud.com | no (tracks only) |
| Bandcamp | bandcamp.com | no (tracks only) |

Excluded: Dailymotion (needs browser impersonation, unavailable in yt-dlp-rs),
and every other site.

## App feature → yt-dlp-rs support → routing

| App feature / argument | yt-dlp-rs | Routing |
| --- | --- | --- |
| `--ignore-config` | supported; rs reads `~/.config/yt-dlp-rs/config` otherwise | passed to both |
| `--remote-components ejs:github` | hidden, no effect (EJS bundled) | yt-dlp only |
| `--cache-dir` | accepted, no effect (rs caches nothing) | yt-dlp only |
| `--js-runtimes deno:PATH` | supported (YouTube n/sig) | passed to both |
| `--ffmpeg-location DIR` | supported (dir or binary); **required** for merges, `-x`, `--embed-metadata` (no PATH lookup) | download without ffmpeg → yt-dlp |
| `-x --audio-format best` | supported, but **needs ffprobe** beside ffmpeg (no ffmpeg fallback); bundled ffmpeg has no ffprobe | audio-only without sibling ffprobe → yt-dlp |
| `-f bestvideo+bestaudio/best`, `bestaudio/best` | supported | rs |
| `--download-sections *S-E` (clip ranges) | supported via FFmpegFD, ffmpeg stats inherited | rs |
| `--live-from-start --no-part` | hidden, YouTube native DASH generator (beta) | yt-dlp |
| `--embed-metadata --no-embed-info-json --no-embed-chapters` | supported | rs |
| `--windows-filenames`, `--restrict-filenames`, `--trim-filenames 200` | supported | rs |
| `--no-overwrites`/`--force-overwrites`, "has already been downloaded" | supported, same message | rs |
| `--newline --progress --verbose`, `[download] NN.N% of … at … ETA …` | same format/printers as upstream | rs |
| `--print before_dl:…%(live_status)s / %(duration)s`, `after_move:filepath` | supported; `after_move` prints the absolute path | rs |
| `[download] Destination:`, `[Merger] Merging formats into "…"` | same lines | rs |
| `-o` templates (`%(title)s [%(id)s].%(ext)s`, clip label) | supported | rs |
| `-j --no-download`, `-J --flat-playlist` | supported; fields used (`title`, `duration`, `thumbnail(s)`, `uploader`, `description`, `entries[].url/title/duration/availability`) present | rs (listings only where ported) |
| `--ignore-no-formats-error` (post probes) | hidden, **no effect**; a photo slide makes `-J` fail | Instagram `/p/` posts (all operations) → yt-dlp; Twitter posts stay on rs |
| `--playlist-items N`, `--no-playlist` | supported | rs |
| `--cookies FILE` (Helium export) | supported (file is rewritten, like yt-dlp) | rs |
| `--cookies-from-browser` safari/chrome/chromium/edge/brave/firefox/opera/vivaldi/whale, `firefox:PATH` (Zen) | all accepted and read natively | rs (first use may raise a separate Keychain prompt for yt-dlp-rs) |
| Subtitles | the app passes no subtitle options | n/a |

## Fallback

When yt-dlp-rs was chosen and the operation throws anything except a user stop
(`cancelled`, `liveRecordingStopped`), `fileAlreadyExists`, `CancellationError`
or a cookie configuration error, the same operation runs once with yt-dlp. yt-dlp-rs
results are also treated as failures when `-j` has no formats or a listing has no
entries. Before a download retry, files created during the yt-dlp-rs attempt
that share a reported destination's stem (`Title.f137.mp4.part`, `Title.mp4`, …)
are removed; pre-existing files are never touched. Each fallback counts towards
the per-site session limit. The engine and fallback reason are logged
(`YTDLPService`, `[Engine]`), and `VideoItem.downloadEngine` records the engine
that produced the file.
