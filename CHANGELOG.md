# v.4.4.0

> In development. Release validation is still in progress.

This release focuses on conversion correctness, reliable cancellation, saved-state recovery, and recording improvements.

## Conversion

- **Trim and crop validation catches invalid requests before encoding.** Anamorphic sources, odd dimensions, image sequences with companion audio, and custom filter ordering receive corrected geometry and timing.
- **Export settings stay consistent throughout each job**, including filenames, destinations, track routing, codecs, subtitles, metadata, timecode, and generated video.
- **Ambiguous numeric custom filters fail with guidance before automatic cropping or stream remapping**, preventing the app from silently overriding the wrong filter.
- **Matroska metadata shows channel counts without guessing speaker layouts**, and AVC-Intra mono splitting preserves channels by position.
- **Audio routing preserves track order and intentional duplication**, with fixes for channel operations, subtitle-container compatibility, and Stream Copy track metadata.
- **AV2 Matroska exports preserve audio timing and padding**, including delayed tracks, trims, AAC preroll, and Opus codec delay. Additional AAC channel layouts are supported.
- **AV2 assembly rejects damaged or incompatible segments.** Invalid trims and unsupported generated-video combinations report errors instead of producing incomplete output.
- **DCP frame preparation reports damaged frames and write failures** before wrapping a package.
- **IMF export is temporarily unavailable** while package descriptors and standards conformance are validated. Existing IMF settings are preserved.
- **Failed and cancelled conversions clean up their partial outputs**, while existing files and source media remain protected from replacement.

## Cancellation and recovery

- **External helpers share bounded execution and process-tree cancellation.** Conversion, downloads, uploads, transcription, analytics, and metadata probes report launch failures, timeouts, and tool errors.
- **Deno and yt-dlp update retries wait for the previous update to drain**, including extraction and checksum work.
- **Retries wait for cancelled helpers to finish**, with stale callbacks prevented from changing newer jobs. Conversion cancellation also drains native waveform and package preparation.
- **Subtitle jobs stage their results before publishing**, reserve separate names, and preserve unrelated or edited subtitle files when retrying. Publication is coordinated across app processes.
- **Uploads to the same remote destination run in queue order within the app.** Overlapping uploads from another app process on the same Mac report a retryable error. Retries wait for cancelled transfers, and file access remains open until each transfer finishes.
- **Transcription captures settings once per run**, and Parakeet rejects invalid chunk durations or overlap settings that cannot advance through the source.

## Saved settings and file access

- **Damaged download history and schedules are preserved**, with recovery guidance and an explicit reset action.
- **Unreadable upload profiles and saved-access records are preserved.** Opening Upload Settings cannot replace damaged profiles with an empty default, and a malformed bookmark entry no longer prevents other saved locations from resolving.
- **Malformed settings imports and audio routes are rejected** instead of silently changing saved preferences. Legacy audio presets and upload-profile upgrades preserve newer choices.
- **Watch-folder access can be renewed from Settings.** Scan, access, and Trash failures provide recovery guidance; cleanup pauses when access is insufficient.
- **SSH keys selected with Browse retain sandbox access across launches**, with guidance when access must be granted again.
- **Imports retain their filename and destination settings while metadata loads**, including camera-card groups and image sequences.

## Recording and preview

- **Growing recordings support Auto, 25, 29.97, 50, 59.94, and 60 fps**, with rational timing and drop-frame timecode at the two NTSC rates. Non-growing recording presets retain variable frame rate.
- **Stopping growing recordings drains final frames and timecode**, including immediate-stop recordings, and reports writer failures.
- **Screen, window, microphone, and audio-meter setup can time out or be cancelled**, preventing late callbacks from restarting stopped work.
- **Preview and thumbnail operations have bounded waits**, and replaced players ignore stale setup and seek callbacks.
- **Screenshots use consistent format and transparency settings**, including recovery from an invalid saved alpha preference.

## Shortcuts

- **Cold-launch requests remain available until a window accepts them**, and a submission is handled by only one receiving window.
- **File-bearing Shortcuts conversions run in submission order**, retaining each request’s preset and destination while importing and converting.

## Interface and diagnostics

- **Tool Diagnostics in Settings checks bundled helpers and selected transcription models**, with paths, architecture, executable status, and recovery guidance.
- **Norwegian translations cover more Settings, downloads, recording, and Shortcuts controls**, including all previously untranslated App Intent strings.
- **Accessibility names and keyboard access are improved** for Settings, crop and trim controls, folder actions, and screenshots.
- **The conversion toolbar stays disabled when no files are waiting.**

## Dependencies and release checks

- **Bundled FFmpeg updated to 9.0.1**, MPVKit updated for preview playback, and SwiftMediaMetadata updated to 3.0.0.
- **Release checks verify bundled dependency inventories and packaged notice contents**, and block publication while attribution or source review is incomplete, or FFmpeg’s reported license disagrees with its attribution or notice.

# v.4.3.0

A smaller, focused release built around **Shortcuts & Spotlight**. Instead of a single "convert with whatever's selected" action, there's now **one Convert action per export preset**, a **Convert with Default Preset** action that follows your configured default — so it can drive any of your *custom* presets — and the most common presets are surfaced as zero-setup **Spotlight / Siri shortcuts**. All of them now **launch the app automatically** when it isn't already running. Under the hood, the bundled **FFmpeg moves to 8.1.1**. Rounding it out: the queue's **drag-to-share handle now works on every drag** (not just the first after launch), and **importing from a camera card no longer freezes the window**.

## Shortcuts & App Intents

