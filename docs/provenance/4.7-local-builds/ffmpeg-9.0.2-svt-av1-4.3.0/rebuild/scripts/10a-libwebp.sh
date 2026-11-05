#!/bin/bash

# Build libwebp (WebP image codec library)

source "$(dirname "$0")/../config.sh"

COMPONENT="libwebp"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libwebp ${LIBWEBP_VERSION}..."

cd "${SOURCE_DIR}"

# Download and extract libwebp
if [ ! -d "libwebp-${LIBWEBP_VERSION}" ]; then
    download_file "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" \
        "libwebp-${LIBWEBP_VERSION}.tar.gz"
    tar xf "libwebp-${LIBWEBP_VERSION}.tar.gz"
fi

cd "libwebp-${LIBWEBP_VERSION}"

./configure \
    --prefix="${INSTALL_DIR}" \
    --disable-shared \
    --enable-static \
    --enable-libwebpmux \
    --enable-libwebpdemux \
    --disable-png \
    --disable-jpeg \
    --disable-tiff \
    --disable-gif \
    --disable-dependency-tracking

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
