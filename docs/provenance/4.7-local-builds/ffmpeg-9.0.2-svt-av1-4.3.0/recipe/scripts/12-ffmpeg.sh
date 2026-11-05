#!/bin/bash

# Build FFmpeg with all codecs and macOS VideoToolbox/AudioToolbox support

set -e

if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: Apple Silicon (ARM64) is required" >&2
    exit 1
fi

source "$(dirname "$0")/../config.sh"

VARIANT="${FFMPEG_VARIANT:-full}"
case "${VARIANT}" in
    full|photo-agent) ;;
    *) echo "ERROR: Unknown full build variant: ${VARIANT}" >&2; exit 1 ;;
esac
RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"

COMPONENT="$(ffmpeg_component_name "${VARIANT}")"

OUT_DIR="${OUTPUT_DIR}/${FFMPEG_VERSION}/${VARIANT}"

if is_complete "${COMPONENT}"; then
    echo "[SKIP] ${COMPONENT} already built"
    # Preserve signed dist binaries on resume; restore missing stock outputs only.
    if [ "${VARIANT}" = "full" ] && [ -f "${BIN_DIR}/ffmpeg" ] &&
       { [ ! -x "${OUT_DIR}/ffmpeg" ] || [ ! -x "${OUT_DIR}/ffprobe" ]; }; then
        mkdir -p "${OUT_DIR}"
        copy_dist_binary "${BIN_DIR}/ffmpeg" "${OUT_DIR}/ffmpeg"
        copy_dist_binary "${BIN_DIR}/ffprobe" "${OUT_DIR}/ffprobe"
    fi
    if [ -x "${OUT_DIR}/ffmpeg" ] && [ -x "${OUT_DIR}/ffprobe" ]; then
        write_dist_readme "${OUT_DIR}" "${VARIANT}"
        exit 0
    fi
    echo "Completed binaries are missing; rebuilding ${VARIANT}..."
else
    echo "Building FFmpeg ${FFMPEG_VERSION} (${VARIANT})..."
fi

resolve_ffmpeg_metal

# Extract separate source trees so a patch/configure can never affect full/photo.
TREE="${SOURCE_DIR}/ffmpeg-${FFMPEG_VERSION}"
if [ "${VARIANT}" = "photo-agent" ]; then
    TREE="${SOURCE_DIR}/ffmpeg-${FFMPEG_VERSION}-photo-agent"
fi
if [ ! -d "${TREE}" ]; then
    ARCHIVE="${SOURCE_DIR}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    if [ ! -f "${ARCHIVE}" ]; then
        download_file "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "${ARCHIVE}"
    fi
    mkdir -p "${TREE}"
    tar xf "${ARCHIVE}" --strip-components=1 -C "${TREE}"
fi
cd "${TREE}"

# Both app builds need the upstream proposed Metal ownership correction.
YADIF_HASH="$(shasum -a 256 libavfilter/vf_yadif_videotoolbox.m | cut -d ' ' -f1)"
case "${YADIF_HASH}" in
    dad7ff78662f5e6eda23e36a8f9fb4c155e6606d2dd8178df81063a657fb8d3c)
        patch --batch --fuzz=0 -p1 -i "${RECIPE_DIR}/ffmpeg/yadif-videotoolbox-autorelease.patch"
        ;;
    950f9acd1346a45171710c163d5f78c0673b0dcd59d57ee767b66919a07c7e37) ;;
    *) echo "ERROR: Unrecognized yadif_videotoolbox source" >&2; exit 1 ;;
esac
if [ "$(shasum -a 256 libavfilter/vf_yadif_videotoolbox.m | cut -d ' ' -f1)" != \
     "950f9acd1346a45171710c163d5f78c0673b0dcd59d57ee767b66919a07c7e37" ]; then
    echo "ERROR: YADIF correction produced unexpected source bytes" >&2
    exit 1
fi

# Both app builds expose libopenjpeg's per-frame/per-component size caps so DCP
# exports can honour bitrates other than the fixed cinema_mode limits, then IMF
# profiles (Rsiz with main/sub level) using the same caps for IMF App 2e.
OPENJPEG_ENC_HASH="$(shasum -a 256 libavcodec/libopenjpegenc.c | cut -d ' ' -f1)"
case "${OPENJPEG_ENC_HASH}" in
    6b6bf1241f3606f83929920d08d576e33f88ddb76fa682d98c3cb0ae3d41bef7)
        patch --batch --fuzz=0 -p1 -i "${RECIPE_DIR}/ffmpeg/libopenjpegenc-max-size.patch"
        patch --batch --fuzz=0 -p1 -i "${RECIPE_DIR}/ffmpeg/libopenjpegenc-imf.patch"
        ;;
    9c5e75a7941888a2cf4972c21a9481a0f5d7c3791dcb210e1512d8e014a19c39)
        patch --batch --fuzz=0 -p1 -i "${RECIPE_DIR}/ffmpeg/libopenjpegenc-imf.patch"
        ;;
    740027d284ec225b67220fa7bd970f1cf6be953953d558a223e2c7c96fdcbb12) ;;
    *) echo "ERROR: Unrecognized libopenjpegenc source" >&2; exit 1 ;;
