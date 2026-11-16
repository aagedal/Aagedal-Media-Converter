// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How speaker changes appear in subtitles once diarization has run.
enum SubtitleSpeakerStyle: String, CaseIterable, Codable, Sendable {
    /// No diarization.
    case off
    /// Broadcast style: a cue that holds two speakers puts each on its own
    /// line, both starting with "– ". A new speaker otherwise starts a new cue.
    case dashes
    /// Every change of speaker starts a new cue prefixed with the speaker's name.
    case names
}

struct SubtitleCue: Sendable, Equatable {
    var start: Double
    var end: Double
    var lines: [String]
}

/// Groups timed words into readable subtitle cues. Engines no longer decide cue
/// boundaries; one implementation applies line length, reading time and
/// speaker rules to every word-level transcript.
struct SubtitleCueBuilder: Sendable {
    var maxLineLength = AppConstants.defaultWhisperMaxLineLength
    var maxLines = 2
    var maxDuration = 7.0
    var minDuration = 1.0
    /// Pauses longer than this always end the cue.
    var maxPauseInCue = 1.2
    var minGapBetweenCues = 0.08
    var charactersPerSecond = 17.0
    var speakerStyle: SubtitleSpeakerStyle = .off
    var speakerName: @Sendable (Int) -> String = { "\($0 + 1)" }

    static let dialogueDash = "– "

    func cues(for words: [TranscriptWord]) -> [SubtitleCue] {
        var previousSpeaker: Int?
        var cues = group(words.filter { !$0.text.isEmpty }).map { words in
            let speaker = words.lazy.compactMap(\.speaker).first
            // Name a speaker only when the voice changes, not on every cue.
            defer { previousSpeaker = words.last(where: { $0.speaker != nil })?.speaker ?? previousSpeaker }
            return layout(words, naming: speaker != nil && speaker != previousSpeaker)
        }
        applyTiming(&cues)
        return cues
    }

