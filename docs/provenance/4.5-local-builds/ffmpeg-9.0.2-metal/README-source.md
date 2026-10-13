# Corrected full FFmpeg 9.0.2 corresponding sources

This archive supplements the existing `ffmpeg-9.0.2-source.tar.gz` and
`ffmpeg-9.0.2-generated-inputs.tar.gz` archives, which retain the codec-library
sources reused by this build. All three remain required in the app's source
companion. It contains the corrected full FFmpeg source tree, including the Metal
YADIF autorelease patch, actual full-tree configuration, exact modified recipes,
and build qualification/smoke evidence. The separate Photo Agent source tree is
not the FFmpeg variant bundled by this app.

To rebuild, extract the dependency source archive into a writable directory,
then extract this correction archive into the same directory, overlaying its
FFmpeg tree, config.sh, and scripts. Install Xcode and its Metal compiler, CMake,
Meson, Ninja, pkg-config, Python 3, and the usual build utilities. Remove any local
.build-progress file before running `bash rebuild.sh` from the dependency recipe.
It rebuilds the retained libraries, then invokes the corrected full FFmpeg recipe.
The recipe locates the Metal compiler/metallib tools, checks the expected YADIF
source hashes, and keeps the full variant's Whisper filter unmodified. Source
changes can be made before rebuilding to relink modified library code.

The supplied binary reuses compiled libraries from the earlier 9.0.2 build;
qualification.json records that dependency workspace. Apple SDKs, Apple system
libraries, and the Metal toolchain are build prerequisites and are not
redistributed. This source preservation does not claim an independent rebuild
or byte-for-byte reproduction of the supplied binary.
