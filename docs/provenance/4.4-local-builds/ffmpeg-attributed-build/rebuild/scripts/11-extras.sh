#!/bin/bash

# Build extra useful libraries (libass for subtitles)

source "$(dirname "$0")/../config.sh"

COMPONENT="extras"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building extra libraries..."

cd "${SOURCE_DIR}"

# Build libpng (required for freetype)
echo "  Building libpng ${LIBPNG_VERSION}..."
if [ ! -d "libpng-${LIBPNG_VERSION}" ]; then
    download_file "https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.xz" "libpng-${LIBPNG_VERSION}.tar.xz"
    tar xf "libpng-${LIBPNG_VERSION}.tar.xz"
fi
    
    cd "libpng-${LIBPNG_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"

# Build freetype (required for libass)
echo "  Building freetype ${FREETYPE_VERSION}..."
if [ ! -d "freetype-${FREETYPE_VERSION}" ]; then
    download_file "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz" "freetype-${FREETYPE_VERSION}.tar.xz"
    tar xf "freetype-${FREETYPE_VERSION}.tar.xz"
fi
    
    cd "freetype-${FREETYPE_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --without-harfbuzz
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"

# Build fribidi (required for libass)
echo "  Building fribidi ${FRIBIDI_VERSION}..."
if [ ! -d "fribidi-${FRIBIDI_VERSION}" ]; then
    download_file "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "fribidi-${FRIBIDI_VERSION}.tar.xz"
    tar xf "fribidi-${FRIBIDI_VERSION}.tar.xz"
fi
    
    cd "fribidi-${FRIBIDI_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"

# Build HarfBuzz locally so libass cannot silently pick up Homebrew libraries.
echo "  Building harfbuzz ${HARFBUZZ_VERSION}..."
if [ ! -d "harfbuzz-${HARFBUZZ_VERSION}" ]; then
    download_file "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" \
        "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    tar xf "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"

    meson setup "harfbuzz-${HARFBUZZ_VERSION}/build" "harfbuzz-${HARFBUZZ_VERSION}" \
        --prefix="${INSTALL_DIR}" \
        --buildtype=release \
        --default-library=static \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dchafa=disabled \
        -Dpng=disabled \
        -Dicu=disabled \
        -Dgraphite2=disabled \
        -Dfreetype=enabled \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dutilities=disabled \
        -Dintrospection=disabled \
        -Dsubset=disabled \
        -Draster=disabled \
        -Dvector=disabled \
        -Dgpu=disabled

    ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build"
    ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build" install
fi

# Build libass (subtitle rendering)
echo "  Building libass ${LIBASS_VERSION}..."
if [ ! -d "libass-${LIBASS_VERSION}" ]; then
    download_file "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz" "libass-${LIBASS_VERSION}.tar.xz"
    tar xf "libass-${LIBASS_VERSION}.tar.xz"
fi
    
    cd "libass-${LIBASS_VERSION}"
    ./configure \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --disable-fontconfig \
        --disable-libunibreak
    
    make ${MAKEFLAGS}
    make install
    cd "${SOURCE_DIR}"

mark_complete "${COMPONENT}"
