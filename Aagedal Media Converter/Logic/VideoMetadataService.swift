// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import OSLog
import SwiftMediaMetadata

/// Applies a non-joining deadline to the shared in-process media probe while preserving
/// timeout and parent-cancellation errors for callers that need different fallback policy.
enum BoundedVideoMetadataProbe {
    static let defaultTimeout: Duration = .seconds(15)

    static func metadata(
        for url: URL,
        timeout: Duration = defaultTimeout,
        probe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async throws -> VideoMetadata {
        try Task.checkCancellation()
        let metadata = try await NonJoiningTaskDeadline.run(timeout: timeout) {
            try await probe(url)
        }
        try Task.checkCancellation()
        return metadata
    }

    static func essentialInfo(
        for url: URL,
        timeout: Duration = defaultTimeout,
        probe: @escaping @Sendable (URL) async throws -> EssentialVideoInfo = {
            try await VideoMetadataService.shared.fetchEssentialInfo(for: $0)
        }
    ) async throws -> EssentialVideoInfo {
        try Task.checkCancellation()
        let info = try await NonJoiningTaskDeadline.run(timeout: timeout) {
            try await probe(url)
        }
        try Task.checkCancellation()
        return info
    }

    /// Probes independent files concurrently so a large batch is bounded by one probe
    /// deadline instead of accumulating that deadline once per file. Individual failures
    /// remain absent from the result, while parent cancellation is preserved.
    static func availableMetadata(
        for urls: [URL],
        timeout: Duration = defaultTimeout,
        probe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async throws -> [URL: VideoMetadata] {
        try await withThrowingTaskGroup(of: (URL, VideoMetadata?).self) { group in
            for url in urls {
                group.addTask {
                    do {
                        return (url, try await metadata(for: url, timeout: timeout, probe: probe))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (url, nil)
                    }
                }
            }

            var result: [URL: VideoMetadata] = [:]
            for try await (url, metadata) in group {
                if let metadata {
                    result[url] = metadata
                }
            }
            return result
        }
    }
}

struct VideoMetadata: Equatable, Sendable {
    struct Ratio: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var doubleValue: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(numerator: Int, denominator: Int) {
            guard denominator != 0 else { return nil }
            self.numerator = numerator
            self.denominator = denominator
            self.stringValue = "\(numerator):\(denominator)"
        }

        init?(ratioString: String) {
            let trimmed = ratioString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let parsed = Ratio.parse(trimmed, separator: ":") ?? Ratio.parse(trimmed, separator: "/") {
                self = parsed
                return
            }

            if let value = Double(trimmed) {
                let scaledNumerator = Int((value * 10_000).rounded())
                self.numerator = scaledNumerator
                self.denominator = 10_000
                self.stringValue = String(format: value >= 10 ? "%.2f" : "%.4f", value)
                return
            }

            return nil
        }

        static func parse(_ string: String, separator: Character) -> Ratio? {
            let parts = string.split(separator: separator)
            guard parts.count == 2,
                  let numerator = Int(parts[0]),
                  let denominator = Int(parts[1]),
                  denominator != 0 else {
                return nil
            }
            return Ratio(numerator: numerator, denominator: denominator)
        }
    }

    struct FrameRate: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var value: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(frameRateString: String) {
            let trimmed = frameRateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let ratio = Ratio.parse(trimmed, separator: "/") {
                self.numerator = ratio.numerator
                self.denominator = ratio.denominator
                if let value = ratio.doubleValue {
                    self.stringValue = String(format: "%.3f", value)
                } else {
                    self.stringValue = trimmed
                }
                return
            }

            if let value = Double(trimmed), value > 0 {
                self.numerator = Int((value * 1_000).rounded())
                self.denominator = 1_000
                self.stringValue = String(format: "%.3f", value)
                return
            }

            return nil
        }

        /// Build a FrameRate from a floating-point frame rate (rounded to a rational with 1000 as denominator).
        init?(double value: Double?) {
            guard let value, value > 0, value.isFinite else { return nil }
            self.numerator = Int((value * 1_000).rounded())
            self.denominator = 1_000
            self.stringValue = String(format: "%.3f", value)
        }
    }

