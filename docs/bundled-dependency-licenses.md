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
