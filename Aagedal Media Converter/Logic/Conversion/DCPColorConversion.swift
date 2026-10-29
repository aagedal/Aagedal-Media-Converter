// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Rec. 709 → DCI X′Y′Z′ conversion for DCP picture essence, modelled on DCP-o-matic's
/// default colour conversion.
///
/// FFmpeg's implicit `xyz12le` conversion uses a 2.2 source gamma and skips the DCI
/// 48/52.37 luminance normalisation, so D65 white lands at Z = 1.089 and clips (white
/// highlights shift towards yellow, and peak white is ~8% too bright). Instead we bake
/// the full transform into a 3D LUT and hand libopenjpeg the result as `gbrp12le`, which
/// yields a codestream identical in layout to `xyz12le` input (R/G/B planes = X/Y/Z).
enum DCPColorConversion {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "DCPColorConversion")

    /// BT.1886 display gamma: video masters are graded on 2.4-gamma reference monitors.
    static let sourceGamma = 2.4
    /// DCI companding gamma (SMPTE ST 428-1).
    static let dciGamma = 2.6
    /// Reference white (48 cd/m²) relative to the code-value-4095 luminance (52.37 cd/m²).
    static let dciNormalization = 48.0 / 52.37
    static let lutSize = 65

    /// Rec. 709 / sRGB primaries, D65 white, to CIE XYZ. White is deliberately not adapted to
    /// the DCI white point: the projector is calibrated so that D65 XYZ reproduces D65.
    static let rec709ToXYZ: [[Double]] = [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]

    /// Converts gamma-encoded Rec. 709 RGB (0...1) to DCI X′Y′Z′ code values (0...1).
    static func xyzPrime(red: Double, green: Double, blue: Double) -> (x: Double, y: Double, z: Double) {
        let linear = [red, green, blue].map { pow(min(max($0, 0), 1), sourceGamma) }
        let encoded = rec709ToXYZ.map { row -> Double in
            let value = zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 } * dciNormalization
            return pow(min(max(value, 0), 1), 1 / dciGamma)
        }
        return (encoded[0], encoded[1], encoded[2])
    }

    /// Filter chain that converts full-range RGB to X′Y′Z′ carried in `gbrp12le`.
    static var filterChain: String {
        "format=gbrp16le,lut3d=file=\(escapeFilterOptionValue(lutURL().path)):interp=tetrahedral,format=gbrp12le"
    }

    /// Returns the cached LUT, writing it on first use. Versioned by name so a future
    /// change to the maths never reuses a stale file.
    static func lutURL(directory: URL = FileManager.default.temporaryDirectory) -> URL {
        let url = directory
            .appendingPathComponent("AagedalDCP", isDirectory: true)
            .appendingPathComponent("rec709-bt1886-to-dci-xyz-v1.cube")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic write so concurrent exports never read a half-written LUT.
            try cubeData().write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write DCP colour LUT: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    /// Adobe .cube text; red varies fastest, as FFmpeg's lut3d expects.
    static func cubeData(size: Int = lutSize) -> Data {
        var text = "TITLE \"Rec.709 (BT.1886) to DCI XYZ\"\nLUT_3D_SIZE \(size)\n"
        text.reserveCapacity(size * size * size * 28)
        let scale = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let xyz = xyzPrime(red: Double(r) / scale, green: Double(g) / scale, blue: Double(b) / scale)
                    text += String(format: "%.6f %.6f %.6f\n", xyz.x, xyz.y, xyz.z)
                }
            }
        }
        return Data(text.utf8)
    }

    /// FFmpeg parses filter option values twice (option list, then filtergraph).
    private static func escapeFilterOptionValue(_ value: String) -> String {
        func escape(_ input: String, specials: Set<Character>) -> String {
            var result = ""
            for character in input {
                if character == "\\" || character == "'" || specials.contains(character) {
                    result.append("\\")
                }
                result.append(character)
            }
            return result
        }
        return escape(escape(value, specials: [":"]), specials: ["[", "]", ",", ";"])
    }
}
