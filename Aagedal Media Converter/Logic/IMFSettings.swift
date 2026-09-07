// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured once so IMF encoding, essence wrapping, manifests, and cleanup agree.
struct IMFSettings: Sendable {
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
            // J2K image sequence: NOT cinema profile (that's DCP); IMF App #2e uses broadcast J2K profiles
            // No -profile or -cinema_mode; libopenjpeg picks a profile suitable for the YCbCr essence.
            // Note: deep HDR variants may need additional ffmpeg flags; rely on the JP2 → MXF wrap to flag any non-conformance.
            return ["-hide_banner"] + [
                "-c:v", "libopenjpeg",
                "-pix_fmt", "yuv422p10le",
                "-color_primaries", color.colorPrimaries,
                "-color_trc", color.colorTRC,
                "-colorspace", color.colorSpace,
                "-b:v", bitrate.ffmpegValue,
                "-r", frameRate.ffmpegValue,
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-an",
            ]
        case .app5:
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