    func srt(for words: [TranscriptWord]) -> String {
        Self.srt(cues(for: words))
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000, milliseconds / 60_000 % 60,
            milliseconds / 1000 % 60, milliseconds % 1000
        )
    }

    // MARK: - Grouping

    private var lineLength: Int { max(maxLineLength, 10) }
    private var dialogueLineLength: Int { lineLength - Self.dialogueDash.count }

    private func group(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []

        func close() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }

        for (index, word) in words.enumerated() {
            switch breakBefore(word, in: current, replyLength: replyLength(startingAt: index, in: words)) {
            case .none:
                break
            case .hard:
                close()
            case .full:
                // Move the words after the last clause end into the next cue
                // rather than splitting mid-phrase, if enough text stays behind.
                if let clauseEnd = current.lastIndex(where: { $0.endsSentence || $0.endsClause }),
                   length(of: current[...clauseEnd]) >= lineLength {
                    groups.append(Array(current[...clauseEnd]))
                    current = Array(current[(clauseEnd + 1)...])
                    if breakBefore(word, in: current, replyLength: nil) != .none { close() }
                } else {
                    close()
                }
            }
            current.append(word)
            if shouldCloseAfter(current, next: words.indices.contains(index + 1) ? words[index + 1] : nil) {
                close()
            }
        }
        close()
        return groups
    }

    private enum Break {
        case none
        /// A pause or change of speaker.
        case hard
        /// The cue has no room for the word.
        case full
    }

    /// The length of the turn that starts at `index` if a new speaker starts
    /// there: their words until the voice changes again or they pause.
    private func replyLength(startingAt index: Int, in words: [TranscriptWord]) -> Int? {
        guard speakerStyle == .dashes, let speaker = words[index].speaker,
              let previous = words[..<index].last(where: { $0.speaker != nil })?.speaker,
              previous != speaker else { return nil }
        var end = index
        while end + 1 < words.count, words[end + 1].speaker ?? speaker == speaker,
              words[end + 1].start - words[end].end <= maxPauseInCue {
            end += 1
        }
        return length(of: words[index...end])
    }

    private func breakBefore(_ word: TranscriptWord, in cue: [TranscriptWord], replyLength: Int?) -> Break {
        guard let first = cue.first, let last = cue.last else { return .none }
        if word.start - last.end > maxPauseInCue { return .hard }
        let candidate = cue + [word]
        let turns = speakerTurns(candidate)
        if turns.count > 1 {
            switch speakerStyle {
            case .off: break
            case .names: return .hard
            case .dashes:
                // A dialogue cue holds exactly two turns of one line each,
                // and only a reply that fits there whole.
                guard turns.count == 2,
                      turns.allSatisfy({ length(of: $0) <= dialogueLineLength }),
                      (replyLength ?? 0) <= dialogueLineLength else { return .hard }
                return word.end - first.start > maxDuration ? .hard : .none
            }
        }
        if word.end - first.start > maxDuration { return .full }
        let fits = layoutLines(candidate.map(\.text), width: lineLength, firstLineIndent: prefixLength(for: candidate)) != nil
        return fits ? .none : .full
    }

    /// Prefer ending cues at the end of a sentence or clause once they hold
    /// enough text to read comfortably on their own. A short line followed by
    /// another speaker stays open so the reply can share the cue as dialogue.
    private func shouldCloseAfter(_ cue: [TranscriptWord], next: TranscriptWord?) -> Bool {
        guard let last = cue.last else { return false }
        if speakerStyle == .dashes, let next, let speaker = next.speaker,
           let current = cue.last(where: { $0.speaker != nil })?.speaker, speaker != current,
           speakerTurns(cue).count == 1, length(of: cue) <= dialogueLineLength,
           next.start - last.end <= maxPauseInCue {
            return false
        }
        let characters = length(of: cue)
        if last.endsSentence { return characters >= lineLength / 2 }
        if last.endsClause { return characters >= lineLength * 3 / 2 }
        return false
    }

    // MARK: - Layout

    private func layout(_ words: [TranscriptWord], naming: Bool) -> SubtitleCue {
        let turns = speakerTurns(words)
        let lines: [String]
        if speakerStyle == .dashes, turns.count == 2 {
            lines = turns.map { Self.dialogueDash + $0.map(\.text).joined(separator: " ") }
        } else {
            let texts = words.map(\.text)
            let indent = naming ? prefixLength(for: words) : 0
            var laidOut = layoutLines(texts, width: lineLength, firstLineIndent: indent)
                ?? [texts.joined(separator: " ")]
            if speakerStyle == .names, naming, let speaker = words.lazy.compactMap(\.speaker).first {
                laidOut[0] = speakerName(speaker) + ": " + laidOut[0]
            }
            lines = laidOut
        }
        return SubtitleCue(start: words.first?.start ?? 0, end: words.last?.end ?? 0, lines: lines)
    }

    /// Splits words into at most `maxLines` lines no longer than `width`,
    /// choosing the most balanced break and favouring breaks after punctuation.
    /// The first line also leaves room for a prefix such as a speaker name.
    /// Returns nil when the words cannot fit. A single overlong word is allowed
    /// on a line of its own.
    func layoutLines(_ words: [String], width: Int, firstLineIndent: Int = 0) -> [String]? {
        let joined = words.joined(separator: " ")
        if joined.count + firstLineIndent <= width || words.count == 1 { return [joined] }
        guard maxLines >= 2 else { return nil }
        var best: (score: Double, lines: [String])?
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            guard first.count + firstLineIndent <= width, second.count <= width else { continue }
            var score = Double(abs(first.count + firstLineIndent - second.count))
            if let last = words[split - 1].last, ".?!…,;:".contains(last) { score -= Double(width) / 2 }
            // Bottom-heavy lines are easier to read than top-heavy ones.
            if first.count > second.count { score += 2 }
            if best == nil || score < best!.score { best = (score, [first, second]) }
        }
        return best?.lines
    }

    /// Consecutive runs of one speaker. Words without a speaker stay with the
    /// surrounding turn.
    private func speakerTurns(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var turns: [[TranscriptWord]] = []
        var currentSpeaker: Int?
        for word in words {
            if let speaker = word.speaker, let current = currentSpeaker, speaker != current {
                turns.append([word])
            } else if turns.isEmpty {
                turns.append([word])
            } else {
                turns[turns.count - 1].append(word)
            }
            currentSpeaker = word.speaker ?? currentSpeaker
        }
        return turns
    }

    private func prefixLength(for words: [TranscriptWord]) -> Int {
        guard speakerStyle == .names, let speaker = words.lazy.compactMap(\.speaker).first else { return 0 }
        return speakerName(speaker).count + 2
    }

    private func length(of words: some Collection<TranscriptWord>) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(words.count - 1, 0)
    }

    // MARK: - Timing

    /// Gives each cue enough time to be read without overlapping the next one.
    private func applyTiming(_ cues: inout [SubtitleCue]) {
        for index in cues.indices {
            let characters = cues[index].lines.reduce(0) { $0 + $1.count }
            let readable = min(max(minDuration, Double(characters) / charactersPerSecond), maxDuration)
            var end = max(cues[index].end, cues[index].start + readable)
            if index + 1 < cues.count {
                end = min(end, cues[index + 1].start - minGapBetweenCues)
            }
            // Overlapping speech can leave no room at all; keep at least a frame.
            cues[index].end = max(end, cues[index].start + 0.04)
        }
    }
}
