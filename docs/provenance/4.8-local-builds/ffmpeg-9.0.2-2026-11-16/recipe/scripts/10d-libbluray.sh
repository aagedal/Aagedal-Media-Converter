#!/bin/bash

# Build libbluray (Blu-ray disc playback)

source "$(dirname "$0")/../config.sh"

COMPONENT="libbluray"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libbluray ${LIBBLURAY_VERSION}..."

cd "${SOURCE_DIR}"

# Download and extract libbluray
if [ ! -d "libbluray-${LIBBLURAY_VERSION}" ]; then
    download_file "https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VERSION}/libbluray-${LIBBLURAY_VERSION}.tar.xz" \
        "libbluray-${LIBBLURAY_VERSION}.tar.xz"
    tar xf "libbluray-${LIBBLURAY_VERSION}.tar.xz"
fi

cd "libbluray-${LIBBLURAY_VERSION}"

# libbluray 1.4.0 uses meson
# Disable all optional dependencies for a minimal static build
meson setup build \
    --prefix="${INSTALL_DIR}" \
    --default-library=static \
    -Dbdj_jar=disabled \
    -Dfontconfig=disabled \
    -Dfreetype=disabled \
    -Dlibxml2=disabled \
    -Denable_docs=false \
    -Denable_tools=false \
    -Denable_examples=false

ninja -C build
ninja -C build install

mark_complete "${COMPONENT}"
