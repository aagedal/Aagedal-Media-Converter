// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured once so IMF encoding, essence wrapping, manifests, and cleanup agree.
struct IMFSettings: Codable, Equatable, Sendable {
    let resolution: IMFResolution
    let frameRate: IMFFrameRate
    let bitrate: DCPBitrate
    let scalingMode: IMFScalingMode
    let color: IMFColorEncoding
    let proResProfile: IMFProResProfile
    let keepIntermediates: Bool

    init(defaults: UserDefaults = .standard) {
        resolution = IMFResolution(rawValue: defaults.string(forKey: AppConstants.imfResolutionKey)
            ?? AppConstants.defaultIMFResolution) ?? .hd1080
        frameRate = IMFFrameRate(rawValue: defaults.string(forKey: AppConstants.imfFrameRateKey)
            ?? AppConstants.defaultIMFFrameRate) ?? .fps24
        bitrate = DCPBitrate(rawValue: defaults.string(forKey: AppConstants.imfJ2KBitrateKey)
            ?? AppConstants.defaultIMFJ2KBitrate) ?? .high
        scalingMode = IMFScalingMode(rawValue: defaults.string(forKey: AppConstants.imfScalingModeKey)
            ?? AppConstants.defaultIMFScalingMode) ?? .fit
        color = IMFColorEncoding(rawValue: defaults.string(forKey: AppConstants.imfJ2KColorEncodingKey)
            ?? AppConstants.defaultIMFJ2KColorEncoding) ?? .rec709
        proResProfile = IMFProResProfile(rawValue: defaults.string(forKey: AppConstants.imfProResProfileKey)
            ?? AppConstants.defaultIMFProResProfile) ?? .proRes422HQ
        keepIntermediates = defaults.bool(forKey: AppConstants.imfKeepIntermediatesKey)
    }

    /// Per-frame codestream cap for the chosen bitrate: floor(bits/s × den / (8 × num)).
    var maxJ2KFrameBytes: Int {
        bitrate.megabitsPerSecond * 1_000_000 * frameRate.editRateDenominator / (8 * frameRate.editRateNumerator)
    }

    func ffmpegArguments(application: IMFApplication) -> [String] {
        let scaleFilter: String
        switch scalingMode {
        case .fill:
            scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=increase,crop=\(resolution.width):\(resolution.height)"
        case .fit:
            scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=decrease,pad=\(resolution.width):\(resolution.height):-1:-1:color=black"
        }

        switch application {
        case .app2e:
            // ST 2067-21 requires an IMF-profile codestream (lossy 9/7). The bundled ffmpeg's
            // libopenjpegenc-imf.patch adds the IMF profiles; main/sub levels are derived from
            // resolution, chroma format, frame rate and the per-frame cap. libopenjpeg ignores -b:v.
            return ["-hide_banner"] + [
                "-c:v", "libopenjpeg",
                "-pix_fmt", "yuv422p10le",
                "-color_primaries", color.colorPrimaries,
                "-color_trc", color.colorTRC,
                "-colorspace", color.colorSpace,
                "-profile:v", resolution == .uhd2160 ? "imf_4k" : "imf_2k",
                "-max_cs_size", String(maxJ2KFrameBytes),
                "-r", frameRate.ffmpegValue,
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-an",
            ]
        case .rdd45:
            return ["-hide_banner"] + [
                "-c:v", "prores_ks",
                "-profile:v", proResProfile.ffmpegProfile,
                "-pix_fmt", proResProfile.pixelFormat,
                "-color_primaries", color.colorPrimaries,
                "-color_trc", color.colorTRC,
                "-colorspace", color.colorSpace,
                "-r", frameRate.ffmpegValue,
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-an",
            ]
        }
    }
}
