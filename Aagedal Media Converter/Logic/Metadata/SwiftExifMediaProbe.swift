// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import OSLog
import SwiftMediaMetadata

/// In-process probe backed by SwiftMediaMetadata — replaces ffprobe for duration,
/// stream topology, and full metadata. Falls back to AVFoundation for container
/// formats SwiftMediaMetadata does not parse (FLV, WAV, raw AAC).
enum SwiftExifMediaProbe {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "SwiftExifMediaProbe")

    /// Extensions SwiftMediaMetadata can read (video containers + standalone audio).
    /// Kept in sync with `SwiftMediaMetadata.FormatDetector.detectVideoFromExtension` /
    /// `detectAudioFromExtension`.
    static let swiftExifVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v",
        "mxf",
        "mkv", "webm",
        "avi",
        "mpg", "mpeg", "vob", "ts", "m2ts", "mts"
    ]

    static let swiftExifAudioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "opus", "ogg", "oga"
    ]

    static func canReadVideo(_ url: URL) -> Bool {
        swiftExifVideoExtensions.contains(url.pathExtension.lowercased())
    }

    static func canReadAudio(_ url: URL) -> Bool {
        swiftExifAudioExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Reading

    /// Reads a SwiftMediaMetadata `VideoMetadata` off the main actor.
    static func readVideo(_ url: URL) async throws -> SwiftMediaMetadata.VideoMetadata {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let meta = try SwiftMediaMetadata.VideoMetadata.read(from: url)
                    continuation.resume(returning: meta)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads a SwiftMediaMetadata `AudioMetadata` off the main actor.
    static func readAudio(_ url: URL) async throws -> SwiftMediaMetadata.AudioMetadata {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let meta = try SwiftMediaMetadata.AudioMetadata.read(from: url)
                    continuation.resume(returning: meta)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Duration

    /// Returns the container duration in seconds, or nil when no parser can read it.
    /// Tries SwiftMediaMetadata first (for supported containers), then falls back to AVFoundation.
    static func duration(
        for url: URL,
        timeout: Duration = BoundedVideoMetadataProbe.defaultTimeout
    ) async -> Double? {
        await duration(for: url, timeout: timeout, probe: durationWithoutDeadline)
    }

    /// Bounds the entire parser/fallback chain, including callers outside the metadata
    /// service such as partial-download inspection. Late results cannot update the caller.
    static func duration(
        for url: URL,
        timeout: Duration,
        startAccess: @escaping @Sendable (URL) -> SecurityScopedAccess = {
            SecurityScopedBookmarkManager.shared.startAccessing(url: $0)
        },
        stopAccess: @escaping @Sendable (SecurityScopedAccess) -> Void = {
            SecurityScopedBookmarkManager.shared.stopAccessing($0)
        },
        probe: @escaping @Sendable (URL) async -> Double?
    ) async -> Double? {
        do {
            return try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try Task.checkCancellation()
                // Own access inside the non-joining worker: the caller can return and
                // release its access while an uncooperative parser is still reading.
                let access = startAccess(url)
                defer { stopAccess(access) }
                try Task.checkCancellation()
                let result = await probe(url)
                try Task.checkCancellation()
                return result
            }
        } catch {
            return nil
        }
    }

    /// Only for callers that already own a non-joining deadline and retain the
    /// applicable security scope until this entire operation returns.
    static func durationWithoutDeadline(for url: URL) async -> Double? {
        guard !Task.isCancelled else { return nil }
        if canReadVideo(url) {
            if let meta = try? await readVideo(url), let d = meta.duration, d > 0 {
                return d
            }
        }
        guard !Task.isCancelled else { return nil }
        if canReadAudio(url) {
            if let meta = try? await readAudio(url), let d = meta.duration, d > 0 {
                return d
            }
        }
        guard !Task.isCancelled else { return nil }
        return await avFoundationDuration(for: url)
    }

    private static func avFoundationDuration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            logger.warning("AVFoundation duration failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - H.273 → ffprobe string mappings

    /// Maps H.273 Table 2 color primaries code to the ffprobe string equivalent.
    static func primariesString(from code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 1: return "bt709"
        case 4: return "bt470m"
        case 5: return "bt470bg"
        case 6: return "smpte170m"
        case 7: return "smpte240m"
        case 8: return "film"
        case 9: return "bt2020"
        case 10: return "smpte428"
        case 11: return "smpte431"
        case 12: return "smpte432"
        case 22: return "ebu3213"
        case 2: return nil                // unspecified
        default: return nil
        }
    }

    /// Maps H.273 Table 3 transfer characteristics code to the ffprobe string equivalent.
    static func transferString(from code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 1: return "bt709"
        case 4: return "gamma22"
        case 5: return "gamma28"
        case 6: return "smpte170m"
        case 7: return "smpte240m"
        case 8: return "linear"
        case 9: return "log100"
        case 10: return "log316"
        case 11: return "iec61966-2-4"
        case 12: return "bt1361e"
        case 13: return "iec61966-2-1"
        case 14: return "bt2020-10"
        case 15: return "bt2020-12"
        case 16: return "smpte2084"
        case 17: return "smpte428"
        case 18: return "arib-std-b67"
        case 2: return nil
        default: return nil
        }
    }

    /// Maps H.273 Table 4 matrix coefficients code to the ffprobe string equivalent.
    static func matrixString(from code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 0: return "gbr"
        case 1: return "bt709"
        case 4: return "fcc"
        case 5: return "bt470bg"
        case 6: return "smpte170m"
        case 7: return "smpte240m"
        case 8: return "ycgco"
        case 9: return "bt2020nc"
        case 10: return "bt2020c"
        case 11: return "smpte2085"
        case 12: return "chroma-derived-nc"
        case 13: return "chroma-derived-c"
        case 14: return "ictcp"
        case 2: return nil
        default: return nil
        }
    }

    /// Maps full-range flag to the ffprobe colour-range string.
    static func rangeString(from fullRange: Bool?) -> String? {
        switch fullRange {
        case true: return "pc"
        case false: return "tv"
        case nil: return nil
        }
    }

    /// Maps a `VideoFieldOrder` to ffprobe's `field_order` string.
    static func fieldOrderString(from order: SwiftMediaMetadata.VideoFieldOrder?) -> String? {
        guard let order else { return nil }
        switch order {
        case .progressive: return "progressive"
        case .topFieldFirst: return "tt"
        case .bottomFieldFirst: return "bb"
        case .mixed: return "unknown"
        case .unknown: return nil
        }
    }
}
