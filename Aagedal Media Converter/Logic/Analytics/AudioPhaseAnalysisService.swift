// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Unweighted source-sample statistics. Mid=(L+R)/2; side=(L-R)/2.
struct AudioPhaseMeasurement: Codable, Equatable, Sendable {
    let sampleCount: Int64
    let leftEnergy: Double
    let rightEnergy: Double
    let midEnergy: Double
    let sideEnergy: Double
    let crossProduct: Double
    /// Uncentered normalized cross-product; unavailable if either channel has zero energy.
    var correlation: Double? {
        guard leftEnergy > 0, rightEnergy > 0 else { return nil }
        return min(1, max(-1, (crossProduct / sqrt(leftEnergy)) / sqrt(rightEnergy)))
    }
    /// Mono energy relative to mean source-channel energy. Nil is silence;
    /// negative infinity means exact cancellation of non-silent channels.
    var monoFoldDownDeltaDB: Double? {
        let reference = leftEnergy / 2 + rightEnergy / 2
        guard reference > 0 else { return nil }
        return midEnergy == 0 ? -.infinity : 10 * log10(midEnergy / reference)
    }
    var midRMS: Double { sqrt(midEnergy / Double(sampleCount)) }
    var sideRMS: Double { sqrt(sideEnergy / Double(sampleCount)) }

    private enum CodingKeys: String, CodingKey {
        case sampleCount, leftEnergy, rightEnergy, midEnergy, sideEnergy, crossProduct
        case correlation, monoFoldDownDeltaDB, midRMS, sideRMS
    }

    init(sampleCount: Int64, leftEnergy: Double, rightEnergy: Double, midEnergy: Double,
         sideEnergy: Double, crossProduct: Double) {
        self.sampleCount = sampleCount; self.leftEnergy = leftEnergy; self.rightEnergy = rightEnergy
        self.midEnergy = midEnergy; self.sideEnergy = sideEnergy; self.crossProduct = crossProduct
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sampleCount: try c.decode(Int64.self, forKey: .sampleCount),
                  leftEnergy: try c.decode(Double.self, forKey: .leftEnergy),
                  rightEnergy: try c.decode(Double.self, forKey: .rightEnergy),
                  midEnergy: try c.decode(Double.self, forKey: .midEnergy),
                  sideEnergy: try c.decode(Double.self, forKey: .sideEnergy),
                  crossProduct: try c.decode(Double.self, forKey: .crossProduct))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(leftEnergy, forKey: .leftEnergy); try c.encode(rightEnergy, forKey: .rightEnergy)
        try c.encode(midEnergy, forKey: .midEnergy); try c.encode(sideEnergy, forKey: .sideEnergy)
        try c.encode(crossProduct, forKey: .crossProduct)
        try c.encode(correlation, forKey: .correlation)
        try c.encode(monoFoldDownDeltaDB, forKey: .monoFoldDownDeltaDB)
        try c.encode(midRMS, forKey: .midRMS); try c.encode(sideRMS, forKey: .sideRMS)
    }

}

struct AudioPhaseWindow: Codable, Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    let measurement: AudioPhaseMeasurement
    var id: Double { start }
}

/// Whole-source density at fixed full-scale coordinates; no gain normalization.
struct AudioPhaseScope: Codable, Equatable, Sendable {
    let dimension: Int
    let bins: [Int64]
    let clippedSampleCount: Int64
}

struct AudioPhaseAnalysisResult: Codable, Equatable, Sendable {
    let presentation: LoudnessPresentation
    let sampleRate: Int
    let windowSourceSamples: Int
    let windows: [AudioPhaseWindow]
    let totals: AudioPhaseMeasurement
    let scope: AudioPhaseScope
    /// End of decoded audio on the file timeline, including initial offset.
    var duration: Double { windows.last?.end ?? 0 }

    private enum CodingKeys: String, CodingKey { case presentation, sampleRate, windowSourceSamples, windows, totals, scope, duration }
    init(presentation: LoudnessPresentation, sampleRate: Int, windowSourceSamples: Int,
         windows: [AudioPhaseWindow], totals: AudioPhaseMeasurement,
         scope: AudioPhaseScope = .init(dimension: 33, bins: Array(repeating: 0, count: 1089), clippedSampleCount: 0)) {
        self.presentation = presentation; self.sampleRate = sampleRate; self.windowSourceSamples = windowSourceSamples
        self.windows = windows; self.totals = totals; self.scope = scope
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(presentation: try c.decode(LoudnessPresentation.self, forKey: .presentation),
                  sampleRate: try c.decode(Int.self, forKey: .sampleRate),
                  windowSourceSamples: try c.decode(Int.self, forKey: .windowSourceSamples),
                  windows: try c.decode([AudioPhaseWindow].self, forKey: .windows),
                  totals: try c.decode(AudioPhaseMeasurement.self, forKey: .totals),
                  scope: try c.decode(AudioPhaseScope.self, forKey: .scope))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(presentation, forKey: .presentation); try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(windowSourceSamples, forKey: .windowSourceSamples); try c.encode(windows, forKey: .windows)
        try c.encode(totals, forKey: .totals); try c.encode(scope, forKey: .scope)
        try c.encode(duration, forKey: .duration)
    }

}

