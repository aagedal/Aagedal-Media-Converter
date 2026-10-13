#!/bin/bash

# Master FFmpeg Build Script
# This script orchestrates the entire build process and tracks progress

set -e

echo "=========================================="
echo "FFmpeg Custom Build System"
echo "Apple Silicon (ARM64) Build"
echo "=========================================="
echo ""

# Check if running on Apple Silicon
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: This build is configured for Apple Silicon Macs only"
    echo "Current architecture: $(uname -m)"
    echo "Please run this on an M1, M2, or M3 Mac"
    exit 1
fi

# Load configuration
source "$(dirname "$0")/config.sh"

# Check for required tools
echo "Checking for required build tools..."

if ! command -v git &> /dev/null; then
    echo "ERROR: git is required but not installed"
    exit 1
fi

if ! command -v cmake &> /dev/null; then
    echo "ERROR: cmake is required but not installed"
    echo "Install with: brew install cmake"
    exit 1
fi

if ! command -v meson &> /dev/null; then
    echo "ERROR: meson is required but not installed"
    echo "Install with: brew install meson"
    exit 1
fi

if ! command -v ninja &> /dev/null; then
    echo "ERROR: ninja is required but not installed"
    echo "Install with: brew install ninja"
    exit 1
fi

if ! command -v pkg-config &> /dev/null; then
    echo "ERROR: pkg-config is required but not installed"
    echo "Install with: brew install pkg-config"
    exit 1
fi

echo "All required tools found!"
echo ""

while true; do
    read -r -p "Start a clean build or continue the existing build? [c]lean/[r]esume: " build_mode
    case "${build_mode}" in
        c|C|clean|Clean|CLEAN)
            echo "Cleaning previous build artifacts and progress..."
            rm -rf "${BUILD_DIR}" "${SOURCE_DIR}" "${INSTALL_DIR}" "${OUTPUT_DIR}"
            rm -f "${PROGRESS_FILE}"
            mkdir -p "${BUILD_DIR}" "${SOURCE_DIR}" "${INSTALL_DIR}" "${BIN_DIR}" "${LIB_DIR}" "${INCLUDE_DIR}"
            echo "Clean build selected."
            break
            ;;
        r|R|resume|Resume|RESUME)
            echo "Continuing existing build."
            break
            ;;
        *)
            echo "Please enter c for clean or r to continue."
            ;;
    esac
done

# Build components in order
BUILD_SCRIPTS=(
    "01-nasm.sh"
    "02-x264.sh"
    "03-x265.sh"
    "04-libvpx.sh"
    "05-libaom.sh"
    "06-svt-av1.sh"
    "07-vvenc.sh"
    "08-vvdec.sh"
    "09-libjxl.sh"
    "10-audio.sh"
    "10a-libwebp.sh"
    "10b-flac.sh"
    "10c-theora.sh"
    "10e-openjpeg.sh"
    "11-extras.sh"
    "11a-whisper.sh"
    "11b-vmaf.sh"
    "12-ffmpeg.sh"
    "12a-ffmpeg-photo.sh"
    "12b-ffmpeg-photo-agent.sh"
)

echo "Build Progress:"
echo "=========================================="

# Show current progress
TOTAL=${#BUILD_SCRIPTS[@]}
COMPLETED=0

for script in "${BUILD_SCRIPTS[@]}"; do
    script_path="${WORKSPACE}/scripts/${script}"
    if [ ! -f "${script_path}" ]; then
        echo "ERROR: Required script not found: ${script_path}" >&2
        exit 1
    fi
    component_name="$(sed -n 's/^COMPONENT="\([^"]*\)"/\1/p' "${script_path}" | head -1)"
    case "${script}" in
        12-ffmpeg.sh) component_name="$(ffmpeg_component_name full)" ;;
        12b-ffmpeg-photo-agent.sh) component_name="$(ffmpeg_component_name photo-agent)" ;;
    esac
    if [ -z "${component_name}" ]; then
        echo "ERROR: ${script_path} does not declare COMPONENT" >&2
        exit 1
    fi
    
    if is_complete "$component_name" 2>/dev/null; then
        echo "[✓] $component_name"
        COMPLETED=$((COMPLETED + 1))
    else
        echo "[ ] $component_name"
    fi
done

echo "=========================================="
echo "Progress: ${COMPLETED}/${TOTAL} components built"
echo ""

if [ $COMPLETED -eq $TOTAL ]; then
    echo "All components already built!"
    echo ""
    echo "FFmpeg binaries are located at:"
    echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/full/ffmpeg     (+ ffprobe)"
    echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/photo-agent/ffmpeg (+ ffprobe; full codecs, patched Whisper)"
    echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/photo/ffmpeg    (+ ffprobe; image-only: most formats in, AVIF/JXL out)"
    echo ""
    exit 0
fi

echo "Starting build process..."
echo "This will take several hours. You can safely interrupt and resume later."
echo ""

read -p "Press Enter to continue or Ctrl+C to cancel..."
echo ""

# Execute build scripts
for script in "${BUILD_SCRIPTS[@]}"; do
    script_path="${WORKSPACE}/scripts/${script}"
    
    if [ -f "$script_path" ]; then
        echo ""
        echo "=========================================="
        echo "Running: $script"
        echo "=========================================="
        
        chmod +x "$script_path"
        if ! bash "$script_path"; then
            echo "ERROR: Build failed at $script"
            echo "You can fix the issue and re-run this script to continue"
            exit 1
        fi
    else
        echo "ERROR: Required script not found: $script_path" >&2
        exit 1
    fi
done

echo ""
echo "=========================================="
echo "Build Complete!"
echo "=========================================="
echo ""
echo "FFmpeg binaries:"
echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/full/ffmpeg     (+ ffprobe)"
echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/photo/ffmpeg    (+ ffprobe; image-only: most formats in, AVIF/JXL out)"
echo "  ${OUTPUT_DIR}/${FFMPEG_VERSION}/photo-agent/ffmpeg (+ ffprobe; full codecs, patched Whisper)"
echo ""
echo "Supported features:"
echo "  - x264 (H.264)"
echo "  - x265 (HEVC/H.265)"
echo "  - libvpx (VP8/VP9)"
echo "  - libaom (AV1)"
echo "  - SVT-AV1 (Fast AV1)"
echo "  - VVenC/VVdeC (VVC)"
echo "  - libjxl (JPEG XL)"
echo "  - Opus, Vorbis, MP3 LAME"
echo "  - AAC (native encoder + AudioToolbox aac_at)"
echo "  - FLAC (lossless audio)"
echo "  - Theora (video codec)"
echo "  - libwebp (WebP images/animation)"
echo "  - OpenJPEG (JPEG 2000 for DCP)"
echo "  - Whisper (speech recognition/transcription)"
echo "  - VMAF, SSIM, PSNR, MSAD (video quality metrics)"
echo "  - VideoToolbox (macOS hardware acceleration)"
echo "  - AudioToolbox (macOS audio processing)"
echo ""
echo "Test your build:"
echo "  ./dist/${FFMPEG_VERSION}/full/ffmpeg -version"
echo "  ./dist/${FFMPEG_VERSION}/photo/ffmpeg -version"
echo "  ./dist/${FFMPEG_VERSION}/full/ffmpeg -codecs | grep jxl"
echo "  ./dist/${FFMPEG_VERSION}/full/ffmpeg -filters | grep whisper"
echo "  ./dist/${FFMPEG_VERSION}/full/ffmpeg -encoders | grep videotoolbox"
echo ""
