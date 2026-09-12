# Bundled dependency license inventory

`BundledDependencies.json` records the source-tree binary inventory and the byte
sizes and SHA-256 hashes of `LICENSE` and `Licenses/*-LICENSE.txt`. Regenerate it
with `python3 scripts/bundled-dependency-manifest.py` after an intentional binary
or notice change. CI's `--check` catches stale binary **and notice** contents.
The inventory does not claim that every source-tree binary reaches the built app.

Publishing additionally requires:

```sh
python3 scripts/bundled-dependency-manifest.py --check --require-complete-licenses
```

`release.sh` runs this gate before building, signing, notarizing, or uploading.
It rejects missing notice references and `NOASSERTION` licenses, even when the
checked-in manifest is otherwise current. It also rejects explicit
`pendingAttribution` work, and inconsistencies between an executable's reported
license, recorded license, and notice header. Ordinary inventory checks remain usable
while attribution work is unfinished. This gate verifies recorded attribution;
it cannot establish that an assignment or a notice is legally sufficient.

## Current attribution and packaging status

The 2026-09-12 completion pass covers all 10 bundled tools and the three pinned
Swift packages. There are no source-tree dylibs. Twelve offline notices are
included in the app, covering AVM, rclone, FFmpeg, MPVKit and their reviewed
transitive components as well as OCR, BMX, asdcplib, Sparkle and
SwiftMediaMetadata/GeoNames. The strict attribution gate passes.

`PackageAttributions.json` binds notice review to exact `Package.resolved`
revisions. `AttributionSources.json` identifies 89 retained source archives;
the strict gate checks required components, byte sizes and SHA-256 hashes.
The release script creates and uploads their source companion with the app.
See [source distribution instructions](attribution-sources.md) and the
[completion record](4.4-attribution-completion.md) for binary replacements,
validation and explicit upstream provenance limits.

When changing dependencies, review actual build options and transitive notices,
update both metadata and source material, regenerate the inventory, and rerun
the strict gate and exported-bundle verification. Final bundle verification
checks notice bytes; it does not substitute for source and license review.

The sections below preserve the earlier audit history; their outstanding counts
are superseded by the completion record.

## Additional provenance findings — 2026-09-11

The [4.4 provenance review](4.4-dependency-provenance-review.md) recovers exact
rclone VCS identity and module records, an AVM revision lead, historical dylib
copy scripts, and pinned package evidence. The 99 missing attributions remain.
The continuation preserved local FFmpeg/AVM build evidence and corrected FFmpeg's
manifest and packaged notice to GPL v3-or-later, matching the executable's report.
FFmpeg remains explicitly blocked by `pendingAttribution` for corresponding sources
and static dependency notices. AVM's pinned local source also corrected its
top-level license from BSD-2-Clause to BSD-3-Clause-Clear; its missing notice remains
unresolved because the retained link records show additional static dependencies.

## Size and static dependency baseline

The unsigned Release build measured on 2026-09-06 (version 4.3.0, build 575,
with this continuation's source changes) contains 275,341,835 logical file bytes
across 144 regular files, counting canonical symlink targets once. Its 44 Mach-O
images account for 236,977,784 bytes. The detailed relative-path inventory is in
[`release-footprint-2026-09-06.json`](release-footprint-2026-09-06.json).

Using the release script's `ditto -c -k --keepParent --norsrc --noextattr --noacl
--noqtn` options produced a 118,295,174-byte ZIP (112.8 MiB). This is an unsigned,
unnotarized development measurement, not a published download or a signed-release
size guarantee. No binary cleanup was performed. Launch/import memory and
post-cleanup comparisons remain unmeasured.

The report identifies 28 framework images (927,584 bytes) outside every bundled
executable's static load-command closure. This is evidence for further investigation,
not proof of disuse: dynamic loading, Swift package packaging requirements, and
runtime behavior must be checked before removal. The source-tree inventory's
96 dylibs also must not be confused with the built bundle's contents.

Generate a fresh report after any packaging change:

```sh
python3 scripts/verify-release-bundle.py /path/to/Release/App.app \
  --architecture arm64 --manifest BundledDependencies.json \
  --report /tmp/Release-Footprint.json
```

Release CI saves that report as an artifact for 90 days. The publishing script
writes `build/Release-Footprint.json` after checking the extracted distribution
bundle. Shared-cache checks use the build host's dyld cache; this does not replace
clean-machine checks on the minimum supported macOS release. None of these size
or dependency checks resolve the 99 outstanding license attributions.
