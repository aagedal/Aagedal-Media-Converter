#!/bin/bash

# Build FFmpeg - PHOTO EDITION
# Minimal image-only build: decodes most image formats, encodes AVIF and JPEG XL
# No audio codecs, no video codecs beyond what images need (AV1 for AVIF, HEVC for HEIC)
# Must run after 12-ffmpeg.sh (shares its source tree)
# Produces ffmpeg-photo and ffprobe-photo binaries

source "$(dirname "$0")/../config.sh"

COMPONENT="ffmpeg-photo"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    exit 0
fi

echo "Building FFmpeg ${FFMPEG_VERSION} (Photo Edition)..."

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

# Clean any previous FFmpeg build (shared source tree with the full builds)
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
    --enable-pic \
    \
    --disable-everything \
    --disable-autodetect \
    --disable-network \
    --disable-avdevice \
    --enable-zlib \
    \
    --enable-libjxl \
    --enable-libsvtav1 \
    --enable-libaom \
    --enable-libwebp \
    \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-protocol=fd \
    \
    --enable-demuxer=image2 \
    --enable-demuxer=image2pipe \
    --enable-demuxer=mov \
    --enable-demuxer=gif \
    --enable-demuxer=apng \
    --enable-demuxer=jpegxl_anim \
    --enable-demuxer=image_png_pipe \
    --enable-demuxer=image_jpeg_pipe \
    --enable-demuxer=image_jpegls_pipe \
    --enable-demuxer=image_jpegxl_pipe \
    --enable-demuxer=image_webp_pipe \
    --enable-demuxer=image_bmp_pipe \
    --enable-demuxer=image_tiff_pipe \
    --enable-demuxer=image_j2k_pipe \
    --enable-demuxer=image_dds_pipe \
    --enable-demuxer=image_dpx_pipe \
    --enable-demuxer=image_exr_pipe \
    --enable-demuxer=image_hdr_pipe \
    --enable-demuxer=image_pam_pipe \
    --enable-demuxer=image_pbm_pipe \
    --enable-demuxer=image_pcx_pipe \
    --enable-demuxer=image_pfm_pipe \
    --enable-demuxer=image_pgm_pipe \
    --enable-demuxer=image_ppm_pipe \
    --enable-demuxer=image_psd_pipe \
    --enable-demuxer=image_qoi_pipe \
    --enable-demuxer=image_sgi_pipe \
    --enable-demuxer=image_sunrast_pipe \
    --enable-demuxer=image_gif_pipe \
    \
    --enable-decoder=png \
    --enable-decoder=apng \
    --enable-decoder=mjpeg \
    --enable-decoder=jpegls \
    --enable-decoder=jpeg2000 \
    --enable-decoder=libjxl \
    --enable-decoder=libaom_av1 \
    --enable-decoder=hevc \
    --enable-decoder=webp \
    --enable-decoder=tiff \
    --enable-decoder=bmp \
    --enable-decoder=gif \
    --enable-decoder=targa \
    --enable-decoder=pcx \
    --enable-decoder=psd \
    --enable-decoder=pam \
    --enable-decoder=pbm \
    --enable-decoder=pgm \
    --enable-decoder=ppm \
    --enable-decoder=pfm \
    --enable-decoder=sgi \
    --enable-decoder=sunrast \
    --enable-decoder=dds \
    --enable-decoder=dpx \
    --enable-decoder=exr \
    --enable-decoder=qoi \
    --enable-decoder=hdr \
    \
    --enable-parser=av1 \
    --enable-parser=hevc \
    --enable-parser=mjpeg \
    --enable-parser=png \
    --enable-parser=bmp \
    --enable-parser=gif \
    --enable-parser=webp \
    --enable-parser=jpegxl \
    --enable-parser=jpeg2000 \
    \
    --enable-muxer=image2 \
    --enable-muxer=avif \
    --enable-muxer=webp \
    \
    --enable-encoder=libjxl \
    --enable-encoder=libsvtav1 \
    --enable-encoder=libaom_av1 \
    --enable-encoder=libwebp \
    --enable-encoder=png \
    --enable-encoder=mjpeg \
    --enable-encoder=tiff \
    --enable-encoder=exr \
    \
    --enable-filter=scale \
    --enable-filter=format \
    --enable-filter=null \
    --enable-filter=crop \
    --enable-filter=transpose

make ${MAKEFLAGS}

if ! ./ffmpeg -version | head -1 | grep -Fq "ffmpeg version ${FFMPEG_VERSION}"; then
    echo "ERROR: built FFmpeg binary is not version ${FFMPEG_VERSION}" >&2
    exit 1
fi

# Copy to dist without `make install`
# (installing would overwrite the full binaries in ${BIN_DIR})
OUT_DIR="${OUTPUT_DIR}/${FFMPEG_VERSION}/photo"
echo "Creating photo edition standalone binaries in ${OUT_DIR}..."
mkdir -p "${OUT_DIR}"
cp "ffmpeg" "${OUT_DIR}/ffmpeg"
cp "ffprobe" "${OUT_DIR}/ffprobe"
chmod +x "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe"
write_dist_readme "${OUT_DIR}" "photo"

echo ""
echo "FFmpeg (Photo Edition) binaries created:"
echo "  ${OUT_DIR}/ffmpeg"
echo "  ${OUT_DIR}/ffprobe"

mark_complete "${COMPONENT}"
