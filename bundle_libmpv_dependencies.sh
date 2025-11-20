#!/usr/bin/env bash

# Find and copy ALLX11 missing dependencies for libmpv
set -e

BINARIES_DIR="Aagedal Media Converter/Binaries"

echo "🔍 Finding all missing dependencies..."

# List of all known missing libraries based on dyld errors
missing_libs=(
    "libX11.6.dylib"
    "libxcb.1.dylib"
    "libffi.8.dylib"
    "libfontconfig.1.dylib"
    "libfreetype.6.dylib"
    "libharfbuzz.0.dylib"
    "libfribidi.0.dylib"
    "libudfread.3.dylib"
    "libpng16.16.dylib"
    "libglib-2.0.0.dylib"
    "libpcre2-8.0.dylib"
    "libgraphite2.3.dylib"
    "libhwy.1.dylib"
    "libbrotlidec.1.dylib"
    "libbrotlicommon.1.dylib"
    "libbrotlienc.1.dylib"
    "libsodium.26.dylib"
    "libintl.8.dylib"
    "libp11-kit.0.dylib"
    "libidn2.0.dylib"
    "libunistring.5.dylib"
    "libtasn1.6.dylib"
    "libhogweed.6.dylib"
    "libnettle.8.dylib"
    "libgmp.10.dylib"
    "libcrypto.3.dylib"
    "libssl.3.dylib"
    "libXau.6.dylib"
    "libXdmcp.6.dylib"
    "libxcb-shm.0.dylib"
    "libxcb-render.0.dylib"
    "libxcb-shape.0.dylib"
)

echo "📥 Copying missing libraries..."
for lib in "${missing_libs[@]}"; do
    src="/opt/homebrew/lib/$lib"
    dest="$BINARIES_DIR/$lib"
    
    if [ -f "$src" ] && [ ! -f "$dest" ]; then
        echo "  📥 $lib"
        cp "$src" "$dest"
        chmod +w "$dest"
    elif [ -f "$dest" ]; then
        echo "  ✓ Already have: $lib"
    else
        echo "  ⚠️  Not found: $lib"
    fi
done

echo ""
echo "🔧 Relinking all libraries..."
for lib_file in "$BINARIES_DIR"/*.dylib; do
    lib_name=$(basename "$lib_file")
    
    # Get all dependencies
    deps=$(otool -L "$lib_file" 2>/dev/null |  grep -E "(\/opt\/homebrew|\/usr\/local)" | awk '{print $1}' || true)
    
    if [ -n "$deps" ]; then
        echo "  🔧 $lib_name"
        while read -r dep; do
            if [ -n "$dep" ]; then
                dep_name=$(basename "$dep")
                install_name_tool -change "$dep" "@rpath/$dep_name" "$lib_file" 2>/dev/null || true
            fi
        done <<< "$deps"
    fi
    
    # Fix the library's own ID
    install_name_tool -id "@rpath/$lib_name" "$lib_file" 2>/dev/null || true
done

total=$(ls -1 "$BINARIES_DIR"/*.dylib | wc -l | xargs)
echo ""
echo "✅ Done! Total libraries: $total"
echo ""
echo "📝 Next:"
echo "   1. In Xcode Build Phases → Copy Files, click +"
echo "   2. Select ALL $total .dylib files from Binaries/"
echo "   3. Destination: Frameworks, Code Sign On Copy: ✓"
echo "   4. Clean Build (Shift+Cmd+K) and Run!"
