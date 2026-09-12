// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftMediaMetadata",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "SwiftMediaMetadata",
            targets: ["SwiftMediaMetadata"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure modulemap for zlib — no `pkgConfig` because that drags in
        // Homebrew's macOS libz.a during Linux-musl cross-compile. The
        // musl SDK's libz.a is passed via `-Xlinker` in Scripts/build-release.sh.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),
        .target(
            name: "SwiftMediaMetadata",
            dependencies: ["CZlib"],
            path: "Sources/SwiftMediaMetadata",
            resources: [.copy("Resources/GeoLocationDatabase.bin")],
            linkerSettings: [
                // `-lz` is enough on macOS (default sysroot search finds libz).
                // For Linux-musl we pass the absolute libz.a path in the build
                // script — see Scripts/build-release.sh.
                .linkedLibrary("z", .when(platforms: [.macOS, .iOS]))
            ]
        ),
        .executableTarget(
            name: "swift-exif",
            dependencies: [
                "SwiftMediaMetadata",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: ["SwiftMediaMetadata"],
            path: "Sources/Benchmark"
        ),
        .testTarget(
            name: "SwiftMediaMetadataTests",
            dependencies: ["SwiftMediaMetadata"],
            path: "Tests/SwiftMediaMetadataTests",
            resources: [.copy("Fixtures/Resources")]
        ),
        // Black-box CLI tests — spawn the built `swift-exif` binary as a subprocess.
        // Gated behind SWIFT_EXIF_RUN_CLI_TESTS=1 so `swift test` skips them by
        // default. Run with `Scripts/run-cli-tests.sh` or:
        //   SWIFT_EXIF_RUN_CLI_TESTS=1 swift test --filter SwiftMediaMetadataCLITests
        .testTarget(
            name: "SwiftMediaMetadataCLITests",
            dependencies: ["SwiftMediaMetadata", "swift-exif"],
            path: "Tests/SwiftMediaMetadataCLITests"
        ),
    ]
)