/// Streams interleaved double-precision source samples without gain, resampling,
/// downmix, or a preview matrix. At most 100,000 windows are retained.
actor AudioPhaseAnalysisService {
    static let shared = AudioPhaseAnalysisService()
    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    init(runner: any SubprocessRunning = SubprocessRunner(),
         ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func analyze(file: URL, trackIndex: Int) async throws -> AudioPhaseAnalysisResult {
        try await analyze(file: file, presentation: .track(trackIndex))
    }

    func analyze(file: URL, presentation: LoudnessPresentation) async throws -> AudioPhaseAnalysisResult {
        try Task.checkCancellation()
        let indices = presentation.streamIndices
        guard indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count else {
            throw AnalyticsError.parsingFailed("Select distinct, valid audio tracks.")
        }
        switch presentation {
        case .track, .stereo: break
        case .surround51: throw AnalyticsError.parsingFailed("Phase analysis requires one stereo track or two matching mono tracks.")
        }
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let expected: GroupedPeakTimingCollector.Summary?
        if case .stereo = presentation {
            expected = try await AudioPeakAnalysisService(runner: runner, ffmpegPathProvider: ffmpegPathProvider)
                .validateGroupedTracks(file: file, presentation: presentation)
        } else {
            expected = nil
        }
        let measurement = "asettb=1/sr,ashowinfo@amc_phase_source,"
            + "aformat=sample_fmts=dbl,asetnsamples=n=4800:p=0,ashowinfo@amc_phase_window"
        let graph = AudioPeakAnalysisService.filterGraph(for: presentation, measurementFilter: measurement)
        let request = SubprocessRequest(executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:2", "-i", file.path,
                        "-filter_complex", graph, "-map", "[peaks]", "-c:a", "pcm_f64le", "-f", "f64le", "pipe:1"],
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [path, file.path])
        let collector = AudioPhaseSampleCollector()
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Phase analysis failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        let report = try collector.finish(presentation: presentation)
        if let expected {
            guard report.sampleRate == expected.rate, report.totals.sampleCount == expected.samples,
                  report.windows.first.map({ abs($0.start * Double(expected.rate) - Double(expected.start)) < 0.5 }) == true,
                  abs(report.duration - expected.end) * Double(expected.rate) < 0.5 else {
                throw AnalyticsError.parsingFailed("Grouped phase analysis did not preserve every source sample.")
            }
        }
        return report
    }
}

/// Raw samples and timestamp metadata arrive independently. Each stream is
/// summarized immediately and reconciled at EOF, so pipe scheduling cannot
/// cause unbounded buffering or attribution to the wrong frame.
final class AudioPhaseSampleCollector: @unchecked Sendable {
    private struct Timing {
        var frames = 0
        var start: Int64 = 0
        var samples: Int64 = 0
        var rate = 0
    }
    private struct Frame { let pts: Int64; let samples: Int; let rate: Int }
    private let lock = NSLock()
    private let windowLimit: Int
    private var source = Timing()
    private var frames: [Frame] = []
    private var measurements: [AudioPhaseMeasurement] = []
    private var pendingBytes = Data()
    private var pendingLog = ""
    private var completed = false
    private var failure: String?
    private var bins: [Int64] = Array(repeating: 0, count: 1089)
    private var clippedSamples: Int64 = 0
    private var count: Int64 = 0
    private var left = 0.0, right = 0.0, mid = 0.0, side = 0.0, cross = 0.0

    init(windowLimit: Int = 100_000) { self.windowLimit = windowLimit }

