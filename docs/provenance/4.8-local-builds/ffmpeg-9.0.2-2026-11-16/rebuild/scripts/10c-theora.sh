#!/bin/bash

# Build libtheora (Theora video codec)

source "$(dirname "$0")/../config.sh"

COMPONENT="theora"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libtheora ${THEORA_VERSION}..."

cd "${SOURCE_DIR}"

# Download and extract libtheora
if [ ! -d "libtheora-${THEORA_VERSION}" ]; then
    download_file "https://downloads.xiph.org/releases/theora/libtheora-${THEORA_VERSION}.tar.gz" \
        "libtheora-${THEORA_VERSION}.tar.gz"
    tar xf "libtheora-${THEORA_VERSION}.tar.gz"
fi

cd "libtheora-${THEORA_VERSION}"

./configure \
    --prefix="${INSTALL_DIR}" \
    --disable-shared \
    --enable-static \
    --disable-examples \
    --disable-spec \
    --disable-dependency-tracking \
    --with-ogg="${INSTALL_DIR}"

make ${MAKEFLAGS}
make install

mark_complete "${COMPONENT}"
