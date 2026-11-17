#!/bin/bash

# Build x264 (H.264 encoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="x264"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building x264..."

cd "${SOURCE_DIR}"

if [ ! -d "x264" ]; then
    git clone --depth 1 -b stable https://code.videolan.org/videolan/x264.git
fi

cd x264

./configure \
    --prefix="${INSTALL_DIR}" \
    --enable-static \
    --enable-pic \
    --disable-cli \
    --host=aarch64-apple-darwin

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
