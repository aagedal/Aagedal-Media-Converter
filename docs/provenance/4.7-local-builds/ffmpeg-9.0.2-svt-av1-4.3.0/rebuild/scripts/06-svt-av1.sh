#!/bin/bash

# Build SVT-AV1 (Fast AV1 encoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="svt-av1"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building SVT-AV1 ${SVT_AV1_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "SVT-AV1-v${SVT_AV1_VERSION}" ]; then
    download_file "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVT_AV1_VERSION}/SVT-AV1-v${SVT_AV1_VERSION}.tar.gz" "SVT-AV1-v${SVT_AV1_VERSION}.tar.gz"
    tar xf "SVT-AV1-v${SVT_AV1_VERSION}.tar.gz"
fi

mkdir -p "SVT-AV1-v${SVT_AV1_VERSION}/build"
cd "SVT-AV1-v${SVT_AV1_VERSION}/build"

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_APPS=OFF \
    -DBUILD_DEC=ON \
    ..

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
