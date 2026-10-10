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

for helper in ffmpeg rclone tesseract asdcp-wrap bmxparse raw2bmx bmxtranswrap avmenc avmdec mxf2raw ssimulacra2_rs; do
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

# Preserve the upstream bin/../lib layout so the native NeMo CLI resolves all
# runtime libraries inside the app, without Homebrew or DYLD overrides.
nemo_source="$SRCROOT/Aagedal Media Converter/Binaries/NeMoSpeech"
nemo_staging="$staging_dir/NeMoSpeech"
nemo_output="$resource_dir/NeMoSpeech"
/bin/rm -rf "$nemo_staging" "$nemo_output"
/bin/cp -R "$nemo_source" "$nemo_staging"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    while IFS= read -r -d '' image; do
        /bin/chmod u+w "$image"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --options runtime "$timestamp_flag" "$image"
        /usr/bin/codesign --verify --strict "$image"
    done < <(/usr/bin/find "$nemo_staging/lib" -type f -name '*.dylib' -print0)
    nemo_signing_args=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$timestamp_flag")
    if [[ "$EXPANDED_CODE_SIGN_IDENTITY" == - ]]; then
        nemo_signing_args+=(--entitlements "$SRCROOT/scripts/nemo-development.entitlements")
    fi
    /usr/bin/codesign "${nemo_signing_args[@]}" "$nemo_staging/bin/nemo-speech"
    /usr/bin/codesign --verify --strict "$nemo_staging/bin/nemo-speech"
fi
/bin/cp -R "$nemo_staging" "$nemo_output"
/bin/cp "$SRCROOT/Licenses/nemo-speech-LICENSE.txt" "$resource_dir/nemo-speech-LICENSE.txt"
