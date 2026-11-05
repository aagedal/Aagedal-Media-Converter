// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum BitrateStreamKind: String, CaseIterable, Codable, Sendable {
    case video
    case audio

    /// `V` skips attached pictures such as cover art, which are not part of the timeline.
    var mapSpecifier: String { self == .video ? "0:V:0" : "0:a:0" }
}

enum BitrateAnalysisError: Error, LocalizedError, Equatable {
    case noStream(BitrateStreamKind)
    case noPackets
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noStream(.video): return "This file has no video stream."
        case .noStream(.audio): return "This file has no audio stream."
        case .noPackets: return "Bitrate analysis did not return any packets for this stream."
        case .failed(let reason): return "Bitrate analysis failed. \(reason)"
        }
    }
}

struct BitratePacket: Equatable, Sendable {
    let seconds: Double
    let bytes: Int
    let isKeyframe: Bool
}

struct BitrateWindow: Equatable, Sendable, Identifiable {
    let start: Double
    let bitsPerSecond: Double
    var id: Double { start }
}

/// Packet sizes of one stream in presentation order. Times are relative to the first
/// presented packet, which matches the encoded time used by quality timelines.
struct BitrateTimeline: Equatable, Sendable {
    static let windowChoices: [Double] = [0.5, 1, 2, 5, 10, 30, 60]

    let stream: BitrateStreamKind
    let codec: String?
    let packets: [BitratePacket]
    let duration: Double
    let totalBytes: Int
    let keyframeTimes: [Double]

    init(stream: BitrateStreamKind, codec: String?, packets: [BitratePacket], duration: Double) {
        self.stream = stream
        self.codec = codec
        self.packets = packets
        self.duration = duration
        totalBytes = packets.reduce(0) { $0 + $1.bytes }
        keyframeTimes = stream == .video ? packets.filter(\.isKeyframe).map(\.seconds) : []
    }

    var averageBitsPerSecond: Double { duration > 0 ? Double(totalBytes) * 8 / duration : 0 }

    /// Mean spacing between keyframes, or "Every frame" for intra-only streams.
    var keyframeIntervalDescription: String {
        guard keyframeTimes.count > 1, let first = keyframeTimes.first, let last = keyframeTimes.last else { return "—" }
        if keyframeTimes.count == packets.count { return String(localized: "Every frame") }
        return ((last - first) / Double(keyframeTimes.count - 1)).formatted(.number.precision(.fractionLength(2))) + " s"
    }

    /// The smallest offered window that keeps the chart at or below `maxWindows` points.
    static func automaticWindow(duration: Double, maxWindows: Int = 1000) -> Double {
        guard duration.isFinite, duration > 0 else { return 1 }
        let limit = Double(max(1, maxWindows))
        return windowChoices.first { duration / $0 <= limit } ?? (duration / limit).rounded(.up)
    }

    /// Bytes are attributed to the window holding each packet's presentation time. The
    /// final window is divided by its actual length so a short tail is not under-reported.
    func windows(size: Double) -> [BitrateWindow] {
        guard size.isFinite, size > 0, duration > 0 else { return [] }
        let count = max(1, Int((duration / size).rounded(.up)))
        var bytes = [Int](repeating: 0, count: count)
        for packet in packets {
            bytes[min(count - 1, max(0, Int(packet.seconds / size)))] += packet.bytes
        }
        return bytes.enumerated().compactMap { index, total in
            let start = Double(index) * size
            let length = min(size, duration - start)
            guard length > 0 else { return nil }
            return BitrateWindow(start: start, bitsPerSecond: Double(total) * 8 / length)
        }
    }

    /// Average bitrate over `span` seconds centred on `seconds`, clamped to the stream.
    func bitsPerSecond(around seconds: Double, span: Double = 1) -> Double? {
        guard seconds.isFinite, span > 0, duration > 0, !packets.isEmpty else { return nil }
        let length = min(span, duration)
        let start = max(0, min(seconds - length / 2, duration - length))
        let end = start + length
        var index = firstPacketIndex(atOrAfter: start)
        var total = 0
        while index < packets.count, packets[index].seconds < end {
            total += packets[index].bytes
            index += 1
        }
        return Double(total) * 8 / length
    }

