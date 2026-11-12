// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Per-item picture and sound adjustments applied while re-encoding:
/// rotation/flip, speed, fades, audio offset, volume, replacement audio,
/// burned-in subtitles and an optional loudness override.
struct MediaAdjustments: Codable, Equatable, Hashable, Sendable {
    enum Rotation: Int, Codable, CaseIterable, Identifiable, Sendable {
        case none = 0
        case clockwise90 = 90
        case rotate180 = 180
        case counterClockwise90 = 270

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .none: return String(localized: "No rotation", comment: "Rotation option.")
            case .clockwise90: return String(localized: "90° clockwise", comment: "Rotation option.")
            case .rotate180: return String(localized: "180°", comment: "Rotation option.")
            case .counterClockwise90: return String(localized: "90° counter-clockwise", comment: "Rotation option.")
            }
        }
    }

    enum AudioReplacementMode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The file's audio tracks replace every source track.
        case replace
        /// The file's audio tracks follow the source tracks.
        case add

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .replace: return String(localized: "Replace source audio", comment: "Replacement audio mode.")
            case .add: return String(localized: "Add as extra tracks", comment: "Replacement audio mode.")
            }
        }
    }

    struct ReplacementAudio: Codable, Equatable, Hashable, Sendable {
        var path: String
        var mode: AudioReplacementMode = .replace

        var url: URL { URL(fileURLWithPath: path) }
    }

    enum SubtitleSource: Codable, Equatable, Hashable, Sendable {
        /// Subtitle-relative index (`0:s:N`) of a text subtitle stream in the source.
        case embedded(streamIndex: Int)
        /// An external .srt, .ass, .ssa or .vtt file.
        case file(path: String)
    }

    enum SubtitlePosition: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottom
        case top

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bottom: return String(localized: "Bottom", comment: "Burned-in subtitle position.")
            case .top: return String(localized: "Top", comment: "Burned-in subtitle position.")
            }
        }
    }

    struct BurnInSubtitles: Codable, Equatable, Hashable, Sendable {
        var source: SubtitleSource
        /// libass font size relative to a 288-line script; 18–24 suits most footage.
        var fontSize: Int = 20
        /// Draws an opaque box behind the text instead of an outline.
        var backgroundBox: Bool = false
        var position: SubtitlePosition = .bottom

        /// Overrides for SRT/VTT styling. ASS/SSA files keep their own styles.
        var forceStyle: String {
            var parts = ["FontSize=\(fontSize)"]
            if backgroundBox {
                parts += ["BorderStyle=3", "Outline=1", "Shadow=0", "BackColour=&H80000000"]
            } else {
                parts += ["BorderStyle=1", "Outline=1.5", "Shadow=0.5"]
            }
            parts.append("Alignment=\(position == .top ? 8 : 2)")
            parts.append("MarginV=\(position == .top ? 20 : 24)")
            return parts.joined(separator: ",")
        }
    }

    enum LoudnessOverride: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Follow the global setting in Settings → Encoding.
        case useDefault
        case on
        case off

        var id: String { rawValue }
    }

    static let minimumSpeed = 0.25
    static let maximumSpeed = 4.0
    /// Export volume range in dB, matching the trim view's volume line.
    static let audioGainRange: ClosedRange<Double> = -30...24

    var rotation: Rotation = .none
    var flipHorizontal = false
    var flipVertical = false
    /// Playback speed multiplier; 2 halves the duration. Audio keeps its pitch.
    var speed: Double = 1
    var videoFadeIn: Double = 0
    var videoFadeOut: Double = 0
    var audioFadeIn: Double = 0
    var audioFadeOut: Double = 0
    /// Positive values delay the audio; negative values make it play earlier.
    var audioOffset: Double = 0
    /// Export volume in dB, set with the trim view's volume line. Nil when the
    /// line only scales the waveform display.
    var audioGain: Double?
    var replacementAudio: ReplacementAudio?
    var burnInSubtitles: BurnInSubtitles?
    var loudness: LoudnessOverride = .useDefault

    init() {}

    var changesSpeed: Bool { abs(speed - 1) > 0.0001 }

    /// Whether the export volume differs audibly from the source.
    var changesVolume: Bool { abs(audioGain ?? 0) >= 0.05 }

    var hasVideoAdjustments: Bool {
        rotation != .none || flipHorizontal || flipVertical || changesSpeed
            || videoFadeIn > 0 || videoFadeOut > 0 || burnInSubtitles != nil
    }

    /// Item-level audio changes. The loudness override is resolved separately.
    var hasAudioAdjustments: Bool {
        changesSpeed || audioFadeIn > 0 || audioFadeOut > 0
            || abs(audioOffset) > 0.0001 || changesVolume || replacementAudio != nil
    }

    /// An enabled export volume counts even at 0 dB, so the trim view's toggle survives editing.
    var isActive: Bool {
        hasVideoAdjustments || hasAudioAdjustments || audioGain != nil || loudness != .useDefault
    }

    /// Short labels for the queue row and history summaries.
    var summary: [String] {
        var lines: [String] = []
        if rotation != .none { lines.append(rotation.displayName) }
        if flipHorizontal { lines.append(String(localized: "Flipped horizontally", comment: "Adjustment summary.")) }
        if flipVertical { lines.append(String(localized: "Flipped vertically", comment: "Adjustment summary.")) }
        if changesSpeed { lines.append(String(localized: "Speed \(Self.formatted(speed))×", comment: "Adjustment summary.")) }
        if videoFadeIn > 0 || videoFadeOut > 0 {
            lines.append(String(localized: "Video fade \(Self.formatted(videoFadeIn)) s / \(Self.formatted(videoFadeOut)) s", comment: "Adjustment summary: fade in / fade out seconds."))
        }
        if audioFadeIn > 0 || audioFadeOut > 0 {
            lines.append(String(localized: "Audio fade \(Self.formatted(audioFadeIn)) s / \(Self.formatted(audioFadeOut)) s", comment: "Adjustment summary: fade in / fade out seconds."))
        }
        if abs(audioOffset) > 0.0001 {
            lines.append(String(localized: "Audio offset \(Self.formatted(audioOffset)) s", comment: "Adjustment summary."))
        }
        if let audioGain {
            lines.append(String(localized: "Volume \(Self.formattedGain(audioGain))", comment: "Adjustment summary: export volume in decibels, for example +6 dB."))
        }
        if let replacementAudio {
            lines.append("\(replacementAudio.mode.displayName): \(replacementAudio.url.lastPathComponent)")
        }
        if burnInSubtitles != nil { lines.append(String(localized: "Burned-in subtitles", comment: "Adjustment summary.")) }
        switch loudness {
        case .useDefault: break
        case .on: lines.append(String(localized: "Loudness normalization on", comment: "Adjustment summary."))
        case .off: lines.append(String(localized: "Loudness normalization off", comment: "Adjustment summary."))
        }
        return lines
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// A signed decibel value, such as "+6 dB" or "−3.5 dB".
    static func formattedGain(_ decibels: Double) -> String {
        let rounded = (decibels * 10).rounded() / 10
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(0...1)))
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : ""
        return "\(sign)\(magnitude) dB"
    }
}

