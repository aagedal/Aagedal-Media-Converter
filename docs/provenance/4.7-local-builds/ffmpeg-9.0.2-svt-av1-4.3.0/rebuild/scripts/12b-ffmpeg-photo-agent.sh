#!/bin/bash

# Full codec build with Photo Agent's canonical Whisper output contract.
set -e
export FFMPEG_VARIANT="photo-agent"
exec bash "$(dirname "$0")/12-ffmpeg.sh"
