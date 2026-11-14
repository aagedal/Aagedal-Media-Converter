// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import Foundation

/// Contents of `aligner.json`, written by `scripts/convert-wav2vec2-coreml.py`.
struct WordAlignerManifest: Codable, Sendable, Equatable {
    let format: Int
    let id: String
    let sourceRepository: String
    let license: String
    let languages: [String]
    let sampleRate: Int
    let maximumSeconds: Double
    let normalizeAudio: Bool
    let blankTokenID: Int
    let wordDelimiter: String?
    let lowercase: Bool
    let vocabulary: [String: Int]
}

/// Plans the audio windows that words are aligned in. Each window holds up to
/// `maximumWindow` seconds of words and reaches at most `padding` beyond them,
/// never into a neighbouring window, so speech from one window cannot pull
/// words in another.
enum WordAlignmentPlanner {
    struct Window: Equatable {
        var words: Range<Int>
        var start: Double
        var end: Double
    }

    static func windows(
        for words: [TranscriptWord],
        duration: Double,
        maximumWindow: Double = 20,
        splitPause: Double = 1.0,
        padding: Double = 1.0
    ) -> [Window] {
        guard !words.isEmpty else { return [] }
        var groups: [Range<Int>] = []
        var groupStart = 0
        for index in 1..<max(words.count, 1) {
            let pause = words[index].start - words[index - 1].end
            let length = words[index].end - words[groupStart].start
            // Prefer pauses and sentence ends; cut anywhere when a window is full.
            let sentenceBreak = words[index - 1].endsSentence && length > maximumWindow / 2
            if pause >= splitPause || sentenceBreak || length > maximumWindow {
                groups.append(groupStart..<index)
                groupStart = index
            }
        }
        groups.append(groupStart..<words.count)

        return groups.enumerated().map { position, range in
            let first = words[range.lowerBound].start
            let last = words[range.upperBound - 1].end
            var start = max(0, first - padding)
            var end = min(duration, last + padding)
            if position > 0 {
                let previousEnd = words[groups[position - 1].upperBound - 1].end
                start = max(start, (previousEnd + first) / 2)
            }
            if position + 1 < groups.count {
                let nextStart = words[groups[position + 1].lowerBound].start
                end = min(end, (last + nextStart) / 2)
            }
            return Window(words: range, start: min(start, first), end: max(end, last))
        }
    }
}

/// Refines word times with a wav2vec2 CTC model converted to Core ML.
final class Wav2Vec2WordAligner {
    static let modelFileName = "Wav2Vec2CTC.mlmodelc"
    static let manifestFileName = "aligner.json"

    let manifest: WordAlignerManifest
    private let model: MLModel
    private let aligner: CTCForcedAligner

    init(directory: URL) throws {
        manifest = try JSONDecoder().decode(
            WordAlignerManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent(Self.manifestFileName))
        )
        let configuration = MLModelConfiguration()
        // Inputs vary in length; the GPU handles that without recompiling for
        // each shape as the Neural Engine would.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(
            contentsOf: directory.appendingPathComponent(Self.modelFileName),
            configuration: configuration
        )
        aligner = CTCForcedAligner(
            vocabulary: manifest.vocabulary,
            blankTokenID: manifest.blankTokenID,
            wordDelimiter: manifest.wordDelimiter,
            lowercase: manifest.lowercase
        )
    }

    /// Returns `words` with refined times. Windows the model cannot align keep
    /// their original times.
    func align(
        _ words: [TranscriptWord],
        audio: PCMWaveFile,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TranscriptWord] {
        guard audio.sampleRate == manifest.sampleRate else { throw PCMWaveFile.FormatError.unsupported }
        let windows = WordAlignmentPlanner.windows(
            for: words,
            duration: audio.duration,
            maximumWindow: min(20, manifest.maximumSeconds - 4)
        )
        var result = words
        for (position, window) in windows.enumerated() {
            try Task.checkCancellation()
            progress(Double(position) / Double(max(windows.count, 1)))
            let firstSample = audio.sampleIndex(at: window.start)
            let lastSample = audio.sampleIndex(at: min(window.end, window.start + manifest.maximumSeconds))
            // The convolutional front end needs at least a few frames of audio.
            guard lastSample - firstSample >= manifest.sampleRate / 2 else { continue }
            var samples = audio.floatSamples(firstSample..<lastSample)
            if manifest.normalizeAudio { Self.normalize(&samples) }

            let (logProbabilities, frames, vocabularySize) = try await emissions(for: samples)
            let windowWords = Array(words[window.words])
            let secondsPerFrame = Double(samples.count) / Double(frames) / Double(manifest.sampleRate)
            guard let ranges = aligner.align(
                words: windowWords.map(\.text),
                logProbabilities: logProbabilities,
                frameCount: frames,
                vocabularySize: vocabularySize,
                secondsPerFrame: secondsPerFrame
            ) else { continue }
            let offset = Double(firstSample) / Double(manifest.sampleRate)
            let aligned = CTCForcedAligner.merge(ranges, into: windowWords, offset: offset)
            result.replaceSubrange(window.words, with: aligned)
        }
        progress(1)
        return result
    }

    private func emissions(for samples: [Float]) async throws -> ([Float], Int, Int) {
        let input = MLShapedArray<Float>(scalars: samples, shape: [1, samples.count])
        let features = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLMultiArray(input)]
        )
        let output = try await model.prediction(from: features)
        guard let array = output.featureValue(for: "log_probabilities")?.multiArrayValue,
              array.shape.count == 3 else { throw PCMWaveFile.FormatError.unsupported }
        let shaped = MLShapedArray<Float>(array)
        return (shaped.scalars, shaped.shape[1], shaped.shape[2])
    }

    private static func normalize(_ samples: inout [Float]) {
        let count = Float(samples.count)
        let mean = samples.reduce(0, +) / count
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let scale = 1 / (variance + 1e-7).squareRoot()
        for index in samples.indices { samples[index] = (samples[index] - mean) * scale }
    }
}
