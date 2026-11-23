# FFmpeg 9.1 corresponding source (2026-11-22 build)

This archive holds the complete corresponding source of the FFmpeg 9.1 binary
bundled after Aagedal Media Converter 4.8.0 beta 2: the FFmpeg 9.1 tree with its
source patches applied (libopenjpeg `max_cs_size`/`max_comp_size` and IMF profiles,
canonical Whisper JSON with `initial_prompt` and word details, and the MOV `fiel`
atom for H.264), every library source it links, and the build recipe. It replaces
the FFmpeg 9.0.2 archive of the 2026-11-16 build, used through 4.8.0 beta 2. The
Metal YADIF autorelease teardown fix is part of FFmpeg 9.1 itself and is no longer a
separate patch.

To rebuild, extract the archive into a writable directory, install Xcode with its
Metal compiler, CMake, Meson, Ninja, pkg-config, Python 3 and the usual build
utilities, and run `bash rebuild.sh`. The replay recipe rebuilds the retained source
trees instead of skipping them and does not download libjxl's dependencies, which
are included. The exact scripts that produced the binary, its configuration and
version output are in `build-evidence/`. Source changes can be made before
rebuilding to relink modified library code.

Apple SDKs, Apple system libraries and the Metal toolchain are build prerequisites
and are not redistributed. The separate Photo Agent FFmpeg tree is not the variant
bundled by this app and is left out. This source preservation does not claim a
byte-for-byte reproduction of the supplied binary.
