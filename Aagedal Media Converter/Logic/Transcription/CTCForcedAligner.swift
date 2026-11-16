// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finds where known text occurs in a CTC model's per-frame character
/// probabilities (forced alignment, as in WhisperX). The model supplies the
/// emissions; this type only maps text to tokens and runs Viterbi over them.
struct CTCForcedAligner: Sendable {
    let vocabulary: [String: Int]
    let blankTokenID: Int
    let wordDelimiterID: Int?
    let lowercase: Bool

    init(vocabulary: [String: Int], blankTokenID: Int, wordDelimiter: String?, lowercase: Bool) {
        self.vocabulary = vocabulary
        self.blankTokenID = blankTokenID
        self.wordDelimiterID = wordDelimiter.flatMap { vocabulary[$0] }
        self.lowercase = lowercase
    }

    /// Letters some training sets spelled out; the German model, for one, has
    /// no ß because its transcripts wrote "ss".
    private static let spelledOut: [String: String] = ["ß": "ss", "æ": "ae", "œ": "oe"]

    /// Characters of `word` the model can emit. Letters the vocabulary lacks
    /// fall back to their base letter (é → e), their spelled-out form (ß → ss)
    /// and, for Traditional Chinese characters, to Simplified (電 → 电);
    /// anything else, such as digits or punctuation, is skipped. Kana keep
    /// their voicing marks (が never becomes か).
    func tokens(for word: String) -> [Int] {
        var text = (lowercase ? word.lowercased() : word.uppercased()).precomposedStringWithCanonicalMapping
        // Half-width katakana write voicing as a separate character (ｶﾞ), so
        // they are widened as a whole before characters are looked up.
        if text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) {
            text = text.folding(options: .widthInsensitive, locale: nil)
        }
        return text.flatMap { character -> [Int] in
            let key = String(character)
            if let id = token(key) { return [id] }
            let base = key.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            if base != key, let id = token(base) { return [id] }
            if let spelled = Self.spelledOut[key.lowercased()] {
                let letters = (lowercase ? spelled : spelled.uppercased()).map { token(String($0)) }
                if letters.allSatisfy({ $0 != nil }) { return letters.compactMap { $0 } }
            }
            if character.cjkScript == .han,
               let simplified = key.applyingTransform(StringTransform("Hant-Hans"), reverse: false),
               simplified != key, let id = token(simplified) {
                return [id]
            }
            return []
        }
    }

    private func token(_ key: String) -> Int? {
        guard let id = vocabulary[key], id != blankTokenID, id != wordDelimiterID else { return nil }
        return id
    }

    /// Aligns `words` against `frameCount` × `vocabularySize` log probabilities
    /// (row-major). Returns one time range per word, in seconds relative to the
    /// first frame, or nil for words with nothing the model can emit. Returns
    /// nil overall when the text cannot fit in the frames.
    func align(
        words: [String],
        logProbabilities: [Float],
        frameCount: Int,
        vocabularySize: Int,
        secondsPerFrame: Double
    ) -> [ClosedRange<Double>?]? {
        precondition(logProbabilities.count >= frameCount * vocabularySize)
        // Token sequence with the owning word for each token.
        var sequence: [Int] = []
        var owners: [Int?] = []
        var previousWord: String?
        for (index, word) in words.enumerated() {
            let wordTokens = tokens(for: word)
            guard !wordTokens.isEmpty else { continue }
            // Japanese and Chinese models never heard a delimiter between
            // words, so it is only placed where the text has a space.
            if let delimiter = wordDelimiterID, let previousWord,
               !TranscriptText.separator(between: previousWord, and: word).isEmpty {
                sequence.append(delimiter)
                owners.append(nil)
            }
            sequence += wordTokens
            owners += Array(repeating: index, count: wordTokens.count)
            previousWord = word
        }
        guard !sequence.isEmpty else { return Array(repeating: nil, count: words.count) }
        guard let path = viterbi(
            sequence, logProbabilities: logProbabilities,
            frameCount: frameCount, vocabularySize: vocabularySize
        ) else { return nil }

        var ranges = [ClosedRange<Double>?](repeating: nil, count: words.count)
        for (tokenIndex, frames) in path.enumerated() {
            guard let word = owners[tokenIndex] else { continue }
            let start = Double(frames.lowerBound) * secondsPerFrame
            let end = Double(frames.upperBound + 1) * secondsPerFrame
            if let existing = ranges[word] {
                ranges[word] = min(existing.lowerBound, start)...max(existing.upperBound, end)
            } else {
                ranges[word] = start...end
            }
        }
        return ranges
    }

    /// Standard CTC Viterbi over the blank-interleaved sequence. Returns, for
    /// each token, the frames in which the best path emits it.
    private func viterbi(
        _ tokens: [Int],
        logProbabilities: [Float],
        frameCount: Int,
        vocabularySize: Int
    ) -> [ClosedRange<Int>]? {
        let states = tokens.count * 2 + 1
        var minimumFrames = tokens.count
        for index in 1..<tokens.count where tokens[index] == tokens[index - 1] { minimumFrames += 1 }
        guard frameCount >= minimumFrames else { return nil }

        func label(_ state: Int) -> Int { state % 2 == 0 ? blankTokenID : tokens[state / 2] }

        let negativeInfinity = -Float.infinity
        var previous = [Float](repeating: negativeInfinity, count: states)
        var current = previous
        // 0: stay, 1: from state-1, 2: from state-2.
        var steps = [UInt8](repeating: 0, count: frameCount * states)

        previous[0] = logProbabilities[blankTokenID]
        if states > 1 { previous[1] = logProbabilities[label(1)] }

        for frame in 1..<max(frameCount, 1) {
            let row = frame * vocabularySize
            // Only states that can still reach the end in the frames left matter.
            let firstState = max(0, states - 2 * (frameCount - frame) - 1)
            let lastState = min(states - 1, 2 * frame + 1)
            for index in current.indices { current[index] = negativeInfinity }
            for state in firstState...lastState {
                var best = previous[state]
                var step: UInt8 = 0
                if state >= 1, previous[state - 1] > best {
                    best = previous[state - 1]
                    step = 1
                }
                if state >= 2, state % 2 == 1, tokens[state / 2] != tokens[state / 2 - 1],
                   previous[state - 2] > best {
                    best = previous[state - 2]
                    step = 2
                }
                guard best > negativeInfinity else { continue }
                current[state] = best + logProbabilities[row + label(state)]
                steps[frame * states + state] = step
            }
            swap(&previous, &current)
        }

        var state = states > 1 && previous[states - 2] > previous[states - 1] ? states - 2 : states - 1
        guard previous[state] > negativeInfinity else { return nil }
        var spans = [ClosedRange<Int>?](repeating: nil, count: tokens.count)
        for frame in stride(from: frameCount - 1, through: 0, by: -1) {
            if state % 2 == 1 {
                let token = state / 2
                spans[token] = spans[token].map { frame...$0.upperBound } ?? frame...frame
            }
            guard frame > 0 else { break }
            state -= Int(steps[frame * states + state])
        }
        let resolved = spans.compactMap { $0 }
        return resolved.count == tokens.count ? resolved : nil
    }
}

