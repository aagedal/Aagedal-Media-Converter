// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AudioPeakSettings: Equatable, Sendable {
    var thresholdDBFS: Double = -1
    var imbalanceThresholdDB: Double = 6

    func validate() throws {
        guard thresholdDBFS.isFinite, (-120...0).contains(thresholdDBFS),
              imbalanceThresholdDB.isFinite, (0...120).contains(imbalanceThresholdDB) else {
            throw AnalyticsError.parsingFailed("Peak threshold must be between −120 and 0 dBFS and imbalance threshold between 0 and 120 dB.")
        }
    }
}

struct AudioPeakInterval: Equatable, Sendable, Identifiable {
    let start: Double
    let end: Double
    let channel: Int
    let peakDBFS: Double
    var id: String { "\(channel):\(start)" }
    var duration: Double { end - start }
}

struct AudioChannelLevel: Equatable, Sendable, Identifiable {
    let channel: Int
    let peakDBFS: Double
    let rmsDBFS: Double
    var id: Int { channel }
}

struct AudioPeakAnalysisResult: Equatable, Sendable {
    let settings: AudioPeakSettings
    let intervals: [AudioPeakInterval]
    let channels: [AudioChannelLevel]
    /// End of decoded audio on the file timeline, including any initial offset.
    let duration: Double
    /// Unweighted whole-track RMS range. Nil for mono or entirely silent audio.
    let imbalanceDB: Double?
}

/// Measures source sample peaks (not reconstructed true peaks). Markers cover
/// 4,800-sample windows, merged when adjacent, without padding or resampling.
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
        try Task.checkCancellation()
        try settings.validate()
        guard trackIndex >= 0 else { throw AnalyticsError.parsingFailed("Select a valid audio track.") }
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1", "-i", file.path,
                        "-map", "0:a:\(trackIndex)", "-af", Self.filterGraph, "-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [path, file.path])
        let collector = AudioPeakLogCollector(settings: settings)
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed("Audio peak analysis failed. " + request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        return try collector.finish()
    }

    static let filterGraph = "asettb=1/sr,asetnsamples=n=4800:p=0,ashowinfo,"
        + "astats=metadata=1:reset=1:measure_perchannel=Peak_level+RMS_level:measure_overall=Number_of_samples,ametadata=mode=print"
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
    private var stderrPending = ""
    private var stdoutPending = ""
    private var frame: Frame?
    private var invalid = false
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

    init(settings: AudioPeakSettings, markerLimit: Int = 100_000) {
        self.settings = settings
        self.markerLimit = markerLimit
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

    func finish() throws -> AudioPeakAnalysisResult {
        lock.lock()
        defer { lock.unlock() }
        if !invalid { flushFrame() }
        guard !invalid, completed, frameCount > 0, totalSamples > 0,
              stderrPending.isEmpty, stdoutPending.isEmpty else {
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
                  let samples = token("nb_samples:", line).flatMap(Int.init), samples > 0, samples <= 4800,
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
        guard current.header, current.sampleCount == current.samples,
              current.peaks.count == current.channels, current.rms.count == current.channels,
              rate == nil || rate == current.rate, channelCount == nil || channelCount == current.channels,
              start >= end - 0.5 / Double(current.rate) else { invalid = true; return }
        if rate == nil {
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
