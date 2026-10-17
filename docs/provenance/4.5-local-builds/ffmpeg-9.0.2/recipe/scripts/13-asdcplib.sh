#!/bin/bash

# Build asdcplib (SMPTE DCP/MXF library + asdcp-wrap tool)
# License: BSD 3-Clause
# Used for creating DCP-compliant audio MXF files

source "$(dirname "$0")/../config.sh"

COMPONENT="asdcplib"
ASDCPLIB_VERSION="rel_2_13_2"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building asdcplib (${ASDCPLIB_VERSION})..."

cd "${SOURCE_DIR}"

# Clone asdcplib
if [ ! -d "asdcplib" ]; then
    git clone --depth 1 --branch "${ASDCPLIB_VERSION}" https://github.com/cinecert/asdcplib.git
fi

cd asdcplib

# Build with CMake (more reliable on macOS than autotools)
rm -rf build_arm64
mkdir -p build_arm64
cd build_arm64

cmake .. \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DWITHOUT_SSL=ON

make ${MAKEFLAGS}
make install

echo "asdcp-wrap location: ${BIN_DIR}/asdcp-wrap"
ls -la "${BIN_DIR}/asdcp-wrap" 2>/dev/null || echo "WARNING: asdcp-wrap not found in ${BIN_DIR}"

mark_complete "${COMPONENT}"
