// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct BlackDetectionSettings: Codable, Equatable, Sendable {
    var minimumDuration: Double = 0.5
    /// FFmpeg `pic_th`: share of pixels that must be black for a black picture.
    var pictureBlackRatio: Double = 0.98
    /// FFmpeg `pix_th`: luma threshold for a black pixel, as a fraction of the range.
    var pixelThreshold: Double = 0.10

    func validate() throws {
        guard minimumDuration.isFinite, minimumDuration > 0, minimumDuration <= 86_400 else {
            throw AnalyticsError.parsingFailed("Minimum black duration must be greater than zero and at most 24 hours.")
        }
        guard pictureBlackRatio.isFinite, pictureBlackRatio > 0, pictureBlackRatio <= 1 else {
            throw AnalyticsError.parsingFailed("The black picture ratio must be greater than 0 and at most 1.")
        }
        guard pixelThreshold.isFinite, pixelThreshold >= 0, pixelThreshold <= 1 else {
            throw AnalyticsError.parsingFailed("The black pixel threshold must be between 0 and 1.")
        }
    }
}

struct BlackInterval: Codable, Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    var duration: Double { end - start }
    var id: Double { start }

    private enum CodingKeys: String, CodingKey { case start, end, duration }

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        let reportedDuration = try values.decode(Double.self, forKey: .duration)
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              reportedDuration.isFinite, reportedDuration == duration else {
            throw DecodingError.dataCorruptedError(forKey: .duration, in: values,
                                                   debugDescription: "Invalid black interval or duration.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(duration, forKey: .duration)
    }
}

struct BlackDetectionResult: Codable, Equatable, Sendable {
    let settings: BlackDetectionSettings
    let intervals: [BlackInterval]
}

struct SceneCutSettings: Codable, Equatable, Sendable {
    /// FFmpeg `scdet` threshold on its 0–100 scene change score.
    var threshold: Double = 10

    func validate() throws {
        guard threshold.isFinite, threshold > 0, threshold <= 100 else {
            throw AnalyticsError.parsingFailed("The scene cut threshold must be greater than 0 and at most 100.")
        }
    }
}

struct SceneCut: Codable, Equatable, Sendable, Identifiable {
    /// File-relative time of the first frame after the cut.
    let time: Double
    let score: Double
    var id: Double { time }
}

struct SceneCutResult: Codable, Equatable, Sendable {
    let settings: SceneCutSettings
    let cuts: [SceneCut]
}

/// Scene cut report plus one thumbnail per cut, when thumbnails were requested.
struct SceneCutAnalysisOutput: Sendable {
    let result: SceneCutResult
    /// Empty, or exactly one JPEG per cut in cut order.
    let thumbnails: [URL]
}

