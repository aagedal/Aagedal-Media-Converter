#!/bin/bash

# Build self-contained libmpv for macOS app bundling
# Based on IINA's build instructions

set -e

echo "🔧 Building self-contained libmpv..."
echo ""

# Check if we're in the right directory
if [ ! -d "Aagedal Media Converter" ]; then
    echo "❌ Error: Run this script from the project root"
    exit 1
fi

# Install build dependencies
echo "📦 Installing build dependencies..."
brew install meson nasm pkg-config

# Clone mpv if needed
if [ ! -d "mpv-build" ]; then
    echo "📥 Cloning mpv-build..."
    git clone https://github.com/mpv-player/mpv-build.git
    cd mpv-build
    
    # Use IINA's recommended commit or latest stable
    echo "📥 Fetching mpv sources..."
    ./use-mpv-release
else
    echo "✓ mpv-build already exists"
    cd mpv-build
fi

# Configure for static linking
echo "⚙️  Configuring build for static dependencies..."

# Create build options file
cat > mpv_options <<EOF
--enable-libmpv-shared
--disable-cplayer
--enable-static-build
--disable-manpage-build
EOF

# Build mpv
echo "🔨 Building mpv (this will take several minutes)..."
./rebuild -j$(sysctl -n hw.ncpu)

# Copy the built library
echo "📋 Copying libmpv.dylib..."
BUILT_LIB="./mpv/build/libmpv.dylib"

if [ -f "$BUILT_LIB" ]; then
    cp "$BUILT_LIB" "../Aagedal Media Converter/Frameworks/libmpv.dylib"
    chmod +w "../Aagedal Media Converter/Frameworks/libmpv.dylib"
    
    # Fix install name
    install_name_tool -id "@rpath/libmpv.dylib" "../Aagedal Media Converter/Frameworks/libmpv.dylib"
    
    echo ""
    echo "✅ Success! libmpv.dylib built and installed"
    echo ""
    echo "📊 Library info:"
    file "../Aagedal Media Converter/Frameworks/libmpv.dylib"
    echo ""
    echo "📝 Dependencies:"
    otool -L "../Aagedal Media Converter/Frameworks/libmpv.dylib" | grep -v "libmpv.dylib"
    echo ""
    echo "✅ Done! Now in Xcode:"
    echo "   1. Remove ALL old .dylib files from Copy Files phase"
    echo "   2. Add ONLY the new libmpv.dylib"
    echo "   3. Clean Build and Run!"
else
    echo "❌ Error: Build failed, libmpv.dylib not found"
    exit 1
fi
