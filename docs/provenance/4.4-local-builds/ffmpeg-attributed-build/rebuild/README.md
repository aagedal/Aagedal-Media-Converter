FFmpeg 9.0.1 corresponding source

Install Xcode command-line tools and Metal compiler, CMake, Meson, Ninja, pkg-config, and standard build utilities. Extract the source companion into a writable directory, then run bash rebuild.sh. All source directories used by this build are included. Test media, downloaded duplicates and build outputs are omitted. Build scripts rebuild existing sources rather than skipping them. You may edit library sources before rebuilding; generated outputs go to compiled/ and dist/. Preserve modified sources and notices when redistributing changes.

The original exact invoked scripts, version/source evidence, and configuration are in build-evidence/. The replay recipe differs only to rebuild existing source directories and avoid downloading libjxl dependencies already included. Xcode/Apple SDKs and system libraries are not redistributed. Local Git metadata is retained only for the two public source clones so their version generators retain the revision.
