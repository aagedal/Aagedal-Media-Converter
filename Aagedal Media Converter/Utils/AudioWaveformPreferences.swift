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

/// Selects which rendering engine produces waveform video frames.
enum WaveformRenderingEngine: String, CaseIterable, Identifiable {
    /// Native Swift renderer via CoreGraphics.
    case swift = "swift"
    /// Legacy FFmpeg filter renderer (showwaves / showspectrum).
    case ffmpeg = "ffmpeg"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .ffmpeg: return "FFmpeg (Classic)"
        }
    }
}

/// Visual styles available in the native Swift waveform renderer.
enum SwiftWaveformStyle: String, CaseIterable, Identifiable {
    /// Vertically expanding pill-shaped capsules per frequency band.
    case capsules
    /// Classic mirrored equalizer bars, rectangular, reflected across center.
    case bars
    /// Smooth curved line connecting band peaks with filled area.
    case wire

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .capsules: return "Capsules"
        case .bars: return "Bars"
        case .wire: return "Wire"
        }
    }
}

/// Frequency-to-band mapping strategy for the native Swift renderer.
enum FrequencyDistribution: String, CaseIterable, Identifiable {
    /// Logarithmic (base-2) spacing — perceptual, good for music.
    case logarithmic
    /// Mel scale — psychoacoustic model, smoother bass-to-treble transition.
    case mel
    /// Linear — equal Hz per band, technical/metering look.
    case linear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .logarithmic: return "Logarithmic"
        case .mel: return "Mel Scale"
        case .linear: return "Linear"
        }
    }
}

enum WaveformStyle: String, CaseIterable, Identifiable {
    case linear
    case circle
    case lines = "compressed"
    case fisheye
    case spectrogram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear:
            return "Linear"
        case .circle:
            return "Circular (slow)"
        case .lines:
            return "Lines"
        case .fisheye:
            return "Fisheye"
        case .spectrogram:
            return "Spectrogram"
        }
    }
}

struct AudioWaveformPreferences {
    struct WaveformVideoConfig: Sendable {
        let resolution: CGSize
        let width: Int
        let height: Int
        let backgroundHex: String
        let foregroundHex: String
        let normalizeAudio: Bool
        let style: WaveformStyle
        let frameRate: Double
        let renderingEngine: WaveformRenderingEngine
        let swiftStyle: SwiftWaveformStyle
        let bandCount: Int
        let frequencyDistribution: FrequencyDistribution
        let foregroundGradientEnabled: Bool
        let foregroundGradientEndHex: String
        let backgroundGradientEnabled: Bool
        let backgroundGradientEndHex: String
        let waveformOpacity: Double

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

        var foregroundGradientEndColor: Color {
            Color(hex: foregroundGradientEndHex)
        }

        var backgroundGradientEndColor: Color {
            Color(hex: backgroundGradientEndHex)
        }
    }

