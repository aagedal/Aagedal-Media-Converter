// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct SpeakerSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var speaker: Int
}

/// Finds who speaks when with the bundled NeMo Speech runtime and NVIDIA's
/// Nemotron 3 Diarization model (Sortformer v3, up to eight speakers). When
/// speaker changes are on and Silero cannot run, the Whisper pipeline also
/// uses these segments for speech-only audio.
struct SpeakerDiarizer: Sendable {
    static let model = "nemotron-3-diarization"
    static let timeout: Duration = .seconds(2 * 60 * 60)

    let subprocessRunner: any SubprocessRunning
    let executablePath: String

    /// Whether NeMo Speech has cached the model in its default location.
    static var isModelCached: Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        return isModelCached(in: caches)
    }

    /// NeMo Speech creates the model folder before downloading and writes a
    /// `.verified` file next to the GGUF only once its checksum matches, so a
    /// cancelled or failed pull does not count.
    static func isModelCached(in caches: URL) -> Bool {
        let model = caches.appendingPathComponent("NeMoSpeech/models/nvidia/Nemotron-3-Diarization")
        let fileManager = FileManager.default
        guard let revisions = try? fileManager.contentsOfDirectory(at: model, includingPropertiesForKeys: nil) else {
            return false
        }
        return revisions.contains { revision in
            let files = (try? fileManager.contentsOfDirectory(atPath: revision.path)) ?? []
            return files.contains { $0.hasSuffix(".gguf.verified") }
        }
    }

    /// Downloads and verifies the model ahead of the first run.
    static func pullModel(executablePath: String, runner: any SubprocessRunning = SubprocessRunner()) async throws {
        try await NemotronCLITranscriber.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: ["pull", model],
            timeout: .seconds(60 * 60),
            standardOutputCaptureLimit: 64 * 1024,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [executablePath]
        ), using: runner)
    }

    func diarize(audio: URL, outputFile: URL) async throws -> [SpeakerSegment] {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: ["diarize", audio.path, "--model", Self.model,
                        "--format", "json", "--output", outputFile.path, "--force", "--quiet"],
            timeout: Self.timeout,
            standardOutputCaptureLimit: 64 * 1024,
            standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: [audio.path, outputFile.path, executablePath]
        )
        try await NemotronCLITranscriber.run(request, using: subprocessRunner)
        return try Self.parse(Data(contentsOf: outputFile))
    }

    /// Reads `{"segments":[{"start":s,"end":s,"speaker":n}]}`.
    static func parse(_ data: Data) throws -> [SpeakerSegment] {
        struct Output: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let speaker: Int
            }
            let segments: [Segment]
        }
        return try JSONDecoder().decode(Output.self, from: data).segments
            .filter { $0.end > $0.start }
            .map { SpeakerSegment(start: $0.start, end: $0.end, speaker: $0.speaker) }
            .sorted { $0.start < $1.start }
    }

    /// Gives each word the speaker whose segments overlap it most, or the
    /// nearest segment within `tolerance`. Speakers are renumbered 0, 1, … in
    /// the order they are first heard.
    static func assignSpeakers(
        to words: [TranscriptWord],
        segments: [SpeakerSegment],
        tolerance: Double = 0.5
    ) -> [TranscriptWord] {
        guard !segments.isEmpty else { return words }
        let longest = segments.map { $0.end - $0.start }.max() ?? 0
        var order: [Int: Int] = [:]
        return words.map { word in
            var result = word
            // Segments are sorted by start; only those starting before the word
            // ends and not ending long before it begins can matter.
            // The lower bound gets a millisecond of slack so a segment exactly
            // `tolerance` away is not lost to rounding or the strict search.
            let upper = firstIndex(in: segments, startingAfter: word.end + tolerance)
            let lower = firstIndex(in: segments, startingAfter: word.start - longest - tolerance - 0.001)
            var overlap: [Int: Double] = [:]
            var nearest: (distance: Double, speaker: Int)?
            for segment in segments[lower..<upper] {
                let shared = min(segment.end, word.end) - max(segment.start, word.start)
                if shared > 0 {
                    overlap[segment.speaker, default: 0] += shared
                } else {
                    let distance = max(segment.start - word.end, word.start - segment.end)
                    if distance <= tolerance, distance < (nearest?.distance ?? .infinity) {
                        nearest = (distance, segment.speaker)
                    }
                }
            }
            let speaker = overlap.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
                ?? nearest?.speaker
            if let speaker {
                if order[speaker] == nil { order[speaker] = order.count }
                result.speaker = order[speaker]
            }
            return result
        }
    }

    private static func firstIndex(in segments: [SpeakerSegment], startingAfter time: Double) -> Int {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
