#!/bin/bash

# Build libjxl (JPEG XL encoder/decoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="libjxl"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building libjxl dependencies and library ${LIBJXL_VERSION}..."

cd "${SOURCE_DIR}"

# Build brotli (required for libjxl)
if [ ! -d "brotli-${BROTLI_VERSION}" ]; then
    echo "  Building brotli..."
    download_file "https://github.com/google/brotli/archive/v${BROTLI_VERSION}.tar.gz" "v${BROTLI_VERSION}.tar.gz"
    tar xf "v${BROTLI_VERSION}.tar.gz"
    
    mkdir -p "brotli-${BROTLI_VERSION}/build"
    cd "brotli-${BROTLI_VERSION}/build"
    
    cmake \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF \
        ..
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"
fi

# Build highway (required for libjxl)
if [ ! -d "highway-${HIGHWAY_VERSION}" ]; then
    echo "  Building highway..."
    download_file "https://github.com/google/highway/archive/${HIGHWAY_VERSION}.tar.gz" "${HIGHWAY_VERSION}.tar.gz"
    tar xf "${HIGHWAY_VERSION}.tar.gz"
    
    mkdir -p "highway-${HIGHWAY_VERSION}/cmake-build"
    cd "highway-${HIGHWAY_VERSION}/cmake-build"
    
    cmake \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF \
        -DHWY_ENABLE_TESTS=OFF \
        -DHWY_ENABLE_EXAMPLES=OFF \
        ..
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"
fi

# Build libjxl
if [ ! -d "libjxl-${LIBJXL_VERSION}" ]; then
    download_file "https://github.com/libjxl/libjxl/archive/v${LIBJXL_VERSION}.tar.gz" "v${LIBJXL_VERSION}.tar.gz"
    tar xf "v${LIBJXL_VERSION}.tar.gz"
fi
cd "libjxl-${LIBJXL_VERSION}"
./deps.sh
cd "${SOURCE_DIR}"


mkdir -p "libjxl-${LIBJXL_VERSION}/build"
cd "libjxl-${LIBJXL_VERSION}/build"

# Tools/devtools are standalone CLIs (cjxl, cjpegli, ...) that FFmpeg doesn't
# need; they also require a static zlib that macOS doesn't ship, so skip them
cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    ..

make ${MAKEFLAGS}
make install

# Fix libjxl_threads.pc to include -lc++ for proper static linking
if [ -f "${INSTALL_DIR}/lib/pkgconfig/libjxl_threads.pc" ]; then
    sed -i '' 's/Libs\.private: -lm$/Libs.private: -lm -lc++/' "${INSTALL_DIR}/lib/pkgconfig/libjxl_threads.pc"
fi

mark_complete "${COMPONENT}"
