#!/bin/bash
# Copy ALL possible libmpv dependencies from Homebrew

set -e

FRAMEWORKS_DIR="Aagedal Media Converter/Frameworks"

echo "🔍 Finding all libraries in /opt/homebrew/lib..."

# Copy ALL .dylib files from Homebrew
for lib in /opt/homebrew/lib/*.dylib; do
    lib_name=$(basename "$lib")
    
    # Skip symlinks, only copy real files
    if [ -f "$lib" ] && [ ! -L "$lib" ]; then
        if [ ! -f "$FRAMEWORKS_DIR/$lib_name" ]; then
            echo "  📥 $lib_name"
            cp "$lib" "$FRAMEWORKS_DIR/"
            chmod +w "$FRAMEWORKS_DIR/$lib_name"
        fi
    fi
done

echo ""
echo "🔧 Relinking all libraries..."
for lib_file in "$FRAMEWORKS_DIR"/*.dylib; do
    lib_name=$(basename "$lib_file")
    
    # Get dependencies
    deps=$(otool -L "$lib_file" 2>/dev/null | grep -E "(\/opt\/homebrew|\/usr\/local)" | awk '{print $1}' || true)
    
    if [ -n "$deps" ]; then
        while read -r dep; do
            if [ -n "$dep" ]; then
                dep_name=$(basename "$dep")
                install_name_tool -change "$dep" "@rpath/$dep_name" "$lib_file" 2>/dev/null || true
            fi
        done <<< "$deps"
    fi
    
    # Fix library ID
    install_name_tool -id "@rpath/$lib_name" "$lib_file" 2>/dev/null || true
done

total=$(ls -1 "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | xargs)
echo ""
echo "✅ Done! Total libraries: $total"
echo ""
echo "📝 Next steps:"
echo "   1. In Xcode Build Phases → Copy Files:"
echo "      - Remove all old entries"
echo "      - Click + and select ALL $total .dylib files"
echo "   2. Clean Build (Shift+Cmd+K) and Run!"
echo ""
echo "Note: If you still get missing library errors,"
echo "run this script again to catch any new dependencies."
