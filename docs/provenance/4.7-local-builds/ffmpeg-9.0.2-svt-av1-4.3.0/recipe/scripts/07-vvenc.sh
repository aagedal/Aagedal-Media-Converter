#!/bin/bash

# Build VVenC (VVC encoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="vvenc"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building VVenC ${VVENC_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "vvenc-${VVENC_VERSION}" ]; then
    download_file "https://github.com/fraunhoferhhi/vvenc/archive/refs/tags/v${VVENC_VERSION}.tar.gz" \
        "vvenc-${VVENC_VERSION}.tar.gz"
    tar xf "vvenc-${VVENC_VERSION}.tar.gz"
fi

mkdir -p "vvenc-${VVENC_VERSION}/build"
cd "vvenc-${VVENC_VERSION}/build"

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DVVENC_ENABLE_LINK_TIME_OPT=OFF \
    -DVVENC_INSTALL_FULLFEATURE_APP=OFF \
    -DVVENC_INSTALL_SIMPLE_APP=OFF \
    ..

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
