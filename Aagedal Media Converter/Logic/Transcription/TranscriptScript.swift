// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NaturalLanguage

/// Writing conventions that change how words are split, joined and laid out.
/// Japanese and Chinese put no spaces between words; Korean does, but its
/// syllables are as wide as Han characters, so its lines are shorter too.
enum TranscriptScript: Sendable, Equatable {
    case spaced
    case japanese
    case chinese
    case korean

    /// The script for the transcript's language, or, when the language is not
    /// one of these, the script most of the transcript is written in.
    static func detect(language: String?, words: [TranscriptWord]) -> TranscriptScript {
        switch language.map(TranscriptLanguage.normalized) {
        case "ja": return .japanese
        case "zh", "yue": return .chinese
        case "ko": return .korean
        default: break
        }
        var kana = 0, han = 0, hangul = 0, other = 0
        for character in words.prefix(400).lazy.flatMap(\.text) where character.isLetter {
            switch character.cjkScript {
            case .kana: kana += 1
            case .han: han += 1
            case .hangul: hangul += 1
            case nil: other += 1
            }
        }
        if hangul > other + kana + han { return .korean }
        guard kana + han > other + hangul else { return .spaced }
        // Japanese text always has some kana; Chinese has none.
        return kana > 0 ? .japanese : .chinese
    }

    /// Characters per line for a Latin-script maximum of `length`. Subtitle
    /// guidelines (Netflix among them) allow about 13 full-width characters
    /// per line in Japanese and 16 in Chinese and Korean against 42 in Latin
    /// scripts, so the setting scales by those ratios.
    func lineLength(forLatin length: Int) -> Int {
        switch self {
        case .spaced: length
        case .japanese: max(8, (length * 13 + 21) / 42)
        case .chinese, .korean: max(8, (length * 16 + 21) / 42)
        }
    }

    /// Comfortable reading speed, from the same guidelines.
    var charactersPerSecond: Double {
        switch self {
        case .spaced: 17
        case .japanese: 4
        case .chinese: 9
        case .korean: 12
        }
    }
}

enum CJKScript {
    case han, kana, hangul
}

extension Character {
    var cjkScript: CJKScript? {
        guard let value = unicodeScalars.first?.value else { return nil }
        switch value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F, 0x3005, 0x3007: return .han
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        default: return nil
        }
    }

    /// Han, kana and the full-width punctuation that goes with them, which
    /// take no space before or after.
    var isWrittenWithoutSpaces: Bool {
        if let script = cjkScript { return script != .hangul }
        guard let value = unicodeScalars.first?.value else { return false }
        // CJK punctuation and full-width forms (not half-width Hangul).
        return (0x3000...0x303F).contains(value) || (0xFF00...0xFF65).contains(value)
    }
}

enum TranscriptText {
    /// What goes between two words: nothing next to Han or kana, otherwise a space.
    static func separator(between previous: String, and next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        return last.isWrittenWithoutSpaces || first.isWrittenWithoutSpaces ? "" : " "
    }

    static func join(_ words: some Sequence<String>) -> String {
        var result = ""
        for word in words {
            result += separator(between: result, and: word) + word
        }
        return result
    }
}

/// The FFmpeg whisper filter splits its output only at spaces, so Japanese and
/// Chinese arrive as whole phrases of several seconds. This splits them into
/// words with `NLTokenizer`, joins particles and endings back onto the word
/// they follow so lines don't break before them, and times each word by its
/// share of the phrase's characters. Alignment then refines those times.
enum TranscriptWordSplitter {
    static func split(_ words: [TranscriptWord], script: TranscriptScript) -> [TranscriptWord] {
        guard script == .japanese || script == .chinese else { return words }
        return words.flatMap { split($0, script: script) }
    }

    static func split(_ word: TranscriptWord, script: TranscriptScript) -> [TranscriptWord] {
        let text = normalizedPunctuation(word.text, script: script)
        guard text.contains(where: \.isWrittenWithoutSpaces) else { return [word] }
        let units = merge(tokens(in: text, script: script), script: script)
        guard !units.isEmpty else { return [word] }
        let weights = units.map { $0.filter { $0.isLetter || $0.isNumber }.count }
        let total = Double(max(weights.reduce(0, +), 1))
        let duration = word.end - word.start
        var elapsed = 0
        var result = zip(units, weights).map { unit, weight in
            let start = word.start + duration * Double(elapsed) / total
            elapsed += weight
            return TranscriptWord(
                text: unit, start: start, end: word.start + duration * Double(elapsed) / total, speaker: word.speaker
            )
        }
        result[result.count - 1].endsPhrase = true
        return result
    }

