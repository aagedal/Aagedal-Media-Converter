# Isolated MPV CoreAudio rebuild

The 2026-09-26 runtime probe found stale AudioUnit cleanup in the published
CoreAudio `.1` candidate. The recipe now also applies
`mpv-0.41.0-coreaudio-clear-failed-unit.patch` and disables the separate CLI
player (`cplayer=false`). The fresh universal replacement and matching source are
published as `aagedal-1.0.0-n8.1.2-coreaudio.2`. The app previously pinned it at
`400202b687841fb394cbf0ef59ad8c6fcfc1275b`. The current package merges official
MPVKit 1.1.0 and rebuilds these fixes
against FFmpeg 9.0.2 at `68c8989362a0daedabcc1540b2b5f0e1fea4be1f`; see
[the update validation](../mpvkit-1.1.0-update-2026-10-15.md). See the
[failure-cleanup validation](../4.5-mpv-coreaudio-failure-cleanup-validation-2026-09-26.md).

To repeat the isolated runtime check after an Xcode build:

```bash
python3 scripts/verify-mpv-coreaudio-runtime.py \
  --products /path/to/DerivedData/Build/Products/Debug \
  --ffmpeg "Aagedal Media Converter/Binaries/ffmpeg" \
  --output /private/tmp/mpv-coreaudio-runtime-new
```

Use `--libmpv /path/to/candidate/Libmpv.framework/Versions/A/Libmpv` to test a
local replacement without changing the app or package cache. Normal login-session
audio-service access is required. The four modes cover actual silent playback,
simulated device notification, and forced initialization/format failures; physical
device changes and signed application checks remain separate.

`rebuild-mpv-coreaudio.py` stages a macOS GPL libmpv-only build from the pinned
local MPVKit recipe and its existing dependency outputs. It applies the complete
retained upstream CoreAudio initialization-failure patch explicitly, including
when the source checkout already exists. It does not update the app dependency.

```sh
python3 docs/dependency-patches/rebuild-mpv-coreaudio.py \
  --mpvkit ../MPVKit \
  --output /private/tmp/amc-mpv-coreaudio-candidate \
  --build
```

Omit `--build` to inspect the staged recipe first. The output path must not exist.
The driver requires MPVKit revision `230c3174f1515898f24599147ad61c2a277d0dc2`
and mpv revision `41f6a645068483470267271e1d09966ca3b9f413`. Existing source
modifications are retained and recorded as a binary Git diff; the original
checkout is never patched. A full source-input manifest hashes every copied file
(including untracked/ignored inputs) and records symlink targets; Git status and
the manifest checksum are retained in build evidence. Dependency directories are read through symlinks,
while source, libmpv build outputs, framework assembly, and release packaging
live in the staging directory. Do not move/remove the dependency inputs during
the build.

The copied recipe calls only `BuildMPV().buildALL()`. Its normal fresh build
generates arm64/x86_64 Meson configurations using the installed SDK, then uses
MPVKit's framework/xcframework assembly and packaging. It also:

- Restores tracked macOS bundle assets removed by previous packaging, directly
  from the pinned mpv commit. Unexpected deleted source files cause failure.
- Preserves `TMPDIR` and the compiler module-cache path in the recipe's process
  launcher, which otherwise discards them and causes sandboxed compiler probes
  to fail.
- Disables SwiftPM's nested manifest sandbox for this local build recipe; the
  enclosing execution sandbox remains in force.

`rebuild-evidence.json` records source revisions, patch/diff checksums, restored
assets, installed SDK, build status, and candidate archive/binary checksums.
`build.log` retains full build output.
These are candidate-build diagnostics, not complete redistribution provenance:
dependency payload checksums, source archives, notices, framework correspondence,
versioned archive publication, package pin updates, and app-level CoreAudio
failure/hotplug/teardown validation remain release gates. A successful build is
explicitly marked `release_ready: false`.

The original patch attribution is preserved in
`mpv-0.41.0-coreaudio-init-failure.patch`. Historical 4.4 provenance is unchanged.

## Verified candidate — 2026-09-22

The isolated build completed successfully with the macOS 27 SDK: both arm64 and
x86_64 libmpv libraries compiled, and MPVKit assembled the universal framework,
XCFramework, and ZIP archives. `lipo -archs` confirmed both architectures.
The compact result and archive checksums are retained in
`mpv-coreaudio-build-2026-09-22.json`. The candidate and full logs remain at
`/private/tmp/amc-mpv-coreaudio-20260922-d/`; temporary files are not durable
release storage. No existing dependency output, app package pin, bundled binary,
or historical attribution record was replaced. This closes the local rebuild
feasibility gap, not the runtime CoreAudio release blocker.

## Candidate correspondence audit

Run the read-only candidate verifier before integrating or publishing a build:

```sh
python3 scripts/verify-mpv-candidate.py \
  --candidate /private/tmp/amc-mpv-coreaudio-20260922-d \
  --evidence docs/dependency-patches/mpv-coreaudio-build-2026-09-22.json \
  --report /private/tmp/amc-mpv-candidate-verification.json
```

