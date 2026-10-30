# Corresponding sources and release attribution

Release distributions include a separate `Aagedal_Media_Converter_*_Sources_*.tar`
companion alongside the application ZIP. It contains reviewed source archives,
licenses, patches and build instructions for the bundled copyleft components.
The app's About > Licenses viewer also provides the collected notices offline.
The companion's `AttributionSources.json` records each archive's component,
filename, byte size and SHA-256. Paths in that distributed manifest are relative
to the extracted companion. Source code for the application itself is available
from this repository at the release's commit, including Xcode project and package
pins. Apple SDKs, system libraries and general build tools are not redistributed.

## Source material

- **FFmpeg 9.0.2:** the corrected full build includes the Metal YADIF teardown
  correction. The original dependency-source and generated-input archives retain
  the codec libraries reused by this build; a third correction archive preserves
  the patched full FFmpeg tree, exact modified recipes, patch authorship/license,
  and actual full-tree configuration. Extract the dependency archive first, then
  overlay the correction archive and follow its `README-metal-source.md` to rebuild.
  All three archives remain required in the source companion. Install Xcode with
  its Metal compiler, CMake, Meson, Ninja, pkg-config, Python 3, and the usual build
  utilities. Current evidence is in
  `docs/provenance/4.5-local-builds/ffmpeg-9.0.2-metal/`; the earlier capture and its
  explicitly scoped generated dependency inputs remain in `ffmpeg-9.0.2/`.
- **rclone:** the reviewed minimal source revision with only the unused `serve s3`
  command removed; its S3 storage backend remains. The archive includes the
  exact source patch, Go toolchain/module inputs, notices and `rebuild.py`, plus
  directions for installing a modified helper through the app's custom-tool
  setting. An offline rebuild reproduced the distributed helper byte-for-byte.
- **AVM/Eigen:** the retained Eigen source and applicable licenses, including
  every compiler-referenced Eigen file. Other AVM component notices and patent
  statements are included in `avm-LICENSE.txt`; their permissive licenses do not
  all require a separate source distribution. The integrated encoder/main build
  retains the complete pinned merged tree, dependency archives, resolved patch
  and build recipe in `avm-2026-10-14-integrated-source.tar.gz`. Rebuild instructions
  and dependency-byte verification are in `docs/av2-integrated-encoder-2026-10-14.md`
  and `docs/provenance/avm-2026-10-14-integrated/`. Historical reference-build
  evidence is retained separately.
- **MPVKit:** pinned wrapper and upstream dependency sources, the retained patched
  mpv and FFmpeg sources, build configurations/recipes and their transitive source
  inputs. The package review distinguishes direct archive/payload matches from
  version/build-date inferences for some upstream runtime notices. It does not
  claim every upstream binary has been independently reproduced.
- **yt-dlp-rs MPL-2.0 crates:** the unmodified crates.io sources of the four
  MPL-2.0 crates statically linked into the bundled yt-dlp-rs helper, verified
  against its `Cargo.lock` checksums. Recreate the archive byte-for-byte with
  `python3 scripts/generate-ytdlp-rs-notices.py <tag>`; see
  `docs/provenance/yt-dlp-rs/README.md`.
- **SwiftMediaMetadata 3.1.0:** the exact pinned source tree, including the GeoNames
  database and its upstream acknowledgement. Its source package identifies
  required platform tools and dependencies in `Package.swift`.

Detailed evidence for the existing dependency set is retained under
`docs/provenance/4.4-local-builds/`. The 4.5 patched MPVKit package and source
archive are recorded in `docs/4.5-mpv-coreaudio-package-validation-2026-09-25.md`.
The replacement `coreaudio.2` package at revision
`400202b687841fb394cbf0ef59ad8c6fcfc1275b` includes the additional failed-unit
handle cleanup; its published source and updated compile/patch records replace
the active CoreAudio source/configuration entries in `AttributionSources.json`.
The 4.4 provenance remains historical. See
`docs/4.5-mpv-coreaudio-failure-cleanup-validation-2026-09-26.md`.
Build recipes describe their dependencies; use the recorded revisions instead
of current branches. Where a local source archive has no upstream download URL,
retain that archive or restore it from the source companion. Regenerating or
changing an archive requires reviewing its contents and updating its recorded
hash; do not simply remove it from the manifest to make the release gate pass.

## Preparing a release

Required local archives are listed in the repository's `AttributionSources.json`
and stored under ignored `build/attribution/`. They are deliberately separate
from `build/release/`, which holds replaceable release outputs. Keep a durable
copy of the generated source companion with the release artifacts.

For the October 14 integrated AVM build, all 91 reviewed archives are available
locally and both strict attribution checks pass. Missing worktree inputs were
restored by matching existing reviewed archives against the unchanged manifest;
no source requirement or hash was relaxed. The generated companion and check
results are recorded in
`docs/provenance/avm-2026-10-14-integrated/release-attribution.json`. These source
archives are ignored by Git, so a new worktree must still restore them from
retained source material before running the release checks.

```sh
python3 scripts/package-attribution-sources.py --check
python3 scripts/bundled-dependency-manifest.py --check --require-complete-licenses
python3 scripts/package-attribution-sources.py --output /path/to/Sources.tar
```

The strict attribution gate checks required source-component coverage and every
source archive's bytes, in addition to tool and Swift-package notice coverage.
Swift package attributions are tied to `Package.resolved` revisions; adding or
updating a package requires a new review. `release.sh` freezes those package
versions, builds the source companion before signing, and verifies its copied
source bytes. It uploads sources before replacing an existing public binary;
new releases remain drafts until both source and binary uploads succeed. Source
filenames include version, build and manifest hash, preserving source material
for older builds. Manual releases must attach the source companion as well as
the application ZIP. No public release is performed by the attribution checks.

After publishing the GitHub release, `release.sh` opens an appcast-only PR using
an isolated temporary checkout. Merge the printed PR and confirm that the
**Publish website appcast** workflow succeeds: publishing the release alone does
not deploy the app's live update feed. The helper preserves entries from `main`
and reuses an open PR when retried. If this step fails, the script exits with an
error and prints a `publish-release-appcast.py` command to retry using the
verified artifacts, without rebuilding or uploading the release again. When
GitHub CLI is unavailable or unauthenticated, the script prints the manual
release and appcast deployment steps instead.

## MPVKit 1.1.0 / FFmpeg 9.0.2 — 2026-10-15

The current package pin is `68c8989362a0daedabcc1540b2b5f0e1fea4be1f`.
Its eight custom macOS GPL libraries are rebuilt together against FFmpeg n9.0.2,
retaining mpv 0.41.0, CoreAudio fixes and opt-in audio-analysis filters. The
`mpvkit-n9.0.2-sources.tar.gz` archive replaces the previous local mpv/FFmpeg and
CoreAudio configuration archives. It includes the exact staged sources, patches,
library-only Swift recipe and per-architecture compiler configurations. The
separate `MPVKit-1.1.0-pinned-source.tar.gz` records the exact wrapper commit.
Unchanged auxiliary source inputs and their original build recipes remain
required. Both archives are recorded with their byte counts and SHA-256 in
`AttributionSources.json`; the custom source archive is also a release asset.

The offline MPVKit notice includes the retained original collections plus current
FFmpeg n9.0.2 license and source permission notices. The additional notice
collection has a checked SHA-256 and source index under
`docs/provenance/4.5-local-builds/mpvkit-n9.0.2/`. Original 4.4/4.5 CoreAudio
records above remain historical. Current evidence and validation scope are in
[the update report](mpvkit-1.1.0-update-2026-10-15.md).