- **One "Convert Immediately" action per built-in preset.** Every built-in export preset — VideoLoop, VideoLoop with Sound, Animated Still, H.264, H.265, AV1, AV2, TV (HEVC and AVC-Intra), ProRes, Proxy, Stream Copy, Audio Only, Image Sequence, DCP, and both IMF flavours — is now its own Shortcuts action (e.g. *Convert to ProRes*, *Extract Audio*, *Remux (Stream Copy)*). Each adds the files, sets the output folder to the source folder, switches the app to that preset, and starts conversion. Actions use your saved settings for that preset (encoder, resolution, container, quality, audio), so a one-tap shortcut behaves exactly like picking the preset in the app.
- **New "Convert with Default Preset" action.** Converts using whatever you've set as the default preset in Settings, resolved at the moment it runs. Because the default can be *any* preset — including one of the ten user-defined **Custom** slots — this is the way to drive a custom preset from Shortcuts or Spotlight, which can't expose each custom slot as its own static action (their names are user-defined).
- **Spotlight & Siri shortcuts.** The ten most common presets — led by **Convert (Default Preset)** — are exposed as zero-setup App Shortcuts, so you can run them from Spotlight or by voice (e.g. *"Convert with Aagedal Media Converter"*) without first building a shortcut. Because a Spotlight/Siri phrase can't carry files, running one this way opens the app, switches to that preset, and presents a file picker — convert actions then start as soon as you choose your files. Apple caps this surface at ten per app; the niche presets (AV2, TV, Image Sequence, DCP, IMF) stay available as full actions inside the Shortcuts app.
- **The app now opens automatically.** Every convert action and "Add to Encode Queue" now launches the app if it isn't already running and reliably hands off its files, instead of silently doing nothing when the app was closed. A small launch-time buffer replays a request that arrives before the window's receivers are ready, so nothing is lost to the cold-launch race — and never runs twice.

## Encoding

- **Bundled FFmpeg updated to 8.1.1.** Replaces the previous build that dynamically linked Homebrew's `libvorbis.dylib` — and crashed on launch — with a self-contained, statically-linked GPL build. Non-free components are dropped: `libfdk_aac` gives way to the native `aac` / `aac_at` encoders.

## Fixes

- **Drag-to-share works on every drag, not just the first.** The drag handle on a finished queue row (the four-arrows icon) lets you drag the exported file straight into another app or Finder. It used to work only on the first drag after launch and then go dead — or start reordering the queue instead — because the drag was started from the wrong place and an unfinished drag session blocked all the ones after it. It now begins a proper file drag every time. The drag image is the row's own thumbnail (rounded, with a soft drop shadow) instead of a generic black document icon, and dropping the file back onto the queue re-adds it so you can compare the export against the original.
- **Importing from a camera card no longer freezes the window.** Scanning a camera/SD card ran on the main thread, locking up the UI until it finished. The scan now runs off the main actor, so the window stays responsive.

# v.4.2.0

The headline is experimental **AV2 encoding** via the bundled AOM AVM reference encoder — full round-trip (encode, decode, thumbnails, preview-not-available messaging), parallel chunked encoding that actually uses your cores, and Matroska muxing so the bitstream lands in a real container. Also new: **growing-file screen recording** — record straight into DaVinci Resolve (and Premiere) and edit the clip while it's still being captured — now across **several displays at once** in a tiled live overlay, plus a redesigned recording menu-bar menu, an expandable capture overlay, and a new **virtual display** you can record a window onto off-screen, without it cluttering your real monitors. Alongside: opt-in **settings & custom-preset sync** across Macs, a much faster queue sort, and a handful of crash and correctness fixes.

## Screen recording — growing files

- **Three growing presets, now the default for screen recording:** *Growing HEVC 10-bit 4:2:2 (Resolve/Premiere)* (the default), *Growing H.264 (Compatibility)*, and *Growing ProRes 4444 (Visually Lossless)*. Each writes a fragmented `.mov` in-process via AVAssetWriter (hardware HEVC 10-bit 4:2:2, H.264 for maximum compatibility, or visually-lossless ProRes 4444), so the file is editable the moment recording starts and survives an interruption. Non-growing HEVC 10-bit 4:2:2 and ProRes 4444 presets remain for when you'd rather import after recording; the Settings preset picker now spells out the trade-off (constant frame rate / edit-while-recording vs variable frame rate / smaller files). Note ProRes can't compress duplicate frames, so growing ProRes on a mostly-static screen makes large files.
- **Recognised as a true growing file by DaVinci Resolve** — the recording is tagged with the Blackmagic `com.blackmagicdesign.metadata:recording` extended attribute while capturing (reverse-engineered; see `docs/growing-file-research`), so Resolve shows the red REC overlay and fast-refreshes the clip (~5 s) instead of its generic ~1-min media rescan. The attribute is removed automatically on stop — and on a write error, or swept on next launch if a crash or quit interrupted a recording — so a finished or abandoned clip never carries a stale REC overlay.
- **Constant frame rate + timecode.** ScreenCaptureKit delivers frames only on change; a CFR pump re-emits the latest frame on a fixed clock so the file has a clean constant frame rate (important for NLEs), and a per-frame timecode track is written starting at wall-clock time-of-day.
- **Removed the broken growing-`.ts` path.** The experimental FFmpeg-pipe `.ts` presets (which deadlocked — HEVC produced a 0 KB file, H.264 froze after one frame) are gone, along with their dead pipe writer. Stored defaults pointing at them fall back to a working preset automatically.

## Screen recording — overlay controls

- **One menu-bar menu instead of two icons.** While recording, the menu bar previously showed two separate icons — a red stop button and a rectangle to re-open the hidden preview. They're now a single red icon whose dropdown holds everything: **Stop Recording**, **Show / Hide Preview**, an **Extend Auto-Stop** submenu (**+1 / +5 / +10 / +30 min**, plus **Cancel Auto-Stop**), and a live status section showing how long you've recorded and — when an auto-stop is set — how long is left and the exact stop time. Extending when no auto-stop is active simply starts one from now.
- **Expandable capture overlay.** The floating preview panel toggles between a compact size and an expanded view via the button in its top-right corner. Expanded fills ~90% of its display, sized to the captured area's aspect ratio so the preview fills edge-to-edge with no letterboxing — useful for keeping an eye on the capture from across the room, on an external display, or while navigating a virtual screen. The audio meters keep their width (only their height grows with the video preview), the panel stays clamped on-screen, and your choice is remembered across launches. The live preview's capture resolution scales up with the panel so it stays sharp.

