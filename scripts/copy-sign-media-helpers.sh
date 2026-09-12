#!/bin/bash
# Xcode build phase: sign copied helpers before the enclosing app is sealed.
set -euo pipefail

: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
: "${DERIVED_FILE_DIR:?}"
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
staging_dir="$DERIVED_FILE_DIR/SignedMediaHelpers"
mkdir -p "$resource_dir"
mkdir -p "$staging_dir"

for helper in ffmpeg rclone tesseract asdcp-wrap bmxparse raw2bmx bmxtranswrap avmenc avmdec mxf2raw; do
    source_path="$SRCROOT/Aagedal Media Converter/Binaries/$helper"
    staging_path="$staging_dir/$helper"
    output_path="$resource_dir/$helper"
    /bin/cp -f "$source_path" "$staging_path"
    /bin/chmod u+w,a+x "$staging_path"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
        : "${EXPANDED_CODE_SIGN_IDENTITY:?Xcode did not supply a signing identity}"
        timestamp_flag=--timestamp
        if [[ "$EXPANDED_CODE_SIGN_IDENTITY" == - ]]; then
            timestamp_flag=--timestamp=none
        fi
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --options runtime "$timestamp_flag" "$staging_path"
        /usr/bin/codesign --verify --strict "$staging_path"
    fi
    /bin/cp -f "$staging_path" "$output_path"
    /bin/chmod a+x "$output_path"
done