    private func firstPacketIndex(atOrAfter seconds: Double) -> Int {
        var low = 0
        var high = packets.count
        while low < high {
            let middle = (low + high) / 2
            if packets[middle].seconds < seconds { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

enum BitrateFormatting {
    /// Chooses one unit for a chart so its axis does not mix kbit/s and Mbit/s.
    static func usesMegabits(peak: Double) -> Bool { peak >= 1_000_000 }

    static func string(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond.isFinite else { return "—" }
        if usesMegabits(peak: bitsPerSecond) {
            return (bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(2))) + " Mbit/s"
        }
        return (bitsPerSecond / 1_000).formatted(.number.precision(.fractionLength(0))) + " kbit/s"
    }
}

/// Reads packet sizes by stream-copying one stream into FFmpeg's `framecrc` muxer, which
/// demuxes without decoding. The app bundles no ffprobe, and this is just as fast.
actor BitrateAnalysisService {
    static let shared = BitrateAnalysisService()

    private struct CacheKey: Hashable {
        let path: String
        let size: Int?
        let modified: Date?
        let stream: BitrateStreamKind
    }

    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?
    private var cache: [CacheKey: BitrateTimeline] = [:]
    private var cacheOrder: [CacheKey] = []

    init(
        runner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func analyze(file: URL, stream: BitrateStreamKind) async throws -> BitrateTimeline {
        try Task.checkCancellation()
        guard let path = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let key = CacheKey(path: file.standardizedFileURL.path,
                           size: (attributes?[.size] as? NSNumber)?.intValue,
                           modified: attributes?[.modificationDate] as? Date,
                           stream: stream)
        if let cached = cache[key] { return cached }

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-v", "error",
                        "-i", file.path, "-map", stream.mapSpecifier,
                        "-c", "copy", "-f", "framecrc", "-"],
            timeout: .seconds(2 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [path, file.path]
        )
        let collector = BitratePacketCollector()
        let result = try await runner.run(request) { collector.consume($0) }
        try Task.checkCancellation()
        guard result.succeeded else {
            if result.standardErrorText.contains("matches no streams") {
                throw BitrateAnalysisError.noStream(stream)
            }
            throw BitrateAnalysisError.failed(request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        let timeline = try collector.finish(stream: stream)
        cache[key] = timeline
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > 8 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return timeline
    }
}

/// Parses `framecrc` lines (`stream, dts, pts, duration, size, crc[, F=0xflags]`) as they
/// stream in, so long files never need their whole listing in memory as text.
final class BitratePacketCollector: @unchecked Sendable {
    private struct RawPacket {
        let pts: Int64
        let duration: Int64
        let bytes: Int
        let isKeyframe: Bool
    }

    private static let noTimestamp = Int64.min
    private static let keyFlag: UInt = 0x1
    private static let discardFlag: UInt = 0x4

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var timeBase: (numerator: Int64, denominator: Int64)?
    private var codec: String?
    private var packets: [RawPacket] = []
    private var invalid = false

    func consume(_ chunk: SubprocessOutputChunk) {
        guard chunk.stream == .standardOutput else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: chunk.data)
        var lineStart = 0
        while let newline = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            parse(String(decoding: pending[lineStart..<newline], as: UTF8.self))
            lineStart = newline + 1
        }
        pending.removeFirst(lineStart)
        if pending.count > 64 * 1024 { invalid = true; pending.removeAll() }
    }

    func finish(stream: BitrateStreamKind) throws -> BitrateTimeline {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { parse(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        guard !invalid, let timeBase, timeBase.denominator > 0, !packets.isEmpty else {
            throw BitrateAnalysisError.noPackets
        }
        let scale = Double(timeBase.numerator) / Double(timeBase.denominator)
        let origin = packets.map(\.pts).min() ?? 0
        let ordered = packets.sorted { $0.pts < $1.pts }
        let end = ordered.map { $0.pts + max(0, $0.duration) }.max() ?? origin
        var duration = Double(end - origin) * scale
        let lastStart = Double((ordered.last?.pts ?? origin) - origin) * scale
        if duration <= lastStart {
            // Packets without durations: extend by the mean packet interval.
            duration = lastStart + (ordered.count > 1 ? lastStart / Double(ordered.count - 1) : 1)
        }
        return BitrateTimeline(
            stream: stream,
            codec: codec,
            packets: ordered.map {
                BitratePacket(seconds: Double($0.pts - origin) * scale, bytes: $0.bytes, isKeyframe: $0.isKeyframe)
            },
            duration: duration
        )
    }

    private func parse(_ line: String) {
        if line.hasPrefix("#") {
            parseHeader(line)
            return
        }
        let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 5 else { return }
        guard fields[0] == "0" else { return }
        guard let dts = Int64(fields[1]), let pts = Int64(fields[2]),
              let duration = Int64(fields[3]), let bytes = Int(fields[4]), bytes >= 0 else {
            invalid = true
            return
        }
        var flags = Self.keyFlag  // framecrc omits the field when the flags are exactly KEY.
        if let field = fields.dropFirst(5).first(where: { $0.hasPrefix("F=0x") }) {
            guard let parsed = UInt(field.dropFirst(4), radix: 16) else { invalid = true; return }
            flags = parsed
        }
        // Discarded packets (e.g. before an MP4 edit list start) are never presented.
        guard flags & Self.discardFlag == 0 else { return }
        let time = pts != Self.noTimestamp ? pts : dts != Self.noTimestamp ? dts : packets.last?.pts
        guard let time else { return }
        packets.append(RawPacket(pts: time, duration: duration, bytes: bytes,
                                 isKeyframe: flags & Self.keyFlag != 0))
    }

    private func parseHeader(_ line: String) {
        if line.hasPrefix("#tb 0:") {
            let parts = line.dropFirst("#tb 0:".count).trimmingCharacters(in: .whitespaces).split(separator: "/")
            guard parts.count == 2, let numerator = Int64(parts[0]), let denominator = Int64(parts[1]),
                  numerator > 0, denominator > 0 else { invalid = true; return }
            timeBase = (numerator, denominator)
        } else if line.hasPrefix("#codec_id 0:") {
            codec = line.dropFirst("#codec_id 0:".count).trimmingCharacters(in: .whitespaces)
        }
    }
}
