// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct SilenceDetectionSettings: Equatable, Sendable {
    var thresholdDBFS: Double = -50
    var minimumDuration: Double = 1

    func validate() throws {
        guard thresholdDBFS.isFinite, thresholdDBFS >= -120, thresholdDBFS <= 0 else {
            throw AnalyticsError.parsingFailed("Silence threshold must be between −120 and 0 dBFS.")
        }
        guard minimumDuration.isFinite, minimumDuration > 0, minimumDuration <= 86_400 else {
            throw AnalyticsError.parsingFailed("Minimum silence duration must be greater than zero and at most 24 hours.")
        }
    }
}

struct SilenceInterval: Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    var duration: Double { end - start }
    var id: Double { start }
}

struct SilenceAnalysisResult: Equatable, Sendable {
    let presentation: LoudnessPresentation
    let settings: SilenceDetectionSettings
    let intervals: [SilenceInterval]
}

/// Decodes the complete selected presentation. All channels must remain below
/// the threshold together; a quiet channel alone is not a silent presentation.
actor SilenceAnalysisService {
    static let shared = SilenceAnalysisService()

    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    init(
        runner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func analyze(
        file: URL,
        presentation: LoudnessPresentation,
        settings: SilenceDetectionSettings = .init()
    ) async throws -> SilenceAnalysisResult {
        try Task.checkCancellation()
        try settings.validate()
        let indices = presentation.streamIndices
        guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count else {
            throw AnalyticsError.parsingFailed("Select distinct, valid audio tracks for silence analysis.")
        }
        if case .surround51 = presentation, indices.count != 6 {
            throw AnalyticsError.parsingFailed("A 5.1 grouping requires exactly six mono tracks.")
        }
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1",
                        "-i", file.path, "-filter_complex", Self.filterGraph(for: presentation, settings: settings),
                        "-map", "[silence]", "-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [path, file.path]
        )
        let collector = SilenceLogCollector()
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Silence analysis failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        return SilenceAnalysisResult(presentation: presentation, settings: settings,
                                     intervals: try collector.finish())
    }

    static func filterGraph(for presentation: LoudnessPresentation, settings: SilenceDetectionSettings) -> String {
        let inputs = presentation.streamIndices.map { "[0:a:\($0)]" }.joined()
        let join: String
        switch presentation {
        case .track: join = ""
        case .stereo: join = "join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR,"
        case .surround51:
            join = "join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,"
        }
        // FFmpeg normalizes the container start timestamp by default. Preserve
        // stream offsets within that file timeline (including delayed audio).
        return "\(inputs)\(join)asetpts=PTS,"
            + "silencedetect=noise=\(settings.thresholdDBFS)dB:duration=\(settings.minimumDuration):mono=0[silence]"
    }
}

/// Consume the live stream rather than the runner's bounded diagnostic tail:
/// long files can produce more silence events than that tail retains.
final class SilenceLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stderrPending = ""
    private var stdoutPending = ""
    private var intervals: [SilenceInterval] = []
    private var start: Double?
    private var invalid = false
    private var completed = false
    private var decodedAudio = false

    func consume(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        defer { lock.unlock() }
        switch chunk.stream {
        case .standardError:
            stderrPending += String(decoding: chunk.data, as: UTF8.self)
            drain(&stderrPending, stderr: true)
        case .standardOutput:
            stdoutPending += String(decoding: chunk.data, as: UTF8.self)
            drain(&stdoutPending, stderr: false)
        }
    }

    func finish() throws -> [SilenceInterval] {
        lock.lock()
        defer { lock.unlock() }
        // A partial final event/progress line is not evidence of completion.
        guard !invalid, start == nil, completed, decodedAudio,
              !stderrPending.contains("silence_"), stdoutPending.isEmpty else {
            throw AnalyticsError.parsingFailed("Silence analysis did not produce a complete audio report. Retry with a readable audio track.")
        }
        return intervals
    }

    private func drain(_ pending: inout String, stderr: Bool) {
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            parse(line, stderr: stderr)
        }
        // Diagnostics should be short lines. Bound malformed output as well.
        if pending.utf8.count > 64 * 1024 { invalid = true; pending = "" }
    }

    private func parse(_ line: String, stderr: Bool) {
        if !stderr {
            if line == "progress=end" { completed = true }
            if line.hasPrefix("out_time_us="), let time = Double(line.dropFirst("out_time_us=".count)), time.isFinite, time > 0 {
                decodedAudio = true
            }
            return
        }
        guard line.contains("silencedetect"), line.contains("silence_") else { return }
        if line.contains("silence_start:") {
            guard let value = number(after: "silence_start:", in: line), value >= 0,
                  start == nil, value >= (intervals.last?.end ?? 0) else { invalid = true; return }
            start = value
        } else if line.contains("silence_end:") {
            guard let value = number(after: "silence_end:", in: line), let start,
                  let duration = number(after: "silence_duration:", in: line), duration > 0,
                  value > start, abs((value - start) - duration) <= max(0.001, value * 0.00002) else {
                invalid = true
                return
            }
            intervals.append(SilenceInterval(start: start, end: value))
            self.start = nil
        } else { invalid = true }
    }

    private func number(after marker: String, in line: String) -> Double? {
        guard let range = line.range(of: marker),
              let token = line[range.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "|" }).first,
              let value = Double(token), value.isFinite else { return nil }
        return value
    }
}
