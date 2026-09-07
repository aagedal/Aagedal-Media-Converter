//
//  FFMPEGProbeService.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog
import SwiftMediaMetadata

/// Probe facade preserved for existing callers (ffprobe removed in favour of SwiftMediaMetadata).
enum FFMPEGProbeService {
    static let defaultTimeout: Duration = .seconds(15)

    struct AudioStreamInfo: Equatable, Sendable {
        let index: Int?
        let channels: Int?
        let channelLayout: String?
        let codecName: String?

        /// Returns true if FFmpeg can decode this audio stream.
        /// Streams with unknown codecs (like Apple's APAC spatial audio) return false.
        var isDecodable: Bool {
            guard let codec = codecName?.lowercased() else { return false }
            if codec.isEmpty { return false }
            let unsupportedCodecs = ["apac"] // Apple Positional Audio Codec (spatial audio)
            return !unsupportedCodecs.contains(codec)
        }
    }

    /// Fetches audio stream metadata for the supplied input URL via SwiftMediaMetadata.
    static func fetchAudioStreams(
        for url: URL,
        timeout: Duration = defaultTimeout
    ) async -> [AudioStreamInfo]? {
        await fetchAudioStreams(for: url, timeout: timeout) { url in
            try await resolvedAudioStreams(for: url, timeout: timeout)
        }
    }

