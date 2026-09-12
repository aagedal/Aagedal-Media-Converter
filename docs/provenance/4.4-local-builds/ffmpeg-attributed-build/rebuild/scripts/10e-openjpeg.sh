#!/bin/bash

# Build OpenJPEG (JPEG 2000 encoder/decoder for DCP support)

source "$(dirname "$0")/../config.sh"

COMPONENT="openjpeg"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building OpenJPEG ${OPENJPEG_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "openjpeg-${OPENJPEG_VERSION}" ]; then
    download_file "https://github.com/uclouvain/openjpeg/archive/refs/tags/v${OPENJPEG_VERSION}.tar.gz" "v${OPENJPEG_VERSION}.tar.gz"
    tar xf "v${OPENJPEG_VERSION}.tar.gz"
fi

mkdir -p "${BUILD_DIR}/openjpeg"
cd "${BUILD_DIR}/openjpeg"

cmake "${SOURCE_DIR}/openjpeg-${OPENJPEG_VERSION}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_CODEC=OFF \
    -DBUILD_THIRDPARTY=OFF \
    -DBUILD_TESTING=OFF

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