## Screen recording — multiple displays

- **Record several screens at once, each to its own file.** The display picker in the floating overlay is now multi-select (with a **Record All Displays** shortcut), and every selected screen records in parallel to its own `.mov` named `ScreenCapture_<timestamp>_<DisplayName>.mov` so files never collide. Each file is fully self-contained — it gets the system-audio and (when enabled) microphone tracks plus the growing-file treatment (Blackmagic REC attribute, constant frame rate, per-frame timecode) — so every screen is independently importable as its own multicam angle, all sharing one start timestamp.
- **A single tiled overlay, not one panel per screen.** The preview shows a live tile per selected display, laid out side-by-side for two and wrapping into a grid for three or more, with the audio meters flanking the whole grid. The panel sizes itself to the tiles and still toggles between compact and expanded.
- **Per-screen controls on hover.** Hovering a tile reveals three buttons: **expand** that screen to a ~90% focus view (and collapse back to the grid), **start / stop recording** for that screen alone, and **remove** it from the recording. Recording is fully independent — you can start one screen, add another mid-session, stop or remove a screen while the rest keep rolling; a red **REC** badge marks the tiles that are live. Stopping the last active screen ends the session and offers all the saved files at once (reveal-all in Finder, or add them all to the encoding queue).
- **Region capture stays single-display.** Drawing a capture region still targets one screen; switching to Region mode collapses a multi-screen selection down to the primary display.

## Screen recording — virtual display

- **Record a window off-screen on a virtual display.** A new ＋ menu beside the display picker — in both the floating control panel and the capture window — spins up a headless **virtual display** (a real macOS display backed by no hardware) at **720p, 1080p, 1440p, or 4K**. Drag any window or live feed onto it and record it like any monitor, without it taking up space on your physical screens. The new display appears in the display picker automatically and is selected for capture straight away; a **Remove** entry in the same menu tears it down, and any virtual displays are cleaned up on quit so none linger.
- **Created as an extended desktop, not a mirror.** macOS drops a freshly created virtual display into a mirror set, pinned on top of your main screen. Each one is immediately detached into the extended desktop — session-scoped, so it never touches your saved display arrangement — so what you record is its own independent space rather than a copy of your main monitor.
- **Pixel-perfect capture.** The display is a plain SDR panel at exactly the chosen resolution, so the recording is those precise pixels with no scaling.
- **Built from scratch, GPL-clean.** Virtual displays use Apple's private `CGVirtualDisplay` API — the same mechanism apps like BetterDisplay rely on, since there's no public API for this. The interface is hand-declared in this project (no third-party code), so it stays fully open-source and GPL-3.0, adds no dependencies, and is isolated behind a runtime availability check that degrades to "unavailable" if the private API ever changes — leaving normal display capture unaffected. As a private API it isn't App-Store-compatible, which doesn't affect this direct-download build.

## AV2 encoding (experimental)

> ⚠️ **Experimental.** AV2 isn't in FFmpeg yet, so encoding goes through the AOM AVM reference encoder, which is inherently very slow (tens of seconds per frame at HD even at the fastest preset). Output is a young, evolving bitstream — treat it as a preview, not a delivery format.

- **New `.av2` export preset.** Encoded by the bundled `avmenc` over a two-process pipe: FFmpeg decodes / trims / scales to Y4M, piped into `avmenc`. Supports Constant-Quality (`--qp`) and VBR (`--target-bitrate`) modes, 8/10-bit, speed, and tiling, with an **EXPERIMENTAL** badge and a video-only warning in the AV2 settings card.
- **Parallel chunked encoding.** The clip is split into one frame-range chunk per core and a separate `avmenc` runs per chunk, then the segment `.ivf` files are joined in Swift. This scales far better than AVM's tile threading and compresses better (no tile boundaries). Auto-on, with a single-process escape hatch; Constant-Quality only (VBR can't span chunk boundaries). A configurable chunk count lives in AV2 settings.
- **Auto-tiling for single-process encodes.** AVM only parallelizes across tiles, so an untiled encode runs effectively single-threaded. When tiling is left on **Auto (0)**, tile columns/rows are now derived from the frame size (keeping each tile ≥ ~256px) — measured ~30% faster on an 18-core machine. Explicit tile values are still respected. Default speed is now the fastest `avmenc` setting (cpu-used 9).
- **Matroska muxing.** FFmpeg can't write AV2, so a new in-app muxer writes a `.mkv` with a `V_AV2` video track plus audio (AAC in ADTS, or Opus in Ogg with proper `OpusHead` / CodecDelay / SeekPreRoll). The AV2 CodecPrivate is harvested from a one-frame `avmenc --webm` probe; video frames are copied verbatim from the IVF. New AV2 settings choose the container (IVF / Matroska) and audio codec + bitrate.
- **Full decode round-trip.** `.ivf` and AV2-in-Matroska (`.mkv` / `.webm`) sources now decode through `avmdec` → FFmpeg, so AV2 is a real input, not encode-only. Decoding goes via self-describing **Y4M**, so 4:2:0 / 4:2:2 / 4:4:4 and 8/10-bit are all preserved instead of being silently downsampled to 4:2:0. Verified: AV2 `.mkv` → HEVC and ProRes 422 with audio intact.
- **Queue rows and thumbnails for AV2.** `.ivf` files are classified as video (dimensions and duration read from the IVF header in pure Swift, since FFmpeg/SwiftExif can't probe AV2), so they show a real duration and a decoded thumbnail and route correctly when transcoded to another video preset. The interactive trim player shows a clear "Preview not available for this format" message — there's no AV2 decoder in AVFoundation / VLCKit / MPV yet.
- **Accurate encode progress.** Progress is now driven by `avmenc`'s per-frame `POC:` output rather than FFmpeg (which only decodes the source and finishes in seconds), so the bar tracks the real encode instead of pinning at 100% while `avmenc` is still working.
- **`avmenc` / `avmdec` are codesigned** with the Developer ID Application identity, hardened runtime, and a secure timestamp — matching the other bundled CLI tools so notarization passes.

## Settings & custom-preset sync

- **Sync an allowlisted slice of settings across Macs** — your 10 custom presets, codec settings, file-naming, waveform, and general preferences — as a single versioned JSON snapshot. Off by default.
- Because this is a non-App-Store build with no iCloud entitlement, **"iCloud sync" writes the snapshot into the iCloud Drive folder on disk** (CloudDocs), which the OS syncs automatically. The same format also powers a **custom folder** target and manual **Export / Import** from the File menu.
- Machine-specific data (folder paths, bookmarks, binary install state, upload credentials) is deliberately excluded from the allowlist. A rolling local backup is taken before every apply, with newest-wins-and-notify, loop guards, and graceful handling when iCloud Drive is off. New **Sync** settings tab; an "updated from <Mac>" toast confirms an incoming change.

## Performance

- **Much faster queue sort with many items.** Sorting resolved each item's sort key lazily inside the comparator, so every one of the O(n log n) comparisons did an O(n) scan *and* a synchronous disk stat for the creation date — one keypress fired thousands of blocking `stat` calls on the main thread (part of the "lagging with many queued items" symptom). Keys are now resolved once up front (each file stat'd at most once, and only when the sort mode needs dates), then sorted on cached keys. The group-editor sort got the same decorate-sort-undecorate treatment.
- **Row-thumbnail generation is decoupled from encode start.** Starting an encode used to block on metadata probing *and* row-thumbnail generation together; for non-native card formats (MKV/MXF/MTS) the thumbnail is an FFmpeg seek+decode that can take several seconds, stalling conversion even though the encode never uses the thumbnail. Encode start now waits only for the metadata it needs; the thumbnail is generated independently on the import task.

