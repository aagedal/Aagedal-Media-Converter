# Bundled SSIMULACRA2

The app ships the official Rust image-comparison CLI (`ssimulacra2_rs` 0.5.2),
using the SSIMULACRA2 metric crate 0.5.1. The executable is ARM64, matching the
other currently bundled media helpers, and targets macOS 15.0.

## Source and build

- CLI upstream: https://github.com/rust-av/ssimulacra2
- Revision: `05f2b4e216059c5d735f9665a51648a37d684e70`
- `source/src/` is the unmodified CLI source from that revision.
- The standalone `source/Cargo.toml` removes the workspace-only lint setting,
  enables `lcms2/static`, and retains the release LTO/codegen settings. It sets
  `strip = "none"` because stripped procedural-macro dylibs produced malformed
  Mach-O LINKEDIT string tables rejected by the build host's loader.
- `source/Cargo.lock` pins the exact dependency versions and crate checksums.
- Compiler: Rust 1.89.0 (`29483883e`, 2025-08-04), upstream's minimum supported
  Rust version. Xcode command-line tools provide the C compiler and SDK.
- Build features: `--no-default-features`. FFmpeg already extracts PNG frames;
  native video/AVIF support and VapourSynth are unnecessary.
- Little CMS is statically linked. `otool -L` reports only macOS-provided
  `libSystem.B.dylib` and `libiconv.2.dylib`; no Rust installation or external
  library is needed to run the shipped helper.
- Initial binary SHA-256:
  `e0bfdd1d9218429ac838d646498696f8994b93a523a3faeb31f4adea1301b10d`.
  Xcode signs a staged copy with the app's identity; the checked-in binary is
  retained unchanged. Signing changes the packaged binary's hash.

To rebuild, install Rust 1.89.0 with the minimal profile, then run
`scripts/build-ssimulacra2.sh` from the repository. The script builds the locked
source, audits dependencies, regenerates the notices, checks runtime linkage,
and installs the helper into `Aagedal Media Converter/Binaries/`. Review changed
hashes, dependency inventory, and notices together. Normal Xcode builds copy
and sign the checked-in helper and do not invoke Cargo or access the network.

## License review

The app is GPL-3.0-or-later. The CLI and metric are BSD-2-Clause, which permits
source/binary redistribution with preserved copyright, conditions, and
warranty disclaimer. The exact image-only dependency closure in
`dependencies.json` offers GPLv3-compatible MIT, Apache-2.0, BSD-2-Clause,
BSD-3-Clause, Zlib, or equivalent permissive options. `unicode-ident` also
requires Unicode-3.0, so its notice is included. Little CMS is MIT licensed.
Rust's standard-library copyright index is retained in full, including
conditional platform components; its MIT/Apache choices are used. No upstream
metric code has been relicensed or modified.

Compatibility references:

- CLI/metric license: https://github.com/rust-av/ssimulacra2/blob/05f2b4e216059c5d735f9665a51648a37d684e70/LICENSE
- FSF license list: https://www.gnu.org/licenses/license-list.html
- Apache/GPLv3 compatibility: https://www.apache.org/licenses/GPL-compatibility

`Licenses/ssimulacra2-LICENSE.txt` preserves notices from the locked crates,
including build dependencies and statically compiled Little CMS, and the Rust
standard library. It is packaged in the app and exposed in About → Licenses.
The two crate archives that omit full license files are supplemented with
unmodified notices retrieved from their exact upstream source revisions:

- number_prefix 0.4.0: https://raw.githubusercontent.com/ogham/rust-number-prefix/v0.4.0/LICENCE
- zune-inflate 0.2.54: https://raw.githubusercontent.com/etemesi254/zune-image/69502ce83fdfecdd0beefd677e2abb3781b29d98/LICENSE.md
- zune-inflate Zlib option: https://raw.githubusercontent.com/etemesi254/zune-image/69502ce83fdfecdd0beefd677e2abb3781b29d98/LICENSE-ZLIB

Retain these notices, dependency inventory, lockfile, source, and rebuild script
when redistributing or updating the helper. The BSD-licensed helper does not
require shipping its source, but the exact CLI source and lockfile are kept here
for review and rebuilds; dependency sources are identified by Cargo's immutable
registry checksums and upstream repository URLs.
