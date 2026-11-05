# FFmpeg 9.0.2 corresponding source (SVT-AV1 4.3.0 build)

This archive holds the complete corresponding source of the FFmpeg binary bundled
since Aagedal Media Converter 4.7.0: the FFmpeg 9.0.2 tree with its source patches
applied (Metal YADIF autorelease teardown, libopenjpeg `max_cs_size`/`max_comp_size`
and IMF profiles, canonical Whisper JSON), every library source it links, and the
build recipe. It replaces the three FFmpeg 9.0.2 archives of the 4.5 builds.

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