    static func loadConfig(defaults: UserDefaults = .standard) -> WaveformVideoConfig {
        // Load aspect ratio and short edge, compute resolution
        let aspectRatioRaw = defaults.string(forKey: AppConstants.audioWaveformAspectRatioKey) ?? AppConstants.defaultAudioWaveformAspectRatio
        let aspectRatio = AspectRatio(rawValue: aspectRatioRaw) ?? .ratio16_9
        let shortEdge = defaults.integer(forKey: AppConstants.audioWaveformShortEdgeKey)
        let effectiveShortEdge = shortEdge > 0 ? shortEdge : AppConstants.defaultAudioWaveformShortEdge
        let (width, height) = computeResolution(aspectRatio: aspectRatio, shortEdge: effectiveShortEdge)

        let background = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformBackgroundColorKey), fallback: "000000")
        let foreground = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformForegroundColorKey), fallback: "FFFFFF")
        let normalize = defaults.bool(forKey: AppConstants.audioWaveformNormalizeKey)
        let styleRaw = defaults.string(forKey: AppConstants.audioWaveformStyleKey) ?? AppConstants.defaultAudioWaveformStyleRaw
        let style = WaveformStyle(rawValue: styleRaw) ?? .fisheye
        let frameRate = sanitizeFrameRate(defaults.double(forKey: AppConstants.audioWaveformFrameRateKey))

        let engineRaw = defaults.string(forKey: AppConstants.audioWaveformRenderingEngineKey) ?? "swift"
        let renderingEngine = WaveformRenderingEngine(rawValue: engineRaw) ?? .swift
        let swiftStyleRaw = defaults.string(forKey: AppConstants.audioWaveformSwiftStyleKey) ?? "capsules"
        let swiftStyle = SwiftWaveformStyle(rawValue: swiftStyleRaw) ?? .capsules
        let bandCount = defaults.integer(forKey: AppConstants.audioWaveformBandCountKey)
        let effectiveBandCount = bandCount > 0 ? bandCount : 32
        let distRaw = defaults.string(forKey: AppConstants.audioWaveformFrequencyDistributionKey) ?? "mel"
        let frequencyDistribution = FrequencyDistribution(rawValue: distRaw) ?? .mel

        let fgGradientEnabled = defaults.bool(forKey: AppConstants.audioWaveformForegroundGradientEnabledKey)
        let fgGradientEnd = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformForegroundGradientEndColorKey), fallback: "FF0000")
        let bgGradientEnabled = defaults.bool(forKey: AppConstants.audioWaveformBackgroundGradientEnabledKey)
        let bgGradientEnd = sanitizeHex(defaults.string(forKey: AppConstants.audioWaveformBackgroundGradientEndColorKey), fallback: "333333")
        let opacity = defaults.object(forKey: AppConstants.audioWaveformOpacityKey) != nil
            ? min(1.0, max(0.5, defaults.double(forKey: AppConstants.audioWaveformOpacityKey)))
            : 1.0

        return WaveformVideoConfig(
            resolution: CGSize(width: width, height: height),
            width: width,
            height: height,
            backgroundHex: background,
            foregroundHex: foreground,
            normalizeAudio: normalize,
            style: style,
            frameRate: frameRate,
            renderingEngine: renderingEngine,
            swiftStyle: swiftStyle,
            bandCount: effectiveBandCount,
            frequencyDistribution: frequencyDistribution,
            foregroundGradientEnabled: fgGradientEnabled,
            foregroundGradientEndHex: fgGradientEnd,
            backgroundGradientEnabled: bgGradientEnabled,
            backgroundGradientEndHex: bgGradientEnd,
            waveformOpacity: opacity
        )
    }

    /// Computes output resolution from aspect ratio and short edge
    /// Short edge is always the height for landscape ratios, width for portrait ratios
    static func computeResolution(aspectRatio: AspectRatio, shortEdge: Int) -> (Int, Int) {
        guard let numericRatio = aspectRatio.numericRatio else {
            // Free aspect ratio - default to 16:9
            let width = Int(round(Double(shortEdge) * (16.0 / 9.0)))
            return (makeEven(width), makeEven(shortEdge))
        }

        if numericRatio >= 1.0 {
            // Landscape or square: short edge is height
            let width = Int(round(Double(shortEdge) * numericRatio))
            return (makeEven(width), makeEven(shortEdge))
        } else {
            // Portrait: short edge is width
            let height = Int(round(Double(shortEdge) / numericRatio))
            return (makeEven(shortEdge), makeEven(height))
        }
    }

    /// Ensures dimension is even (required by video codecs)
    private static func makeEven(_ value: Int) -> Int {
        return (value / 2) * 2
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
        guard value.isFinite else { return AppConstants.defaultAudioWaveformFrameRate }
        let valid = value >= 10 && value <= 120
        if valid { return value }
        if value == 0 { return AppConstants.defaultAudioWaveformFrameRate }
        return min(max(value, 10), 120)
    }
}

/// Captures generated-video appearance and preset resolution before request preparation.
/// Single-item and merge exports share the same audio-routing compatibility policy.
struct GeneratedVideoSettings: Sendable {
    private let preset: ExportPreset
    private let waveform: WaveformVideoRequest
    private let synthesized: SynthesizedVideoRequest

    init(preset: ExportPreset, defaults: UserDefaults = .standard) {
        self.preset = preset
        let config = AudioWaveformPreferences.loadConfig(defaults: defaults)
        let resolution = preset.resolvedWaveformResolution(defaultResolution: config.resolution, defaults: defaults)
        waveform = WaveformVideoRequest(
            width: Int(resolution.width), height: Int(resolution.height),
            backgroundHex: config.backgroundHex, foregroundHex: config.foregroundHex,
            normalizeAudio: config.normalizeAudio, style: config.style, frameRate: config.frameRate,
            renderingEngine: config.renderingEngine, swiftStyle: config.swiftStyle,
            bandCount: config.bandCount, frequencyDistribution: config.frequencyDistribution,
            foregroundGradientEnabled: config.foregroundGradientEnabled,
            foregroundGradientEndHex: config.foregroundGradientEndHex,
            backgroundGradientEnabled: config.backgroundGradientEnabled,
            backgroundGradientEndHex: config.backgroundGradientEndHex,
            waveformOpacity: config.waveformOpacity
        )
        synthesized = SynthesizedVideoRequest(
            width: Int(resolution.width), height: Int(resolution.height),
            backgroundHex: config.backgroundHex, frameRate: config.frameRate, includeAudio: true
        )
    }

    func requests(for items: [VideoItem]) -> (waveform: WaveformVideoRequest?, synthesized: SynthesizedVideoRequest?) {
        let waveformItems = items.filter(\.requiresWaveformVideo)
        if preset != .streamCopy, !waveformItems.isEmpty,
           !waveformItems.contains(where: Self.splitsAudioToMono) {
            return (waveform, nil)
        }
        let audioOnlyItems = items.filter { !$0.hasVideoStream }
        guard preset.outputsVideoTrack, !audioOnlyItems.isEmpty,
              !audioOnlyItems.contains(where: Self.splitsAudioToMono) else {
            return (nil, nil)
        }
        return (nil, synthesized)
    }

    private static func splitsAudioToMono(_ item: VideoItem) -> Bool {
        if case .splitToMono = item.audioRoutingConfig?.channelOperation { return true }
        return false
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