/// Detects black intervals and scene cuts in the first video stream of a source
/// file. Both scans decode the complete file; trims and conversion settings are
/// not applied, matching silence analysis.
actor VideoEventAnalysisService {
    static let shared = VideoEventAnalysisService()

    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    init(
        runner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func detectBlack(
        file: URL,
        settings: BlackDetectionSettings = .init(),
        durationSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> BlackDetectionResult {
        try Task.checkCancellation()
        try settings.validate()
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1",
                        "-i", file.path, "-filter_complex", Self.blackFilterGraph(settings: settings),
                        "-map", "[black]", "-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [path, file.path]
        )
        let collector = VideoEventLogCollector(kind: .black)
        let result = try await runner.run(request) { chunk in
            if let seconds = collector.consume(chunk) {
                progress(Self.fraction(seconds, of: durationSeconds))
            }
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Black detection failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        return BlackDetectionResult(settings: settings, intervals: try collector.finishBlack())
    }

    /// Writes thumbnails to `thumbnailDirectory` when given. The caller owns that
    /// directory; failed or cancelled scans remove any thumbnails they wrote.
    func detectSceneCuts(
        file: URL,
        settings: SceneCutSettings = .init(),
        durationSeconds: Double? = nil,
        thumbnailDirectory: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SceneCutAnalysisOutput {
        try Task.checkCancellation()
        try settings.validate()
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        var arguments = ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1",
                         "-i", file.path, "-filter_complex",
                         Self.sceneCutFilterGraph(settings: settings, thumbnails: thumbnailDirectory != nil),
                         "-map", "[cuts]", "-f", "null", "-"]
        var thumbnailPattern: URL?
        if let thumbnailDirectory {
            try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            let pattern = thumbnailDirectory.appendingPathComponent("cut_%05d.jpg")
            thumbnailPattern = pattern
            arguments += ["-map", "[thumbnails]", "-fps_mode", "passthrough", "-q:v", "4", "-f", "image2", pattern.path]
        }
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: Set([path, file.path] + (thumbnailPattern.map { [$0.path] } ?? []))
        )
        let collector = VideoEventLogCollector(kind: .sceneCuts)
        let cuts: [SceneCut]
        do {
            let result = try await runner.run(request) { chunk in
                if let seconds = collector.consume(chunk) {
                    progress(Self.fraction(seconds, of: durationSeconds))
                }
            }
            try Task.checkCancellation()
            guard result.succeeded else {
                throw AnalyticsError.parsingFailed("Scene cut detection failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
            }
            cuts = try collector.finishSceneCuts()
        } catch {
            if let thumbnailDirectory { Self.removeThumbnails(in: thumbnailDirectory) }
            throw error
        }
        var thumbnails: [URL] = []
        if let thumbnailDirectory {
            // The first image is the opening frame, which keeps the encoder fed when
            // a file has no cuts. Thumbnails are optional: a mismatch drops them all.
            let images = (0...cuts.count).map { Self.thumbnailURL(in: thumbnailDirectory, number: $0 + 1) }
            try? FileManager.default.removeItem(at: images[0])
            let extra = Self.thumbnailURL(in: thumbnailDirectory, number: cuts.count + 2)
            if images.dropFirst().allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
               !FileManager.default.fileExists(atPath: extra.path) {
                thumbnails = Array(images.dropFirst())
            } else {
                Self.removeThumbnails(in: thumbnailDirectory)
            }
        }
        return SceneCutAnalysisOutput(result: SceneCutResult(settings: settings, cuts: cuts), thumbnails: thumbnails)
    }

    static func blackFilterGraph(settings: BlackDetectionSettings) -> String {
        // `V` skips attached pictures such as cover art.
        "[0:V:0]blackdetect=d=\(settings.minimumDuration):pic_th=\(settings.pictureBlackRatio):pix_th=\(settings.pixelThreshold)[black]"
    }

    static func sceneCutFilterGraph(settings: SceneCutSettings, thumbnails: Bool) -> String {
        let detect = "[0:V:0]scdet=threshold=\(settings.threshold)"
        guard thumbnails else { return detect + "[cuts]" }
        // scdet tags each cut frame with lavfi.scd.time. The opening frame is
        // interleaved in so the JPEG encoder always receives at least one frame.
        return detect + ",split=3[cuts][first][marked];"
            + "[first]trim=end_frame=1[opening];"
            + "[marked]metadata=mode=select:key=lavfi.scd.time[selected];"
            + "[opening][selected]interleave=nb_inputs=2,"
            + "scale=w='trunc(iw*sar/2)*2':h=ih,setsar=1,"
            + "scale=w=320:h=180:force_original_aspect_ratio=decrease:force_divisible_by=2[thumbnails]"
    }

    static func thumbnailURL(in directory: URL, number: Int) -> URL {
        directory.appendingPathComponent(String(format: "cut_%05d.jpg", number))
    }

    static func removeThumbnails(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("cut_") && file.pathExtension == "jpg" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func fraction(_ seconds: Double, of duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0, seconds.isFinite else { return 0 }
        return min(1, max(0, seconds / duration))
    }
}

/// Pure parsers for the FFmpeg lines the video event scans rely on.
enum VideoEventLogParser {
    struct BlackEvent: Equatable {
        let start: Double
        let end: Double
        let duration: Double
    }

    struct SceneScore: Equatable {
        let score: Double
        let time: Double
    }

    /// `[Parsed_blackdetect_0 @ 0x…] black_start:5 black_end:6 black_duration:1`
    static func blackEvent(_ line: String) -> BlackEvent? {
        guard let payload = payload(of: line, filter: "blackdetect"),
              let start = number(after: "black_start:", in: payload),
              let end = number(after: "black_end:", in: payload),
              let duration = number(after: "black_duration:", in: payload) else { return nil }
        return BlackEvent(start: start, end: end, duration: duration)
    }

    /// `[Parsed_scdet_0 @ 0x…] lavfi.scd.score: 30.359, lavfi.scd.time: 4.451333`
    static func sceneScore(_ line: String) -> SceneScore? {
        guard let payload = payload(of: line, filter: "scdet"),
              let score = number(after: "lavfi.scd.score:", in: payload),
              let time = number(after: "lavfi.scd.time:", in: payload) else { return nil }
        return SceneScore(score: score, time: time)
    }

    /// Whether a line comes from the given filter, even if it is not a valid event.
    static func isFilterLine(_ line: String, filter: String) -> Bool {
        payload(of: line, filter: filter) != nil
    }

    /// `-progress` line `out_time_us=26400000`, in seconds. `N/A` is not progress.
    static func progressSeconds(_ line: String) -> Double? {
        guard line.hasPrefix("out_time_us="), let value = Int64(line.dropFirst("out_time_us=".count)),
              value >= 0 else { return nil }
        return Double(value) / 1_000_000
    }

    private static func payload(of line: String, filter: String) -> Substring? {
        guard line.hasPrefix("[Parsed_\(filter)_"), let close = line.firstIndex(of: "]") else { return nil }
        return line[line.index(after: close)...]
    }

    private static func number(after marker: String, in text: Substring) -> Double? {
        guard let range = text.range(of: marker),
              let token = text[range.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "," }).first,
              let value = Double(token), value.isFinite else { return nil }
        return value
    }
}

/// Consumes the live output stream rather than the runner's bounded diagnostic
/// tail: long files can produce more events than that tail retains.
final class VideoEventLogCollector: @unchecked Sendable {
    enum Kind { case black, sceneCuts }

    private let kind: Kind
    private let lock = NSLock()
    private var stderrPending = ""
    private var stdoutPending = ""
    private var blackIntervals: [BlackInterval] = []
    private var cuts: [SceneCut] = []
    private var invalid = false
    private var completed = false
    private var decodedVideo = false

    init(kind: Kind) { self.kind = kind }

    /// Returns the decoded position in seconds when this chunk advanced progress.
    @discardableResult
    func consume(_ chunk: SubprocessOutputChunk) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        switch chunk.stream {
        case .standardError:
            stderrPending += String(decoding: chunk.data, as: UTF8.self)
            return drain(&stderrPending, stderr: true)
        case .standardOutput:
            stdoutPending += String(decoding: chunk.data, as: UTF8.self)
            return drain(&stdoutPending, stderr: false)
        }
    }

    func finishBlack() throws -> [BlackInterval] {
        try checkComplete(filter: "blackdetect")
        return blackIntervals
    }

    func finishSceneCuts() throws -> [SceneCut] {
        try checkComplete(filter: "scdet")
        return cuts
    }

    private func checkComplete(filter: String) throws {
        lock.lock()
        defer { lock.unlock() }
        // A partial final event/progress line is not evidence of completion.
        guard !invalid, completed, decodedVideo,
              !stderrPending.contains("Parsed_\(filter)_"), stdoutPending.isEmpty else {
            throw AnalyticsError.parsingFailed("Video analysis did not produce a complete report. Retry with a readable video stream.")
        }
    }

    private func drain(_ pending: inout String, stderr: Bool) -> Double? {
        var latest: Double?
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            if let seconds = parse(line, stderr: stderr) { latest = seconds }
        }
        // Diagnostics should be short lines. Bound malformed output as well.
        if pending.utf8.count > 64 * 1024 { invalid = true; pending = "" }
        return latest
    }

    private func parse(_ line: String, stderr: Bool) -> Double? {
        if !stderr {
            if line == "progress=end" { completed = true }
            if let seconds = VideoEventLogParser.progressSeconds(line) {
                if seconds > 0 { decodedVideo = true }
                return seconds
            }
            return nil
        }
        switch kind {
        case .black:
            guard VideoEventLogParser.isFilterLine(line, filter: "blackdetect") else { return nil }
            guard let event = VideoEventLogParser.blackEvent(line), event.start >= 0, event.end > event.start,
                  event.start >= (blackIntervals.last?.end ?? 0),
                  abs((event.end - event.start) - event.duration) <= max(0.001, event.end * 0.00002) else {
                invalid = true
                return nil
            }
            blackIntervals.append(BlackInterval(start: event.start, end: event.end))
        case .sceneCuts:
            guard VideoEventLogParser.isFilterLine(line, filter: "scdet") else { return nil }
            guard let cut = VideoEventLogParser.sceneScore(line), cut.time >= 0, cut.score >= 0,
                  cut.time > (cuts.last?.time ?? -1) else {
                invalid = true
                return nil
            }
            cuts.append(SceneCut(time: cut.time, score: cut.score))
        }
        return nil
    }
}