extension MediaAdjustments {
    /// Tolerant decoding keeps older or newer recipes restorable.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rotation = c.decodeTolerant(Rotation.self, forKey: .rotation) ?? .none
        flipHorizontal = c.decodeTolerant(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = c.decodeTolerant(Bool.self, forKey: .flipVertical) ?? false
        let decodedSpeed = c.decodeTolerant(Double.self, forKey: .speed) ?? 1
        speed = min(max(decodedSpeed, Self.minimumSpeed), Self.maximumSpeed)
        videoFadeIn = max(0, c.decodeTolerant(Double.self, forKey: .videoFadeIn) ?? 0)
        videoFadeOut = max(0, c.decodeTolerant(Double.self, forKey: .videoFadeOut) ?? 0)
        audioFadeIn = max(0, c.decodeTolerant(Double.self, forKey: .audioFadeIn) ?? 0)
        audioFadeOut = max(0, c.decodeTolerant(Double.self, forKey: .audioFadeOut) ?? 0)
        audioOffset = c.decodeTolerant(Double.self, forKey: .audioOffset) ?? 0
        audioGain = c.decodeTolerant(Double.self, forKey: .audioGain).flatMap { gain in
            gain.isFinite ? min(max(gain, Self.audioGainRange.lowerBound), Self.audioGainRange.upperBound) : nil
        }
        replacementAudio = c.decodeTolerant(ReplacementAudio.self, forKey: .replacementAudio)
        burnInSubtitles = c.decodeTolerant(BurnInSubtitles.self, forKey: .burnInSubtitles)
        loudness = c.decodeTolerant(LoudnessOverride.self, forKey: .loudness) ?? .useDefault
    }
}

// MARK: - Loudness normalization

