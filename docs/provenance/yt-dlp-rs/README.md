# Bundled yt-dlp-rs

The app ships the official Apple Silicon release binary of
[yt-dlp-rs](https://github.com/aagedal/yt-dlp-rs), a native Rust adaptation of
yt-dlp, as the baseline `yt-dlp-rs` helper. It is used for supported sites with
automatic fallback to yt-dlp (Settings → Downloads).

## Source and verification

- `release.json` records the pinned tag, release-asset URL, the archive SHA-256
  (checked against the release's `SHA256SUMS`) and the unmodified binary's SHA-256.
- The binary is ARM64, built by upstream CI (`.github/workflows/release.yml`) with
  stable Rust; `otool -L` reports only `/usr/lib/libSystem.B.dylib` and
  `/usr/lib/libiconv.2.dylib`.
- Xcode signs a staged copy with the app identity (`scripts/copy-sign-media-helpers.sh`);
  the checked-in binary is retained unchanged.

To restore or replace it, run `scripts/update-ytdlp-rs.sh [TAG]`. The script
downloads the release asset and `SHA256SUMS`, refuses a checksum, architecture,
linkage or `--version` mismatch, installs the binary, rewrites `release.json`,
regenerates notices (`scripts/generate-ytdlp-rs-notices.py`, needs Cargo and the
Rust toolchain that built the release) and the dependency manifest. Review the
changed notices, `dependencies.json` and `BundledDependencies.json` together.
Normal Xcode builds do not access the network.

Users can additionally download newer releases into Application Support from
Settings → Downloads; the bundled copy always remains selectable.

## License review

yt-dlp-rs and its embedded yt-dlp/ejs challenge solver are released into the
public domain (Unlicense); the solver retains its bundled ISC (meriyah) and BSD
(astring) notices. The locked aarch64-apple-darwin dependency closure in
`dependencies.json` offers GPLv3-compatible MIT, Apache-2.0, ISC, BSD-3-Clause,
Zlib, Unicode-3.0, CDLA-Permissive-2.0 (webpki-roots data) or MPL-2.0 terms.
`Licenses/yt-dlp-rs-LICENSE.txt` retains every crate's license files and the Rust
standard-library notices; it is packaged and shown in About → Licenses. Four
crates ship no license file (fxhash, mac, match_token, selectors); they are used
under their Apache-2.0 or MPL-2.0 options, whose full texts appear in the file.

The MPL-2.0 crates (cssparser, cssparser-macros, dtoa-short, selectors) are
unmodified. Their exact crates.io sources, verified against the `Cargo.lock`
checksums, are packed reproducibly into
`build/attribution/yt-dlp-rs-mpl-crate-sources.tar.gz` by the notices script and
recorded in `AttributionSources.json`, so the release source companion carries them.
