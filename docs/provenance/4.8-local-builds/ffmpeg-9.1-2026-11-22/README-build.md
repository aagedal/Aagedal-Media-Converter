# FFmpeg 9.1 — full build

Static arm64 (Apple Silicon) binaries: `ffmpeg`, `ffprobe`

- Built: 2026-11-22 21:26 CET on macOS 27.2.1
- Minimum macOS: 11.0 (Apple Silicon only)
- License: GPL version 3 or later (no nonfree components)

- Common source addition: libopenjpeg encoder options `max_cs_size`/`max_comp_size` (default 0 = unchanged) for DCI frame-size caps
- OpenJPEG encoder patch SHA-256: 366a2a6219ad17fd8b5d2f17b6047522c365e3b57b72f26590c5f27bb7290904
- Common source addition: libopenjpeg IMF profiles (`-profile imf_2k|imf_4k|imf_8k|imf_2k_r|imf_4k_r|imf_8k_r`, `imf_mainlevel`/`imf_sublevel`, default -1 = derived) with `max_cs_size` rate control
- OpenJPEG IMF patch SHA-256: 1924b8cba46702966b49e100fe0a84f0a4ae5eced95a2c4b96e2bff5df8e8439
- Common source correction: MOV muxer writes the `fiel` atom for H.264 (interlaced field order, e.g. AVC-Intra); MP4 unchanged
- movenc fiel patch SHA-256: be20df6bc35a2fb3e8e1c4f84498c01f7913c7fb0e69ed43303b25a14ea7ea1a

- Whisper output: canonical JSON, sample-bounded timestamps, propagated failures
- Whisper patch SHA-256: 1954662b1ff2651bda8165b0c4f098d18f84b0c0208cd4c81c0d58a3511ab861
- Whisper additions: `initial_prompt` option (default empty, carried into every queue chunk); JSON lines gain `p` (mean text-token probability) and `language`
- Whisper word-details patch SHA-256: 03720a8f08dbd31ffdbf61bbeee80ba129531a84d90a0dd5ec2998d34dc972e9
- Patched af_whisper.c SHA-256: 426d77efd5678d610d095b9f7552a097a39c7798367b4bbfdb0dcb2fe6d15ee4

## External libraries

- libx264 stable — H.264/AVC encoder
- libx265 4.2 — HEVC/H.265 encoder
- libvpx 1.17.0 — VP8/VP9
- libaom 3.15.3 — AV1 encoder/decoder
- libsvtav1 4.3.0 — SVT-AV1 encoder
- libvvenc 1.14.0 — VVC/H.266 encoder
- libjxl 0.13.0 — JPEG XL (with brotli 1.2.1, highway 1.4.0)
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
    --prefix=/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-5e1bafce-a0f5b3d7766f7925/compiled
    --metalcc='xcrun -sdk macosx metal -fmodules-cache-path=/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-5e1bafce-a0f5b3d7766f7925/build/clang-module-cache'
    --metallib='xcrun -sdk macosx metallib'
    --enable-metal
    --arch=arm64
    --target-os=darwin
    --pkg-config-flags=--static
    --extra-cflags='-arch arm64 -I/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-5e1bafce-a0f5b3d7766f7925/compiled/include -O3 -fPIC -mcpu=apple-m1'
    --extra-cxxflags='-arch arm64 -I/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-5e1bafce-a0f5b3d7766f7925/compiled/include -O3 -fPIC -mcpu=apple-m1'
    --extra-ldflags='-arch arm64 -L/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-5e1bafce-a0f5b3d7766f7925/compiled/lib'
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
