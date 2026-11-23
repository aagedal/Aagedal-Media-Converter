#!/bin/bash

# Build x265 (H.265/HEVC encoder)

source "$(dirname "$0")/../config.sh"

COMPONENT="x265"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building x265 ${X265_VERSION}..."

cd "${SOURCE_DIR}"

# Pin the stable release tag so clean builds are reproducible.
if [ ! -d "x265-${X265_VERSION}" ]; then
    git clone --depth 1 --branch "${X265_VERSION}" https://bitbucket.org/multicoreware/x265_git.git "x265-${X265_VERSION}"
fi

cd "x265-${X265_VERSION}"

# Create build directory
mkdir -p build
cd build

cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DHIGH_BIT_DEPTH=ON \
    -DENABLE_ASSEMBLY=ON \
    ../source

make ${MAKEFLAGS}
make install

# x265's CMake install does not provide a pkg-config file. FFmpeg requires one
# now that host/Homebrew pkg-config fallbacks are intentionally disabled.
mkdir -p "${LIB_DIR}/pkgconfig"
cat > "${LIB_DIR}/pkgconfig/x265.pc" << EOF
prefix=${INSTALL_DIR}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: ${X265_VERSION}
Libs: -L\${libdir} -lx265
Libs.private: -lc++ -ldl
Cflags: -I\${includedir}
EOF

mark_complete "${COMPONENT}"