/// Two-pass EBU R128 normalization with FFmpeg's `loudnorm`. The first pass
/// measures each output audio track; the second applies a linear gain when the
/// measured range and true peak allow it, and dynamic normalization otherwise.
struct LoudnessNormalizationSettings: Codable, Equatable, Hashable, Sendable {
    enum Standard: String, Codable, CaseIterable, Identifiable, Sendable {
        case ebuR128
        case atscA85
        case streaming
        case podcast
        case custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ebuR128: return String(localized: "EBU R128 (−23 LUFS, −1 dBTP)", comment: "Loudness standard.")
            case .atscA85: return String(localized: "ATSC A/85 (−24 LUFS, −2 dBTP)", comment: "Loudness standard.")
            case .streaming: return String(localized: "Streaming (−14 LUFS, −1 dBTP)", comment: "Loudness standard.")
            case .podcast: return String(localized: "Web and podcast (−16 LUFS, −1 dBTP)", comment: "Loudness standard.")
            case .custom: return String(localized: "Custom", comment: "Loudness standard.")
            }
        }

        var target: (integrated: Double, truePeak: Double)? {
            switch self {
            case .ebuR128: return (-23, -1)
            case .atscA85: return (-24, -2)
            case .streaming: return (-14, -1)
            case .podcast: return (-16, -1)
            case .custom: return nil
            }
        }
    }

    static let integratedRange: ClosedRange<Double> = -70 ... -5
    static let truePeakRange: ClosedRange<Double> = -9 ... 0
    static let loudnessRangeRange: ClosedRange<Double> = 1 ... 50

    var enabled = false
    var standard: Standard = .ebuR128
    var customIntegrated: Double = -23
    var customTruePeak: Double = -1
    /// Target loudness range. A generous value lets most programmes keep a
    /// linear gain instead of falling back to dynamic compression.
    var loudnessRange: Double = 20

    init() {}

    init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: AppConstants.loudnessNormalizationEnabledKey)
        standard = defaults.string(forKey: AppConstants.loudnessNormalizationStandardKey)
            .flatMap(Standard.init(rawValue:)) ?? .ebuR128
        if let value = defaults.object(forKey: AppConstants.loudnessNormalizationIntegratedKey) as? Double {
            customIntegrated = value
        }
        if let value = defaults.object(forKey: AppConstants.loudnessNormalizationTruePeakKey) as? Double {
            customTruePeak = value
        }
        if let value = defaults.object(forKey: AppConstants.loudnessNormalizationRangeKey) as? Double {
            loudnessRange = value
        }
    }

    var integrated: Double {
        let value = standard.target?.integrated ?? customIntegrated
        return min(max(value, Self.integratedRange.lowerBound), Self.integratedRange.upperBound)
    }

    var truePeak: Double {
        let value = standard.target?.truePeak ?? customTruePeak
        return min(max(value, Self.truePeakRange.lowerBound), Self.truePeakRange.upperBound)
    }

    var clampedLoudnessRange: Double {
        min(max(loudnessRange, Self.loudnessRangeRange.lowerBound), Self.loudnessRangeRange.upperBound)
    }

    /// The setting an item converts with, after its own override.
    func resolved(for override: MediaAdjustments.LoudnessOverride) -> LoudnessNormalizationSettings? {
        switch override {
        case .off: return nil
        case .useDefault: return enabled ? self : nil
        case .on:
            var copy = self
            copy.enabled = true
            return copy
        }
    }
}

/// One track's first-pass `loudnorm` statistics.
struct LoudnormMeasurement: Equatable, Sendable {
    let inputIntegrated: String
    let inputTruePeak: String
    let inputLoudnessRange: String
    let inputThreshold: String
    let targetOffset: String
}

/// The adjustments a conversion runs with, after resolving the global loudness setting.
struct ResolvedMediaAdjustments: Equatable, Sendable {
    var adjustments: MediaAdjustments
    var loudness: LoudnessNormalizationSettings?
    /// Whether the loudness setting came from the item rather than the global default.
    /// Unsupported outputs fail for item settings and silently skip the global one.
    var loudnessIsExplicit: Bool

    init(adjustments: MediaAdjustments?, globalLoudness: LoudnessNormalizationSettings) {
        let adjustments = adjustments ?? MediaAdjustments()
        self.adjustments = adjustments
        loudness = globalLoudness.resolved(for: adjustments.loudness)
        loudnessIsExplicit = adjustments.loudness == .on
    }

    init(adjustments: MediaAdjustments, loudness: LoudnessNormalizationSettings?, loudnessIsExplicit: Bool) {
        self.adjustments = adjustments
        self.loudness = loudness
        self.loudnessIsExplicit = loudnessIsExplicit
    }

    var isActive: Bool { adjustments.hasVideoAdjustments || adjustments.hasAudioAdjustments || loudness != nil }

    /// Adjustments the user set on this item, which must not be dropped silently.
    var hasExplicitAdjustments: Bool {
        adjustments.hasVideoAdjustments || adjustments.hasAudioAdjustments || (loudness != nil && loudnessIsExplicit)
    }
}