It matches the retained patch, pre-patch source diff, and staged patched CoreAudio
source against build evidence. It checks every retained artifact hash, inspects the actual universal framework
with `lipo`, validates the XCFramework's platform/architecture declarations, and
compares archived framework/static-library bytes with the build outputs without
extracting the ZIPs. Missing artifacts, duplicate ZIP members, changed payloads,
and paths escaping staging fail the audit. The September 22 candidate passed
all seven artifact hashes and the three archived binary comparisons. This closes
archive/framework correspondence only; source/dependency provenance, publication,
app integration, signing, and CoreAudio runtime checks remain open.

## Prepare the GPL target asset

The isolated recipe invokes `enable-gpl`, and both retained Meson configurations
record `gpl: true`. Its generic packaging step names the resulting archive
`Libmpv.xcframework.zip`; the app's `MPVKit-GPL` product instead references a
`Libmpv-GPL.xcframework.zip` release asset. The two archive names use the same
internal `Libmpv.xcframework` layout. Prepare a checked, correctly named asset:

```sh
python3 scripts/prepare-mpv-gpl-release.py \
  --candidate /private/tmp/amc-mpv-coreaudio-20260922-d \
  --evidence docs/dependency-patches/mpv-coreaudio-build-2026-09-22.json \
  --output /private/tmp/amc-mpv-gpl-release-20260922
swift package compute-checksum \
  /private/tmp/amc-mpv-gpl-release-20260922/Libmpv-GPL.xcframework.zip
```

The script rechecks candidate hashes, architecture and archive correspondence,
then reads the actual arm64 and x86_64 Meson options before copying the archive.
The prepared asset's SwiftPM checksum is
`abd855457c4783efdb9a5827faa0f1439392cba32150550b1694fe79e6fb3856`.
`release-preparation.json` retains the checks and release steps. The MPVKit
revision, versioned tag, binary asset, and matching source archive have been
published with explicit user authorization. This app's package pin and source
attribution now refer to that revision. See
`../4.5-mpv-coreaudio-package-validation-2026-09-25.md` for published hashes,
app build/test results, and remaining release gates. The original preparation
record remains marked `release_ready: false` because it describes the earlier
local stage, not a final app release.

## Experimental meter timestamp history

The opt-in `mpv-0.41.0-meter-history.patch` and `amc_meter_history.h` target the
current pinned fork, separately from the historical CoreAudio rebuild recipe
above. They are now MPVKit recipe patches; see the 2026-11-12 release build below. See the [prototype instructions,
transport schema, verification and remaining acceptance work](../audio-playback-timestamp-prototype-2026-10-17.md).
Build candidates using `scripts/prototype-mpv-meter-history.py` with matching
source, generated compile commands and static frameworks. The script stages
new outputs and leaves existing build inputs untouched.

The builder also stages `mpv-0.41.0-aac-discard-priming.patch` against the exact
pinned decoder source. It accounts for codec priming already consumed by discarded
frames, including multi-frame skip budgets. See the [AAC startup diagnosis and
nonperiodic peak/RMS validation](../audio-playback-aac-startup-validation-2026-10-17.md).
It is part of the 2026-11-12 release build below.

## Meter history release build — 2026-11-12

The meter history and AAC priming inputs are now MPVKit recipe patches
`0007-af-lavfi-meter-history.patch` and `0008-ad-lavc-aac-discard-priming.patch`
(the repository inputs above, with a description header; `amc_meter_history.h`
is part of 0007). They apply after the six patches of
`aagedal-1.1.0-n9.0.2-resize.1` (`f957f48`), the app's current pin. Only the
GPL `Libmpv` target is republished; the seven FFmpeg targets keep their
resize.1 archives. Build record:
[`mpv-meter-history-build-2026-11-12.json`](mpv-meter-history-build-2026-11-12.json).

**Prepared, not published.** Nothing below has been pushed, tagged or uploaded.

| Item | Value |
| --- | --- |
| MPVKit commits (local branch `amc/meter-history`) | `bb2c1d1` patches, `d2680851a5a56dafb6be8df79989d69817dac891` manifest |
| Release tag (to create) | `aagedal-1.1.0-n9.0.2-history.1` at `d2680851` |
| `Libmpv-GPL.xcframework.zip` | 5,812,616 bytes, SHA-256/SwiftPM `1fb1dc97b90d2f703a334d38c81534c118f160d82c2b6d42fe5ebdd4a1ddfe93` |
| `mpvkit-n9.0.2-history.1-sources.tar.gz` | 24,790,663 bytes, `b814d27ac34ca2f00a50691acd7dc5a0feb341aba65bc7685c8db4555610641a` |
| `MPVKit-1.1.0-history.1-pinned-source.tar.gz` | 127,397 bytes, `54eb17df5865d77ada1ca36e532c0c5eb47642406aa398fd90441e1e7f62b742` |

Everything lives in `~/Library/Caches/AagedalMediaConverter-MPVHistory/`:
`MPVKit/` (clone with the branch), `build-20261112/` (full build tree and
`build.log`), `release-history.1/` (assets, `SHA256SUMS.txt`, a git bundle and
`format-patch` copies of the two commits) and `override/` (local-override
workspace).

