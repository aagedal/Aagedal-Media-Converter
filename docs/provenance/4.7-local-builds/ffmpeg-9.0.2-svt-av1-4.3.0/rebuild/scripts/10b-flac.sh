#!/bin/bash

# Build FLAC (Free Lossless Audio Codec)

source "$(dirname "$0")/../config.sh"

COMPONENT="flac"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building FLAC ${FLAC_VERSION}..."

cd "${SOURCE_DIR}"

# Download and extract FLAC
if [ ! -d "flac-${FLAC_VERSION}" ]; then
    download_file "https://github.com/xiph/flac/releases/download/${FLAC_VERSION}/flac-${FLAC_VERSION}.tar.xz" \
        "flac-${FLAC_VERSION}.tar.xz"
    tar xf "flac-${FLAC_VERSION}.tar.xz"
fi

cd "flac-${FLAC_VERSION}"

# Use cmake for building
mkdir -p build
cd build

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_PROGRAMS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCS=OFF \
    -DINSTALL_MANPAGES=OFF \
    -DWITH_OGG=ON \
    -DOGG_INCLUDE_DIR="${INCLUDE_DIR}" \
    -DOGG_LIBRARY="${LIB_DIR}/libogg.a" \
    ..

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
