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

/// Words from the FFmpeg whisper filter and the language Whisper heard.
struct WhisperTranscript: Sendable, Equatable {
    var words: [TranscriptWord]
    /// The language code most words were transcribed in, as Whisper reports it.
    var language: String?
}

/// Reads the newline-delimited JSON the bundled FFmpeg whisper filter writes
/// with `format=json:max_len=1`: one
/// `{"start":ms,"end":ms,"text":"word","p":0.81,"language":"no"}` per word.
/// Our FFmpeg build escapes the text properly, so a line that is not valid
/// JSON is dropped.
enum WhisperWordJSONParser {
    static func parse(_ data: Data) -> WhisperTranscript {
        var words: [TranscriptWord] = []
        var languageCounts: [String: Int] = [:]
        var bracketDepth = 0
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let (word, language) = parseLine(String(line)) else { continue }
            // Whisper marks non-speech as [BLANK_AUDIO] or similar, which
            // `max_len=1` can split into "[", "BLANK_AUDIO" and "]".
            let opens = word.text.filter { $0 == "[" }.count
            let closes = word.text.filter { $0 == "]" }.count
            let marker = bracketDepth > 0 || opens > 0
            bracketDepth = max(0, bracketDepth + opens - closes)
            guard !marker else { continue }
            words.append(word)
            if let language { languageCounts[language, default: 0] += 1 }
        }
        return WhisperTranscript(
            words: words.sorted { $0.start < $1.start },
            language: languageCounts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        )
    }

    static func parseLine(_ line: String) -> (word: TranscriptWord, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let start = (object["start"] as? NSNumber)?.doubleValue,
              let end = (object["end"] as? NSNumber)?.doubleValue,
              let rawText = object["text"] as? String else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, start.isFinite, end.isFinite else { return nil }
        let language = (object["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (TranscriptWord(text: text, start: max(0, start / 1000), end: max(0, end / 1000)), language)
    }
}

enum TranscriptLanguage {
    /// Whisper's language setting when it names one, otherwise the language
    /// Whisper detected, the language the Whisper model is trained for, or a
    /// guess from the transcript text.
    static func resolve(
        setting: String, model: WhisperModel?, words: [TranscriptWord], detected: String? = nil
    ) -> String? {
        if setting != "auto", !setting.isEmpty { return normalized(setting) }
        if let detected, !detected.isEmpty { return normalized(detected) }
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
