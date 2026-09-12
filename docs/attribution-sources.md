# Corresponding sources and release attribution

The 4.4 distribution includes a separate `Aagedal_Media_Converter_*_Sources_*.tar`
companion alongside the application ZIP. It contains reviewed source archives,
licenses, patches and build instructions for the bundled copyleft components.
The app's About > Licenses viewer also provides the collected notices offline.
The companion's `AttributionSources.json` records each archive's component,
filename, byte size and SHA-256. Paths in that distributed manifest are relative
to the extracted companion. Source code for the application itself is available
from this repository at the release's commit, including Xcode project and package
pins. Apple SDKs, system libraries and general build tools are not redistributed.

## Source material

- **FFmpeg 9.0.1:** a new build from retained dependency sources, with the original
  invoked scripts, source identities and an adjusted `rebuild.sh` that rebuilds
  existing source trees. Install Xcode with its Metal compiler, CMake, Meson,
  Ninja and pkg-config, extract into a writable directory, then run the script.
  Edit dependency sources before rebuilding to relink modified libraries. The
  companion preserves the actual source trees; duplicate downloads, generated
  binaries/build directories and libjxl test media are omitted. A separate
  generated-input archive preserves 28 compiler-referenced generated source
  files for audit; the replay recipe regenerates them from the source tree.
- **rclone:** the reviewed minimal source revision with only the unused `serve s3`
  command removed; its S3 storage backend remains. The archive includes the
  exact source patch, Go toolchain/module inputs, notices and `rebuild.py`, plus
  directions for installing a modified helper through the app's custom-tool
  setting. An offline rebuild reproduced the distributed helper byte-for-byte.
- **AVM/Eigen:** the retained Eigen source and applicable licenses, including
  every compiler-referenced Eigen file. Other AVM component notices and patent
  statements are included in `avm-LICENSE.txt`; their permissive licenses do not
  all require a separate source distribution.
- **MPVKit:** pinned wrapper and upstream dependency sources, the retained patched
  mpv and FFmpeg sources, build configurations/recipes and their transitive source
  inputs. The package review distinguishes direct archive/payload matches from
  version/build-date inferences for some upstream runtime notices. It does not
  claim every upstream binary has been independently reproduced.
- **SwiftMediaMetadata 3.0.0:** the exact pinned source tree, including the GeoNames
  database and its upstream acknowledgement. Its source package identifies
  required platform tools and dependencies in `Package.swift`.

Detailed evidence is retained under `docs/provenance/4.4-local-builds/`. Build
recipes describe their dependencies; use the recorded revisions instead of
current branches. Where a local source archive has no upstream download URL,
retain that archive or restore it from the source companion. Regenerating or
changing an archive requires reviewing its contents and updating its recorded
hash; do not simply remove it from the manifest to make the release gate pass.

## Preparing a release

Required local archives are listed in the repository's `AttributionSources.json`
and stored under ignored `build/attribution/`. They are deliberately separate
from `build/release/`, which holds replaceable release outputs. Keep a durable
copy of the generated source companion with the release artifacts.

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
