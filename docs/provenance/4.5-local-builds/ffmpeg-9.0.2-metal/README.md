# FFmpeg 9.0.2 — full build

Static arm64 (Apple Silicon) binaries: `ffmpeg`, `ffprobe`

- Built: 2026-10-13 12:58 CEST on macOS 27.0.1
- Minimum macOS: 11.0 (Apple Silicon only)
- License: GPL version 3 or later (no nonfree components)

- Common source correction: yadif_videotoolbox Metal autorelease teardown fix (upstream PR 23850)
- YADIF patch SHA-256: ef03bb929ff86d5a8fc3052065e2e120d38ff6d64df6c592c331b0ee18dce595

## External libraries

- libx264 stable — H.264/AVC encoder
- libx265 4.2 — HEVC/H.265 encoder
- libvpx 1.17.0 — VP8/VP9
- libaom 3.15.2 — AV1 encoder/decoder
- libsvtav1 4.2.0 — SVT-AV1 encoder
- libvvenc 1.14.0 — VVC/H.266 encoder
- libjxl 0.12.0 — JPEG XL (with brotli 1.2.0, highway 1.4.0)
- libwebp 1.6.0 — WebP encoder
- libopus 1.6.1 — Opus audio
- libvorbis 1.3.7 — Vorbis audio (with libogg 1.3.6)
- libmp3lame 4.0 — MP3 encoder
- libtheora 1.2.0 — Theora video
- libopenjpeg 2.5.4 — JPEG 2000
- libvmaf 3.2.1 — VMAF quality metric
- whisper 1.9.5 — whisper.cpp speech recognition

## Configure flags

```

  configuration:
    --prefix=/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/compiled
    --metalcc='/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.jWL5ac/Metal.xctoolchain/usr/bin/metal -fmodules-cache-path=/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/build/clang-module-cache'
    --metallib=/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.jWL5ac/Metal.xctoolchain/usr/bin/metallib
    --enable-metal
    --arch=arm64
    --target-os=darwin
    --pkg-config-flags=--static
    --extra-cflags='-arch arm64 -I/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/compiled/include -O3 -fPIC -mcpu=apple-m1'
    --extra-cxxflags='-arch arm64 -I/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/compiled/include -O3 -fPIC -mcpu=apple-m1'
    --extra-ldflags='-arch arm64 -L/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/compiled/lib'
    --extra-libs='-lpthread -lm -lz'
    --enable-static
    --disable-shared
    --enable-gpl
    --enable-version3
    --disable-debug
    --disable-doc
    --enable-pthreads
    --enable-runtime-cpudetect
    --enable-neon
    --enable-pic
    --disable-libxcb
    --disable-libxcb-shm
    --disable-libxcb-xfixes
    --disable-libxcb-shape
    --disable-sdl2
    --disable-xlib
    --disable-libfontconfig
    --enable-libass
    --enable-libharfbuzz
    --enable-libfreetype
    --enable-libfribidi
    --enable-libx264
    --enable-libx265
    --enable-libvpx
    --enable-libaom
    --enable-libsvtav1
    --enable-libvvenc
    --enable-libjxl
    --enable-libwebp
    --enable-libopus
    --enable-libvorbis
    --enable-libmp3lame
    --enable-libtheora
    --enable-libopenjpeg
    --enable-libvmaf
    --enable-whisper
    --enable-videotoolbox
    --enable-audiotoolbox
    --enable-encoder=libx264
    --enable-encoder=libx265
    --enable-encoder=libvpx_vp8
    --enable-encoder=libvpx_vp9
    --enable-encoder=libaom_av1
    --enable-encoder=libsvtav1
    --enable-encoder=libvvenc
    --enable-encoder=libjxl
    --enable-encoder=libwebp
    --enable-encoder=libwebp_anim
    --enable-encoder=libopus
    --enable-encoder=libvorbis
    --enable-encoder=libmp3lame
    --enable-encoder=aac
    --enable-encoder=aac_at
    --enable-encoder=flac
    --enable-encoder=libtheora
    --enable-encoder=libopenjpeg
    --enable-encoder=h264_videotoolbox
    --enable-encoder=hevc_videotoolbox
    --enable-encoder=prores_videotoolbox
    --enable-decoder=libjxl
    --enable-decoder=aac
    --enable-decoder=aac_at
    --enable-decoder=flac
    --enable-decoder=vvc
    --enable-decoder=theora
    --enable-filter=scale
    --enable-filter=overlay
    --enable-filter=whisper
    --enable-filter=yadif_videotoolbox
    --enable-filter=ssim
    --enable-filter=psnr
    --enable-filter=xpsnr
    --enable-filter=msad

Exiting with exit code 0
```
