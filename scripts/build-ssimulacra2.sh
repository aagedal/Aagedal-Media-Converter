#!/bin/bash
# Maintainer-only build. Ordinary Xcode builds use the checked-in helper.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/docs/provenance/ssimulacra2/source"
build_dir="${SSIMULACRA2_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/amc-ssimulacra2.XXXXXX")}"
target=aarch64-apple-darwin
export CARGO_TARGET_DIR="$build_dir"
export MACOSX_DEPLOYMENT_TARGET=15.0
# Prevent a local Little CMS override from introducing a non-system dylib.
unset LCMS2_LIB_DIR LCMS2_INCLUDE_DIR
cargo +1.89.0 build --manifest-path "$source_dir/Cargo.toml" --locked \
    --release --no-default-features --target "$target"
cargo +1.89.0 metadata --manifest-path "$source_dir/Cargo.toml" --locked \
    --no-default-features --filter-platform "$target" --format-version 1 > "$build_dir/metadata.json"
rust_sysroot="$(rustc +1.89.0 --print sysroot)"
python3 "$repo_root/scripts/generate-ssimulacra2-notices.py" "$build_dir/metadata.json" \
    "$rust_sysroot/share/doc/rust/COPYRIGHT-library.html"
helper="$build_dir/$target/release/ssimulacra2_rs"
# Only macOS-provided libraries may be needed at runtime.
if /usr/bin/otool -L "$helper" | /usr/bin/awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System\/Library)\// { print; bad = 1 } END { exit bad ? 0 : 1 }'; then
    echo 'Unexpected runtime dependency; refusing to bundle.' >&2
    exit 1
fi
/usr/bin/install -m 755 "$helper" "$repo_root/Aagedal Media Converter/Binaries/ssimulacra2_rs"
"$helper" --version
/usr/bin/shasum -a 256 "$repo_root/Aagedal Media Converter/Binaries/ssimulacra2_rs"
