// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AudioPeakSettings: Codable, Equatable, Sendable {
    var thresholdDBFS: Double = -1
    var imbalanceThresholdDB: Double = 6
    /// Nil retains the original sample-only analysis and report schema.
    var truePeakThresholdDBTP: Double? = nil

    func validate() throws {
        if let threshold = truePeakThresholdDBTP, !threshold.isFinite || !(-120...6).contains(threshold) {
            throw AnalyticsError.parsingFailed("True-peak threshold must be between −120 and +6 dBTP.")
        }
        guard thresholdDBFS.isFinite, (-120...0).contains(thresholdDBFS),
              imbalanceThresholdDB.isFinite, (0...120).contains(imbalanceThresholdDB) else {
            throw AnalyticsError.parsingFailed("Peak threshold must be between −120 and 0 dBFS and imbalance threshold between 0 and 120 dB.")
        }
    }
}

struct AudioPeakInterval: Codable, Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    let channel: Int
    let peakDBFS: Double
    var id: String { "\(channel):\(start)" }
    var duration: Double { end - start }
}

struct AudioChannelLevel: Codable, Equatable, Sendable, Identifiable {
    let channel: Int
    let peakDBFS: Double
    let rmsDBFS: Double
    var id: Int { channel }
}

struct AudioTruePeakInterval: Codable, Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    let channel: Int
    let peakDBTP: Double
    var id: String { "\(channel):\(start)" }
}

struct AudioTruePeakChannel: Codable, Equatable, Sendable, Identifiable {
    let channel: Int
    let peakDBTP: Double
    var id: Int { channel }
}

/// Estimated reconstructed peaks, independently measured with continuous 4×
/// libswresample interpolation. This is not a certified BS.1770 conformance meter.
struct AudioTruePeakResult: Codable, Equatable, Sendable {
    let thresholdDBTP: Double
    let sourceSampleRate: Int
    let measurementSampleRate: Int
    let windowSourceSamples: Int
    let method: String
    let channels: [AudioTruePeakChannel]
    let intervals: [AudioTruePeakInterval]
}

struct AudioPeakAnalysisResult: Codable, Equatable, Sendable {
    let settings: AudioPeakSettings
    let intervals: [AudioPeakInterval]
    let channels: [AudioChannelLevel]
    /// End of decoded audio on the file timeline, including any initial offset.
    let duration: Double
    /// Unweighted whole-track RMS range. Nil for mono or entirely silent audio.
    let imbalanceDB: Double?
    var presentation: LoudnessPresentation? = nil
    var truePeaks: AudioTruePeakResult? = nil
}

