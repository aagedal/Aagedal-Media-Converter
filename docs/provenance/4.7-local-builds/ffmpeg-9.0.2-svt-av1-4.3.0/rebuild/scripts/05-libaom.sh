#!/bin/bash

# Build libaom (AV1 encoder/decoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="libaom"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libaom ${LIBAOM_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "libaom-${LIBAOM_VERSION}" ]; then
    download_file "https://storage.googleapis.com/aom-releases/libaom-${LIBAOM_VERSION}.tar.gz" "libaom-${LIBAOM_VERSION}.tar.gz"
    tar xf "libaom-${LIBAOM_VERSION}.tar.gz"
fi

mkdir -p "libaom-${LIBAOM_VERSION}/build"
cd "libaom-${LIBAOM_VERSION}/build"

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_DOCS=OFF \
    ..

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