    static func fetchAudioStreams(
        for url: URL,
        timeout: Duration,
        probe: @escaping @Sendable (URL) async throws -> [AudioStreamInfo]?
    ) async -> [AudioStreamInfo]? {
        do {
            return try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try await probe(url)
            }
        } catch is CancellationError {
            return nil
        } catch NonJoiningTaskDeadlineError.timedOut {
            Logger().warning("Audio stream probe timed out for \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            Logger().error("Audio stream probe failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func resolvedAudioStreams(
        for url: URL,
        timeout: Duration
    ) async throws -> [AudioStreamInfo]? {
        guard SwiftExifMediaProbe.canReadVideo(url) else {
            // Audio-only containers go through readAudio — still materialise a single
            // AudioStreamInfo so callers that expect a non-nil array keep working.
            if SwiftExifMediaProbe.canReadAudio(url),
               let meta = try? await withSecurityScopedAccess(to: url, operation: {
                   try await SwiftExifMediaProbe.readAudio(url)
               }) {
                return [AudioStreamInfo(
                    index: 0,
                    channels: meta.channels,
                    channelLayout: meta.channelLayout,
                    codecName: meta.codec
                )]
            }
            return []
        }

        let metadata = try await BoundedVideoMetadataProbe.metadata(for: url, timeout: timeout)
        let streams = metadata.audioStreams.map { AudioStreamInfo(
            index: $0.index,
            channels: $0.channels,
            channelLayout: $0.channelLayout,
            codecName: $0.codec
        ) }
        Logger().debug("SwiftMediaMetadata audio streams for \(url.lastPathComponent): \(streams.map { "\($0.codecName ?? "unknown"):\($0.channels ?? 0)ch" })")
        return streams
    }

    /// Returns the media duration reported by SwiftMediaMetadata (or AVFoundation fallback).
    static func getVideoDuration(
        for url: URL,
        timeout: Duration = defaultTimeout
    ) async -> Double? {
        await getVideoDuration(for: url, timeout: timeout) { url in
            await withSecurityScopedAccess(to: url) {
                await SwiftExifMediaProbe.duration(for: url)
            }
        }
    }

    static func getVideoDuration(
        for url: URL,
        timeout: Duration,
        probe: @escaping @Sendable (URL) async throws -> Double?
    ) async -> Double? {
        do {
            return try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try await probe(url)
            }
        } catch is CancellationError {
            return nil
        } catch NonJoiningTaskDeadlineError.timedOut {
            Logger().warning("Duration probe timed out for \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            Logger().error("Duration probe failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Chapters

    /// Fetches chapter markers for `url` via SwiftMediaMetadata's container parsers.
    ///
    /// Supports MP4/MOV `chpl` boxes, QuickTime text-track chapters, and
    /// Matroska `Chapters` master elements. Returns an empty array for
    /// containers SwiftMediaMetadata can't parse (e.g. FLV, raw audio) or that carry
    /// no chapter data.
    ///
    /// Chapters whose duration can't be determined (Matroska open-ended
    /// entries, Nero `chpl` boxes) get their end time inferred from the
    /// start of the next chapter or from the container duration.
    static func fetchChapters(
        for url: URL,
        timeout: Duration = defaultTimeout
    ) async -> [Chapter] {
        await fetchChapters(for: url, timeout: timeout) { url in
            try await withSecurityScopedAccess(to: url) {
                try await unboundedChapters(for: url)
            }
        }
    }

    static func fetchChapters(
        for url: URL,
        timeout: Duration,
        probe: @escaping @Sendable (URL) async throws -> [Chapter]
    ) async -> [Chapter] {
        guard SwiftExifMediaProbe.canReadVideo(url) else { return [] }

        do {
            return try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try await probe(url)
            }
        } catch is CancellationError {
            return []
        } catch NonJoiningTaskDeadlineError.timedOut {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "ChapterProbe")
                .warning("Chapter probe timed out for \(url.lastPathComponent, privacy: .public)")
            return []
        } catch {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "ChapterProbe")
                .debug("SwiftMediaMetadata chapter read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func unboundedChapters(for url: URL) async throws -> [Chapter] {
        let meta = try await SwiftExifMediaProbe.readVideo(url)

        let sorted = meta.chapters.sorted { $0.startTime < $1.startTime }
        let duration = meta.duration ?? 0

        return sorted.enumerated().compactMap { idx, chapter in
            let start = chapter.startTime
            let end: Double = {
                if let e = chapter.endTime { return e }
                // Open-ended: use the next chapter's start, else the container duration.
                if idx + 1 < sorted.count { return sorted[idx + 1].startTime }
                return duration > start ? duration : start
            }()
            guard end > start else { return nil }
            let id = chapter.id.map { Int(truncatingIfNeeded: $0) } ?? chapter.index
            return Chapter(id: id, start: start, end: end, title: chapter.title)
        }
    }
}

// MARK: - Post-Export Verification

extension FFMPEGProbeService {
    /// Result of verifying output file stream presence.
    struct StreamVerificationResult: Equatable, Sendable {
        let videoStreamCount: Int
        let audioStreamCount: Int
    }

    /// Probes the output file to count video and audio streams.
    /// Used as a safety check after merge/concat to detect silent data loss.
    static func verifyOutputStreams(
        for url: URL,
        timeout: Duration = defaultTimeout
    ) async -> StreamVerificationResult? {
        await verifyOutputStreams(for: url, timeout: timeout) { url in
            try await resolvedStreamVerification(for: url)
        }
    }

    static func verifyOutputStreams(
        for url: URL,
        timeout: Duration,
        probe: @escaping @Sendable (URL) async throws -> StreamVerificationResult?
    ) async -> StreamVerificationResult? {
        do {
            return try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try await probe(url)
            }
        } catch is CancellationError {
            return nil
        } catch NonJoiningTaskDeadlineError.timedOut {
            Logger().warning("Output stream verification timed out for \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            Logger().error("Output stream verification failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func resolvedStreamVerification(for url: URL) async throws -> StreamVerificationResult? {
        if SwiftExifMediaProbe.canReadVideo(url) {
            let metadata = try await withSecurityScopedAccess(to: url) {
                try await SwiftExifMediaProbe.readVideo(url)
            }
            let videoCount = metadata.videoStreams.filter { $0.isAttachedPic != true }.count
            let audioCount = metadata.audioStreams.count
            return StreamVerificationResult(videoStreamCount: videoCount, audioStreamCount: audioCount)
        }
        if SwiftExifMediaProbe.canReadAudio(url),
           (try? await withSecurityScopedAccess(to: url, operation: {
               try await SwiftExifMediaProbe.readAudio(url)
           })) != nil {
            return StreamVerificationResult(videoStreamCount: 0, audioStreamCount: 1)
        }
        return nil
    }
}

private extension FFMPEGProbeService {
    static func withSecurityScopedAccess<Output: Sendable>(
        to url: URL,
        operation: @escaping @Sendable () async throws -> Output
    ) async rethrows -> Output {
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        return try await operation()
    }
}