## Uploads

- **Force-retry failed group uploads with Option-click.** Plain-clicking a group header's upload icon still toggles upload on/off; **Option-clicking** now restarts every item in the group whose upload failed or was cancelled, mirroring the existing per-item modifier-click.

## Stability

- **No more crash on Macs with zero active displays.** Four screen-capture sites used `NSScreen.main ?? NSScreen.screens[0]`, which traps when no display is active (`NSScreen.main` can be nil *and* `screens` can be empty). They now use `.screens.first` with a guard.
- **Custom-command parsing no longer drops an empty quoted argument.** An explicitly empty quoted arg (e.g. `-vf ""`) used to vanish, shifting every following token onto the wrong flag. It's now emitted correctly as `""`.

## Housekeeping

- **SwiftExif now resolves from Codeberg** (`taagedal/SwiftExif`, 1.9.1). The GitHub mirror is frozen at 1.6.0, so "Update to Latest Package Versions" kept re-resolving the stale URL and finding nothing newer. Both consumers compile unchanged.
- **Release zips strip AppleDouble metadata** (`--norsrc --noextattr --noacl --noqtn`). Without this, `ditto` encodes xattrs / ACLs / creation dates as `._<name>` companions inside the zip, which macOS Sequoia no longer merges back on extract — they surface as visible files inside the `.app`, break the codesignature seal, and trip Gatekeeper's "app is damaged". The 4.1.2 release zip was re-packaged retroactively with the same fix.
- Removed the stale `GEMINI.md` project-context file (recoverable from git history).

# v.4.1.3

A focused follow-up to 4.1.2. The recording-region picker now feels native — aspect-ratio lock plus macOS-style Shift / Option / Space modifiers during a drag — camera-card imports gained an opt-in "start encoding after import" toggle and finally do the right thing on multi-format cards, deleting an encoding group mid-upload no longer crashes, and new installs are opted in to automatic updates with a friendly first-launch opt-out notice.

## Recording region

- **Aspect-ratio lock for the capture region.** A new menu in the floating control panel offers **16:9**, **9:16**, **1:1**, **3:2**, **2:3**, **4:3**, and **3:4** (persisted per app launch). When a ratio is locked, the rectangle snaps to it while you draw and resize, so you don't have to eyeball the proportions.
- **macOS-native modifier keys during a region drag.** Hold **Space** to move the rectangle rigidly while drawing, then release to resume drawing from the new anchor. Hold **Shift** to lock the non-dominant axis (aspect-ratio takes precedence when both apply). Hold **Option** to scale symmetrically from the start point when drawing, or from the rect center when resizing. Modifier transitions replay the last drag value, so the region updates the moment you press or release a key — no extra mouse motion required.
- **Shift mid-drag now preserves the size you already drew** instead of collapsing the locked axis to a 1pt line. Holding Shift *before* the drag starts still produces the perfectly horizontal or vertical guide as before.
- **The capture overlay now holds keyboard focus** while the app is hidden, so Shift / Option / Space actually reach the drag pipeline. The previous build's `nonactivatingPanel` + `NSApp.hide` combo sent keystrokes to whichever app was previously frontmost, which is why modifiers silently did nothing during a drag. Space is now swallowed by the overlay too, instead of leaking through to whatever's playing underneath.

## Camera-card imports

- **"Start encoding after import" toggle in the camera-card sheet** (persisted across launches). Honoured by the regular, auto-split, and force-merge import paths — so multi-clip imports start encoding the moment they hit the queue when the option is on.
- **Multi-format card imports now honour the concat + upload intent.** When clips on the same card can't merge into one file (e.g. the operator switched to 4K or slow-mo mid-shoot), plain **Import** is no longer the primary action — **Auto-split** takes over with a tooltip pointing at the concat toggle, so Return picks the safe path that actually preserves your intent. Per-group filenames now include codec in the suffix, with `_g2`/`_g3`/… tie-breakers if any names still collide. Previously, H.264 1080p25 + H.265 1080p25 on the same card produced two outputs with the same base name.

