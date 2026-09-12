#!/bin/bash

# FFmpeg Build Configuration
# This file contains shared configuration used by all build scripts

set -e

# Build directories
export WORKSPACE="${WORKSPACE:-$(pwd)}"
export BUILD_DIR="${WORKSPACE}/build"
export SOURCE_DIR="${WORKSPACE}/sources"
export INSTALL_DIR="${WORKSPACE}/compiled"
export BIN_DIR="${INSTALL_DIR}/bin"
export LIB_DIR="${INSTALL_DIR}/lib"
export INCLUDE_DIR="${INSTALL_DIR}/include"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/clang-module-cache"

# Final binaries land in dist/<ffmpeg-version>/<variant>/ (full, photo, minimal)
# so every variant keeps the plain names ffmpeg/ffprobe and versions can coexist
# Avoid exporting the generic name DIST_DIR: libvpx uses it internally and
# would otherwise install into our distribution folder instead of compiled/.
export OUTPUT_DIR="${WORKSPACE}/dist"

# Create directories if they don't exist
mkdir -p "${BUILD_DIR}" "${SOURCE_DIR}" "${INSTALL_DIR}" "${BIN_DIR}" "${LIB_DIR}" "${INCLUDE_DIR}" "${CLANG_MODULE_CACHE_PATH}"

# Number of CPU cores for parallel builds. getconf is a useful fallback in
# sandboxed build environments where sysctl may be restricted.
CPU_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
export CPU_COUNT
export MAKEFLAGS="-j${CPU_COUNT}"

# Apple Silicon (ARM64) specific settings
export ARCH="arm64"
export MACOSX_DEPLOYMENT_TARGET="11.0"  # macOS 11.0 Big Sur minimum for Apple Silicon

# Compiler flags for static builds on macOS (Apple Silicon optimized)
export CFLAGS="-arch arm64 -I${INCLUDE_DIR} -O3 -fPIC -mcpu=apple-m1"
export CXXFLAGS="-arch arm64 -I${INCLUDE_DIR} -O3 -fPIC -mcpu=apple-m1"
export LDFLAGS="-arch arm64 -L${LIB_DIR}"
export PKG_CONFIG_PATH="${LIB_DIR}/pkgconfig"
# Do not let pkg-config fall back to Homebrew or other host libraries. Every
# third-party library linked into FFmpeg must come from this build prefix.
export PKG_CONFIG_LIBDIR="${LIB_DIR}/pkgconfig"

# Clean up libtool .la files and -uninstalled.pc files that can cause linking issues
find "${LIB_DIR}" -name "*.la" -delete 2>/dev/null || true
find "${LIB_DIR}/pkgconfig" -name "*-uninstalled.pc" -delete 2>/dev/null || true

# macOS SDK path (for VideoToolbox support)
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)

# Library versions
export NASM_VERSION="3.02"
export X264_VERSION="stable"
export X265_VERSION="4.2"
export LIBVPX_VERSION="1.16.0"
export LIBAOM_VERSION="3.14.1"
export SVT_AV1_VERSION="4.2.0"
export VVENC_VERSION="1.14.0"
export VVDEC_VERSION="3.2.0"
export LIBJXL_VERSION="0.12.0"
export OPUS_VERSION="1.6.1"
export VORBIS_VERSION="1.3.7"
export OGG_VERSION="1.3.6"
export LAME_VERSION="4.0"
export LIBASS_VERSION="0.17.5"
export FREETYPE_VERSION="2.14.3"
export FRIBIDI_VERSION="1.0.16"
export HARFBUZZ_VERSION="14.3.1"
export LIBPNG_VERSION="1.6.58"
export BROTLI_VERSION="1.2.0"
export HIGHWAY_VERSION="1.4.0"
export LIBWEBP_VERSION="1.6.0"
export FLAC_VERSION="1.5.0"
export THEORA_VERSION="1.2.0"
export LIBBLURAY_VERSION="1.5.0"
export WHISPER_VERSION="1.9.2"
export OPENJPEG_VERSION="2.5.4"
export VMAF_VERSION="3.2.0"
export FFMPEG_VERSION="9.0.1"

# Progress tracking
export PROGRESS_FILE="${PROGRESS_FILE:-${WORKSPACE}/.build-progress}"

# A progress file is reusable only when every source version is identical.
# This prevents a resume after a version bump from silently linking stale
# libraries from a previous build.
export BUILD_CONFIGURATION_ID="${NASM_VERSION}|${X264_VERSION}|${X265_VERSION}|${LIBVPX_VERSION}|${LIBAOM_VERSION}|${SVT_AV1_VERSION}|${VVENC_VERSION}|${VVDEC_VERSION}|${LIBJXL_VERSION}|${OPUS_VERSION}|${VORBIS_VERSION}|${OGG_VERSION}|${LAME_VERSION}|${LIBASS_VERSION}|${FREETYPE_VERSION}|${FRIBIDI_VERSION}|${HARFBUZZ_VERSION}|${LIBPNG_VERSION}|${BROTLI_VERSION}|${HIGHWAY_VERSION}|${LIBWEBP_VERSION}|${FLAC_VERSION}|${THEORA_VERSION}|${LIBBLURAY_VERSION}|${WHISPER_VERSION}|${OPENJPEG_VERSION}|${VMAF_VERSION}|${FFMPEG_VERSION}"
export BUILD_CONFIGURATION_HEADER="# versions: ${BUILD_CONFIGURATION_ID}"

progress_matches_configuration() {
    [ -f "${PROGRESS_FILE}" ] && grep -Fqx "${BUILD_CONFIGURATION_HEADER}" "${PROGRESS_FILE}"
}

