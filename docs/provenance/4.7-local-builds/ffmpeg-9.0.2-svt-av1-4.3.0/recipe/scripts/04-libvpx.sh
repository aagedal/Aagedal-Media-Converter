#!/bin/bash

# Build libvpx (VP8/VP9 encoder/decoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="libvpx"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libvpx ${LIBVPX_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "libvpx-${LIBVPX_VERSION}" ]; then
    download_file "https://github.com/webmproject/libvpx/archive/v${LIBVPX_VERSION}.tar.gz" "v${LIBVPX_VERSION}.tar.gz"
    tar xf "v${LIBVPX_VERSION}.tar.gz"
fi

cd "libvpx-${LIBVPX_VERSION}"

./configure \
    --prefix="${INSTALL_DIR}" \
    --target=arm64-darwin20-gcc \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --disable-examples \
    --disable-unit-tests \
    --enable-vp8 \
    --enable-vp9 \
    --enable-vp9-highbitdepth

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