## Stability

- **Deleting an encoding group while it's uploading no longer crashes.** Removing a group with an active rclone upload used to crash with "Index out of range" — the deletion handler tore down the group's array slot while the upload kept running and its progress callback fired into a binding whose backing array had just shrunk. The handler now cancels every in-flight upload in the group via `UploadManager.cancelUpload(itemID:)` first, and the upload-progress callback bounds-checks against a snapshot of the binding so any late-arriving rclone tick for a removed item is dropped silently.
- **New per-group Cancel upload button** on the group header's upload row gives you a non-destructive way to stop an upload — you no longer have to delete the whole group to abort. Visible only while the group is actively uploading or pending upload; hidden once the upload settles.

## Auto-update

- **New installs are opted in to automatic updates** by default. Sparkle's update dialog doesn't surface the auto-install preference, so users would otherwise have to dig into Settings to enable it. A one-time first-launch notice ("Automatic updates are on … turn off in Settings → Updates") with an **Open Settings…** shortcut lets you flip it back if you'd rather review each update by hand.
- **The first-launch notice is suppressed on Homebrew installs** (brew owns the bundle there), and is hardened against drift: the "have I shown this yet" flag survives across app updates via `UserDefaults.standard`, and the notice only fires when Sparkle is actually configured to install updates automatically — so a user who explicitly turned the preference off doesn't see a notice claiming otherwise.

## Localization

- **Norwegian translations caught up** across recent additions: Settings sidebar tabs (the labels were plain `String`s, so `Label.init` bypassed catalog lookup), FileZilla import, IMF / DCP wrap errors, MCA default labels, custom-filename template, capture overlay, the Sparkle / Homebrew update flow, and various settings and help text.
- **Typo and half-translation fixes** — "Vesjon" → "Versjon", "S3-kompatibel Storage" → "S3-kompatibel lagring", and positional placeholder fixes for the plural `%lld clip%@` forms.

## Housekeeping

- Drops the `com.apple.security.network.client` entitlement from both Debug and Release builds. It's a sandbox-only restriction; under the hardened runtime without the sandbox, it does nothing. The `com.apple.security.cs.disable-library-validation` entitlement stays — still required to load the bundled FFmpeg / MPV / VLCKit dylibs. No behavioural change for users.

# v.4.1.2

The headline is auto-update support for direct-download installs and a move of the project repository from GitHub to Codeberg. Also rolls up the small fixes that landed since 4.1.0 was tagged.

## Auto-update

- **Direct-download installs now auto-update.** A new updater (built on the Sparkle framework) checks for new releases on a configurable schedule, downloads them in the background, and — if you've opted in — installs the update on next launch. Daily / weekly / monthly cadence and an **Install updates automatically** toggle live under **Settings → Updates**, alongside a **Check for Updates…** item that's also reachable from the app menu. Update binaries are EdDSA-signed against a key embedded in this release; tampered or downgrade attempts are rejected before install.
- **Homebrew installs are detected and routed through `brew upgrade` instead.** The auto-updater never replaces a bundle that brew manages — that would create a checksum mismatch on the next `brew upgrade --cask`. When the in-app check finds an update on a brew install, the notification offers a one-click **Copy brew Command** button (`brew upgrade --cask aagedal-media-converter`) in place of the Download button, and Settings → Updates shows the same command with a copy-to-clipboard helper.

## Moved to Codeberg