    let duration: Double?
    let formatName: String?
    let containerLongName: String?
    let sizeBytes: Int64?
    let bitRate: Int64?
    let comment: String?
    let timecode: String?
    let timecodes: [TimecodeEntry]
    let frameCount: Int?
    let containerCreationDate: Date?
    let containerModificationDate: Date?
    let title: String?
    let artist: String?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let gpsAltitude: Double?
    let warnings: [String]

    struct VideoStream: Equatable, Sendable {
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pixelFormat: String?
        let hasAlpha: Bool
        let pixelAspectRatio: Ratio?
        let displayAspectRatio: Ratio?
        let frameRate: FrameRate?
        let bitDepth: Int?
        let bitRate: Int64?
        let duration: Double?
        let chromaSubsampling: String?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let colorRange: String?
        let chromaLocation: String?
        let fieldOrder: String?
        let isInterlaced: Bool?
        let title: String?
        let isDefault: Bool
        let isForced: Bool

        /// Calculates chroma channel resolution based on subsampling
        /// Returns nil for 4:4:4 (same as luma), grayscale, or unknown subsampling
        var chromaResolution: (width: Int, height: Int)? {
            guard let width, let height, let subsampling = chromaSubsampling else { return nil }

            // 4:4:4 has same resolution as luma, no need to show separately
            let factors: (h: Int, v: Int)? = switch subsampling {
            case "4:2:2": (2, 1)  // Half horizontal
            case "4:2:0": (2, 2)  // Half horizontal and vertical
            case "4:1:1": (4, 1)  // Quarter horizontal
            case "4:1:0": (4, 2)  // Quarter horizontal, half vertical
            default: nil
            }

            guard let factors else { return nil }
            return (width / factors.h, height / factors.v)
        }

        /// Formatted string for chroma resolution display
        var chromaResolutionDescription: String? {
            guard let res = chromaResolution else { return nil }
            return "\(res.width)×\(res.height)"
        }
    }

    struct AudioStream: Equatable, Sendable {
        let index: Int?
        let languageCode: String?
        let title: String?
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let sampleRate: Int?
        let channels: Int?
        let channelLayout: String?
        let bitDepth: Int?
        let bitRate: Int64?
        let isDefault: Bool
    }

    struct SubtitleStream: Equatable, Sendable {
        let index: Int?
        let languageCode: String?
        let title: String?
        let codec: String?
        let codecLongName: String?
        let isDefault: Bool
        let isForced: Bool
        let isHearingImpaired: Bool
        let duration: Double?
    }

    let videoStreams: [VideoStream]
    let audioStreams: [AudioStream]
    let subtitleStreams: [SubtitleStream]

    /// Returns the primary video stream (first non-cover-art stream)
    /// Use this for operations that need a single stream (crop, aspect ratio, codec detection)
    var primaryVideoStream: VideoStream? {
        videoStreams.first
    }

    func isDefaultAudioStream(index: Int) -> Bool {
        guard audioStreams.indices.contains(index) else { return false }
        return audioStreams[index].isDefault
    }
}

enum VideoMetadataError: Error {
    case unsupportedContainer
    case readFailed(String)
}

/// Essential video information needed for import (obtained in a single probe call)
struct EssentialVideoInfo: Sendable {
    let duration: Double
    let hasVideoStream: Bool
    let videoStreamCount: Int
    let hasAudioStream: Bool
    let primaryCodec: String?
    let width: Int?
    let height: Int?
}

