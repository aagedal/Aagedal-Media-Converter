// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Values are captured before an operation suspends, so later preference edits
/// affect the next operation rather than changing an in-flight subtitle job.
struct TranscriptionSettingsSnapshot: Sendable {
    let whisperModel: WhisperModel
    let whisperLanguage: String
    let parakeetModel: ParakeetModel
    let parakeetLanguage: String
    let embedSubtitles: Bool
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