# Download to a temporary name so an interrupted transfer can never be
# mistaken for a valid source archive on the next resume.
download_file() {
    local url="$1"
    local output="$2"
    local partial="${output}.part"

    if ! curl --fail --location --retry 3 --retry-all-errors \
        --connect-timeout 30 --output "${partial}" "${url}"; then
        rm -f "${partial}"
        return 1
    fi
    mv "${partial}" "${output}"
}

# Helper function to mark component as complete
mark_complete() {
    local component="$1"

    if ! progress_matches_configuration; then
        echo "${BUILD_CONFIGURATION_HEADER}" > "${PROGRESS_FILE}"
    fi
    if ! grep -Fqx "${component}" "${PROGRESS_FILE}"; then
        echo "${component}" >> "${PROGRESS_FILE}"
    fi
    echo "[✓] ${component} completed"
}

# Write a README.md next to the dist binaries documenting the build:
# variant, date, license, configure flags (read from the binary itself),
# and the versions of the external libraries that variant links
write_dist_readme() {
    local out_dir="$1"
    local variant="$2"
    local bin="${out_dir}/ffmpeg"
    local conf

    [ -x "${bin}" ] || return 0

    local binary binary_name version_line
    for binary in "${bin}" "${out_dir}/ffprobe"; do
        binary_name="$(basename "${binary}")"
        version_line="$(${binary} -version | sed -n '1p')"
        case "${version_line}" in
            "${binary_name} version ${FFMPEG_VERSION} "*) ;;
            *)
                echo "ERROR: ${binary} does not report exact version ${FFMPEG_VERSION}: ${version_line}" >&2
                return 1
                ;;
        esac
    done

    # Guard: the dist binaries must be fully static apart from system libs.
    # A Homebrew dylib reference means a dependency silently failed to build
    # statically (it also crashes under hardened-runtime signing).
    if otool -L "${bin}" "${out_dir}/ffprobe" 2>/dev/null | grep -Eq "/opt/homebrew|/usr/local|/compiled/"; then
        echo "ERROR: ${out_dir} binaries link non-system build dependencies:" >&2
        otool -L "${bin}" "${out_dir}/ffprobe" | grep -E "/opt/homebrew|/usr/local|/compiled/" >&2
        return 1
    fi

    conf="$("${bin}" -buildconf 2>/dev/null)"
    if [ -z "${conf}" ]; then
        echo "ERROR: ${bin} failed to execute — cannot write build manifest" >&2
        return 1
    fi

    {
        echo "# FFmpeg ${FFMPEG_VERSION} — ${variant} build"
        echo ""
        echo "Static arm64 (Apple Silicon) binaries: \`ffmpeg\`, \`ffprobe\`"
        echo ""
        echo "- Built: $(date '+%Y-%m-%d %H:%M %Z') on macOS $(sw_vers -productVersion)"
        echo "- Minimum macOS: ${MACOSX_DEPLOYMENT_TARGET} (Apple Silicon only)"
        echo "- License: GPL version 3 or later (no nonfree components)"
        echo ""
        echo "## External libraries"
        echo ""

        local entry name ver desc
        for entry in \
            "libx264:${X264_VERSION:-}:H.264/AVC encoder" \
            "libx265:${X265_VERSION:-}:HEVC/H.265 encoder" \
            "libvpx:${LIBVPX_VERSION:-}:VP8/VP9" \
            "libaom:${LIBAOM_VERSION:-}:AV1 encoder/decoder" \
            "libsvtav1:${SVT_AV1_VERSION:-}:SVT-AV1 encoder" \
            "libvvenc:${VVENC_VERSION:-}:VVC/H.266 encoder" \
            "libjxl:${LIBJXL_VERSION:-}:JPEG XL (with brotli ${BROTLI_VERSION:-}, highway ${HIGHWAY_VERSION:-})" \
            "libwebp:${LIBWEBP_VERSION:-}:WebP encoder" \
            "libopus:${OPUS_VERSION:-}:Opus audio" \
            "libvorbis:${VORBIS_VERSION:-}:Vorbis audio (with libogg ${OGG_VERSION:-})" \
            "libmp3lame:${LAME_VERSION:-}:MP3 encoder" \
            "libtheora:${THEORA_VERSION:-}:Theora video" \
            "libopenjpeg:${OPENJPEG_VERSION:-}:JPEG 2000" \
            "libvmaf:${VMAF_VERSION:-}:VMAF quality metric" \
            "whisper:${WHISPER_VERSION:-}:whisper.cpp speech recognition"
        do
            name="${entry%%:*}"
            ver="$(echo "${entry}" | cut -d: -f2)"
            desc="${entry#*:*:}"
            if echo "${conf}" | grep -q -- "--enable-${name}"; then
                echo "- ${name} ${ver} — ${desc}"
            fi
        done

        echo ""
        echo "## Configure flags"
        echo ""
        echo '```'
        echo "${conf}"
        echo '```'
    } > "${out_dir}/README.md"

    echo "Build manifest written: ${out_dir}/README.md"
}

# Helper function to check if component is already built
is_complete() {
    local component="$1"
    if progress_matches_configuration; then
        grep -Fqx "${component}" "${PROGRESS_FILE}" 2>/dev/null
        return $?
    fi
    return 1
}

echo "Build configuration loaded"
echo "Target architecture: Apple Silicon (ARM64)"
echo "Workspace: ${WORKSPACE}"
echo "Install directory: ${INSTALL_DIR}"
echo "CPU cores: ${CPU_COUNT}"
