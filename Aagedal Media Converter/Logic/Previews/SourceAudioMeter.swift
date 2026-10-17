// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A bounded source-audio window, independent of system output/capture permissions.
struct SourceAudioMeterRequest: Hashable, Sendable {
    static let windowDuration = 8.0
    let url: URL
    /// Zero-based audio-stream ordinal, not the container stream ID or MPV track ID.
    let track: Int
    let channels: Int
    let window: Int

    var start: Double { Double(window) * Self.windowDuration }
    var displayedChannels: Int { min(8, max(1, channels)) }

    func adjacent(_ delta: Int) -> Self {
        Self(url: url, track: track, channels: channels, window: max(0, window + delta))
    }
}

/// Mono streams form one meter bank; stereo/surround streams stay separate.
struct SourceAudioMeterGroup: Identifiable, Equatable {
    let tracks: [Int]
    var id: Int { tracks[0] }
    var isMultiMono: Bool { tracks.count > 1 }

    static func groups(channelCounts: [Int?]) -> [Self] {
        let mono = channelCounts.indices.filter { channelCounts[$0] == 1 }
        return channelCounts.indices.compactMap { index in
            if channelCounts[index] == 1 {
                return index == mono.first ? Self(tracks: mono) : nil
            }
            return Self(tracks: [index])
        }
    }
}

struct SourceAudioMeterChunk: Sendable {
    let request: SourceAudioMeterRequest
    /// Sample peaks per channel in 10 ms bins, without normalization or downmixing.
    let peaks: [[Float]]
    static let sampleRate = 48_000
    static let framesPerBin = 480

    init(request: SourceAudioMeterRequest, pcm: Data) {
        self.request = request
        let channels = request.displayedChannels
        let frames = pcm.count / (MemoryLayout<Float>.size * channels)
        var bins = Array(repeating: Array(repeating: Float(0), count: channels),
                         count: (frames + Self.framesPerBin - 1) / Self.framesPerBin)
        pcm.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sample = samples[frame * channels + channel]
                    if sample.isFinite {
                        bins[frame / Self.framesPerBin][channel] = max(bins[frame / Self.framesPerBin][channel], abs(sample))
                    }
                }
            }
        }
        peaks = bins
    }

    func levels(at time: Double) -> [Float] {
        let silence = Array(repeating: Float(-60), count: request.displayedChannels)
        guard time.isFinite, time >= request.start,
              time < request.start + SourceAudioMeterRequest.windowDuration else { return silence }
        let index = Int((time - request.start) * 100)
        guard peaks.indices.contains(index) else { return silence }
        // A short peak hold keeps transients visible between playback callbacks.
        return (0..<request.displayedChannels).map { channel in
            let peak = peaks[max(0, index - 9)...index].map { $0[channel] }.max() ?? 0
            return peak > 0 ? max(-60, 20 * log10(peak)) : -60
        }
    }
}

enum SourceAudioMeterDecoder {
    static func arguments(for request: SourceAudioMeterRequest) -> [String] {
        var filters: [String] = []
        if request.channels > 8 {
            // Keep the first eight source channels individually; -ac 8 would downmix.
            filters.append("pan=8c|" + (0..<8).map { "c\($0)=c\($0)" }.joined(separator: "|"))
        }
        // Fill timestamp gaps and preserve delayed-track alignment with the preview.
        filters.append("aresample=48000:async=1:first_pts=0")
        return ["-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1",
                "-ss", String(request.start), "-i", request.url.path,
                "-map", "0:a:\(request.track)", "-vn", "-sn", "-dn",
                "-t", String(SourceAudioMeterRequest.windowDuration),
                "-af", filters.joined(separator: ","),
                "-ar", "48000", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"]
    }

    static nonisolated func decode(_ request: SourceAudioMeterRequest,
                                   runner: any SubprocessRunning = SubprocessRunner()) async throws -> SourceAudioMeterChunk {
        guard let path = BinaryPathResolver.ffmpegPath else {
            throw PreviewAssetError.generationFailed("Audio decoder unavailable")
        }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: request.url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let result = try await runner.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: path), arguments: arguments(for: request),
            timeout: .seconds(20), standardOutputCaptureLimit: 16 * 1024 * 1024,
            standardErrorCaptureLimit: 4096, sensitiveValues: [request.url.path]
        ))
        try Task.checkCancellation()
        guard result.succeeded, result.discardedStandardOutputBytes == 0 else {
            throw PreviewAssetError.generationFailed("Source audio metering unavailable")
        }
        return SourceAudioMeterChunk(request: request, pcm: result.standardOutput)
    }
}

