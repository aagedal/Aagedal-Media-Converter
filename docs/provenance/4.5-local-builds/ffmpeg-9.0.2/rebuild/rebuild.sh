#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export WORKSPACE="$PWD"
# Override FFMPEG_METALCC/FFMPEG_METALLIB if Xcode cannot locate Metal.
bash scripts/02-x264.sh
bash scripts/03-x265.sh
bash scripts/04-libvpx.sh
bash scripts/05-libaom.sh
bash scripts/06-svt-av1.sh
bash scripts/07-vvenc.sh
bash scripts/09-libjxl.sh
bash scripts/10-audio.sh
bash scripts/10a-libwebp.sh
bash scripts/10c-theora.sh
bash scripts/10e-openjpeg.sh
bash scripts/11-extras.sh
bash scripts/11a-whisper.sh
bash scripts/11b-vmaf.sh
bash scripts/12-ffmpeg.sh
