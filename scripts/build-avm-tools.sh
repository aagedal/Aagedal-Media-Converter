#!/bin/bash
# Rebuild the pinned AV2 reference tools; signing and installation are separate.
set -euo pipefail

avm_revision=0da4c36474f8d1952bbc54e3ccf833d5f0d2280c
if [[ $# != 2 ]]; then
    echo "Usage: $0 AVM_SOURCE_DIR BUILD_DIR" >&2
    exit 2
fi
avm_source_dir="$1"
avm_build_dir="$2"
if [[ -e "$avm_source_dir/.git" ]]; then
    if [[ "$(git -C "$avm_source_dir" rev-parse HEAD)" != "$avm_revision" ]]; then
        echo "AVM source must be checked out at $avm_revision" >&2
        exit 1
    fi
    git -C "$avm_source_dir" diff --quiet HEAD --
else
    # The hash-verified source companion has no Git history. Preserve its exact
    # version string before CMake's Git-free version generation runs.
    [[ "$(cat "$avm_source_dir/amc-source-revision.txt")" == "$avm_revision" ]]
    mkdir -p "$avm_build_dir/config"
    cp "$avm_source_dir/amc-avm-version.h" "$avm_build_dir/config/avm_version.h"
fi
cmake -S "$avm_source_dir" -B "$avm_build_dir" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF
cmake --build "$avm_build_dir" --target avmenc avmdec -j "${AVM_BUILD_JOBS:-8}"
