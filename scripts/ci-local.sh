#!/usr/bin/env bash
# Aagedal Media Converter
# Copyright © 2026 Truls Aagedal
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the checks from .github/workflows/validate.yml on this Mac. Run it before
# pushing or opening a pull request; GitHub only validates main, tags and manual
# runs.
#
# Usage: scripts/ci-local.sh [--release] [--clean]
#   --release  Also build Release and verify the app bundle (the workflow's
#              release job).
#   --clean    Start from empty DerivedData instead of reusing the last run's.
#
# Set DEVELOPER_DIR to pick an Xcode; it defaults to /Applications/Xcode.app.

set -euo pipefail

release=false
clean=false
for arg in "$@"; do
    case "$arg" in
        --release) release=true ;;
        --clean) clean=true ;;
        -h|--help) sed -n '5,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

# xcode-select may point at the Command Line Tools, which can't build the project.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROJECT="Aagedal Media Converter.xcodeproj"
SCHEME="Aagedal Media Converter"
WORK_DIR="${HOME}/Library/Caches/AagedalMediaConverter-CI"
DERIVED_DATA="${WORK_DIR}/DerivedData"
RESULTS="${WORK_DIR}/Results"

if $clean; then rm -rf "$DERIVED_DATA"; fi
rm -rf "$RESULTS"
mkdir -p "$RESULTS"

step() { printf '\n==> %s\n' "$1"; }

# Shows the xcodebuild log only when it fails; the result bundle has the details.
xcodebuild_quiet() {
    local name="$1"; shift
    local log="${RESULTS}/${name}.log"
    if ! xcodebuild "$@" >"$log" 2>&1; then
        grep -E "error:|failed on|Failing tests|\*\* .* FAILED \*\*" "$log" | tail -40 || true
        echo "Full log: $log" >&2
        echo "Result bundle: ${RESULTS}/${name}.xcresult" >&2
        exit 1
    fi
}

step "Verify bundled dependency manifest"
scripts/bundled-dependency-manifest.py --check

step "Test release validation scripts"
python3 -m unittest discover -s scripts/tests

step "Check localization catalog"
python3 scripts/check-localizations.py

step "Build Debug app"
xcodebuild_quiet Debug-Build build \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "${RESULTS}/Debug-Build.xcresult" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO

step "Run unit tests"
xcodebuild_quiet Unit-Tests test \
    -project "$PROJECT" -scheme "Aagedal Media Converter Unit Tests" -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "${RESULTS}/Unit-Tests.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    -only-testing:"Aagedal Media ConverterTests" \
    CODE_SIGNING_ALLOWED=NO

if $release; then
    step "Build Release app"
    xcodebuild_quiet Release-Build build \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "${RESULTS}/Release-Build.xcresult" \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO

    step "Verify Release architectures and library resolution"
    python3 scripts/verify-release-bundle.py \
        "${DERIVED_DATA}/Build/Products/Release/${SCHEME}.app" \
        --architecture arm64 --manifest BundledDependencies.json \
        --report "${RESULTS}/Release-Footprint.json"
fi

step "All checks passed"
