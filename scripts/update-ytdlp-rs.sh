#!/bin/bash
# Maintainer-only: restore or replace the bundled yt-dlp-rs helper from a pinned
# GitHub release. Ordinary Xcode builds copy and sign the checked-in binary and
# never access the network.
#
# Usage: scripts/update-ytdlp-rs.sh [TAG]
#   TAG defaults to the pinned release below. Changing it requires reviewing the
#   regenerated notices (Licenses/yt-dlp-rs-LICENSE.txt), the dependency
#   inventory and BundledDependencies.json before committing.
#   Set YTDLP_RS_SKIP_NOTICES=1 to only replace the binary (no Cargo needed).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-v0.3.0-beta.1}"
repository="aagedal/yt-dlp-rs"
target="aarch64-apple-darwin"
asset="yt-dlp-rs-${tag}-${target}.tar.gz"
base_url="https://github.com/${repository}/releases/download/${tag}"
destination="$repo_root/Aagedal Media Converter/Binaries/yt-dlp-rs"
provenance_dir="$repo_root/docs/provenance/yt-dlp-rs"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/amc-ytdlp-rs.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/download" "$work_dir/extract"

echo "Downloading $asset and SHA256SUMS from $repository $tag"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    -o "$work_dir/download/$asset" "$base_url/$asset"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    -o "$work_dir/download/SHA256SUMS" "$base_url/SHA256SUMS"

expected="$(/usr/bin/awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$work_dir/download/SHA256SUMS")"
actual="$(/usr/bin/shasum -a 256 "$work_dir/download/$asset" | /usr/bin/awk '{ print $1 }')"
if [[ -z "$expected" ]]; then
    echo "SHA256SUMS has no entry for $asset; refusing to bundle." >&2
    exit 1
fi
if [[ "$expected" != "$actual" ]]; then
    echo "Checksum mismatch for $asset (expected $expected, got $actual); refusing to bundle." >&2
    exit 1
fi
echo "Verified archive SHA-256 $actual"

/usr/bin/tar -xzf "$work_dir/download/$asset" -C "$work_dir/extract"
helper="$work_dir/extract/yt-dlp-rs-${tag}-${target}/yt-dlp-rs"
if [[ ! -f "$helper" ]]; then
    echo "Archive does not contain yt-dlp-rs-${tag}-${target}/yt-dlp-rs" >&2
    exit 1
fi
/bin/chmod 755 "$helper"

if [[ "$(/usr/bin/lipo -archs "$helper")" != arm64 ]]; then
    echo 'Unexpected architecture; refusing to bundle.' >&2
    exit 1
fi
# Only macOS-provided libraries may be needed at runtime.
if /usr/bin/otool -L "$helper" | /usr/bin/awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System\/Library)\// { print; bad = 1 } END { exit bad ? 0 : 1 }'; then
    echo 'Unexpected runtime dependency; refusing to bundle.' >&2
    exit 1
fi
version_output="$("$helper" --version)"
expected_version="yt-dlp-rs ${tag#v}"
if [[ "$version_output" != "$expected_version" ]]; then
    echo "Unexpected --version output '$version_output' (expected '$expected_version')." >&2
    exit 1
fi

/usr/bin/install -m 755 "$helper" "$destination"
binary_sha="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{ print $1 }')"

mkdir -p "$provenance_dir"
/usr/bin/python3 -I - "$provenance_dir/release.json" "$tag" "$repository" "$base_url/$asset" "$actual" "$binary_sha" <<'PY'
import json, sys
path, tag, repository, url, archive_sha, binary_sha = sys.argv[1:]
record = {
    "releaseTag": tag,
    "version": tag.removeprefix("v"),
    "repository": f"https://github.com/{repository}",
    "archiveURL": url,
    "archiveSHA256": archive_sha,
    "checksumSource": url.rsplit("/", 1)[0] + "/SHA256SUMS",
    "platform": "aarch64-apple-darwin",
    "binarySHA256": binary_sha,
    "contents": "Unmodified yt-dlp-rs executable from the release archive. Build copies are signed with the app identity.",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY

echo "Installed $version_output ($binary_sha)"

if [[ "${YTDLP_RS_SKIP_NOTICES:-0}" != 1 ]]; then
    python3 "$repo_root/scripts/generate-ytdlp-rs-notices.py" "$tag"
fi
python3 "$repo_root/scripts/bundled-dependency-manifest.py"

# Keep the app's record of the bundled version in sync (used to compare it with
# downloaded updates without running the binary).
constants="$repo_root/Aagedal Media Converter/Utils/AppConstants.swift"
/usr/bin/sed -i '' -E "s/(static let bundledYTDLPRSVersion = \")[^\"]*(\")/\1${tag#v}\2/" "$constants"
if ! /usr/bin/grep -q "static let bundledYTDLPRSVersion = \"${tag#v}\"" "$constants"; then
    echo "Could not update AppConstants.bundledYTDLPRSVersion" >&2
    exit 1
fi
