#!/bin/bash

# Build libvmaf (Netflix's video quality assessment library)
# License: BSD 2-Clause
# Used for VMAF quality metric filtering in FFmpeg

source "$(dirname "$0")/../config.sh"

COMPONENT="vmaf"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libvmaf ${VMAF_VERSION}..."

cd "${SOURCE_DIR}"

if [ ! -d "vmaf-${VMAF_VERSION}" ]; then
    download_file "https://github.com/Netflix/vmaf/archive/v${VMAF_VERSION}.tar.gz" "v${VMAF_VERSION}.tar.gz"
    tar xf "v${VMAF_VERSION}.tar.gz"
fi

cd "vmaf-${VMAF_VERSION}/libvmaf"

rm -rf build_arm64

meson setup build_arm64 \
    --prefix="${INSTALL_DIR}" \
    --buildtype=release \
    --default-library=static \
    -Denable_tests=false \
    -Denable_docs=false \
    -Dbuilt_in_models=true \
    -Denable_float=true \
    -Dc_args="${CFLAGS}" \
    -Dc_link_args="${LDFLAGS}"

ninja -C build_arm64 ${MAKEFLAGS}
ninja -C build_arm64 install

# Fix libvmaf.pc: svm.cpp requires libc++ for static linking
sed -i '' 's/^Libs: \(.*\)-lm$/Libs: \1-lm -lc++/' "${INSTALL_DIR}/lib/pkgconfig/libvmaf.pc"

mark_complete "${COMPONENT}"