    func consume(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        if chunk.stream == .standardOutput {
            var data = pendingBytes
            data.append(chunk.data)
            let bytes = data.count - data.count % 16
            data.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: bytes, by: 16) {
                    guard failure == nil else { break }
                    let l = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                    let r = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
                    guard l.isFinite, r.isFinite else { failure = "Non-finite source audio samples."; break }
                    let m = l / 2 + r / 2, s = l / 2 - r / 2
                    // Clamp before integer conversion, including huge finite samples.
                    let x = Int(((min(1, max(-1, s)) + 1) * 16).rounded())
                    let y = Int(((min(1, max(-1, m)) + 1) * 16).rounded())
                    bins[y * 33 + x] += 1
                    if abs(s) > 1 || abs(m) > 1 { clippedSamples += 1 }
                    left += l * l; right += r * r; mid += m * m; side += s * s; cross += l * r
                    count += 1
                    if count == 4800 { flushSamples() }
                }
            }
            pendingBytes = Data(data.suffix(data.count - bytes))
        } else {
            pendingLog += String(decoding: chunk.data, as: UTF8.self)
            while let newline = pendingLog.firstIndex(of: "\n") {
                let line = String(pendingLog[..<newline])
                pendingLog.removeSubrange(...newline)
                parse(line)
                if failure != nil { break }
            }
            if pendingLog.utf8.count > 64 * 1024 { failure = "Oversized phase metadata line." }
        }
    }

    func finish(presentation: LoudnessPresentation) throws -> AudioPhaseAnalysisResult {
        lock.lock()
        defer { lock.unlock() }
        if count > 0 { flushSamples() }
        guard failure == nil, completed, pendingBytes.isEmpty, pendingLog.isEmpty,
              !frames.isEmpty, frames.count == measurements.count, source.samples > 0 else {
            throw AnalyticsError.parsingFailed(failure ?? "Incomplete phase analysis samples or timeline.")
        }
        var expected = source.start
        var windows: [AudioPhaseWindow] = []
        for (frame, measurement) in zip(frames, measurements) {
            guard frame.rate == source.rate, frame.pts == expected, measurement.sampleCount == Int64(frame.samples) else {
                throw AnalyticsError.parsingFailed("Phase analysis did not preserve continuous source samples.")
            }
            windows.append(.init(start: Double(frame.pts) / Double(frame.rate),
                                 end: (Double(frame.pts) + Double(frame.samples)) / Double(frame.rate), measurement: measurement))
            let next = expected.addingReportingOverflow(Int64(frame.samples))
            guard !next.overflow else { throw AnalyticsError.parsingFailed("Phase timeline overflowed.") }
            expected = next.partialValue
        }
        guard expected - source.start == source.samples else {
            throw AnalyticsError.parsingFailed("Phase analysis did not preserve every source sample.")
        }
        let totals = measurements.reduce(AudioPhaseMeasurement(sampleCount: 0, leftEnergy: 0, rightEnergy: 0,
                                                               midEnergy: 0, sideEnergy: 0, crossProduct: 0)) { a, b in
            .init(sampleCount: a.sampleCount + b.sampleCount, leftEnergy: a.leftEnergy + b.leftEnergy,
                  rightEnergy: a.rightEnergy + b.rightEnergy, midEnergy: a.midEnergy + b.midEnergy,
                  sideEnergy: a.sideEnergy + b.sideEnergy, crossProduct: a.crossProduct + b.crossProduct)
        }
        guard [totals.leftEnergy, totals.rightEnergy, totals.midEnergy, totals.sideEnergy, totals.crossProduct].allSatisfy(\.isFinite) else {
            throw AnalyticsError.parsingFailed("Phase energy totals overflowed.")
        }
        return .init(presentation: presentation, sampleRate: source.rate, windowSourceSamples: 4800, windows: windows, totals: totals,
                     scope: .init(dimension: 33, bins: bins, clippedSampleCount: clippedSamples))
    }

    private func flushSamples() {
        guard measurements.count < windowLimit else { failure = "Phase analysis exceeded the 100,000-window limit."; return }
        guard [left, right, mid, side, cross].allSatisfy(\.isFinite) else { failure = "Phase sample energy overflowed."; return }
        measurements.append(.init(sampleCount: count, leftEnergy: left, rightEnergy: right, midEnergy: mid, sideEnergy: side, crossProduct: cross))
        count = 0; left = 0; right = 0; mid = 0; side = 0; cross = 0
    }

    private func parse(_ line: String) {
        if line == "progress=end" { completed = true; return }
        let isSource = line.contains("ashowinfo@amc_phase_source")
        guard (isSource || line.contains("ashowinfo@amc_phase_window")), line.contains(" n:") else { return }
        guard let index = token("n:", line).flatMap(Int.init),
              let pts = token("pts:", line).flatMap(Int64.init), pts >= 0,
              token("channels:", line).flatMap(Int.init) == 2,
              let rate = token("rate:", line).flatMap(Int.init), rate > 0,
              let samples = token("nb_samples:", line).flatMap(Int.init), samples > 0 else {
            failure = "Phase analysis requires exactly two decoded channels and valid source timestamps."; return
        }
        if isSource {
            guard index == source.frames else { failure = "Incomplete source phase metadata."; return }
            if source.frames == 0 { source.start = pts; source.rate = rate }
            let expected = source.start.addingReportingOverflow(source.samples)
            let total = source.samples.addingReportingOverflow(Int64(samples))
            guard !expected.overflow, !total.overflow, source.rate == rate,
                  abs(Double(pts) - Double(expected.partialValue)) <= max(1, Double(rate) / 1000) else {
                failure = "Phase analysis requires continuous source timestamps (within 1 ms container precision)."; return
            }
            source.frames += 1; source.samples = total.partialValue
        } else {
            guard index == frames.count, samples <= 4800, frames.count < windowLimit else {
                failure = "Malformed phase window metadata or exceeded the 100,000-window limit."; return
            }
            frames.append(.init(pts: pts, samples: samples, rate: rate))
        }
    }

    private func token(_ key: String, _ line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        return line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