/// Retain only nearby windows. Long sources never require decoding the whole file.
actor SourceAudioMeterCache {
    private var chunks: [SourceAudioMeterRequest: SourceAudioMeterChunk] = [:]
    private var order: [SourceAudioMeterRequest] = []

    func load(_ request: SourceAudioMeterRequest, capacity: Int = 3) async throws -> SourceAudioMeterChunk {
        if let cached = chunks[request] { return cached }
        let chunk = try await SourceAudioMeterDecoder.decode(request)
        try Task.checkCancellation()
        chunks[request] = chunk
        order.removeAll { $0 == request }
        order.append(request)
        while order.count > max(3, capacity) { chunks.removeValue(forKey: order.removeFirst()) }
        return chunk
    }
}

/// Playhead-synchronized source measurements. LUFS uses the original channel layout,
/// including LFE exclusion, even when only the first eight channels are displayed.
struct PlaybackAudioMeterSample: Equatable, Sendable {
    let seconds: Double
    let peaks: [Double?]
    let rms: [Double?]
    let momentaryLUFS: Double?
    let shortTermLUFS: Double?
}

struct PlaybackAudioMeterChunk: Sendable {
    let request: SourceAudioMeterRequest
    let samples: [PlaybackAudioMeterSample]

    init(request: SourceAudioMeterRequest, metadata: String) {
        self.request = request
        let origin = max(0, request.start - 3)
        var samples: [PlaybackAudioMeterSample] = []
        var timestamp: Double?
        var values: [String: Double] = [:]
        func finishFrame() {
            guard let timestamp else { return }
            // ebur128 metadata timestamps mark the start of each 100 ms frame.
            // Publish at its end, after the measured samples have played.
            let seconds = origin + timestamp + 0.1
            guard seconds >= request.start - 0.00001,
                  seconds <= request.start + SourceAudioMeterRequest.windowDuration + 0.00001 else { return }
            let peaks = (1...request.displayedChannels).map { values["lavfi.astats.\($0).Peak_level"] }
            let rms = (1...request.displayedChannels).map { values["lavfi.astats.\($0).RMS_level"] }
            samples.append(PlaybackAudioMeterSample(
                seconds: seconds, peaks: peaks, rms: rms,
                momentaryLUFS: origin + timestamp + 0.1 >= 0.4 ? values["lavfi.r128.M"] : nil,
                shortTermLUFS: timestamp + 0.1 >= 3 - 0.00001 ? values["lavfi.r128.S"] : nil
            ))
        }
        for line in metadata.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "pts_time:") {
                finishFrame()
                timestamp = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
                values.removeAll(keepingCapacity: true)
            } else if let separator = line.firstIndex(of: "="),
                      let value = Double(line[line.index(after: separator)...]), value.isFinite {
                values[String(line[..<separator])] = value
            }
        }
        finishFrame()
        self.samples = samples
    }

    func sample(at time: Double) -> PlaybackAudioMeterSample? {
        guard time.isFinite, time >= request.start,
              time < request.start + SourceAudioMeterRequest.windowDuration,
              let sample = samples.last(where: { $0.seconds <= time + 0.00001 }),
              time - sample.seconds < 0.2 else { return nil }
        return sample
    }
}

