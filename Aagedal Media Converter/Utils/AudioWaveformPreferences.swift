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
import SwiftUI
import AppKit

enum WaveformStyle: String, CaseIterable, Identifiable {
    case linear
    case circle
    case compressed
    case fisheye
    case spectrogram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear:
            return "Linear"
        case .circle:
            return "Circular (slow)"
        case .compressed:
            return "Compressed"
        case .fisheye:
            return "Fisheye"
        case .spectrogram:
            return "Spectrogram"
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
        let frameRate: Double

        var resolutionString: String {
            "\(width)x\(height)"
        }

        var backgroundFFmpegColor: String {
            "0x" + backgroundHex
        }

        var foregroundFFmpegColor: String {
            "0x" + foregroundHex
        }

        var backgroundColor: Color {
            Color(hex: backgroundHex)
        }

        var foregroundColor: Color {
            Color(hex: foregroundHex)
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
        let frameRate = sanitizeFrameRate(defaults.double(forKey: AppConstants.audioWaveformFrameRateKey))

        return WaveformVideoConfig(
            resolution: CGSize(width: width, height: height),
            width: width,
            height: height,
            backgroundHex: background,
            foregroundHex: foreground,
            normalizeAudio: normalize,
            style: style,
            frameRate: frameRate
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

    static func sanitizeFrameRate(_ value: Double) -> Double {
        let valid = value.isFinite && value >= 10 && value <= 120
        if valid { return value }
        if value == 0 { return AppConstants.defaultAudioWaveformFrameRate }
        return min(max(value, 10), 120)
    }
}

extension Color {
    init(hex: String) {
        let sanitized = AudioWaveformPreferences.sanitizeHex(hex, fallback: "000000")
        var hexNumber: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&hexNumber)

        let red = Double((hexNumber & 0xFF0000) >> 16) / 255.0
        let green = Double((hexNumber & 0x00FF00) >> 8) / 255.0
        let blue = Double(hexNumber & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    func toHexString(includeHash: Bool = false) -> String {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            return includeHash ? "#000000" : "000000"
        }
        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        let hexString = String(format: "%02X%02X%02X", red, green, blue)
        return includeHash ? "#" + hexString : hexString
    }
}
