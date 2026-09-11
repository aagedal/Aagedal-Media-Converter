// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreFoundation

/// Values are captured before an operation suspends, so later preference edits
/// affect the next operation rather than changing an in-flight subtitle job.
struct TranscriptionSettingsSnapshot: Sendable {
    let whisperModel: WhisperModel
    let whisperLanguage: String
    let parakeetModel: ParakeetModel
    let parakeetLanguage: String
    let embedSubtitles: Bool
}

/// Validated once at the start of a Parakeet run. Nonpositive stored values
/// retain the historical meaning of using the CLI defaults.
struct ParakeetSettingsSnapshot: Sendable, Equatable {
    // A single chunk cannot usefully exceed the entire transcription deadline.
    static let maximumChunkDuration = 12 * 60 * 60

    let chunkDuration: Int
    let overlapDuration: Int

    init(
        chunkDuration: Int = AppConstants.defaultParakeetChunkDuration,
        overlapDuration: Int = AppConstants.defaultParakeetOverlapDuration
    ) {
        self.chunkDuration = (1...Self.maximumChunkDuration).contains(chunkDuration)
            ? chunkDuration : AppConstants.defaultParakeetChunkDuration
        let requestedOverlap = (1...Self.maximumChunkDuration).contains(overlapDuration)
            ? overlapDuration : AppConstants.defaultParakeetOverlapDuration
        // The CLI must advance after each chunk, including chunks shorter than
        // its default overlap. Explicitly pass zero for a one-second chunk.
        self.overlapDuration = min(requestedOverlap, self.chunkDuration - 1)
    }

    init(defaults: UserDefaults) {
        self.init(
            chunkDuration: Self.duration(defaults.object(forKey: AppConstants.parakeetChunkDurationKey))
                ?? AppConstants.defaultParakeetChunkDuration,
            overlapDuration: Self.duration(defaults.object(forKey: AppConstants.parakeetOverlapDurationKey))
                ?? AppConstants.defaultParakeetOverlapDuration
        )
    }

    var arguments: [String] {
        // Keep the historical CLI defaults when neither setting is customized.
        // CLI versions can default to a different chunk size (e.g. 120 seconds),
        // so a custom setting must send the validated pair together.
        guard chunkDuration != AppConstants.defaultParakeetChunkDuration
                || overlapDuration != AppConstants.defaultParakeetOverlapDuration else { return [] }
        return ["--chunk-duration", "\(chunkDuration)", "--overlap-duration", "\(overlapDuration)"]
    }

    private static func duration(_ value: Any?) -> Int? {
        let number: Double
        if let stored = value as? NSNumber {
            guard CFGetTypeID(stored) != CFBooleanGetTypeID() else { return nil }
            number = stored.doubleValue
        } else if let stored = value as? String, let parsed = Double(stored) {
            number = parsed
        } else {
            return nil
        }
        guard number.isFinite, number.rounded(.towardZero) == number,
              (1...Double(maximumChunkDuration)).contains(number) else { return nil }
        return Int(number)
    }
}

struct OCRSettingsSnapshot: Sendable {
    let engine: OCREngineKind
    let language: String
    let embedSubtitles: Bool

    func language(forStreamLanguage streamLanguage: String?) -> String {
        streamLanguage ?? language
    }
}

struct AnalyticsSettingsSnapshot: Sendable {
    let enabledMetrics: [QualityMetric]
    let vmafModel: VMAFModel
    let ssimulacra2MaxFrames: Int
    let autoExport: AnalyticsAutoExportSettingsSnapshot
}

struct AnalyticsAutoExportSettingsSnapshot: Sendable {
    let enabled: Bool
    let format: AnalyticsExportFormat
}

protocol TranscriptionSettingsProviding: Sendable {
    func transcriptionSnapshot() -> TranscriptionSettingsSnapshot
}

protocol OCRSettingsProviding: Sendable {
    func ocrSnapshot() -> OCRSettingsSnapshot
}

protocol AnalyticsSettingsProviding: Sendable {
    func analyticsSnapshot() -> AnalyticsSettingsSnapshot
}

/// UserDefaults synchronizes its own access; this immutable adapter never
/// changes its store reference. Tests can supply a private suite instead of
/// changing the application's standard defaults.
final class PostConversionSettings: TranscriptionSettingsProviding, OCRSettingsProviding,
    AnalyticsSettingsProviding, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func transcriptionSnapshot() -> TranscriptionSettingsSnapshot {
        let whisperRaw = defaults.string(forKey: AppConstants.whisperModelKey)
            ?? AppConstants.defaultWhisperModel
        let parakeetRaw = defaults.string(forKey: AppConstants.parakeetModelKey)
            ?? AppConstants.defaultParakeetModel
        return TranscriptionSettingsSnapshot(
            whisperModel: WhisperModel(rawValue: whisperRaw) ?? .base,
            whisperLanguage: defaults.string(forKey: AppConstants.whisperLanguageKey)
                ?? AppConstants.defaultWhisperLanguage,
            parakeetModel: ParakeetModel.model(for: parakeetRaw) ?? ParakeetModel.allModels[0],
            parakeetLanguage: defaults.string(forKey: AppConstants.parakeetLanguageKey)
                ?? AppConstants.defaultParakeetLanguage,
            embedSubtitles: defaults.bool(forKey: AppConstants.embedSubtitlesKey)
        )
    }

    func ocrSnapshot() -> OCRSettingsSnapshot {
        let engineRaw = defaults.string(forKey: AppConstants.ocrEngineKey) ?? AppConstants.defaultOCREngine
        let engine = OCREngineKind(rawValue: engineRaw) ?? .tesseract
        let language: String
        switch engine {
        case .tesseract:
            language = defaults.string(forKey: AppConstants.tesseractLanguageKey)
                ?? AppConstants.defaultTesseractLanguage
        case .appleVision:
            language = defaults.string(forKey: AppConstants.visionLanguageKey)
                ?? AppConstants.defaultVisionLanguage
        }
        return OCRSettingsSnapshot(
            engine: engine, language: language,
            embedSubtitles: defaults.bool(forKey: AppConstants.embedSubtitlesKey)
        )
    }

    func analyticsSnapshot() -> AnalyticsSettingsSnapshot {
        let metrics = defaults.stringArray(forKey: AppConstants.analyticsEnabledMetricsKey)
            ?? AppConstants.defaultAnalyticsEnabledMetrics
        let model = defaults.string(forKey: AppConstants.analyticsVMAFModelKey)
            ?? AppConstants.defaultAnalyticsVMAFModel
        let maxFrames = defaults.integer(forKey: AppConstants.ssimulacra2MaxFramesKey)
        return AnalyticsSettingsSnapshot(
            enabledMetrics: metrics.compactMap(QualityMetric.init(rawValue:)),
            vmafModel: VMAFModel(rawValue: model) ?? .vmaf_v0_6_1,
            ssimulacra2MaxFrames: maxFrames > 0 ? maxFrames : AppConstants.defaultSSIMULACRA2MaxFrames,
            autoExport: AnalyticsAutoExportSettingsSnapshot(
                enabled: defaults.bool(forKey: AppConstants.analyticsAutoExportKey),
                format: AnalyticsExportFormat(rawValue:
                    defaults.string(forKey: AppConstants.analyticsAutoExportFormatKey)
                        ?? AppConstants.defaultAnalyticsAutoExportFormat
                ) ?? .json
            )
        )
    }
}
