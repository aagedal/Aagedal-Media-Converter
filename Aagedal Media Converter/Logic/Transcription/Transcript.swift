// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NaturalLanguage

/// One recognised word with its timing in seconds from the start of the media.
/// Engines produce these; alignment refines the times and diarization fills in
/// the speaker before `SubtitleCueBuilder` turns them into subtitle cues.
struct TranscriptWord: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    /// Zero-based speaker index from diarization, or nil when unknown.
    var speaker: Int?

    init(text: String, start: Double, end: Double, speaker: Int? = nil) {
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.speaker = speaker
    }

    var endsSentence: Bool {
        guard let last = text.trimmingCharacters(in: Self.closingQuotes).last else { return false }
        return ".?!…".contains(last)
    }

    var endsClause: Bool {
        guard let last = text.trimmingCharacters(in: Self.closingQuotes).last else { return false }
        return ",;:–—".contains(last)
    }

    private static let closingQuotes = CharacterSet(charactersIn: "\"'»”’)")
}

/// Reads the newline-delimited JSON the FFmpeg whisper filter writes with
/// `format=json:max_len=1`: one `{"start":ms,"end":ms,"text":"word"}` per word.
/// The filter escapes only quotes, so a line that is not valid JSON is read
/// with a lenient fallback instead of being dropped.
enum WhisperWordJSONParser {
    static func parse(_ data: Data) -> [TranscriptWord] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
            .sorted { $0.start < $1.start }
    }

    static func parseLine(_ line: String) -> TranscriptWord? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let start: Double
        let end: Double
        let rawText: String
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let startValue = (object["start"] as? NSNumber)?.doubleValue,
           let endValue = (object["end"] as? NSNumber)?.doubleValue,
           let text = object["text"] as? String {
            start = startValue
            end = endValue
            rawText = text
        } else if let match = trimmed.wholeMatch(of: lenientLine),
                  let startValue = Double(match.1), let endValue = Double(match.2) {
            start = startValue
            end = endValue
            rawText = String(match.3)
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else {
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, start.isFinite, end.isFinite else { return nil }
        return TranscriptWord(text: text, start: max(0, start / 1000), end: max(0, end / 1000))
    }

    nonisolated(unsafe) private static let lenientLine =
        /\{"start":(-?\d+(?:\.\d+)?),"end":(-?\d+(?:\.\d+)?),"text":"(.*)"\}/
}

enum TranscriptLanguage {
    /// Whisper's language setting when it names one, otherwise the language the
    /// Whisper model is trained for, otherwise a guess from the transcript text.
    static func resolve(setting: String, model: WhisperModel?, words: [TranscriptWord]) -> String? {
        if setting != "auto", !setting.isEmpty { return normalized(setting) }
        switch model {
        case .norwegianTiny, .norwegianSmall, .norwegianMedium, .norwegianLarge: return "no"
        case .swedishBase, .swedishSmall, .swedishMedium, .swedishLarge: return "sv"
        default: break
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words.prefix(400).map(\.text).joined(separator: " "))
        guard let language = recognizer.dominantLanguage else { return nil }
        return normalized(language.rawValue)
    }

    /// Whisper uses "no" for Norwegian; NaturalLanguage and BCP 47 use "nb".
    static func normalized(_ code: String) -> String {
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return base == "nb" ? "no" : base
    }
}