extension CTCForcedAligner {
    /// Gives words the model could not place (numbers, symbols) the gap between
    /// their aligned neighbours, falling back to their original times.
    static func merge(
        _ ranges: [ClosedRange<Double>?],
        into words: [TranscriptWord],
        offset: Double
    ) -> [TranscriptWord] {
        var result = words
        for (index, range) in ranges.enumerated() {
            guard let range else { continue }
            result[index].start = range.lowerBound + offset
            result[index].end = range.upperBound + offset
        }
        var index = 0
        while index < result.count {
            guard ranges[index] == nil else { index += 1; continue }
            var runEnd = index
            while runEnd + 1 < result.count, ranges[runEnd + 1] == nil { runEnd += 1 }
            let lower = index > 0 ? result[index - 1].end : nil
            let upper = runEnd + 1 < result.count ? result[runEnd + 1].start : nil
            if let lower, let upper, upper > lower {
                let share = (upper - lower) / Double(runEnd - index + 1)
                for position in index...runEnd {
                    result[position].start = lower + share * Double(position - index)
                    result[position].end = result[position].start + share
                }
            } else {
                for position in index...runEnd {
                    if let lower { result[position].start = max(result[position].start, lower) }
                    if let upper { result[position].end = min(result[position].end, upper) }
                    result[position].end = max(result[position].end, result[position].start)
                }
            }
            index = runEnd + 1
        }
        return result
    }
}
