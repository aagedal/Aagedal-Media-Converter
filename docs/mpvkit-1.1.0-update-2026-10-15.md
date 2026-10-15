# MPVKit 1.1.0 / FFmpeg 9.0.2 update — 2026-10-15

Media Converter now pins the aagedal MPVKit fork at
`68c8989362a0daedabcc1540b2b5f0e1fea4be1f`, replacing
`400202b687841fb394cbf0ef59ad8c6fcfc1275b`.

The fork's merge commit incorporates official main through
[`d9194243bdc6`](https://github.com/mpvkit/MPVKit/commit/d9194243bdc68b87d8989376ab52aee7da6c8e0b),
including the FFmpeg n9.0.2 recipe, removal of obsolete FFmpeg shaderc/sonic
options, and build-time Vulkan shader compiler discovery. The isolated rebuild
script now reads source tags from the Swift recipe rather than hardcoding 8.1.2.
The existing sibling MPVKit working copy was left untouched; the update was
prepared in `/private/tmp/amc-mpvkit-update-20261015` and pushed to fork main.

## Published dependency

[Release `aagedal-1.1.0-n9.0.2-audio.1`](https://github.com/aagedal/MPVKit/releases/tag/aagedal-1.1.0-n9.0.2-audio.1)
contains eight freshly rebuilt macOS GPL frameworks for arm64 and x86_64. mpv
remains 0.41.0; its FFmpeg libraries are now n9.0.2. The custom codec options,
CoreAudio initialization/disposed-handle cleanup fixes, and opt-in
`astats`/`asetnsamples`/`ebur128` filters are retained. Experimental video scopes
and decoder-raster remain disabled. Auxiliary library artifacts are unchanged;
LGPL package targets use official 1.1.0-n9.0.2 artifacts.

The manifest uses exact URLs/checksums. All eight binary archives and the source
archive were downloaded after publication and match their qualified local hashes.
Xcode resolved the exact package revision, and all eight Debug framework payloads
match the qualified binaries byte-for-byte.

## Validation

- Both architecture builds pass. All eight archives have matching framework
  payloads, universal arm64/x86_64 slices, and object deployment floors no higher
  than macOS 12. Actual build configurations enable GPL and the analysis filters.
- Eight audio-analysis signal/filter cases pass on arm64 and eight under x86_64
  Rosetta, covering mono/stereo/5.1/silence, peak/RMS, loudness, true peak, filter
  removal, exact seek and restart.
- CoreAudio normal playback, simulated device notification, forced initialization
  failure and forced stream-format failure each pass four cycles with zero
  invalid calls and zero remaining listeners.
- Signed Debug app tests: all 22 `MPVPreviewObservationTests` pass, zero skipped.
  Result bundle: `/private/tmp/amc-mpvkit-n9-tests.xcresult`.
- Signed Release build passes. Strict/deep signature verification passes; static
  bundle validation verifies 59 arm64 Mach-O images, all executable Hardened
  Runtime signatures, bundled library resolution and 14 packaged license notices.
  Build log: `/private/tmp/amc-mpvkit-n9-release-build.log`.
- Both signed Debug MPV UI tests pass: preview seek/screenshot/reopen (45.897 s)
  and stitching sequence playback/replay (75.833 s), zero failures.
  Result bundle: `/private/tmp/amc-mpvkit-n9-ui-tests.xcresult`.
- Dependency-manifest and attribution-source unit tests: 26 pass.
- All 89 corresponding-source archives verify. Strict complete-license manifest
  validation and offline notice generation checks pass.

Evidence is retained under
[`provenance/4.5-local-builds/mpvkit-n9.0.2/`](provenance/4.5-local-builds/mpvkit-n9.0.2/).
Build/probe logs and complete source companion are under `/private/tmp/` with
prefix `amc-mpvkit-n9-`; the source companion is
`/private/tmp/amc-mpvkit-n9-complete-sources.tar`.

## Source and notice updates

`PackageAttributions.json`, `BundledDependencies.json`, the project pin and the
resolved package revision agree. The new custom source archive replaces the old
local mpv/FFmpeg/CoreAudio configuration source entries; a separate archive
retains the exact published wrapper commit. Existing auxiliary source archives
remain required. The offline notice retains original collections and adds the
current FFmpeg n9.0.2 license/permission notices, source index and checked digest.
The notice generator verifies that the current selected target graph has the
same notice coverage and unchanged auxiliary archive hashes.

Dependency probes do not establish physical hotplug, physical Intel hardware,
or long-duration thermal behavior. Local Apple Development signing does not
establish Developer ID distribution or notarization.