    /// Whisper often writes ASCII commas and question marks in Chinese and
    /// Japanese. After a Han or kana character they become full-width.
    static func normalizedPunctuation(_ text: String, script: TranscriptScript) -> String {
        let replacements: [Character: Character] = script == .japanese
            ? [",": "、", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
            : [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        var result = ""
        for (index, character) in zip(text.indices, text) {
            if let replacement = replacements[character], result.last?.isWrittenWithoutSpaces == true,
               text.index(after: index) == text.endIndex || text[text.index(after: index)].isWrittenWithoutSpaces
                || text[text.index(after: index)].isWhitespace {
                result.append(replacement)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Words from `NLTokenizer`, with punctuation kept on the word before it
    /// and spaces dropped.
    private static func tokens(in text: String, script: TranscriptScript) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        if script == .japanese {
            tokenizer.setLanguage(.japanese)
        } else {
            // A tokenizer set to Simplified Chinese splits Traditional text
            // into single characters.
            let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
            tokenizer.setLanguage(simplified == text ? .simplifiedChinese : .traditionalChinese)
        }
        tokenizer.string = text
        var tokens: [String] = []
        var position = text.startIndex
        func appendGap(upTo end: String.Index) {
            let gap = text[position..<end].filter { !$0.isWhitespace }
            guard !gap.isEmpty else { return }
            if tokens.isEmpty { tokens.append(String(gap)) } else { tokens[tokens.count - 1] += gap }
        }
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            appendGap(upTo: range.lowerBound)
            // Leading punctuation, such as an opening quote, stays with this word.
            if let last = tokens.last, last.allSatisfy({ Self.openingPunctuation.contains($0) }) {
                tokens[tokens.count - 1] += text[range]
            } else {
                tokens.append(String(text[range]))
            }
            position = range.upperBound
            return true
        }
        appendGap(upTo: text.endIndex)
        return tokens
    }

    private static let openingPunctuation: Set<Character> = ["「", "『", "（", "(", "【", "〈", "《", "“", "\""]

    /// Chinese particles and suffixes that belong to the word before them.
    private static let chineseParticles: Set<String> = [
        "的", "了", "着", "过", "们", "吗", "呢", "吧", "啊", "地", "得", "么", "嗎", "們", "過", "著", "麼",
    ]
    /// Numbers and demonstratives that take a measure word (一个, 这部).
    private static let chineseCounters: Set<Character> = Set("一二三四五六七八九十百千万两几这那每哪某萬兩幾這")

    /// Joins tokens into units a line may break between: in Japanese, words
    /// followed by their hiragana particles and endings (映画祭が, 始まりました)
    /// and compounds of kanji or katakana; in Chinese, words with their
    /// particles and measure words.
    private static func merge(_ tokens: [String], script: TranscriptScript) -> [String] {
        let maximumLength = script == .japanese ? 8 : 6
        var units: [String] = []
        var lastToken = ""
        for token in tokens {
            defer { lastToken = token }
            guard let unit = units.last, unit.count + token.count <= maximumLength,
                  !TranscriptWord(text: unit, start: 0, end: 0).endsSentenceOrClause else {
                units.append(token)
                continue
            }
            let attaches: Bool
            if script == .japanese {
                let kind = japaneseKind(token)
                attaches = kind == .hiragana || (kind != .other && kind == japaneseKind(lastToken))
            } else {
                attaches = chineseParticles.contains(token.filter { !$0.isPunctuation })
                    || (token.count == 1 && unit.allSatisfy { chineseCounters.contains($0) })
            }
            if attaches { units[units.count - 1] += token } else { units.append(token) }
        }
        return units
    }

    private enum JapaneseKind { case hiragana, katakana, kanji, other }

    private static func japaneseKind(_ token: String) -> JapaneseKind {
        let letters = token.filter { !$0.isPunctuation }
        guard !letters.isEmpty else { return .other }
        func all(_ range: ClosedRange<UInt32>, or extra: Set<UInt32> = []) -> Bool {
            letters.unicodeScalars.allSatisfy { range.contains($0.value) || extra.contains($0.value) }
        }
        if all(0x3041...0x309F) { return .hiragana }
        // ー (U+30FC) lengthens katakana.
        if all(0x30A0...0x30FF) { return .katakana }
        if letters.allSatisfy({ $0.cjkScript == .han }) { return .kanji }
        return .other
    }
}
