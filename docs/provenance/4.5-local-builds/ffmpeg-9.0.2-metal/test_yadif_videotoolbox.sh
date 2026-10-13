#!/bin/bash

# Exercise Metal deinterlacing through EOF, including the autorelease teardown.
set -e
source "$(dirname "$0")/../config.sh"

VARIANT="${1:-full}"
case "${VARIANT}" in
    full|photo-agent) ;;
    *) echo "ERROR: Expected full or photo-agent" >&2; exit 2 ;;
esac
FFMPEG_BIN="${OUTPUT_DIR}/${FFMPEG_VERSION}/${VARIANT}/ffmpeg"

for FORMAT in nv12 p010le; do
    for MODE in send_frame send_field; do
        TARGET="${BUILD_DIR}/yadif-${VARIANT}-${FORMAT}-${MODE}"
        if ! "${FFMPEG_BIN}" -nostdin -hide_banner -loglevel verbose -y \
            -init_hw_device videotoolbox=vt -filter_hw_device vt \
            -f lavfi -i testsrc2=size=128x128:rate=25:duration=0.16 \
            -vf "format=${FORMAT},setfield=tff,hwupload,yadif_videotoolbox=mode=${MODE}:parity=tff:deint=all,hwdownload,format=${FORMAT}" \
            -fps_mode passthrough -f framemd5 "${TARGET}.framemd5" > "${TARGET}.log" 2>&1; then
            echo "ERROR: ${VARIANT} ${FORMAT} ${MODE} failed; see ${TARGET}.log" >&2
            exit 1
        fi
        EXPECTED=4
        [ "${MODE}" != "send_field" ] || EXPECTED=8
        COUNT="$(awk '!/^#/ && NF {n++} END {print n+0}' "${TARGET}.framemd5")"
        if [ "${COUNT}" != "${EXPECTED}" ] || ! grep -q 'Using Metal device:' "${TARGET}.log"; then
            echo "ERROR: Expected ${EXPECTED} frames on Metal; got ${COUNT}" >&2
            exit 1
        fi
        echo "PASS: ${VARIANT} ${FORMAT} ${MODE}: ${COUNT} frames, successful Metal teardown"
    done
done
