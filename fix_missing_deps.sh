#!/bin/bash
# Recursively find and bundle missing dependencies from Homebrew

# Recursively find and bundle missing dependencies from Homebrew

FRAMEWORKS_DIR="Aagedal Media Converter/Frameworks"

# Function to check and copy a library
copy_lib_if_missing() {
    local lib_name="$1"
    local src_path="/opt/homebrew/lib/$lib_name"
    local dest_path="$FRAMEWORKS_DIR/$lib_name"
    
    if [ ! -f "$dest_path" ]; then
        if [ -f "$src_path" ]; then
            echo "  📥 Copying missing: $lib_name"
            cp "$src_path" "$dest_path"
            chmod +w "$dest_path"
            return 0 # Copied
        else
            # Try finding it if not in direct path (some might be in Cellar symlinks)
            found_path=$(find /opt/homebrew/lib -name "$lib_name" | head -1)
            if [ -n "$found_path" ]; then
                echo "  📥 Copying missing (found): $lib_name"
                cp "$found_path" "$dest_path"
                chmod +w "$dest_path"
                return 0
            else
                echo "  ⚠️  Could not find: $lib_name"
                return 1
            fi
        fi
    else
        return 1 # Already exists
    fi
}

echo "🔍 Scanning for missing dependencies..."

# 1. Start with known missing ones from this step
copy_lib_if_missing "libleptonica.6.dylib" || true
copy_lib_if_missing "libgif.dylib" || true
copy_lib_if_missing "libtiff.6.dylib" || true
copy_lib_if_missing "libwebpmux.3.dylib" || true

# 2. Recursive scan loop
changed=1
while [ $changed -eq 1 ]; do
    changed=0
    echo "  🔄 Scanning all bundled libraries for missing dependencies..."
    
    for lib in "$FRAMEWORKS_DIR"/*.dylib; do
        # Get dependencies that look like Homebrew paths or @rpath but aren't in Frameworks
        deps=$(otool -L "$lib" | grep -E "/opt/homebrew|@rpath" | awk '{print $1}')
        
        for dep in $deps; do
            dep_name=$(basename "$dep")
            
            # Ignore self
            if [ "$dep_name" == "$(basename "$lib")" ]; then continue; fi
            
            # Check if we have it
            if [ ! -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                echo "    🔎 Found missing dependency: $dep_name (needed by $(basename "$lib"))"
                if copy_lib_if_missing "$dep_name"; then
                    changed=1
                fi
            fi
        done
    done
done

echo "🔧 Relinking all libraries..."
for lib in "$FRAMEWORKS_DIR"/*.dylib; do
    lib_name=$(basename "$lib")
    
    # Fix ID
    install_name_tool -id "@rpath/$lib_name" "$lib" 2>/dev/null || true
    
    # Fix dependencies
    deps=$(otool -L "$lib" | grep -E "(\/opt\/homebrew|\/usr\/local)" | awk '{print $1}')
    for dep in $deps; do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$dep_name" "$lib" 2>/dev/null || true
    done
done

total=$(ls -1 "$FRAMEWORKS_DIR"/*.dylib | wc -l | xargs)
echo ""
echo "✅ Done! Total libraries: $total"