- **Source code is now at [codeberg.org/taagedal/Aagedal-Media-Converter](https://codeberg.org/taagedal/Aagedal-Media-Converter).** All in-app links — the About window and the Settings → Updates source-code link — point at Codeberg now. The GitHub mirror is no longer the source of truth.
- **Homebrew tap moved to [codeberg.org/taagedal/homebrew-tap](https://codeberg.org/taagedal/homebrew-tap).** If you installed via brew, switch taps once: `brew untap aagedal/tap && brew tap taagedal/tap https://codeberg.org/taagedal/homebrew-tap`. After that, `brew upgrade --cask aagedal-media-converter` works as before.
- **The in-app update check now polls Codeberg's releases API**, so existing 4.1.1 installs surface this release in the update banner and can manually download it. After installing 4.1.2, Sparkle takes over for direct-download users; brew users continue to get notified by the in-app check and routed to brew.

## Bug fixes (rolled up from 4.1.1 and 4.1.2)

- **Capture region overlay can now be set to pass mouse clicks through** to the windows underneath, so the recording region selector doesn't block interaction with whatever's behind it while you frame a shot.
- **Upload settings now persist the full password.** A truncation bug was storing a shortened version, which broke authentication after relaunch. Existing entries continue to work — just re-enter the password if upload fails.
- **Tab key in the Upload and General settings panes** is no longer captured by the queue's table view. Settings now tracks its own NSWindow via `viewDidMoveToWindow`, so Tab cycles between fields the way it should.
- **Merged-group upload counter** showed "1/N" instead of "1/1" when uploading a merged group — fixed.
- **README screenshots scale correctly on Codeberg.** The inline `width`/`height` attributes that GitHub respects were being mis-applied by Codeberg's renderer, leaving the images either huge or tiny. Letting them flow at their natural size fixes the layout.

# v.4.1.0

A broadcast and cinema-leaning release: full IMF package export, per-item DCP/IMF metadata, MCA labels carried through audio routing, and a second OCR engine for bitmap subtitles.

## IMF & DCP

> ⚠️ **Experimental.** The IMF and DCP paths have not yet been validated against a professional mastering or QC workflow. Output may not pass strict compliance checks (Photon, Clairmeta, etc.) and the package layout, metadata fields, and MCA label derivation are likely to change. Treat as a preview — don't rely on it for delivery yet, and please report any issues you run into.

- **IMF export** — two new presets, **IMF (App #2e — JPEG 2000)** and **IMF (App #5 — ProRes)**, producing a complete IMF package folder (CPL, PKL, ASSETMAP.xml) with editable metadata. Audio is rewrapped as 24‑bit 48 kHz PCM with MCA labels (preserved from the source MXF when available, otherwise standard SMPTE layouts for mono / stereo / 5.1). Resolution and frame‑rate selections are persisted per preset.
- **Per‑item DCP/IMF metadata editor** — a film‑stack icon appears next to the comment button on each queue row when a DCP or IMF preset is active. Opens a sheet to edit **ContentTitle**, **ContentKind** (feature, trailer, etc.), **Annotation**, and **AudioLanguage** per item. The title auto‑populates from the filename. The sheet width was bumped to 640pt so the title/annotation fields and the Content Kind / Rating / Audio Language row fit comfortably in non‑English locales too.
- **Wrap failures now surface in the queue.** Missing `asdcp-wrap`, non‑zero exits, JP2/manifest assembly errors, and audio extraction failures populate the row's error capsule and tooltip instead of silently completing with an audio‑less or partial package.
- **Live progress through the wrap and packaging stages.** Audio extraction, `asdcp-wrap`, and manifest writes now report progress to the queue card instead of pegging at the FFmpeg hand-off, and a deadlock around `asdcp-wrap`'s stdout pipe is fixed so long IMF audio essences no longer hang the wrap step.
- **Quality Analytics runs on the inner MXF** for DCP and IMF exports, so VMAF / PSNR / SSIMULACRA2 compare the actual mastered essence instead of stopping at the package boundary.

## Audio Routing — MCA Labels

- **Imported from MXF and IMF inputs** — SMPTE ST 377‑4 MCA descriptors are now parsed from MXF files (and IMF packages dropped onto the queue), and the routing inspector surfaces them inline, e.g. `Track 1 • DX • 5.1 • L R C LFE Ls Rs`.
- **Injected into TV (AVC‑Intra MXF) output** — when routing audio through the mono‑split AVC‑Intra workflow, the encoder now emits a matching `bmx --track-mca-labels` file. Source labels are preferred; standard SMPTE labels are derived for mono / stereo / 5.1 layouts when the source has none.
- **Per‑track manual override** — each output track in the routing inspector now has a tag‑icon menu for picking the **Soundfield** (Mono, Stereo, Dual Mono, 5.1, 7.1, Lt‑Rt) and the **Audio Element** (Main, Music & Effects, Dialog, …). Overrides take precedence over auto‑derived labels. (Applies to AVC‑Intra TV output today; IMF and DCP continue to derive from the source.)

## Subtitles

- **Apple Vision OCR engine** for PGS/VOBSUB bitmap subtitles, alongside the existing Tesseract engine. Vision is noticeably more accurate than Tesseract — especially on stylised or anti‑aliased subtitle bitmaps where Tesseract tends to mis‑read glyphs like `I` vs. `|` or `rn` vs. `m` — and needs no extra binaries or language packs. New picker in **Settings → Subtitles → OCR Engine**; Vision is the default for new installs, while existing users keep their current Tesseract setup.
- **Real progress during PGS extraction.** Subtitle dumps now stream FFmpeg's demux progress into the queue card (mapped onto the 0–15% extract slice), and the status label shows what the engine is actually doing — "Extracting subtitle stream", "Recognizing text", "Transcribing (Whisper)" — instead of a bare percentage that left feature-length rips looking frozen.

## Metadata

- **SwiftExif updated to 1.6.0** (from 1.3.1) — enables the MXF MCA descriptor parsing used by the routing inspector, and includes upstream parsing fixes.
- **Faster imports** — concurrent SwiftExif reads of the same file are now coalesced into a single parse, so the parallel async‑let import flow no longer probes every file twice.

## UI & polish

- Queue cards now adapt correctly to **Light mode** — backgrounds, the idle encode (play) button, and the group‑child cool tint were all stuck on the dark palette. Reset/Delete row buttons were reordered (reset before delete) to match the toolbar, and reset is now hidden entirely when not applicable instead of greying out.
- **Idle queue cards now carry a thin, theme-aware outline** so cards read as distinct cards in both light and dark mode without being shouty.
- **Click a queue row's error capsule to copy the full message** to the clipboard, with a brief "Copied to clipboard" confirmation. Long `bmxtranswrap` / `asdcp-wrap` stderr lines (and any other truncated failure text) are now reachable instead of being hidden by row truncation.
- **Wider Settings sidebar** so longer non-English row labels stop wrapping, and **new encoding groups now adopt a configurable default format** instead of always falling back to the global preset.
- The metadata row's hover and click hit‑area now ends at the rightmost visible label instead of stretching across the empty trailing space, so that area is free for normal row selection.
- Queue rows now apply **resolution / codec / FPS as soon as the metadata probe returns**, instead of waiting on the thumbnail+duration step. Imported queues feel like they fill in faster.
- Queue card thumbnails **re‑rasterize when the window moves between displays** with different backing scales, so dragging the window to or from an external non‑Retina display no longer leaves blurry artwork.
- App Intent display names (**Add to Encode Queue**, **Convert Immediately**) are now tracked in the string catalog so they can be localized.

## Bug fixes

- **Running two subtitle engines on the same source overwrote the first engine's SRT.** Tesseract → Whisper (and any other combination) shared the hard-coded `<base>.srt` destination, so the second run silently replaced the first. The first run for a given basename now writes the canonical `<base>.srt`; subsequent runs from a different engine write `<base>.<method>.srt` so both outputs sit side-by-side. Wired through Tesseract, Whisper, and Parakeet.
- **MKV PGS / VOBSUB subtitles were silently rejected by OCR.** SwiftExif's Matroska reader returns the container‑native codec IDs (`S_HDMV/PGS`, `S_VOBSUB`), but the four bitmap‑codec gates in the OCR launch path only knew FFprobe's vocabulary, so the OCR button stayed hidden on MKVs and any OCR run aborted with "No bitmap subtitle stream found". All gates now recognize both naming styles.
- **Tesseract OCR mapped the wrong stream on MKV inputs.** The extract step used absolute stream indexing (`0:N`); SwiftExif reports `index` relative to subtitle streams, so on a typical \[video, audio, subtitle\] MKV the muxer tried to ingest the video stream and rejected the run with "sup muxer does not support any stream of type video". Now uses the type‑relative `0:s:N` selector.
- **Tesseract pipeline hardened.** A misconfigured `tessdata` path now surfaces as a real error instead of silently producing an empty SRT, cancellations land mid‑extract instead of queueing behind the actor (and translate to *cancelled* rather than the misleading "FFmpeg exited 15"), and 60 s extraction / 10 s per‑frame timeouts prevent a wedged subprocess from pinning the queue forever. Orphan `/tmp/TesseractOCR-*` directories are also swept at launch.

# v.4.0.1

A follow-up release focused on the download/upload pipeline: a bundled rclone, whole-playlist downloads, audio-only downloads, and a round of security hardening across both yt-dlp and rclone.

## Downloads

- **Whole-playlist download toggle** — paste a playlist, channel, or album URL and every entry is queued up front so you can see the full size of the job. Downloads run sequentially through the existing pipeline; per-item retry/cancel still works. The toggle only appears for URLs that look like a playlist (YouTube `list=` / `/playlist` / `/channel` / `/@handle`, Vimeo `/album` / `/channels` / `/showcase`, SoundCloud `/sets`).
- **Audio-only toggle** in the URL dialogue — pulls the best audio-only stream and extracts it without re-encoding when possible. Persisted on the queue item and on scheduled downloads.
- **File controls on the queue row** for downloaded sources — reveal-in-Finder, copy-path, and drag-out, tinted to match the DOWNLOADING status capsule.
- Update banner now offers **Release Notes** and **Download** buttons that go straight to the GitHub release page and the `.zip` asset, instead of the generic releases landing page. Notifications now fire when the GitHub release is published rather than waiting on the Homebrew cask schedule.

## Uploads (rclone)

- **Bundled minimal rclone binary** so uploads work out of the box, with an **App / Homebrew / Custom** picker in Upload Settings mirroring the yt-dlp pattern. Custom binaries are validated against an `rclone v…` version string with a per-file fingerprint cache.

## Security & hardening

- **Block downloads to private networks by default** — rejects URLs whose host is a private/loopback/link-local IP (10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, IPv6 `::1` / `fc00::/7` / `fe80::/10`) or `localhost` / `*.local`. New **Allow private network downloads** toggle in Settings → Download lifts the restriction for LAN media servers (Jellyfin, Plex).
- **rclone credential leak hardening** — passwords and S3 secrets are passed via `RCLONE_CONFIG_<NAME>_*` environment variables and stdin, never on argv where `ps` could see them. Error messages bubbled to the UI have embedded credentials stripped and length-bounded; subprocess output is logged at `.private` privacy.
- **rclone install verification** — downloaded rclone binaries must match the SHA-256 entry in the release's `SHA256SUMS` and carry a valid Apple code signature before the quarantine xattr is cleared. GitHub fetches send a User-Agent and refuse cross-host redirects. Subprocesses run with timeouts and a watchdog instead of blocking forever.
- **yt-dlp output path confined to the chosen folder** — the post-download path emitted by yt-dlp is validated against the output directory before any filesystem touch, defending against `%(title)s` template escapes. A security-scoped bookmark is held for the lifetime of the subprocess so non-default folders survive across relaunch.
- yt-dlp updates **refuse to install when the SHA2-256SUMS manifest is missing** instead of silently skipping verification.

## Bug fixes

- Fixed the toolbar preset label and queue row filenames going stale when switching the nested format under **Animated Still** (AVIF↔GIF↔APNG) or **Audio Only** (WAV↔AAC↔MP4↔FLAC).
- Fixed the yt-dlp output filename label staying frozen on the "Fetching info…" placeholder until the download completed, instead of updating when the real title arrived.
- Widened the URL download overlay (620pt) and history list (220pt) so the four toggles no longer feel cramped, and arrow-key navigation now keeps the selected history entry inside the visible scroll area.
- Disabled the **Schedule** checkbox when **Whole playlist** is on (the persistence model doesn't support that combination); turning the playlist toggle on clears any pending schedule.
- The **Whole playlist** toggle (and any value carried over from a prior session) is now gated by the playlist-URL heuristic so a single-video URL can no longer accidentally kick off a playlist run.

# v.4.0.0

This is the biggest release yet, rolling up everything from the 3.9 beta plus a lot of polish since. Highlights up top; bug fixes at the bottom.

## Encoding Groups & Camera Card Import

### Encoding Groups
A new item type in the encoding queue. An Encoding Group can have its own encoding settings, separate from the rest of the queue. This was primarily built to work together with the new Card Import dialogue, but you can also create a group on its own with **⌘N** and drag items from the queue into it.

Groups can be placed anywhere in the queue, and you can now edit a group in a dedicated editor window.

### Camera Card Import
A new memory-card import dialogue (**⌘⇧I**) lets you select a camera folder and automatically extract videos from subfolders into an Encoding Group. You can name the card, and output files will be numbered sequentially after the card name.

Combined with Encoding Groups, you can now import and queue media from multiple cameras in one batch while still using the Stream Copy preset per-group.

## Redesigned Queue (much faster scrolling)

The queue rows have been rebuilt from SwiftUI to AppKit. Scrolling stays smooth even with hundreds of items, thumbnails decode off the main thread, and progress updates no longer thrash the UI.

While we were in there we also redesigned the cell layout for 4.0:

- New liquid-glass circular thumbnail badges with a blurred toolbar overlay.
- Filmstrip thumbnails and waveforms generate on demand as you scroll into view.
- Expanded row metadata, larger badges, and a persistent timecode badge.
- Status text moved below the progress bar so nothing shifts around during encoding.
- Hover actions and **Shift+⌘** modifier shortcuts directly on queue rows.
- Right-click context menu for quick actions (Show in Finder, Preview, Trim, Metadata, Audio Routing, Attach Subtitle, Rename, Reset, Remove).
- Drag encoded files out to any app, and drag them back into the queue to re-encode.

## Region-based Screen Recording

Record a specific area of your screen instead of the full display. An interactive full-screen overlay lets you draw and resize a selection rectangle, then captures only that region at native resolution with a floating control panel.

You can also **schedule a recording** from the same overlay, and hover the audio meters in the preview for level tooltips.

## Subtitles & Transcription

### Parakeet transcription engine
Added Parakeet (NeMo ASR via MLX) as a second speech-to-text engine alongside Whisper, optimized for Apple Silicon — potentially much faster transcription. Requires Python and `parakeet-mlx` to be installed manually.

### Tesseract OCR
New OCR engine for turning PGS/VOBSUB subtitle image files (common in DVD/Blu-ray) into SRT by reading text from image frames. Generally faster and better timed than re-transcribing, with the caveat that characters can occasionally be misread (e.g. `I` vs. `|`).

### Subtitle embedding
Automatically embed generated SRT subtitles into the output video after transcription or OCR.

### Attach subtitle files
Attach external SRT/ASS/SSA files to queue items and optionally mux them into an already-encoded output.

## Video Quality Analytics

Run analytics to compare the quality of an encode against its source, view the results in a new UI overlay, and manually or automatically export the report to JSON or PDF.

Supported metrics:

- **VMAF**
- **PSNR**
- **XPSNR**
- **SSIMULACRA2** (requires `cargo install`; flagged with a performance warning in settings)

## Metadata & C2PA

Metadata reading has been migrated from ExifTool to a bundled SwiftExif, which is much faster and means one less external dependency.

- Expanded metadata window with a source ↔ output comparison view.
- Export full metadata reports as JSON or PDF.
- C2PA content credentials support, with correct handling when credentials aren't present.
- Chapter data now read directly via SwiftExif.
- Faster imports overall, thanks to deduped probes and a cap on concurrent probing.

## Unified Audio Only preset

The three separate audio presets (WAV, AAC, MP4) have been consolidated into a single **Audio Only** preset with configurable format, codec, bit depth, and bitrate.

## Encoding options

- **More CRF options** for finer quality control.
- **AV1 tune modes** with new tuning options, including SVT-AV1-PSY "Subjective Quality" tuning.
- Updated FFMPEG binary with **SVT-AV1 4.1.0** for faster, higher-quality AV1 and AVIF encoding.
- **Subtitle preservation toggle** — choose whether to keep existing subtitles in the output.
- Improved help descriptions throughout the preset settings.

## Crop & Preview

- Redesigned crop handles: L-shaped corner brackets and rectangular edge handles for a more professional look.
- Crop corner cursors now have a white outline so they're visible on dark backgrounds.
- Throttled trim drag seeks and added cursor affordances for the different trim modes.
- HDR thumbnails are now correctly tone-mapped for SDR display.
- Filmstrip thumbnails use AVFoundation (with an FFMPEG fallback) for faster generation and instant tooltips.
- Fullscreen player adopts the cleaner design from Aagedal Media Player.

## Settings & UI

- **New Settings layout** — redesigned from a tab bar to a collapsible sidebar with an icon-only mode. The per-tab pages have also been reorganized for a more consistent layout.
- **Searchable keyboard shortcuts** — filter shortcuts by key combo, description, or group name.
- **Auto-delete old encodes** — optional setting to automatically clean up encoded files older than a configurable number of days from the default output folder.
- **Confirmation dialogs** for destructive actions (removing items, resetting, etc.).
- **Norwegian Bokmål translations**.
- Expanded About page with links and licenses for bundled dependencies.

## Downloads (yt-dlp)

- Surfaces the first real yt-dlp error when a download fails, with a stall watchdog to catch frozen downloads.
- SHA256 verification for downloaded yt-dlp and deno binaries.
- Hardened argument handling and tighter output-path parsing.
- Cancel button and polished status UI for yt-dlp and deno downloads.
- Download overlay now only appears when yt-dlp is actually configured, with cleaner URL validation and Tab focus handling.

## Watch Folder

- Watch Folder auto-activates on launch if it was enabled when you quit.
- Unified Upload and folder layouts.

## Bug fixes

- Fixed merge/concat stripping audio across all presets.
- Fixed Stream Copy dropping audio in certain cases.
- Fixed concat merge using the sequential file name instead of the encoding group name.
- Fixed encoding group item actions, metadata view, and single-file card import.
- Fixed missing metadata for encoding group items and stale merge temp files.
- Fixed the encoding queue not updating when files were added via drag-and-drop.
- Fixed batch conversion ordering when encoding groups are interleaved with regular items.
- Fixed subtitle cancellation showing a spurious error.
- Fixed missing and incorrect entries in the Keyboard settings view, and made the shortcut search match group titles.
- Fixed analytics cancellation and routed the button to the results view.
- Fixed black frames when combining trim with the Stream Copy preset (particularly nasty when also merging).
- Fixed the ETA calculation to use FFMPEG's `speed=` field instead of a broken formula.
- Surfaced FFMPEG error reasons in the UI when conversion fails, with better error pattern matching.
- Fixed long filenames breaking queue row layout and yt-dlp status strings.
- Fixed layout shifts in the toggle buttons and status area during encoding.
- Fixed the fullscreen player's Space key being swallowed by the queue's keyboard monitor.
- Fixed several crash risks: replaced `fatalError` and force-casts with safe error handling, and closed security-scoped resource leaks in the conversion pipeline and preview generator.
- Fixed C2PA false positives and hid C2PA UI when credentials aren't available.
- Mitigated the MPV Metal validation crash when toggling crop mode during a seek.
- Guarded the update-notification against cancellation errors.
