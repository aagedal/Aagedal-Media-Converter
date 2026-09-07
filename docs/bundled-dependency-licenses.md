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
checked-in manifest is otherwise current. Ordinary inventory checks remain usable
while attribution work is unfinished. This gate verifies recorded attribution;
it cannot establish that an assignment or a notice is legally sufficient.

## Remaining attribution and packaging work

As of 2026-09-05 the inventory contains 10 tools and 96 dylibs. Seven tools refer
to existing notices. `avmdec`, `avmenc`, and `rclone` have no local notice, and all
96 dylibs retain `NOASSERTION` pending evidence for their exact bundled builds.
The publication gate therefore currently fails for 99 entries. The exact paths
are in `summary.entriesMissingLocalLicenseFile` and in the gate's diagnostics.

The repository also includes an mpv notice, which is inventoried even though no
entry currently references it. The presence of a project's generic license text
alone does not establish the effective license of a particular binary and its
compiled dependencies. Do not assign dylib licenses solely from their names.

Before publishing:

1. Establish provenance and versions for the actual bundled builds, including
   enabled build options and statically linked components. Preserve the evidence
   alongside the attribution when adding metadata.
2. Add the corresponding full notices and any required accompanying material,
   and connect each retained binary to its reviewed attribution. Account for
   transitive dependencies, downloaded components, and package frameworks beyond
   this manifest's Binaries/Frameworks scope separately.
3. Keep new notices included in app resources and the About > Licenses viewer.
   The six current notices are packaged and readable offline. Exported-bundle,
   final-ZIP, and Release CI validation now checks their byte sizes and SHA-256
   against the manifest using `verify-release-bundle.py --manifest BundledDependencies.json`.
   This checks packaging, not completeness of attribution.
4. Complete reachability analysis before removing unused binaries, regenerate the
   inventory, and rerun the strict gate plus exported-bundle validation.

No binary or license text was replaced during the inventory/gate change.

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