actor VideoMetadataService {
    static let shared = VideoMetadataService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoMetadata")
    private let cache: NSCache<NSURL, CachedMetadata> = {
        let c = NSCache<NSURL, CachedMetadata>()
        c.countLimit = 256
        return c
    }()
    private let essentialInfoCache: NSCache<NSURL, CachedEssentialInfo> = {
        let c = NSCache<NSURL, CachedEssentialInfo>()
        c.countLimit = 1024
        return c
    }()
    private let hasVideoStreamCache: NSCache<NSURL, CachedBool> = {
        let c = NSCache<NSURL, CachedBool>()
        c.countLimit = 1024
        return c
    }()

    // Single-flight tables: concurrent callers for the same URL await the same Task
    // instead of each spawning a fresh SwiftMediaMetadata parse (heavy for large MKV/MXF files).
    private var inFlightMetadata: [URL: Task<VideoMetadata, Error>] = [:]
    private var inFlightEssential: [URL: Task<EssentialVideoInfo, Error>] = [:]
    // Shared single-flight at the SwiftMediaMetadata layer: when both fetchEssentialInfo and
    // metadata(for:) race for the same URL (typical `async let` import flow), they
    // coalesce onto one readVideo parse instead of two.
    private var inFlightRawVideo: [URL: Task<SwiftMediaMetadata.VideoMetadata, Error>] = [:]

    private final class CachedMetadata: NSObject {
        let metadata: VideoMetadata
        init(metadata: VideoMetadata) {
            self.metadata = metadata
        }
    }

    private final class CachedEssentialInfo: NSObject {
        let info: EssentialVideoInfo
        init(info: EssentialVideoInfo) {
            self.info = info
        }
    }

    private final class CachedBool: NSObject {
        let value: Bool
        init(value: Bool) {
            self.value = value
        }
    }

    // MARK: - Cached Duration Lookup

    /// Returns cached duration if available from either metadata cache or essential info cache.
    /// Returns nil if not cached (caller should fall back to probing).
    func cachedDuration(for url: URL) -> Double? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.metadata.duration
        }
        if let cached = essentialInfoCache.object(forKey: url as NSURL) {
            return cached.info.duration
        }
        return nil
    }

    /// Returns cached hasVideoStream if available from either cache.
    /// Returns nil if not cached.
    func cachedHasVideoStream(for url: URL) -> Bool? {
        if let cached = hasVideoStreamCache.object(forKey: url as NSURL) {
            return cached.value
        }
        if let cached = cache.object(forKey: url as NSURL) {
            return !cached.metadata.videoStreams.isEmpty
        }
        if let cached = essentialInfoCache.object(forKey: url as NSURL) {
            return cached.info.hasVideoStream
        }
        return nil
    }

    // MARK: - Fast Video Stream Detection

    /// Checks whether the file has at least one timed video track (excluding cover art).
    /// SwiftMediaMetadata memory-maps the file so this stays fast even for multi-gigabyte inputs.
    /// AV2 `.ivf` sources can't be read by SwiftMediaMetadata or AVFoundation, so derive their essential
    /// video info (dimensions, frame-rate-derived duration) directly from the IVF container
    /// header. Without this they're misclassified as non-video and routed through the audio /
    /// waveform-synthesis path. Returns nil for anything that isn't a recognizable AV2 `.ivf`.
    private func av2EssentialInfo(for url: URL) -> EssentialVideoInfo? {
        guard url.pathExtension.lowercased() == "ivf",
              let header = IVFHeaderParser.parse(url: url), header.isAV2 else {
            return nil
        }
        return EssentialVideoInfo(
            duration: header.durationSeconds ?? 0,
            hasVideoStream: true,
            videoStreamCount: 1,
            hasAudioStream: false,
            primaryCodec: "av2",
            width: header.width,
            height: header.height
        )
    }

    func hasVideoStream(for url: URL) async -> Bool {
        if let cached = hasVideoStreamCache.object(forKey: url as NSURL) {
            return cached.value
        }

        if let cached = essentialInfoCache.object(forKey: url as NSURL) {
            hasVideoStreamCache.setObject(CachedBool(value: cached.info.hasVideoStream), forKey: url as NSURL)
            return cached.info.hasVideoStream
        }

        if av2EssentialInfo(for: url) != nil {
            hasVideoStreamCache.setObject(CachedBool(value: true), forKey: url as NSURL)
            return true
        }

        let scope = startAccess(for: url)
        defer { stopAccess(scope, for: url) }

        guard SwiftExifMediaProbe.canReadVideo(url) else {
            // Audio-only container / unsupported format — treat as "no video".
            hasVideoStreamCache.setObject(CachedBool(value: false), forKey: url as NSURL)
            return false
        }

        do {
            let meta = try await SwiftExifMediaProbe.readVideo(url)
            let timedVideo = meta.videoStreams.filter { $0.isAttachedPic != true }
            let hasVideo = !timedVideo.isEmpty
            hasVideoStreamCache.setObject(CachedBool(value: hasVideo), forKey: url as NSURL)
            return hasVideo
        } catch {
            logger.warning("SwiftMediaMetadata hasVideoStream probe failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Assuming video exists.")
            return true
        }
    }

    /// Fetches essential video info in one parse (optimized for bulk imports).
    /// Returns: duration, hasVideoStream, videoStreamCount, hasAudioStream, primaryCodec, width, height.
    func fetchEssentialInfo(for url: URL) async throws -> EssentialVideoInfo {
        if let cached = essentialInfoCache.object(forKey: url as NSURL) {
            return cached.info
        }
        if let inFlight = inFlightEssential[url] {
            return try await inFlight.value
        }

        let task = Task { [weak self] () throws -> EssentialVideoInfo in
            guard let self else { throw CancellationError() }
            return try await self.performFetchEssentialInfo(for: url)
        }
        inFlightEssential[url] = task
        defer { inFlightEssential.removeValue(forKey: url) }
        return try await task.value
    }

    /// Single-flight wrapper around `SwiftExifMediaProbe.readVideo`. Concurrent callers
    /// (typically `fetchEssentialInfo` and `metadata(for:)` racing via `async let`)
    /// share one parse instead of each spawning their own.
    private func readRawVideo(for url: URL) async throws -> SwiftMediaMetadata.VideoMetadata {
        if let inFlight = inFlightRawVideo[url] {
            return try await inFlight.value
        }
        let task = Task.detached {
            try await SwiftExifMediaProbe.readVideo(url)
        }
        inFlightRawVideo[url] = task
        defer { inFlightRawVideo.removeValue(forKey: url) }
        return try await task.value
    }

    private func performFetchEssentialInfo(for url: URL) async throws -> EssentialVideoInfo {
        let scope = startAccess(for: url)
        defer { stopAccess(scope, for: url) }

        // AV2 .ivf: derive video info from the IVF header (SwiftMediaMetadata/AVFoundation can't read it).
        if let av2Info = av2EssentialInfo(for: url) {
            essentialInfoCache.setObject(CachedEssentialInfo(info: av2Info), forKey: url as NSURL)
            hasVideoStreamCache.setObject(CachedBool(value: true), forKey: url as NSURL)
            return av2Info
        }

        let info: EssentialVideoInfo
        if SwiftExifMediaProbe.canReadVideo(url) {
            do {
                let meta = try await readRawVideo(for: url)
                let timedVideo = meta.videoStreams.filter { $0.isAttachedPic != true }
                let primary = timedVideo.first
                info = EssentialVideoInfo(
                    duration: meta.duration ?? 0,
                    hasVideoStream: !timedVideo.isEmpty,
                    videoStreamCount: timedVideo.count,
                    hasAudioStream: !meta.audioStreams.isEmpty,
                    primaryCodec: primary?.codec,
                    width: primary?.width,
                    height: primary?.height
                )
            } catch {
                throw VideoMetadataError.readFailed(error.localizedDescription)
            }
        } else if SwiftExifMediaProbe.canReadAudio(url) {
            let audio = try? await SwiftExifMediaProbe.readAudio(url)
            let audioDuration: Double
            if let d = audio?.duration {
                audioDuration = d
            } else {
                audioDuration = await SwiftExifMediaProbe.duration(for: url) ?? 0
            }
            info = EssentialVideoInfo(
                duration: audioDuration,
                hasVideoStream: false,
                videoStreamCount: 0,
                hasAudioStream: audio != nil,
                primaryCodec: nil,
                width: nil,
                height: nil
            )
        } else {
            // Formats SwiftMediaMetadata doesn't parse (e.g. FLV, WAV, raw AAC): AVFoundation covers duration.
            let duration = await SwiftExifMediaProbe.duration(for: url) ?? 0
            info = EssentialVideoInfo(
                duration: duration,
                hasVideoStream: false,
                videoStreamCount: 0,
                hasAudioStream: false,
                primaryCodec: nil,
                width: nil,
                height: nil
            )
        }

        essentialInfoCache.setObject(CachedEssentialInfo(info: info), forKey: url as NSURL)
        hasVideoStreamCache.setObject(CachedBool(value: info.hasVideoStream), forKey: url as NSURL)
        return info
    }

    func metadata(for url: URL) async throws -> VideoMetadata {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.metadata
        }
        if let inFlight = inFlightMetadata[url] {
            return try await inFlight.value
        }

        let task = Task { [weak self] () throws -> VideoMetadata in
            guard let self else { throw CancellationError() }
            return try await self.performMetadataFetch(for: url)
        }
        inFlightMetadata[url] = task
        defer { inFlightMetadata.removeValue(forKey: url) }
        return try await task.value
    }

    private func performMetadataFetch(for url: URL) async throws -> VideoMetadata {
        let scope = startAccess(for: url)
        defer { stopAccess(scope, for: url) }

        guard SwiftExifMediaProbe.canReadVideo(url) else {
            throw VideoMetadataError.unsupportedContainer
        }

        let rawMeta: SwiftMediaMetadata.VideoMetadata
        do {
            rawMeta = try await readRawVideo(for: url)
        } catch {
            throw VideoMetadataError.readFailed(error.localizedDescription)
        }

        let metadata = buildMetadata(from: rawMeta, url: url)
        cache.setObject(CachedMetadata(metadata: metadata), forKey: url as NSURL)

        // Seed the secondary caches so later callers don't re-probe.
        let hasVideo = !metadata.videoStreams.isEmpty
        hasVideoStreamCache.setObject(CachedBool(value: hasVideo), forKey: url as NSURL)

        let essentialInfo = EssentialVideoInfo(
            duration: metadata.duration ?? 0,
            hasVideoStream: hasVideo,
            videoStreamCount: metadata.videoStreams.count,
            hasAudioStream: !metadata.audioStreams.isEmpty,
            primaryCodec: metadata.primaryVideoStream?.codec,
            width: metadata.primaryVideoStream?.width,
            height: metadata.primaryVideoStream?.height
        )
        essentialInfoCache.setObject(CachedEssentialInfo(info: essentialInfo), forKey: url as NSURL)

        return metadata
    }

    // MARK: - Security Scope

    private enum AccessScope {
        case direct
        case bookmark
        case none
    }

    private nonisolated func startAccess(for url: URL) -> AccessScope {
        if url.startAccessingSecurityScopedResource() { return .direct }
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            return .bookmark
        }
        return .none
    }

    private nonisolated func stopAccess(_ scope: AccessScope, for url: URL) {
        switch scope {
        case .direct: url.stopAccessingSecurityScopedResource()
        case .bookmark: SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
        case .none: break
        }
    }

    // MARK: - Mapping

    private nonisolated func buildMetadata(from meta: SwiftMediaMetadata.VideoMetadata, url: URL) -> VideoMetadata {
        let timedVideo = meta.videoStreams.filter { $0.isAttachedPic != true }
        let primary = timedVideo.first

        let video = timedVideo.map { Self.mapVideoStream($0) }
        let audio = meta.audioStreams.map { Self.mapAudioStream($0) }
        let subtitles = meta.subtitleStreams.map { Self.mapSubtitleStream($0) }

        // Frame count: prefer the primary stream's frameCount, else derive from duration × fps.
        let frameCount: Int? = {
            if let c = primary?.frameCount, c > 0 { return c }
            if let d = meta.duration,
               d > 0,
               let fps = primary?.avgFrameRate ?? primary?.rFrameRate ?? primary?.frameRate,
               fps > 0 {
                return Int(round(d * fps))
            }
            return nil
        }()

        let timecodes = meta.timecodes.map { tc in
            TimecodeEntry(
                value: tc.value,
                source: Self.mapTimecodeSource(tc.source),
                frameRate: tc.frameRate
            )
        }

        return VideoMetadata(
            duration: meta.duration,
            formatName: meta.format.rawValue,
            containerLongName: meta.formatLongName,
            sizeBytes: meta.fileSize,
            bitRate: meta.bitRate.map { Int64($0) },
            comment: meta.comment,
            timecode: meta.timecode ?? primary?.timecode,
            timecodes: timecodes,
            frameCount: frameCount,
            containerCreationDate: meta.creationDate,
            containerModificationDate: meta.modificationDate,
            title: meta.title,
            artist: meta.artist,
            gpsLatitude: meta.gpsLatitude,
            gpsLongitude: meta.gpsLongitude,
            gpsAltitude: meta.gpsAltitude,
            warnings: meta.warnings,
            videoStreams: video,
            audioStreams: audio,
            subtitleStreams: subtitles
        )
    }

    private static func mapTimecodeSource(_ source: SwiftMediaMetadata.TimecodeSource) -> TimecodeSource {
        switch source {
        case .tmcdTrack: return .tmcdTrack
        case .quicktimeUdta: return .quicktimeUdta
        case .xmpDM: return .xmpDM
        case .xmpDMAlt: return .xmpDMAlt
        case .mxfMaterialPackage: return .mxfMaterialPackage
        case .mxfFilePackage: return .mxfFilePackage
        case .sonyNRT: return .sonyNRT
        case .redR3D: return .redR3D
        }
    }

    static func mapVideoStream(_ stream: SwiftMediaMetadata.VideoStream) -> VideoMetadata.VideoStream {
        let pixelFormat = stream.pixelFormat
        let hasAlpha = pixelFormat.map { hasAlphaChannel(pixelFormat: $0) } ?? false
        let bitDepth = stream.bitDepth ?? pixelFormat.flatMap { bitDepthFromPixelFormat($0) }
        let chromaSubsampling = stream.chromaSubsampling ?? pixelFormat.flatMap { chromaSubsamplingFromPixelFormat($0) }

        // Frame rate: avgFrameRate preferred, then rFrameRate, then the single `frameRate` scalar.
        let frameRate: VideoMetadata.FrameRate? = {
            if let fr = stream.avgFrameRate, let r = VideoMetadata.FrameRate(double: fr) { return r }
            if let fr = stream.rFrameRate, let r = VideoMetadata.FrameRate(double: fr) { return r }
            if let fr = stream.frameRate, let r = VideoMetadata.FrameRate(double: fr) { return r }
            return nil
        }()

        // Pixel aspect ratio as Ratio.
        let par: VideoMetadata.Ratio? = {
            if let (num, den) = stream.pixelAspectRatio {
                return VideoMetadata.Ratio(numerator: num, denominator: den)
            }
            return nil
        }()

        // Display aspect ratio: prefer displayWidth/Height, else derive PAR × width/height.
        let dar: VideoMetadata.Ratio? = {
            if let dw = stream.displayWidth, let dh = stream.displayHeight, dw > 0, dh > 0 {
                return VideoMetadata.Ratio(numerator: dw, denominator: dh)
            }
            if let w = stream.width, let h = stream.height,
               let (pn, pd) = stream.pixelAspectRatio, pd > 0, h > 0 {
                let num = w * pn
                let den = h * pd
                return VideoMetadata.Ratio(numerator: num, denominator: den)
            }
            return nil
        }()

        let fieldOrderString = SwiftExifMediaProbe.fieldOrderString(from: stream.fieldOrder)
        let isInterlaced: Bool? = stream.fieldOrder.map { $0 != .progressive && $0 != .unknown && $0 != .mixed ? true : ($0 == .progressive ? false : nil) } ?? nil
        // Simpler: progressive → false, unknown/mixed → nil, anything else (TFF/BFF) → true.
        let interlaced: Bool? = {
            guard let order = stream.fieldOrder else { return nil }
            switch order {
            case .progressive: return false
            case .topFieldFirst, .bottomFieldFirst: return true
            case .mixed, .unknown: return nil
            }
        }()
        _ = isInterlaced

        let color = stream.colorInfo
        let colorPrimaries = SwiftExifMediaProbe.primariesString(from: color?.primaries)
        let colorTransfer = SwiftExifMediaProbe.transferString(from: color?.transfer)
        let colorSpace = SwiftExifMediaProbe.matrixString(from: color?.matrix)
        let colorRange = SwiftExifMediaProbe.rangeString(from: color?.fullRange)

        return VideoMetadata.VideoStream(
            codec: stream.codec,
            codecLongName: stream.codecName,
            profile: stream.profile,
            width: stream.width,
            height: stream.height,
            pixelFormat: pixelFormat,
            hasAlpha: hasAlpha,
            pixelAspectRatio: par,
            displayAspectRatio: dar,
            frameRate: frameRate,
            bitDepth: bitDepth,
            bitRate: stream.bitRate.map { Int64($0) },
            duration: stream.duration,
            chromaSubsampling: chromaSubsampling,
            colorPrimaries: colorPrimaries,
            colorTransfer: colorTransfer,
            colorSpace: colorSpace,
            colorRange: colorRange,
            chromaLocation: stream.chromaLocation,
            fieldOrder: fieldOrderString,
            isInterlaced: interlaced,
            title: stream.title,
            isDefault: stream.isDefault ?? false,
            isForced: stream.isForced ?? false
        )
    }

    static func mapAudioStream(_ stream: SwiftMediaMetadata.AudioStream) -> VideoMetadata.AudioStream {
        VideoMetadata.AudioStream(
            index: stream.index,
            languageCode: stream.language?.lowercased(),
            title: stream.title,
            codec: stream.codec,
            codecLongName: stream.codecName,
            profile: stream.profile,
            sampleRate: stream.sampleRate,
            channels: stream.channels,
            channelLayout: stream.channelLayout,
            bitDepth: stream.bitDepth,
            bitRate: stream.bitRate.map { Int64($0) },
            isDefault: stream.isDefault ?? false
        )
    }

    static func mapSubtitleStream(_ stream: SwiftMediaMetadata.SubtitleStream) -> VideoMetadata.SubtitleStream {
        VideoMetadata.SubtitleStream(
            index: stream.index,
            languageCode: stream.language?.lowercased(),
            title: stream.title,
            codec: stream.codec,
            codecLongName: stream.codecName,
            isDefault: stream.isDefault ?? false,
            isForced: stream.isForced ?? false,
            isHearingImpaired: stream.isHearingImpaired ?? false,
            duration: stream.duration
        )
    }
}

