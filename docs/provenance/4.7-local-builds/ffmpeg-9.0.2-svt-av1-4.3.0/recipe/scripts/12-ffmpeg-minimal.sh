#!/bin/bash

# Build FFmpeg - MINIMAL STATIC VERSION (No Homebrew dependencies)
# Disables problematic libraries that link to Homebrew: JPEG XL, Vorbis, libass

source "$(dirname "$0")/../config.sh"

COMPONENT="ffmpeg-minimal"

echo "Building FFmpeg ${FFMPEG_VERSION} (Minimal Static)..."

cd "${SOURCE_DIR}"

if [ ! -d "ffmpeg-${FFMPEG_VERSION}" ]; then
    download_file "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "ffmpeg-${FFMPEG_VERSION}.tar.xz"
    tar xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"
fi

cd "ffmpeg-${FFMPEG_VERSION}"

if [ ! -f VERSION ] || [ "$(tr -d '\r\n' < VERSION)" != "${FFMPEG_VERSION}" ]; then
    echo "ERROR: FFmpeg source tree does not match requested version ${FFMPEG_VERSION}" >&2
    exit 1
fi

make distclean 2>/dev/null || true

# Add bin directory to PATH for nasm
export PATH="${BIN_DIR}:${PATH}"

./configure \
    --prefix="${INSTALL_DIR}" \
    --metalcc="xcrun -sdk macosx metal -fmodules-cache-path=${CLANG_MODULE_CACHE_PATH}" \
    --arch=arm64 \
    --target-os=darwin \
    --pkg-config-flags="--static" \
    --extra-cflags="${CFLAGS}" \
    --extra-cxxflags="${CXXFLAGS}" \
    --extra-ldflags="${LDFLAGS}" \
    --extra-libs="-lpthread -lm -lz" \
    --enable-static \
    --disable-shared \
    --enable-gpl \
    --enable-version3 \
    --disable-debug \
    --disable-doc \
    --enable-pthreads \
    --enable-runtime-cpudetect \
    --enable-neon \
    \
    --disable-libxcb \
    --disable-libxcb-shm \
    --disable-libxcb-xfixes \
    --disable-libxcb-shape \
    --disable-sdl2 \
    --disable-libass \
    --disable-xlib \
    --disable-libjxl \
    --disable-libvorbis \
    \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-libaom \
    --enable-libsvtav1 \
    --enable-libvvenc \
    --enable-libopus \
    --enable-libmp3lame \
    \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    \
    --enable-encoder=libx264 \
    --enable-encoder=libx265 \
    --enable-encoder=libvpx_vp8 \
    --enable-encoder=libvpx_vp9 \
    --enable-encoder=libaom_av1 \
    --enable-encoder=libsvtav1 \
    --enable-encoder=libvvenc \
    --enable-encoder=libopus \
    --enable-encoder=libmp3lame \
    --enable-encoder=aac \
    --enable-encoder=aac_at \
    --enable-encoder=h264_videotoolbox \
    --enable-encoder=hevc_videotoolbox \
    --enable-encoder=prores_videotoolbox \
    \
    --enable-decoder=aac \
    --enable-decoder=aac_at \
    \
    --enable-filter=scale \
    --enable-filter=overlay

make ${MAKEFLAGS}
make install

if ! "${BIN_DIR}/ffmpeg" -version | head -1 | grep -Fq "ffmpeg version ${FFMPEG_VERSION}"; then
    echo "ERROR: built FFmpeg binary is not version ${FFMPEG_VERSION}" >&2
    exit 1
fi

# Copy standalone binaries to dist
OUT_DIR="${OUTPUT_DIR}/${FFMPEG_VERSION}/minimal"
echo "Creating standalone binaries in ${OUT_DIR}..."
mkdir -p "${OUT_DIR}"
cp "${BIN_DIR}/ffmpeg" "${OUT_DIR}/ffmpeg"
cp "${BIN_DIR}/ffprobe" "${OUT_DIR}/ffprobe"
chmod +x "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe"
write_dist_readme "${OUT_DIR}" "minimal"

echo ""
echo "FFmpeg binaries created:"
echo "  ${OUT_DIR}/ffmpeg"
echo "  ${OUT_DIR}/ffprobe"

mark_complete "${COMPONENT}"
