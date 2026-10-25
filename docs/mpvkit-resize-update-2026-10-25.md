# MPVKit MoltenVK resize fix — 2026-10-25

Media Converter now pins the aagedal MPVKit fork at
`f957f4830d449e80723554cdc05ddc4138c1806e` (release
[`aagedal-1.1.0-n9.0.2-resize.1`](https://github.com/aagedal/MPVKit/releases/tag/aagedal-1.1.0-n9.0.2-resize.1)),
replacing `68c8989362a0daedabcc1540b2b5f0e1fea4be1f`.

## Change

mpv's `moltenvk` gpu-context resized its swapchain only in `reconfig`, so
`vo->dwidth/dheight` kept the size from the last file load. After a host view
resize the video kept drawing into the old rectangle; a paused frame sat at its
old size in a corner. Patch `0006-moltenvk-follow-layer-resize.patch`:

- polls `drawableSize` in `VOCTRL_CHECK_EVENTS` and reports `VO_EVENT_RESIZE`;
- adds `--moltenvk-surface-size=WxH`, which reuses the `VOCTRL_EXTERNAL_RESIZE`
  path of `--android-surface-size` to resize and redraw immediately.

The app sets `moltenvk-surface-size` after `MPVMetalLayer` applies a deferred
`drawableSize` change (`MPVPlayer.surfaceDidResize(to:)`). The clip picker's
temporary fixed-size rendering workaround is removed; all MPV views share the
normal resize path. Everything else matches `aagedal-1.1.0-n9.0.2-audio.1`.

## Verification

- All eight GPL framework archives and the source archive match the release
  `SHA256SUMS.txt` and the checksums in the fork's `Package.swift`; the source
  archive contains the patched `context_moltenvk.m` and the patch file. The
  built app's Libmpv contains the new option.
- Clip picker, paused: six alternating window grows/shrinks, then a resize
  while playing — the frame fills the view at the correct scale every time.
- Six live resizes during playback with `MTL_DEBUG_LAYER=1`
  (`MTL_DEBUG_LAYER_ERROR_MODE=assert`): no validation failure or crash.
- MPV UI tests pass: preview seek/screenshot/reopen, stitching sequence
  playback/replay, source/playback meters, audio regrouping pixels.
- All unit tests pass (1,570, 4 skipped); script tests, localization audit,
  regenerated MPVKit notices and the complete-license manifest gate pass.

## Sources

New archives (git-ignored, under `build/attribution/mpvkit/`):

- `mpvkit-n9.0.2-resize.1-sources.tar.gz` — the release source archive,
  SHA-256 `8c82737847482824982302a2a123c0b2e8517671a76f712abf26ca29fda9d50a`.
- `MPVKit-1.1.0-resize.1-pinned-source.tar.gz` — `git archive` of the pinned
  wrapper commit (same tar content method as the previous archive), SHA-256
  `86b2fa4573fe799adbfec9a54f05597feffd243d46f54590f88145c8fa7b5b3c`.

The previous archives keep their names, so checkouts that still pin the old
revision stay valid. A release checkout needs the two new archives.