// MARK: - Pixel-format helpers (kept for fallback when SwiftMediaMetadata already surfaces most fields)

/// Extracts bit depth from pixel format string
/// Examples: yuv420p10le -> 10, yuv422p12be -> 12, yuv420p -> 8
private func bitDepthFromPixelFormat(_ pixelFormat: String) -> Int? {
    let format = pixelFormat.lowercased()

    let patterns = [
        #"(\d{1,2})(le|be)?$"#,
        #"p(\d{1,2})(le|be)?$"#,
    ]

    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: format, options: [], range: NSRange(format.startIndex..., in: format)) {
            let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            if let range = Range(captureRange, in: format),
               let bitDepth = Int(format[range]),
               bitDepth >= 8 && bitDepth <= 16 {
                return bitDepth
            }
        }
    }

    if format.contains("24") || format.contains("32") {
        return 8
    }

    if format.contains("48") || format.contains("64") {
        return 16
    }

    let eightBitPatterns = ["yuv420p", "yuv422p", "yuv444p", "yuvj420p", "yuvj422p", "yuvj444p", "nv12", "nv21"]
    for pattern in eightBitPatterns {
        if format == pattern {
            return 8
        }
    }

    return nil
}

/// Extracts chroma subsampling from pixel format string
/// Examples: yuv420p -> "4:2:0", yuv422p10le -> "4:2:2", yuv444p -> "4:4:4"
private func chromaSubsamplingFromPixelFormat(_ pixelFormat: String) -> String? {
    let format = pixelFormat.lowercased()

    if format.contains("420") || format.contains("nv12") || format.contains("nv21") {
        return "4:2:0"
    }

    if format.contains("422") || format.contains("yuyv") || format.contains("uyvy") {
        return "4:2:2"
    }

    if format.contains("444") {
        return "4:4:4"
    }

    if format.contains("411") {
        return "4:1:1"
    }

    if format.contains("410") {
        return "4:1:0"
    }

    if format.hasPrefix("rgb") || format.hasPrefix("bgr") || format.hasPrefix("argb") ||
       format.hasPrefix("abgr") || format.hasPrefix("rgba") || format.hasPrefix("bgra") ||
       format.hasPrefix("gbr") {
        return "4:4:4"
    }

    if format.hasPrefix("gray") || format.hasPrefix("mono") || format == "y" {
        return nil
    }

    return nil
}

/// Detects if a pixel format contains an alpha channel.
private func hasAlphaChannel(pixelFormat: String) -> Bool {
    let format = pixelFormat.lowercased()

    if format.contains("4444") { return true }
    if format.contains("rgba") || format.contains("bgra") ||
       format.contains("argb") || format.contains("abgr") { return true }
    if format.hasPrefix("yuva") { return true }
    if format.hasPrefix("gbrap") { return true }
    if format.contains("alpha") { return true }

    let alphaPatterns = ["rgba", "bgra", "argb", "yuva", "gbrap"]
    for pattern in alphaPatterns {
        if format.hasPrefix(pattern) { return true }
    }

    return false
}
