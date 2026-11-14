// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A memory-mapped 16-bit PCM mono WAV file, as FFmpeg writes it for the
/// speech tools. Only the samples a caller asks for are converted.
struct PCMWaveFile: Sendable {
    let sampleRate: Int
    let sampleCount: Int
    private let data: Data
    private let dataOffset: Int

    enum FormatError: Error {
        case unsupported
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { throw FormatError.unsupported }
        var offset = 12
        var sampleRate: Int?
        var payload: (offset: Int, length: Int)?
        while offset + 8 <= data.count, payload == nil {
            let identifier = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = Int(Self.uint32(data, at: offset + 4))
            let body = offset + 8
            if identifier == "fmt " {
                guard body + 16 <= data.count,
                      Self.uint16(data, at: body) == 1,       // PCM
                      Self.uint16(data, at: body + 2) == 1,   // mono
                      Self.uint16(data, at: body + 14) == 16 else { throw FormatError.unsupported }
                sampleRate = Int(Self.uint32(data, at: body + 4))
            } else if identifier == "data" {
                // FFmpeg leaves the length at its maximum when writing to a pipe.
                payload = (body, min(length, data.count - body))
            }
            offset = body + length + (length & 1)
        }
        guard let sampleRate, sampleRate > 0, let payload else { throw FormatError.unsupported }
        self.data = data
        self.sampleRate = sampleRate
        self.dataOffset = payload.offset
        self.sampleCount = payload.length / 2
    }

    var duration: Double { Double(sampleCount) / Double(sampleRate) }

    func sampleIndex(at seconds: Double) -> Int {
        min(max(Int((seconds * Double(sampleRate)).rounded()), 0), sampleCount)
    }

    /// Samples scaled to -1...1.
    func floatSamples(_ range: Range<Int>) -> [Float] {
        let clamped = range.clamped(to: 0..<sampleCount)
        return data.withUnsafeBytes { raw in
            (clamped.lowerBound..<clamped.upperBound).map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(
                    fromByteOffset: dataOffset + index * 2, as: Int16.self
                ))) / 32768
            }
        }
    }

    func rawSamples(_ range: Range<Int>) -> Data {
        let clamped = range.clamped(to: 0..<sampleCount)
        return data.subdata(in: dataOffset + clamped.lowerBound * 2..<dataOffset + clamped.upperBound * 2)
    }

    /// Writes 16-bit mono PCM chunks as one WAV file. Chunks are produced one
    /// at a time, so a long recording is never held in memory at once.
    static func write(_ chunks: some Sequence<Data>, byteCount length: Int, sampleRate: Int, to url: URL) throws {
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + length); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(length)

        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = 0
        for chunk in chunks {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
        guard written == length else { throw FormatError.unsupported }
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

/// Speech found by diarization, joined into the stretches Whisper should hear.
/// Whisper transcribes only these, back to back; `sourceTime` maps its
/// timestamps back onto the original media.
struct SpeechRegionMap: Sendable, Equatable {
    struct Region: Sendable, Equatable {
        var start: Double
        var end: Double
        /// Where the region starts in the speech-only audio.
        var offset: Double
    }

    let regions: [Region]

    /// - Parameters:
    ///   - padding: Kept around each stretch of speech so word edges survive.
    ///   - mergeGap: Shorter pauses stay in, which keeps natural rhythm and
    ///     avoids cutting the audio between closely spaced words.
    init(speech: [ClosedRange<Double>], duration: Double, padding: Double = 0.25, mergeGap: Double = 1.0) {
        var merged: [ClosedRange<Double>] = []
        for range in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let padded = max(0, range.lowerBound - padding)...min(duration, range.upperBound + padding)
            guard padded.upperBound > padded.lowerBound else { continue }
            if let last = merged.last, padded.lowerBound - last.upperBound <= mergeGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, padded.upperBound)
            } else {
                merged.append(padded)
            }
        }
        var offset = 0.0
        regions = merged.map { range in
            defer { offset += range.upperBound - range.lowerBound }
            return Region(start: range.lowerBound, end: range.upperBound, offset: offset)
        }
    }

    var speechDuration: Double { regions.last.map { $0.offset + $0.end - $0.start } ?? 0 }

    func sourceTime(_ time: Double) -> Double {
        guard let region = region(containing: time) else { return time }
        return min(region.start + (time - region.offset), region.end)
    }

    /// Maps words from speech-only time to source time. A word's end stays in
    /// the region its start falls in, so no word stretches across a removed pause.
    func sourceWords(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.map { word in
            guard let region = region(containing: word.start) else { return word }
            var mapped = word
            mapped.start = min(region.start + (word.start - region.offset), region.end)
            mapped.end = min(region.start + (word.end - region.offset), region.end)
            return mapped
        }
    }

    /// Writes the regions of `audio` back to back.
    func writeSpeechAudio(from audio: PCMWaveFile, to url: URL) throws {
        let ranges = regions.map { audio.sampleIndex(at: $0.start)..<audio.sampleIndex(at: $0.end) }
        try PCMWaveFile.write(
            ranges.lazy.map { audio.rawSamples($0) },
            byteCount: ranges.reduce(0) { $0 + $1.count * 2 },
            sampleRate: audio.sampleRate,
            to: url
        )
    }

    private func region(containing time: Double) -> Region? {
        var low = 0
        var high = regions.count - 1
        var match: Region?
        while low <= high {
            let middle = (low + high) / 2
            if regions[middle].offset <= time {
                match = regions[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return match ?? regions.first
    }
}
