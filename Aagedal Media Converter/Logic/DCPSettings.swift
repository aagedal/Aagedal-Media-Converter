// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured once so JPEG 2000 encoding and DCP packaging use the same preferences.
struct DCPSettings: Codable, Equatable, Sendable {
    let resolution: DCPResolution
    let frameRate: DCPFrameRate
    let bitrate: DCPBitrate
    let scalingMode: DCPScalingMode
    let keepJP2Images: Bool

    init(defaults: UserDefaults = .standard) {
        resolution = DCPResolution(rawValue: defaults.string(forKey: AppConstants.dcpResolutionKey)
            ?? AppConstants.defaultDCPResolution) ?? .twoKFull
        frameRate = DCPFrameRate(rawValue: defaults.string(forKey: AppConstants.dcpFrameRateKey)
            ?? AppConstants.defaultDCPFrameRate) ?? .fps24
        bitrate = DCPBitrate(rawValue: defaults.string(forKey: AppConstants.dcpBitrateKey)
            ?? AppConstants.defaultDCPBitrate) ?? .high
        scalingMode = DCPScalingMode(rawValue: defaults.string(forKey: AppConstants.dcpScalingModeKey)
            ?? AppConstants.defaultDCPScalingMode) ?? .fill
        keepJP2Images = defaults.bool(forKey: AppConstants.dcpKeepJP2ImagesKey)
    }

    var ratePlan: DCPJ2KRatePlan {
        DCPJ2KRatePlan(resolution: resolution, frameRate: frameRate, bitrate: bitrate)
    }

    /// Blocks combinations that cannot produce a DCI-compliant picture.
    var configurationError: String? {
        guard frameRate.isSupported(by: resolution) else {
            return String(localized: "4K DCPs are limited to 24, 25 or 30 fps. Choose a 2K resolution for 48 fps.", comment: "Shown when the DCP export settings combine 4K with a high frame rate.")
        }
        return nil
    }

    /// Fits the source into the DCP container (in full-range RGB, so the LUT sees the whole range).
    var scaleFilter: String {
        switch scalingMode {
        case .fill:
            return "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=increase,crop=\(resolution.width):\(resolution.height)"
        case .fit:
            return "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=decrease,pad=\(resolution.width):\(resolution.height):-1:-1:color=black"
        }
    }

    var ffmpegArguments: [String] {
        let plan = ratePlan
        // DCP outputs a JP2 image sequence (not MXF) — asdcp-wrap creates the final MXF.
        // The output path pattern (frame_%06d.jp2) is set by FFMPEGConverter.
        // gbrp12le carries X′Y′Z′ from DCPColorConversion; see that type for why we do not
        // let FFmpeg convert to xyz12le itself.
        return ["-hide_banner",
            "-c:v", "libopenjpeg",
            "-profile", resolution.openjpegProfile,
            "-cinema_mode", plan.cinemaMode,
            "-numresolution", String(resolution.openjpegNumResolution),
            "-pix_fmt", "gbrp12le",
            "-r", frameRate.ffmpegValue,
            "-vf", "\(scaleFilter),\(DCPColorConversion.filterChain)",
            "-map", "0:v:0",
            "-an",
        ]
    }
}