/// Measures unmodified source sample peaks/RMS in 4,800-sample windows.
/// Opt-in estimated true peaks use a separate continuous interpolation pass;
/// the original source measurements never include its edge context or resampling.
actor AudioPeakAnalysisService {
    static let shared = AudioPeakAnalysisService()
    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    init(runner: any SubprocessRunning = SubprocessRunner(),
         ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func analyze(file: URL, trackIndex: Int, settings: AudioPeakSettings = .init()) async throws -> AudioPeakAnalysisResult {
        try await analyze(file: file, presentation: .track(trackIndex), settings: settings)
    }

    /// Validate the complete presentation before grouped audition or analysis.
    func validateGroupedTracks(file: URL, presentation: LoudnessPresentation) async throws {
        try Task.checkCancellation()
        try Self.validateSelection(presentation)
        if case .track = presentation { return }
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        _ = try await validateCompleteGroupedTiming(file: file, indices: presentation.streamIndices, path: path)
    }

    private static func validateSelection(_ presentation: LoudnessPresentation) throws {
        let indices = presentation.streamIndices
        guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count else {
            throw AnalyticsError.parsingFailed("Select distinct, valid audio tracks.")
        }
        if case .surround51 = presentation, indices.count != 6 {
            throw AnalyticsError.parsingFailed("A 5.1 grouping requires exactly six mono tracks.")
        }
    }

    func analyze(file: URL, presentation: LoudnessPresentation,
                 settings: AudioPeakSettings = .init()) async throws -> AudioPeakAnalysisResult {
        try Task.checkCancellation()
        try settings.validate()
        try Self.validateSelection(presentation)
        let indices = presentation.streamIndices
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let timing: GroupedPeakTimingCollector.Summary?
        if case .track = presentation, settings.truePeakThresholdDBTP == nil { timing = nil }
        else {
            let grouped: Bool
            if case .track = presentation { grouped = false } else { grouped = true }
            timing = try await validateCompleteGroupedTiming(file: file, indices: indices, path: path, requireMono: grouped)
        }
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1", "-i", file.path,
                        "-filter_complex", Self.filterGraph(for: presentation), "-map", "[peaks]", "-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [path, file.path])
        let collector = AudioPeakLogCollector(settings: settings)
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Audio peak analysis failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        var report = try collector.finish(expectedSamples: timing?.samples)
        if let timing {
            guard (indices.count == 1 || report.channels.count == indices.count),
                  abs(report.duration - timing.end) < 0.5 / Double(timing.rate) else {
                throw AnalyticsError.parsingFailed("Grouped peak analysis did not preserve every source sample.")
            }
        }
        report.presentation = presentation
        if let threshold = settings.truePeakThresholdDBTP {
            let source = try collector.timelineSummary()
            guard source.rate <= 192_000 else {
                throw AnalyticsError.parsingFailed("True-peak markers support source rates up to 192 kHz.")
            }
            let measurementRate = source.rate * 4
            // Keep interpolation continuous across windows and drain its delayed
            // samples at EOF. Zero extension supplies interpolation context even
            // for one-sample clips; trim excludes that context from markers.
            // No async timestamp compensation, gain or downmix.
            let interpolation = "adelay=64S:all=1,apad=pad_len=64,"
                + "aresample=osr=\(measurementRate):osf=dbl:resampler=swr:filter_size=64:phase_shift=10:linear_interp=0:cutoff=0.97,"
                + "atrim=start_sample=256:end_sample=\((source.samples + 64) * 4),asettb=1/sr,asetpts=PTS-256,"
            let filter = interpolation + Self.measurementFilter(windowSamples: 19_200)
            let peakRequest = SubprocessRequest(
                executableURL: URL(fileURLWithPath: path),
                arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1", "-i", file.path,
                            "-filter_complex", Self.filterGraph(for: presentation, measurementFilter: filter),
                            "-map", "[peaks]", "-f", "null", "-"],
                timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [path, file.path])
            let peakCollector = AudioPeakLogCollector(settings: .init(thresholdDBFS: threshold), windowSamples: 19_200,
                                                       requireContinuous: true)
            let peakProcess = try await runner.run(peakRequest) { peakCollector.consume($0) }
            try Task.checkCancellation()
            guard peakProcess.succeeded else {
                throw AnalyticsError.parsingFailed("True-peak analysis failed. " + peakRequest.redactedDiagnostic(peakProcess.standardErrorText, limit: 500))
            }
            let reconstructed = try peakCollector.finish(expectedSamples: source.samples * 4)
            let measured = try peakCollector.timelineSummary()
            guard measured.rate == measurementRate, abs(measured.start - source.start) < 0.5 / Double(source.rate),
                  abs(reconstructed.duration - report.duration) < 0.5 / Double(source.rate),
                  reconstructed.channels.count == report.channels.count else {
                throw AnalyticsError.parsingFailed("True-peak analysis did not preserve the source timeline and channels.")
            }
            report.truePeaks = .init(thresholdDBTP: threshold, sourceSampleRate: source.rate,
                                     measurementSampleRate: measurementRate, windowSourceSamples: 4_800,
                                     method: "estimated_4x_libswresample_swr_filter64_cutoff0.97_no_certification",
                                     channels: reconstructed.channels.map { .init(channel: $0.channel, peakDBTP: $0.peakDBFS) },
                                     intervals: reconstructed.intervals.map { .init(start: $0.start, end: $0.end, channel: $0.channel, peakDBTP: $0.peakDBFS) })
        }
        return report
    }

    private func validateCompleteGroupedTiming(file: URL, indices: [Int], path: String, requireMono: Bool = true) async throws -> GroupedPeakTimingCollector.Summary {
        let graph = indices.enumerated().map { offset, index in
            "[0:a:\(index)]asettb=1/sr,ashowinfo@amc_peak_timing_\(offset)[timing_\(offset)]"
        }.joined(separator: ";")
        let maps = indices.indices.flatMap { ["-map", "[timing_\($0)]"] }
        let request = SubprocessRequest(executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1", "-i", file.path,
                        "-filter_complex", graph] + maps + ["-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [path, file.path])
        let collector = GroupedPeakTimingCollector(trackCount: indices.count, requireMono: requireMono)
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Could not verify complete grouped audio timing. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        return try collector.finish()
    }

    static func filterGraph(for presentation: LoudnessPresentation, measurementFilter: String = filterGraph) -> String {
        if case .track(let index) = presentation { return "[0:a:\(index)]\(measurementFilter)[peaks]" }
        // Normalize mono labels so amerge concatenates input order, then assign roles
        // explicitly. join can intermittently drop its final full window at EOF.
        // Equal, unpadded framing preserves source samples with different codecs.
        let preparation = presentation.streamIndices.enumerated().map { offset, index in
            "[0:a:\(index)]channelmap=map=0-FC:channel_layout=mono,asetnsamples=n=4800:p=0[group_\(offset)];"
        }.joined()
        let inputs = presentation.streamIndices.indices.map { "[group_\($0)]" }.joined()
        let merge: String
        switch presentation {
        case .track: merge = ""
        case .stereo: merge = "amerge=inputs=2,channelmap=map=0-FL|1-FR:channel_layout=stereo,"
        case .surround51: merge = "amerge=inputs=6,channelmap=map=0-FL|1-FR|2-FC|3-LFE|4-SL|5-SR:channel_layout=5.1(side),"
        }
        return "\(preparation)\(inputs)\(merge)\(measurementFilter)[peaks]"
    }

    static let filterGraph = measurementFilter(windowSamples: 4_800)

    private static func measurementFilter(windowSamples: Int) -> String {
        "asettb=1/sr,asetnsamples=n=\(windowSamples):p=0,ashowinfo,"
            + "astats=metadata=1:reset=1:measure_perchannel=Peak_level+RMS_level:measure_overall=Number_of_samples,ametadata=mode=print"
    }
}

/// Keeps only one frame and bounded markers; diagnostic capture limits do not
/// truncate analysis. Missing/malformed frames and incomplete decodes fail closed.
final class AudioPeakLogCollector: @unchecked Sendable {
    private struct Frame {
        let index: Int
        let pts: Int64
        let rate: Int
        let samples: Int
        let channels: Int
        var header = false
        var sampleCount: Int?
        var peaks: [Int: Double] = [:]
        var rms: [Int: Double] = [:]
    }
    private let lock = NSLock()
    private let settings: AudioPeakSettings
    private let markerLimit: Int
    private let windowSamples: Int
    private let requireContinuous: Bool
    private var firstStart: Double?
    private var stderrPending = ""
    private var stdoutPending = ""
    private var frame: Frame?
    private var invalid = false
    private var discontinuous = false
    private var completed = false
    private var frameCount = 0
    private var rate: Int?
    private var channelCount: Int?
    private var totalSamples: Double = 0
    private var end: Double = 0
    private var peaks: [Double] = []
    private var energies: [Double] = []
    private var intervals: [AudioPeakInterval] = []
    private var active: [Int: AudioPeakInterval] = [:]

    init(settings: AudioPeakSettings, markerLimit: Int = 100_000, windowSamples: Int = 4_800,
         requireContinuous: Bool = false) {
        self.settings = settings
        self.markerLimit = markerLimit
        self.windowSamples = windowSamples
        self.requireContinuous = requireContinuous || settings.truePeakThresholdDBTP != nil
    }

    func timelineSummary() throws -> (rate: Int, samples: Int64, start: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, completed, let rate, let firstStart, totalSamples > 0, totalSamples < Double(Int64.max / 4) else {
            throw AnalyticsError.parsingFailed("Missing continuous source timeline for true-peak analysis.")
        }
        return (rate, Int64(totalSamples), firstStart)
    }

    func consume(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        defer { lock.unlock() }
        // Copying the bounded remainder avoids overlapping inout access to self.
        var pending = chunk.stream == .standardError ? stderrPending : stdoutPending
        pending += String(decoding: chunk.data, as: UTF8.self)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            if !invalid { parse(line, stderr: chunk.stream == .standardError) }
        }
        if pending.utf8.count > 64 * 1024 { invalid = true; pending = "" }
        if chunk.stream == .standardError { stderrPending = pending } else { stdoutPending = pending }
    }

    func finish(expectedSamples: Int64? = nil) throws -> AudioPeakAnalysisResult {
        lock.lock()
        defer { lock.unlock() }
        if !invalid { flushFrame() }
        if discontinuous {
            throw AnalyticsError.parsingFailed(String(localized: "True-peak markers require continuous audio timestamps."))
        }
        guard !invalid, completed, frameCount > 0, totalSamples > 0,
              stderrPending.isEmpty, stdoutPending.isEmpty,
              expectedSamples == nil || Double(expectedSamples!) == totalSamples else {
            throw AnalyticsError.parsingFailed("Audio peak analysis did not produce a complete report, or exceeded the 100,000-marker limit. Retry with a readable audio track or a higher peak threshold.")
        }
        intervals.append(contentsOf: active.values)
        active.removeAll()
        let channels = peaks.indices.map { index in
            AudioChannelLevel(channel: index + 1, peakDBFS: peaks[index],
                              rmsDBFS: energies[index] == 0 ? -.infinity : 10 * log10(energies[index] / totalSamples))
        }
        let levels = channels.map(\.rmsDBFS)
        let imbalance: Double?
        if levels.count < 2 || levels.allSatisfy({ $0 == -.infinity }) { imbalance = nil }
        else { imbalance = levels.max()! - levels.min()! }
        return .init(settings: settings, intervals: intervals.sorted { ($0.start, $0.channel) < ($1.start, $1.channel) },
                     channels: channels, duration: end, imbalanceDB: imbalance)
    }

    private func parse(_ line: String, stderr: Bool) {
        guard stderr else { if line == "progress=end" { completed = true }; return }
        if line.contains("Parsed_ashowinfo_"), line.contains(" n:") {
            flushFrame()
            guard !invalid,
                  let index = token("n:", line).flatMap(Int.init), index == frameCount,
                  let pts = token("pts:", line).flatMap(Int64.init), pts >= 0,
                  let rate = token("rate:", line).flatMap(Int.init), rate > 0,
                  let samples = token("nb_samples:", line).flatMap(Int.init), samples > 0, samples <= windowSamples,
                  let channels = token("channels:", line).flatMap(Int.init), (1...64).contains(channels) else { invalid = true; return }
            frame = Frame(index: index, pts: pts, rate: rate, samples: samples, channels: channels)
        } else if line.contains("Parsed_ametadata_"), line.contains("frame:") {
            guard var current = frame, !current.header,
                  token("frame:", line).flatMap(Int.init) == current.index,
                  token("pts:", line).flatMap(Int64.init) == current.pts else { invalid = true; return }
            current.header = true
            frame = current
        } else if let range = line.range(of: "lavfi.astats."), line.contains("Parsed_ametadata_") {
            guard var current = frame, current.header else { invalid = true; return }
            let pair = line[range.upperBound...].split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { invalid = true; return }
            let key = String(pair[0])
            if key == "Overall.Number_of_samples" {
                guard current.sampleCount == nil, let count = Double(pair[1]), count == Double(current.samples) else { invalid = true; return }
                current.sampleCount = current.samples
            } else {
                let components = key.split(separator: ".")
                guard components.count == 2, let channel = Int(components[0]), (1...current.channels).contains(channel),
                      let value = Double(pair[1]), value.isFinite || value == -.infinity,
                      value <= 300 else { invalid = true; return }
                switch components[1] {
                case "Peak_level":
                    guard current.peaks[channel] == nil else { invalid = true; return }
                    current.peaks[channel] = value
                case "RMS_level":
                    guard current.rms[channel] == nil else { invalid = true; return }
                    current.rms[channel] = value
                default: invalid = true; return
                }
            }
            frame = current
        }
    }

    private func flushFrame() {
        guard let current = frame else { return }
        frame = nil
        let start = Double(current.pts) / Double(current.rate)
        let frameEnd = start + Double(current.samples) / Double(current.rate)
        if requireContinuous, frameCount > 0, abs(start - end) > 0.5 / Double(current.rate) {
            discontinuous = true
            invalid = true
            return
        }
        guard current.header, current.sampleCount == current.samples,
              current.peaks.count == current.channels, current.rms.count == current.channels,
              rate == nil || rate == current.rate, channelCount == nil || channelCount == current.channels,
              start >= end - 0.5 / Double(current.rate) else { invalid = true; return }
        if rate == nil {
            firstStart = start
            rate = current.rate
            channelCount = current.channels
            peaks = Array(repeating: -.infinity, count: current.channels)
            energies = Array(repeating: 0, count: current.channels)
        }
        for channel in 1...current.channels {
            let peak = current.peaks[channel]!
            let rms = current.rms[channel]!
            guard rms <= peak + 0.00001 else { invalid = true; return }
            peaks[channel - 1] = max(peaks[channel - 1], peak)
            energies[channel - 1] += pow(10, rms / 10) * Double(current.samples)
            let previous = active[channel]
            if peak >= settings.thresholdDBFS {
                if let previous, abs(previous.end - start) <= 0.5 / Double(current.rate) {
                    active[channel] = .init(start: previous.start, end: frameEnd, channel: channel, peakDBFS: max(previous.peakDBFS, peak))
                } else {
                    if let previous { intervals.append(previous) }
                    active[channel] = .init(start: start, end: frameEnd, channel: channel, peakDBFS: peak)
                }
            } else if let previous {
                intervals.append(previous)
                active[channel] = nil
            }
        }
        guard intervals.count + active.count <= markerLimit else { invalid = true; return }
        totalSamples += Double(current.samples)
        end = frameEnd
        frameCount += 1
    }

    private func token(_ key: String, _ line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        return line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

/// Streaming, constant-memory validation before merging can conceal missing samples.
/// Matroska timestamps commonly round to milliseconds; tolerate that clock
/// quantization, but never a changed sample rate, sample total, or start time.
/// Sub-millisecond discontinuities cannot be distinguished from that rounding.
final class GroupedPeakTimingCollector: @unchecked Sendable {
    struct Summary {
        let start: Int64
        let samples: Int64
        let rate: Int
        var end: Double { (Double(start) + Double(samples)) / Double(rate) }
    }
    private struct Track {
        var frames = 0
        var start: Int64 = 0
        var samples: Int64 = 0
        var rate = 0
        var channels = 0
    }
    private let lock = NSLock()
    private let requireMono: Bool
    private var tracks: [Track]
    private var stderrPending = ""
    private var stdoutPending = ""
    private var invalid = false
    private var completed = false

    init(trackCount: Int, requireMono: Bool = true) {
        self.requireMono = requireMono
        tracks = Array(repeating: Track(), count: trackCount)
    }

    func consume(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        defer { lock.unlock() }
        var pending = chunk.stream == .standardError ? stderrPending : stdoutPending
        pending += String(decoding: chunk.data, as: UTF8.self)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if chunk.stream == .standardOutput {
                if line == "progress=end" { completed = true }
            } else if !invalid { parse(line) }
        }
        if pending.utf8.count > 64 * 1024 { invalid = true; pending = "" }
        if chunk.stream == .standardError { stderrPending = pending } else { stdoutPending = pending }
    }

    func finish() throws -> Summary {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, completed, stderrPending.isEmpty, stdoutPending.isEmpty,
              let first = tracks.first, first.frames > 0,
              tracks.allSatisfy({ $0.frames > 0 && $0.rate == first.rate && $0.start == first.start && $0.samples == first.samples }) else {
            if !requireMono {
                throw AnalyticsError.parsingFailed(String(localized: "True-peak markers require continuous audio timestamps."))
            }
            throw AnalyticsError.parsingFailed(String(localized: "Grouped peak analysis requires mono tracks with matching sample rates, start times, and decoded lengths, without timestamp discontinuities (within 1 ms container timestamp precision)."))
        }
        return Summary(start: first.start, samples: first.samples, rate: first.rate)
    }

    private func parse(_ line: String) {
        guard let marker = line.range(of: "ashowinfo@amc_peak_timing_"), line.contains(" n:") else { return }
        let suffix = line[marker.upperBound...]
        guard let index = Int(suffix.prefix(while: \.isNumber)), tracks.indices.contains(index),
              let frame = token("n:", line).flatMap(Int.init), frame == tracks[index].frames,
              let pts = token("pts:", line).flatMap(Int64.init), pts >= 0,
              let channels = token("channels:", line).flatMap(Int.init), (1...64).contains(channels),
              !requireMono || channels == 1,
              let rate = token("rate:", line).flatMap(Int.init), rate > 0,
              let count = token("nb_samples:", line).flatMap(Int64.init), count > 0 else { invalid = true; return }
        var track = tracks[index]
        if track.frames == 0 { track.start = pts; track.rate = rate; track.channels = channels }
        let expected = track.start.addingReportingOverflow(track.samples)
        let total = track.samples.addingReportingOverflow(count)
        guard !expected.overflow, !total.overflow, rate == track.rate, channels == track.channels,
              abs(Double(pts) - Double(expected.partialValue)) <= max(1, Double(rate) / 1000) else { invalid = true; return }
        track.frames += 1
        track.samples = total.partialValue
        tracks[index] = track
    }

    private func token(_ key: String, _ line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        return line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