### Rebuild

From a clone of the MPVKit branch, with Xcode's toolchain first in `PATH`
(a swiftly toolchain on `PATH` fails with `unknown argument: '-target-arch-variant'`):

```sh
git archive --prefix=build/ d2680851 | tar -x -C "$WORK"   # or bb2c1d1; the recipe is identical
cd "$WORK/build"
# Same recipe changes as earlier rebuilds: no standalone FFmpeg/mpv programs,
# TMPDIR and the module cache passed through (provenance/build-recipe-*.diff
# in the source archive records them).
mkdir tmp module-cache
PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH" \
TMPDIR="$PWD/tmp" CLANG_MODULE_CACHE_PATH="$PWD/module-cache" \
  swift run --disable-sandbox --build-path .build --package-path Sources/BuildScripts \
  build platform=macos enable-gpl
```

This downloads the pinned auxiliary libraries, builds FFmpeg n9.0.2 and mpv
v0.41.0 for arm64 and x86_64 (about 20 minutes on an M5 Pro) and writes
`dist/release/Libmpv.xcframework.zip`. A later MPV-only rebuild against these
FFmpeg outputs can use `scripts/rebuild-mpv-meter-history.py --recipe-root`
on that tree; it now accepts the 0006–0008 recipe and checks that 0007/0008
produce the same source as the repository inputs.

Checks run on this build:

- `dist/libmpv-v0.41.0` equals upstream `41f6a645` plus 0001–0006 plus the
  three repository inputs (`diff -r`, `.git` excluded).
- Both Meson configurations: `gpl: true`, `cplayer: false`, release build type.
- Universal framework (arm64, x86_64), every object `minos 12.0`; 55 exported
  `mpv_*` functions per architecture and the headers are identical to resize.1;
  the option string is present in both slices.
- The public FFmpeg headers used for the build equal the shipped resize.1
  FFmpeg frameworks' headers. Only the internal `config.h` copies differ:
  resize.1 built arm64 FFmpeg with `ffplay`, which mpv does not use.
- The FFmpeg source tree is byte-identical to the resize.1 source archive's.
- `scripts/verify-mpv-candidate.py` (now with a meter-history evidence mode)
  and `scripts/prepare-mpv-gpl-release.py` pass.

### Test against the app without publishing

`override/AMC-meter-history.xcworkspace` contains the app project and a local
`MPVKit` package whose `Libmpv-GPL` target is `path: "artifacts/Libmpv.xcframework"`
(the extracted asset). A local package with the same identity replaces the
remote one, so the app builds unchanged:

```sh
xcodebuild test -workspace override/AMC-meter-history.xcworkspace \
  -scheme "Aagedal Media Converter Unit Tests" ...
python3 scripts/benchmark-audio-meter.py --workspace override/AMC-meter-history.xcworkspace \
  --configuration Release --seconds 300 --rounds 1 ...
```

Copy the workspace's `xcshareddata/swiftpm/Package.resolved` from the project
(without the `mpvkit` pin) so the other packages keep their pinned revisions.

### Publish (needs approval)

```sh
cd ~/Library/Caches/AagedalMediaConverter-MPVHistory/MPVKit
git push origin amc/meter-history            # or merge into main first
git tag aagedal-1.1.0-n9.0.2-history.1 d2680851a5a56dafb6be8df79989d69817dac891
git push origin aagedal-1.1.0-n9.0.2-history.1
cd ../release-history.1
gh release create aagedal-1.1.0-n9.0.2-history.1 -R aagedal/MPVKit \
  --title "MPVKit 1.1.0 · FFmpeg 9.0.2 · macOS GPL libmpv meter history" \
  --notes-file RELEASE-NOTES.md \
  Libmpv-GPL.xcframework.zip Libmpv-GPL.xcframework.checksum.txt \
  mpvkit-n9.0.2-history.1-sources.tar.gz SHA256SUMS.txt
# Download the assets again and compare with SHA256SUMS.txt.
```

Runtime results against this build (unit, Release, native UI, lifecycle probe
on both architectures and the sustained benchmark) are in
[the metering plan](../AUDIO-METERING-PLAN.md#playback-meter-from-measured-history-prepared-for-release--2026-11-12).
`scripts/benchmark-mpv-meter-lifecycle.py` now attributes frames that a snapshot
still holds from before mpv's graph reset to the original source; it had
compared them with the replacement's reference.

Then, in this repository, apply the prepared pin change (branch
`t3/mpv-meter-history-pin`), copy the two new archives to
`build/attribution/mpvkit/`, run `-resolvePackageDependencies` (it refreshes
`Package.resolved`'s `originHash`), `scripts/generate-mpvkit-notices.py`,
`scripts/bundled-dependency-manifest.py` and `scripts/ci-local.sh --release`.
Keep `mpvkit-n9.0.2-resize.1-sources.tar.gz`: it remains the corresponding
source of the shipped FFmpeg archives.
