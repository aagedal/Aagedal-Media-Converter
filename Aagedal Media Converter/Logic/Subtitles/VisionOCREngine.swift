// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Vision
import OSLog

/// OCR backend that uses Apple's Vision framework (`VNRecognizeTextRequest`).
///
/// No external binary or model file required — runs entirely on the system
/// frameworks shipped with macOS 15+. Typically faster and more accurate than
/// Tesseract for printed Latin-script text.
struct VisionOCREngine: BitmapSubtitleOCREngine {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VisionOCREngine")
    private static let defaultPerFrameTimeout: Duration = .seconds(10)

    typealias RecognitionPerformer = @Sendable (
        _ imageData: Data,
        _ recognitionLanguages: [String],
        _ usesLanguageCorrection: Bool
    ) async throws -> String

    /// Whether Vision should apply language-model post-correction. On for accuracy.
    var usesLanguageCorrection: Bool = true
    private let perFrameTimeout: Duration
    private let recognitionPerformer: RecognitionPerformer

    init(
        usesLanguageCorrection: Bool = true,
        perFrameTimeout: Duration = Self.defaultPerFrameTimeout,
        recognitionPerformer: @escaping RecognitionPerformer = Self.performRecognition
    ) {
        self.usesLanguageCorrection = usesLanguageCorrection
        self.perFrameTimeout = perFrameTimeout
        self.recognitionPerformer = recognitionPerformer
    }

    func recognize(pngURL: URL, language: String) async throws -> String {
        try Task.checkCancellation()

        // Keep the pixels alive independently of TesseractService's per-run scratch
        // directory. A timed-out Vision request may finish after its caller has moved on
        // and removed the temporary PNG.
        let imageData = try Data(contentsOf: pngURL)
        let recognitionLanguages = Self.recognitionLanguages(for: language)
        let useCorrection = usesLanguageCorrection

        do {
            let text = try await NonJoiningTaskDeadline.run(timeout: perFrameTimeout) {
                try await recognitionPerformer(imageData, recognitionLanguages, useCorrection)
            }
            try Task.checkCancellation()
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch NonJoiningTaskDeadlineError.timedOut {
            throw VisionOCREngineError.timedOut(limit: perFrameTimeout)
        }
    }

    // MARK: - Helpers

    /// `VNImageRequestHandler.perform` is synchronous and can fail to return for malformed
    /// or problematic frames. `recognize` runs it on a GCD worker behind a non-joining
    /// deadline so timeout and cancellation never wait for the blocking framework call.
    private static func performRecognition(
        imageData: Data,
        recognitionLanguages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Keep blocking Vision work off Swift's cooperative executor. The outer
            // deadline can stop awaiting this continuation without joining the GCD job.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = usesLanguageCorrection
                if !recognitionLanguages.isEmpty {
                    request.recognitionLanguages = recognitionLanguages
                }

                let handler = VNImageRequestHandler(data: imageData, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: assemble(observations: request.results ?? []))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Joins observation strings in top-to-bottom, left-to-right reading order so
    /// multi-line subtitles come out as one string with line breaks preserved.
    private static func assemble(observations: [VNRecognizedTextObservation]) -> String {
        // Sort by Y descending (Vision uses bottom-left origin, so larger Y = higher on screen).
        // Within roughly the same line, sort by X ascending.
        let lineTolerance: CGFloat = 0.02
        let sorted = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) < lineTolerance {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return dy > 0  // higher Y first → top of frame first
        }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Maps a tessdata-style language code (eng / nor / jpn / …) to one or more
    /// BCP-47 language codes that Vision understands. Falls back to letting Vision
    /// auto-detect when the code is unknown.
    private static func recognitionLanguages(for language: String) -> [String] {
        let key = language.lowercased()
        let mapped = Self.languageMap[key]
        if let mapped { return mapped }
        // If the caller already passed a BCP-47-ish code (contains a hyphen or is 2 chars), trust it.
        if key.contains("-") || key.count == 2 {
            return [language]
        }
        return []
    }

    /// Tessdata code → preferred Vision (BCP-47) codes. Order matters: first entry
    /// is the primary recognition language, additional entries are fallbacks.
    private static let languageMap: [String: [String]] = [
        "eng":     ["en-US"],
        "nor":     ["nb-NO", "nn-NO"],
        "nob":     ["nb-NO"],
        "nno":     ["nn-NO"],
        "dan":     ["da-DK"],
        "swe":     ["sv-SE"],
        "isl":     ["is-IS"],
        "fin":     ["fi-FI"],
        "deu":     ["de-DE"],
        "ger":     ["de-DE"],
        "fra":     ["fr-FR"],
        "fre":     ["fr-FR"],
        "spa":     ["es-ES"],
        "ita":     ["it-IT"],
        "por":     ["pt-BR", "pt-PT"],
        "nld":     ["nl-NL"],
        "dut":     ["nl-NL"],
        "rus":     ["ru-RU"],
        "ukr":     ["uk-UA"],
        "pol":     ["pl-PL"],
        "ces":     ["cs-CZ"],
        "cze":     ["cs-CZ"],
        "hun":     ["hu-HU"],
        "ron":     ["ro-RO"],
        "rum":     ["ro-RO"],
        "tur":     ["tr-TR"],
        "ell":     ["el-GR"],
        "gre":     ["el-GR"],
        "jpn":     ["ja-JP"],
        "kor":     ["ko-KR"],
        "chi_sim": ["zh-Hans"],
        "chi_tra": ["zh-Hant"],
        "tha":     ["th-TH"],
        "vie":     ["vi-VN"],
        "ara":     ["ar-SA"],
        "heb":     ["he-IL"],
    ]

    // MARK: - Public language discovery (used by the settings UI)

    /// Languages currently supported by Vision's text recognizer at the highest revision.
    /// Returns BCP-47 codes (e.g. "en-US"). Empty if Vision is unavailable.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            return try request.supportedRecognitionLanguages()
        } catch {
            logger.warning("Vision supportedRecognitionLanguages failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

enum VisionOCREngineError: Error, LocalizedError {
    case timedOut(limit: Duration)

    var errorDescription: String? {
        switch self {
        case .timedOut(let limit):
            let components = limit.components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let value = seconds.rounded() == seconds
                ? String(Int(seconds))
                : String(format: "%.3g", seconds)
            return "Apple Vision exceeded the \(value)-second per-frame limit"
        }
    }
}
