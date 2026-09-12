# MPVKit offline attribution and retained source

`Licenses/mpvkit-LICENSE.txt` is the offline notice collection for the selected
29-target MPVKit-GPL graph. It includes full upstream distribution notices,
permissive notices from retained sources, exact notices in the pinned macOS
archive headers, and Rust's complete standard-library copyright document.
Additional notices for accompanying source examples and build tools are retained;
the collection deliberately does not assert that every source file is linked.

Regenerate or verify without network access:

```sh
python3 scripts/generate-mpvkit-notices.py
python3 scripts/generate-mpvkit-notices.py --check
```

`notice-index.json` records every notice's original source/archive member,
SHA-256, and exact byte range in the readable `notices/*/NOTICE.txt` containers.
The generator checks every range before assembling the bundled text. Identical
notices are printed once and subsequent occurrences refer to that section.

## Correspondence to the pinned package

- Package revision: `230c3174f1515898f24599147ad61c2a277d0dc2`.
- All 16 macOS architecture slices in the eight custom mpv/FFmpeg archives match
  the retained build's static libraries byte for byte. Although the outer ZIP
  hashes differed, the library payloads match.
  `local-payload-correspondence.json` records both hashes and archive members.
- The other 21 target checksums match the `Package.swift` in their respective
  release build-recipe archives. `recipe-correspondence.json` records that
  relationship; the source selectors and patches are retained in those archives.
- `target-notice-map.json` maps all 29 selected binary targets to their notice
  collections. Upstream build release labels are not mistaken for dependency
  versions: for example libass-build 0.17.5 selects FreeType 2.14.3, FriBidi
  1.0.16, HarfBuzz 14.2.0, and libunibreak 6.1; gnutls-build 3.8.11 selects
  GMP 6.2.1 and Nettle 3.10.

The retained mpv source is revision
`41f6a645068483470267271e1d09966ca3b9f413` plus the local patches (including the
new MoltenVK context source). FFmpeg is revision
`38b88335f99e76ed89ff3c93f877fdefce736c13` plus the VideoToolbox patch.
`local-source-evidence.json` identifies the patched source archives;
`build-configuration/` preserves both architectures' configuration and mpv's
compiler input/dependency graph.

## Source companion inputs

`source-archives.json` lists retained files under `build/attribution/mpvkit/`,
with byte sizes, SHA-256 values, and original URLs where available. These files
are release source-companion inputs, not checked-in binary payloads. In addition
to the top-level sources, they include:

- GnuTLS's exact gnulib, libtasn1, and Nettle import revisions. Its bootstrap
  imports included unistring and mini-libtasn1 from these sources.
- MoltenVK's SPIRV-Cross, SPIRV-Headers, SPIRV-Tools, Vulkan-Headers, and cereal
  revisions. Volk and Vulkan-Tools are demo dependencies and are not selected
  for the MoltenVK runtime.
- Shaderc's complete pinned `DEPS` source set; libplacebo's source submodules
  and its separately selected SPIRV-Cross source.
- libdovi's selected crate sources. Cargo-lock checksums were checked where the
  source lock selects the observed version. Runtime versions visible in the
  pinned binary were recovered separately from their crate distributions.
- Exact pinned MPVKit wrapper/build sources, local mpv/FFmpeg source snapshots,
  local patches, and build configurations.

The retained build recipes describe the original directory layouts and build
commands. For example, GnuTLS imports `gnulib`, `devel/libtasn1`, and
`devel/nettle`; MoltenVK selects its `External/` revisions; shaderc populates
`third_party/` from `DEPS`. The source-archive hashes identify the material
retained for distribution; they are not claims of reproducible compiler output.

## Explicit limits of the recovered evidence

The pinned uavs3d library identifies version 1.2.1 and embeds the string
`51f936c182afae3d58da9aa4871ad8a439db4494`. That revision's upstream source archive
was unavailable during recovery. Its complete BSD notice is nevertheless
available directly in the checksum-verified, shipped `uavs3d.h`; that exact
notice is included. No substitute source revision is represented as its source.

libdovi's release workflow installed an unpinned Rust nightly and rebuilt the
standard library. The release was published on 2025-12-22. The contemporaneous
2025-12-22 nightly, commit `a6525d5264da34f51ad48c178281d3c6323dbfcf`, supplies
the retained standard-library copyright document, source reference, and license
texts. Binary member names and source strings independently identify the runtime
and several exact crate versions. `libdovi-runtime-evidence.json` records these
facts. The date-based nightly identification is an inference, not a proven
compiler identity; the retained notices include the full upstream standard-library
copyright collection, observed crate notices, and the Unicode/BSD exceptions.
The copyright HTML was extracted from the SHA-256-verified Rust distribution;
the plain-text copy preserves its text, and the referenced Unicode-3.0 and
BSD-2-Clause terms are retained separately.
