// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured once so JPEG 2000 encoding and DCP packaging use the same preferences.
struct DCPSettings: Sendable {
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

    var ffmpegArguments: [String] {
        let scaleFilter: String
        switch scalingMode {
        case .fill:
            scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=increase,crop=\(resolution.width):\(resolution.height)"
        case .fit:
            scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=decrease,pad=\(resolution.width):\(resolution.height):-1:-1:color=black"
        }

        var args = ["-hide_banner"] + [
            "-c:v", "libopenjpeg",
            "-profile", resolution.openjpegProfile,
        ]
        if let cinemaMode = frameRate.cinemaModeFor(resolution: resolution) {
            args += ["-cinema_mode", cinemaMode]
        }
        args += [
            "-pix_fmt", "xyz12le",
            "-b:v", bitrate.ffmpegValue,
            "-r", frameRate.ffmpegValue,
            "-vf", scaleFilter,
            "-map", "0:v:0",
            "-an",
        ]
        // DCP outputs JP2 image sequence (not MXF) — asdcp-wrap creates the final MXF
        // The output path pattern (frame_%06d.jp2) is set by FFMPEGConverter
        return args
    }
}
