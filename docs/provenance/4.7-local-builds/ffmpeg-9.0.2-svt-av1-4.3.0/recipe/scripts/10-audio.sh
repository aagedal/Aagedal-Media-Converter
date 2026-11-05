#!/bin/bash

# Build audio codecs (Opus, Vorbis, LAME MP3)

source "$(dirname "$0")/../config.sh"

COMPONENT="audio-codecs"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building audio codecs..."

cd "${SOURCE_DIR}"

# Build libogg (required for Vorbis and Opus)
echo "  Building libogg ${OGG_VERSION}..."
if [ ! -d "libogg-${OGG_VERSION}" ]; then
    download_file "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz" "libogg-${OGG_VERSION}.tar.gz"
    tar xf "libogg-${OGG_VERSION}.tar.gz"
    
    cd "libogg-${OGG_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"
fi

# Build libvorbis
echo "  Building libvorbis ${VORBIS_VERSION}..."
if [ ! -d "libvorbis-${VORBIS_VERSION}" ]; then
    download_file "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz" "libvorbis-${VORBIS_VERSION}.tar.gz"
    tar xf "libvorbis-${VORBIS_VERSION}.tar.gz"
    
    cd "libvorbis-${VORBIS_VERSION}"
    # configure.ac injects -force_cpusubtype_ALL on Darwin; modern Xcode ld rejects it
    sed -i '' 's/-force_cpusubtype_ALL //g' configure.ac
    autoreconf -fiv
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --disable-dependency-tracking

    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"
fi

# Build opus
echo "  Building opus ${OPUS_VERSION}..."
if [ ! -d "opus-${OPUS_VERSION}" ]; then
    download_file "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" "opus-${OPUS_VERSION}.tar.gz"
    tar xf "opus-${OPUS_VERSION}.tar.gz"
    
    cd "opus-${OPUS_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"
fi

# Build LAME MP3
echo "  Building LAME ${LAME_VERSION}..."
if [ ! -d "lame-${LAME_VERSION}" ]; then
    download_file "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" "lame-${LAME_VERSION}.tar.gz"
    tar xf "lame-${LAME_VERSION}.tar.gz"
fi

cd "lame-${LAME_VERSION}"
./configure \
    --prefix="${INSTALL_DIR}" \
    --disable-shared \
    --enable-static \
    --disable-decoder \
    --disable-frontend

make ${MAKEFLAGS}
make install
cd "${SOURCE_DIR}"

mark_complete "${COMPONENT}"
