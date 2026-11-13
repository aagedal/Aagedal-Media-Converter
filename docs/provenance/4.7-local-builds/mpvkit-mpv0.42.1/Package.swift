// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "MPVKit",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .visionOS(.v1)],
    products: [
        .library(
            name: "MPVKit",
            targets: ["_MPVKit"]
        ),
        .library(
            name: "MPVKit-GPL",
            targets: ["_MPVKit-GPL"]
        ),
    ],
    targets: [
        .target(
            name: "_MPVKit",
            dependencies: [
                "Libmpv", "_FFmpeg", "Libuchardet", "Libbluray",
                // Libluajit removed to avoid code signing issues in notarized apps
            ],
            path: "Sources/_MPVKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg",
            dependencies: [
                "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"
            ],
            path: "Sources/_FFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "_MPVKit-GPL",
            dependencies: [
                "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray",
                // Libluajit removed to avoid code signing issues in notarized apps
            ],
            path: "Sources/_MPVKit-GPL",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg-GPL",
            dependencies: [
                "Libavcodec-GPL", "Libavdevice-GPL", "Libavfilter-GPL", "Libavformat-GPL", "Libavutil-GPL", "Libswresample-GPL", "Libswscale-GPL",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "Libsmbclient", "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d", "Libx264-GPL"
            ],
            path: "Sources/_FFmpeg-GPL",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),

        // GPL builds (MPV 0.41, FFmpeg n9.0.2) shared with the Aagedal Film Constructor helpers: every
        // decoder/demuxer, x264, ProRes (Kostya), editor filters/muxers; no LuaJIT
        .binaryTarget(
            name: "Libmpv-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libmpv-GPL.xcframework.zip",
            checksum: "3c419acb0f864122a06d03fcd80fe3213742045fb3c3f17ce3cc6e8fa7539d08"
        ),
        .binaryTarget(
            name: "Libavcodec-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libavcodec-GPL.xcframework.zip",
            checksum: "d3a3037ae8d9ab624340a932a5f28f213bd2d3c3a4919ea2d1afd6a4f6e3e4f7"
        ),
        .binaryTarget(
            name: "Libavdevice-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libavdevice-GPL.xcframework.zip",
            checksum: "00e6450f7ff8e70e8c725840285263ccaf606b95b8a2210c984e6ebb853747e8"
        ),
        .binaryTarget(
            name: "Libavformat-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libavformat-GPL.xcframework.zip",
            checksum: "e4d5a14d4f4210a3f1ee520141b93a4ddc09a6c7bbd0b2b815e4d2a28f318ecd"
        ),
        .binaryTarget(
            name: "Libavfilter-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libavfilter-GPL.xcframework.zip",
            checksum: "a14f8ad346bab78eb5f890de8b4696395fb317a02a850136aa5a6823a5347c56"
        ),
        .binaryTarget(
            name: "Libavutil-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libavutil-GPL.xcframework.zip",
            checksum: "87b497f404659fb1d6780cf50272f139618e23418347bbaf7241f4ddb5bdf7b1"
        ),
        .binaryTarget(
            name: "Libswresample-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libswresample-GPL.xcframework.zip",
            checksum: "7ec5419b5c7f09e734656e372534b7fabdd50cfa1087c8c11def2d07fc68688b"
        ),
        .binaryTarget(
            name: "Libswscale-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libswscale-GPL.xcframework.zip",
            checksum: "51337382b142e58bf4ef104e13adc5cc73f3e77963c8f3f16dadbb8fae2509a5"
        ),
        .binaryTarget(
            name: "Libx264-GPL",
            url: "https://github.com/aagedal/MPVKit/releases/download/aagedal-1.1.0-n9.0.2-mpv0.42.1/Libx264-GPL.xcframework.zip",
            checksum: "a031320df0afc6f3d3a59911996930b2ac3aa3532d03e775c1fbb97f93ddf3d9"
        ),
        //AUTO_GENERATE_TARGETS_BEGIN//

        .binaryTarget(
            name: "Libcrypto",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip",
            checksum: "593283be2a90f7fd66f6e6ed331b2f099cf403e0926fe3b4ac09a7062b793965"
        ),
        .binaryTarget(
            name: "Libssl",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip",
            checksum: "ff5ffd43d015d7285fd37e4a3145b25cbd8d2842740bd629a711c299a20e226a"
        ),

        .binaryTarget(
            name: "gmp",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip",
            checksum: "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"
        ),

        .binaryTarget(
            name: "nettle",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip",
            checksum: "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"
        ),
        .binaryTarget(
            name: "hogweed",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip",
            checksum: "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"
        ),

        .binaryTarget(
            name: "gnutls",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip",
            checksum: "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"
        ),

        .binaryTarget(
            name: "Libunibreak",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip",
            checksum: "940d9833cf4477d0a260d9f2b4066125bc0ff7bbc111ac3c90e774765b77a559"
        ),

        .binaryTarget(
            name: "Libfreetype",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip",
            checksum: "496ca62488530e14b1e4624d20ee2b237c0bd675cd70c19da578a5768302d02d"
        ),

        .binaryTarget(
            name: "Libfribidi",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip",
            checksum: "bc15e097b892f2f90424e4a27ba287070cc2f98a74a4da10e6d2481d15cf5ff9"
        ),

        .binaryTarget(
            name: "Libharfbuzz",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip",
            checksum: "aa8e0b9ca0387dac74e3e93c86e34d11982bb013b28022d0e6966a8427a35b2e"
        ),

        .binaryTarget(
            name: "Libass",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libass.xcframework.zip",
            checksum: "3f4c576d2818ceb4544aa2a20e1f55846511c5e706fd19adc3ea9fd842270498"
        ),

        .binaryTarget(
            name: "Libsmbclient",
            url: "https://github.com/mpvkit/libsmbclient-build/releases/download/4.15.13-2512/Libsmbclient.xcframework.zip",
            checksum: "3a53375fab11bc888cc553664ea5dd902208d04f0cc21ec746302bf356246b6f"
        ),

        .binaryTarget(
            name: "Libbluray",
            url: "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip",
            checksum: "bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d"
        ),

        .binaryTarget(
            name: "Libuavs3d",
            url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip",
            checksum: "bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789"
        ),

        .binaryTarget(
            name: "Libdovi",
            url: "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip",
            checksum: "e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d"
        ),

        .binaryTarget(
            name: "MoltenVK",
            url: "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.2/MoltenVK.xcframework.zip",
            checksum: "aee189c54ad7c62bf734a3dc51eb4cfad5685d1d63b0ec519ecd1b437c332418"
        ),

        .binaryTarget(
            name: "Libshaderc_combined",
            url: "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip",
            checksum: "758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b"
        ),

        .binaryTarget(
            name: "lcms2",
            url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
            checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
        ),

        .binaryTarget(
            name: "Libplacebo",
            url: "https://github.com/aagedal/libplacebo-build/releases/download/7.387.0/Libplacebo.xcframework.zip",
            checksum: "d643739f1097107265b14f1964b9c8058e73bc360ced0660bdadce5f0e4d6433"
        ),

        .binaryTarget(
            name: "Libdav1d",
            url: "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip",
            checksum: "d1a32ae6a1f0193e9f05c44c9176844af7f6d2a58cb33843f6f1b8dfd9224083"
        ),

        .binaryTarget(
            name: "Libavcodec",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavcodec.xcframework.zip",
            checksum: "d516e904490c711c2875dd238d7d8d9f4f46e335829cb8ee7e0e1623e952e372"
        ),
        .binaryTarget(
            name: "Libavdevice",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavdevice.xcframework.zip",
            checksum: "f29bde9d8f788337996f8b2759645a6e22e9056e4bc1e3494458193405f50a5d"
        ),
        .binaryTarget(
            name: "Libavformat",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavformat.xcframework.zip",
            checksum: "0a840424d7a2d971687d6e96d995e21420cce1b27dae74687ff4f5f31dc36e73"
        ),
        .binaryTarget(
            name: "Libavfilter",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavfilter.xcframework.zip",
            checksum: "e764dc3b3d36abb26d6d0ae2f0c6a1de0b80a453f3ca4bf2bb6596c0f6464b19"
        ),
        .binaryTarget(
            name: "Libavutil",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavutil.xcframework.zip",
            checksum: "0ca518d2a3eab22763310d8bcdc977494ddb3daf3dc3b73a2ed84c5eefc13f75"
        ),
        .binaryTarget(
            name: "Libswresample",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libswresample.xcframework.zip",
            checksum: "49edabb3c2e7fb97e6458f2e6a2fea66ab567b55258141e598fecfcd29cd9eeb"
        ),
        .binaryTarget(
            name: "Libswscale",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libswscale.xcframework.zip",
            checksum: "5aebc8107219d518d8e89f0af97365ff9758f91b3096a7d5c1a16e092745de39"
        ),

        .binaryTarget(
            name: "Libuchardet",
            url: "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8/Libuchardet.xcframework.zip",
            checksum: "ea4f548a230a755e059144657cc9e2ff563c1cdeae03974c38f8b6e1a40303fb"
        ),

        .binaryTarget(
            name: "Libluajit",
            url: "https://github.com/mpvkit/libluajit-build/releases/download/2.1.0-fix/Libluajit.xcframework.zip",
            checksum: "3a171ef1627fb88260893dc452f989bd93dd8510814771ba3aff7753470d3f3e"
        ),

        .binaryTarget(
            name: "Libmpv",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libmpv.xcframework.zip",
            checksum: "1d8651bebfe467bd5408751647de692cdacb1d19ba825e11785d770bc88c3225"
        ),
        //AUTO_GENERATE_TARGETS_END//
    ]
)
