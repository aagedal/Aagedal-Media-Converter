# Isolated MPV CoreAudio rebuild

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

It checks every retained artifact hash, inspects the actual universal framework
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
`release-preparation.json` retains the checks and release steps. The asset is
still in temporary storage, unpublished, and marked `release_ready: false`.
Publish it under a new versioned MPVKit release, update that package's GPL
binary-target URL/checksum, then pin this app to the resulting package revision
and validate the app before treating the dependency update as integrated.
