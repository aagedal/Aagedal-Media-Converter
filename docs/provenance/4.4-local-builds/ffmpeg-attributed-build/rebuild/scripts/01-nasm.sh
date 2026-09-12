#!/bin/bash

# Build NASM (assembler required for x264, x265, etc.)

source "$(dirname "$0")/../config.sh"

COMPONENT="nasm"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building NASM ${NASM_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "nasm-${NASM_VERSION}" ]; then
    download_file "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.xz" "nasm-${NASM_VERSION}.tar.xz"
    tar xf "nasm-${NASM_VERSION}.tar.xz"
fi

cd "nasm-${NASM_VERSION}"

./configure \
    --prefix="${INSTALL_DIR}"

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
