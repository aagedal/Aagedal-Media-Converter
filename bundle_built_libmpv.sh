#!/bin/bash
# Bundle the freshly built libmpv.dylib with all its dependencies

set -e

MPV_BUILD_LIB="mpv-build/build_libs/lib/libmpv.dylib"
DEST_DIR="Aagedal Media Converter/Frameworks"

echo "📦 Bundling self-built libmpv with dependencies..."

# Copy the main library
cp "$MPV_BUILD_LIB" "$DEST_DIR/libmpv.dylib"
chmod +w "$DEST_DIR/libmpv.dylib"

# Get all Homebrew dependencies
echo "🔍 Finding dependencies..."
deps=$(otool -L "$MPV_BUILD_LIB" | grep "/opt/homebrew" | awk '{print $1}')

echo "📥 Copying dependencies..."
for dep in $deps; do
    lib_name=$(basename "$dep")
    echo "  📥 $lib_name"
    cp "$dep" "$DEST_DIR/"
    chmod +w "$DEST_DIR/$lib_name"
done

# Recursively find dependencies of dependencies
echo "🔍 Finding transitive dependencies..."
for lib in "$DEST_DIR"/*.dylib; do
    sub_deps=$(otool -L "$lib" 2>/dev/null | grep "/opt/homebrew" | awk '{print $1}' || true)
    for sub_dep in $sub_deps; do
        sub_lib_name=$(basename "$sub_dep")
        if [ ! -f "$DEST_DIR/$sub_lib_name" ]; then
            echo "  📥 $sub_lib_name (transitive)"
            cp "$sub_dep" "$DEST_DIR/"
            chmod +w "$DEST_DIR/$sub_lib_name"
        fi
    done
done

echo "🔧 Relinking all libraries to use @rpath..."
for lib in "$DEST_DIR"/*.dylib; do
    lib_name=$(basename "$lib")
    
    # Fix the library's own ID
    install_name_tool -id "@rpath/$lib_name" "$lib" 2>/dev/null || true
    
    # Fix all Homebrew dependencies
    deps_to_fix=$(otool -L "$lib" 2>/dev/null | grep -E "(\/opt\/homebrew|\/usr\/local)" | awk '{print $1}' || true)
    for dep in $deps_to_fix; do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$dep_name" "$lib" 2>/dev/null || true
    done
done

total=$(ls -1 "$DEST_DIR"/*.dylib | wc -l | xargs)
echo ""
echo "✅ Done! Bundled $total libraries total"
echo ""
echo "📝 Next steps:"
echo "   1. In Xcode Build Phases → Copy Files:"
echo "      - Remove ALL old .dylib entries"
echo "      - Click + and select ALL $total .dylib files from Frameworks/"
echo "      - Destination: Frameworks, Code Sign On Copy: ✓"
echo "   2. Clean Build (Shift+Cmd+K)"
echo "   3. Run!"