esac
if [ "$(shasum -a 256 libavcodec/libopenjpegenc.c | cut -d ' ' -f1)" != \
     "740027d284ec225b67220fa7bd970f1cf6be953953d558a223e2c7c96fdcbb12" ]; then
    echo "ERROR: libopenjpegenc patches produced unexpected source bytes" >&2
    exit 1
fi

if [ "${VARIANT}" = "photo-agent" ]; then
    # Run the actual extracted-function sanitizer harness before compiling.
    python3 "${RECIPE_DIR}/ci/test_ffmpeg_whisper_patch.py"
    PATCHED_HASH="eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71"
    FILTER_HASH="$(shasum -a 256 libavfilter/af_whisper.c | cut -d " " -f1)"
    if [ "${FILTER_HASH}" != "${PATCHED_HASH}" ]; then
        python3 "${RECIPE_DIR}/ffmpeg/prepare_whisper_source.py" libavfilter/af_whisper.c \
            --output libavfilter/af_whisper.c.patched
        mv libavfilter/af_whisper.c.patched libavfilter/af_whisper.c
    fi
else
    # Fail if somebody has patched the stock source instead of the isolated tree.
    python3 "${RECIPE_DIR}/ffmpeg/prepare_whisper_source.py" libavfilter/af_whisper.c
fi

if [ ! -f VERSION ] || [ "$(tr -d '\r\n' < VERSION)" != "${FFMPEG_VERSION}" ]; then
    echo "ERROR: FFmpeg source tree does not match requested version ${FFMPEG_VERSION}" >&2
    exit 1
fi

# A previous interrupted configure in this source directory must not leak into
# the new build configuration.
make distclean 2>/dev/null || true

# Add bin directory to PATH for nasm
export PATH="${BIN_DIR}:${PATH}"

./configure \
    --prefix="${INSTALL_DIR}" \
    --metalcc="${FFMPEG_METALCC} -fmodules-cache-path=${CLANG_MODULE_CACHE_PATH}" \
    --metallib="${FFMPEG_METALLIB}" \
    --enable-metal \
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
    --disable-libxcb \
    --disable-libxcb-shm \
    --disable-libxcb-xfixes \
    --disable-libxcb-shape \
    --disable-sdl2 \
    --disable-xlib \
    --disable-libfontconfig \
    \
    --enable-libass \
    --enable-libharfbuzz \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-libaom \
    --enable-libsvtav1 \
    --enable-libvvenc \
    --enable-libjxl \
    --enable-libwebp \
    --enable-libopus \
    --enable-libvorbis \
    --enable-libmp3lame \
    --enable-libtheora \
    --enable-libopenjpeg \
    --enable-libvmaf \
    --enable-whisper \
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
    --enable-encoder=libjxl \
    --enable-encoder=libwebp \
    --enable-encoder=libwebp_anim \
    --enable-encoder=libopus \
    --enable-encoder=libvorbis \
    --enable-encoder=libmp3lame \
    --enable-encoder=aac \
    --enable-encoder=aac_at \
    --enable-encoder=flac \
    --enable-encoder=libtheora \
    --enable-encoder=libopenjpeg \
    --enable-encoder=h264_videotoolbox \
    --enable-encoder=hevc_videotoolbox \
    --enable-encoder=prores_videotoolbox \
    \
    --enable-decoder=libjxl \
    --enable-decoder=aac \
    --enable-decoder=aac_at \
    --enable-decoder=flac \
    --enable-decoder=vvc \
    --enable-decoder=theora \
    \
    --enable-filter=scale \
    --enable-filter=overlay \
    --enable-filter=whisper \
    --enable-filter=yadif_videotoolbox \
    --enable-filter=ssim \
    --enable-filter=psnr \
    --enable-filter=xpsnr \
    --enable-filter=msad

make ${MAKEFLAGS}
if [ "${VARIANT}" = "full" ]; then
    make install
fi

if ! ./ffmpeg -version | head -1 | grep -Fq "ffmpeg version ${FFMPEG_VERSION}"; then
    echo "ERROR: built FFmpeg binary is not version ${FFMPEG_VERSION}" >&2
    exit 1
fi

# Copy standalone binaries to dist
echo "Creating standalone binaries in ${OUT_DIR}..."
mkdir -p "${OUT_DIR}"
copy_dist_binary ./ffmpeg "${OUT_DIR}/ffmpeg"
copy_dist_binary ./ffprobe "${OUT_DIR}/ffprobe"
chmod +x "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe"
write_dist_readme "${OUT_DIR}" "${VARIANT}"

echo ""
echo "FFmpeg binaries created:"
echo "  ${OUT_DIR}/ffmpeg"
echo "  ${OUT_DIR}/ffprobe"

mark_complete "${COMPONENT}"
