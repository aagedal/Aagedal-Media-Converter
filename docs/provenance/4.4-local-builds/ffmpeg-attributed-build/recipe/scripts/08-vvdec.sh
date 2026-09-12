#!/bin/bash

# Build VVdeC (VVC decoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="vvdec"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building VVdeC ${VVDEC_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "vvdec-${VVDEC_VERSION}" ]; then
    download_file "https://github.com/fraunhoferhhi/vvdec/archive/refs/tags/v${VVDEC_VERSION}.tar.gz" \
        "vvdec-${VVDEC_VERSION}.tar.gz"
    tar xf "vvdec-${VVDEC_VERSION}.tar.gz"
fi

mkdir -p "vvdec-${VVDEC_VERSION}/build"
cd "vvdec-${VVDEC_VERSION}/build"

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    ..

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
