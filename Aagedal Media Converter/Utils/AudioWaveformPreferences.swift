// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import CoreGraphics

enum WaveformStyle: String, CaseIterable, Identifiable {
    case linear
    case circle
    case compressed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear:
            return "Linear"
        case .circle:
            return "Circular"
        case .compressed:
            return "Compressed"
        }
    }
}

struct AudioWaveformPreferences {
    struct WaveformVideoConfig {
        let resolution: CGSize
        let width: Int
        let height: Int
        let backgroundHex: String
        let foregroundHex: String
        let normalizeAudio: Bool
        let style: WaveformStyle

        var resolutionString: String {
            "\(width)x\(height)"
        }

        var backgroundFFmpegColor: String {
            "0x" + backgroundHex
        }

        var foregroundFFmpegColor: String {
            "0x" + foregroundHex
        }
    }

    static func loadConfig() -> WaveformVideoConfig {
        let defaults = UserDefaults.standard
        let resolutionValue = defaults.string(forKey: AppConstants.audioWaveformResolutionKey) ?? "1280x720"
        let (width, height) = parseResolution(resolutionValue) ?? (1280, 720)

        let background = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformBackgroundColorKey), fallback: "000000")
        let foreground = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformForegroundColorKey), fallback: "FFFFFF")
        let normalize = defaults.bool(forKey: AppConstants.audioWaveformNormalizeKey)
        let styleRaw = defaults.string(forKey: AppConstants.audioWaveformStyleKey) ?? AppConstants.defaultAudioWaveformStyleRaw
        let style = WaveformStyle(rawValue: styleRaw) ?? .linear

        return WaveformVideoConfig(
            resolution: CGSize(width: width, height: height),
            width: width,
            height: height,
            backgroundHex: background,
            foregroundHex: foreground,
            normalizeAudio: normalize,
            style: style
        )
    }

    static func parseResolution(_ value: String) -> (Int, Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "x")
        guard components.count == 2,
              let width = Int(components[0]), width > 0,
              let height = Int(components[1]), height > 0 else {
            return nil
        }
        return (width, height)
    }

    static func sanitizeHex(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        var sanitized = trimmed
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }
        sanitized = sanitized.uppercased()
        let validChars = CharacterSet(charactersIn: "0123456789ABCDEF")
        sanitized = String(sanitized.unicodeScalars.filter { validChars.contains($0) })
        if sanitized.count != 6 {
            return fallback.uppercased()
        }
        return sanitized
    }
}
