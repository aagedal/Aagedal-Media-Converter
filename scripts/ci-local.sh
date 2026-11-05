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

step() { printf '\n==> %s\n' "$1"; }

# Runs from other worktrees share DerivedData and Results, so only one runs at a time.
# The lock is a symlink to the owner's pid, so taking it and recording the owner is one
# atomic step; a directory with a pid file could be seen before the pid was written.
LOCK="${WORK_DIR}/lock"
mkdir -p "$WORK_DIR"
lock_owner() {
    if [[ -L "$LOCK" ]]; then readlink "$LOCK"
    elif [[ -d "$LOCK" ]]; then cat "$LOCK/pid" 2>/dev/null  # Written by older versions of this script.
    fi
}
for _ in 1 2 3; do
    # ln into an existing directory (an older version's lock) would succeed, so only try
    # it when nothing is there.
    if [[ ! -e "$LOCK" && ! -L "$LOCK" ]] && ln -s "$$" "$LOCK" 2>/dev/null; then break; fi
    other="$(lock_owner || true)"
    if [[ -z "$other" && -d "$LOCK" && ! -L "$LOCK" ]]; then
        # An older version may be between taking the lock and writing its pid.
        sleep 1
        other="$(lock_owner || true)"
    fi
    # A pid reused by another program doesn't hold the lock.
    if [[ -n "$other" ]] && ps -p "$other" -o command= 2>/dev/null | grep -q 'ci-local\.sh'; then
        echo "Another ci-local.sh run (pid $other) is using $WORK_DIR. Wait for it to finish." >&2
        exit 1
    fi
    # Left behind by a run that was killed. Another run may be recovering it too; the
    # loser's ln fails and it tries again.
    rm -rf "$LOCK"
done
if [[ "$(readlink "$LOCK" 2>/dev/null)" != "$$" ]]; then
    echo "Couldn't take the lock $LOCK. Try again." >&2
    exit 1
fi
trap '[[ "$(readlink "$LOCK" 2>/dev/null)" == "$$" ]] && rm -f "$LOCK"' EXIT

if $clean; then rm -rf "$DERIVED_DATA"; fi
rm -rf "$RESULTS"
mkdir -p "$RESULTS"

# CI pins its Xcode; say which one this run uses.
# sed reads all of it; head would exit early and SIGPIPE xcodebuild under pipefail.
xcodebuild -version | sed -n 1p

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