enum PlaybackAudioMeterDecoder {
    static func arguments(for request: SourceAudioMeterRequest) -> [String] {
        let origin = max(0, request.start - 3)
        let duration = request.start + SourceAudioMeterRequest.windowDuration - origin
        // Three seconds of pre-roll preserves short-term loudness across window
        // boundaries and seeks. Never downmix before EBU R128 weighting.
        let filters = "aresample=48000:async=1:first_pts=0,"
            + "ebur128=metadata=1:framelog=verbose,"
            + "astats=metadata=1:reset=1:measure_perchannel=Peak_level+RMS_level:measure_overall=none,"
            + "ametadata=print:file=-"
        return ["-hide_banner", "-loglevel", "error", "-nostdin", "-nostats", "-threads", "1",
                "-ss", String(origin), "-i", request.url.path, "-map", "0:a:\(request.track)",
                "-vn", "-sn", "-dn", "-t", String(duration), "-af", filters, "-f", "null", "-"]
    }

    static func decode(_ request: SourceAudioMeterRequest,
                       runner: any SubprocessRunning = SubprocessRunner()) async throws -> PlaybackAudioMeterChunk {
        guard let path = BinaryPathResolver.ffmpegPath else {
            throw PreviewAssetError.generationFailed("Audio decoder unavailable")
        }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: request.url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let result = try await runner.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: path), arguments: arguments(for: request),
            timeout: .seconds(20), standardOutputCaptureLimit: 2 * 1024 * 1024,
            standardErrorCaptureLimit: 4096, sensitiveValues: [request.url.path]
        ))
        try Task.checkCancellation()
        guard result.succeeded, result.discardedStandardOutputBytes == 0 else {
            throw PreviewAssetError.generationFailed("Source audio metering unavailable")
        }
        let chunk = PlaybackAudioMeterChunk(request: request, metadata: result.standardOutputText)
        guard !chunk.samples.isEmpty else {
            throw PreviewAssetError.generationFailed("No audio measurements available")
        }
        return chunk
    }
}

/// View-owned cache: no decoder survives closing or hiding the meter. Only nearby
/// windows are retained, so memory and decode work stay bounded for long files.
actor PlaybackAudioMeterCache {
    private var chunks: [SourceAudioMeterRequest: PlaybackAudioMeterChunk] = [:]
    private var order: [SourceAudioMeterRequest] = []

    func load(_ request: SourceAudioMeterRequest) async throws -> PlaybackAudioMeterChunk {
        if let chunk = chunks[request] { return chunk }
        let chunk = try await PlaybackAudioMeterDecoder.decode(request)
        try Task.checkCancellation()
        chunks[request] = chunk
        order.removeAll { $0 == request }
        order.append(request)
        while order.count > 3 { chunks.removeValue(forKey: order.removeFirst()) }
        return chunk
    }
}

/// Decode only finite string metadata. A live filter has no source pre-roll;
/// loudness stays unavailable until enough continuous playback history exists.
enum MPVAudioMeterMetadata {
    static func sample(_ values: [String: String], seconds: Double, history: Double) -> PlaybackAudioMeterSample? {
        guard seconds.isFinite, history.isFinite, history >= 0 else { return nil }
        func finite(_ key: String) -> Double? {
            guard let text = values[key], let value = Double(text), value.isFinite else { return nil }
            return value
        }
        let count = (1...8).last { values["lavfi.astats.\($0).Peak_level"] != nil } ?? 0
        guard count > 0 else { return nil }
        return PlaybackAudioMeterSample(
            seconds: seconds,
            peaks: (1...count).map { finite("lavfi.astats.\($0).Peak_level") },
            rms: (1...count).map { finite("lavfi.astats.\($0).RMS_level") },
            momentaryLUFS: history >= 0.4 ? finite("lavfi.r128.M") : nil,
            shortTermLUFS: history >= 3 ? finite("lavfi.r128.S") : nil
        )
    }
}
