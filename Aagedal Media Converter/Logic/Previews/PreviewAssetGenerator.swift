// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import AppKit
import OSLog
import CryptoKit
import AVFoundation
import CoreImage

/// Represents a single chunk of a waveform image for progressive loading
struct WaveformChunk: Sendable, Identifiable, Equatable {
    let id: Int              // Chunk index (0, 1, 2, ...)
    let url: URL             // Path to chunk image file
    let startTime: Double    // Start time in seconds
    let duration: Double     // Chunk duration in seconds
}

struct PreviewAssets: Sendable {
    let rowThumbnail: URL?
    let thumbnails: [URL]
    let waveform: URL?
    let audioWaveforms: [Int: URL]

    // Chunked waveform support for long files
    let waveformChunks: [WaveformChunk]
    let audioWaveformChunks: [Int: [WaveformChunk]]
    let totalDuration: Double  // Total media duration for chunk width calculation

    // Native waveform images (in-memory, no disk I/O)
    let nativeWaveformImage: SendableImage?
    let nativePerStreamWaveformImages: [Int: SendableImage]

    // Per-channel waveform images (one image per audio channel, not just per stream)
    let nativeChannelWaveform: SendableChannelWaveform?
    let nativePerStreamChannelWaveforms: [Int: SendableChannelWaveform]

    /// Expected total number of chunks based on duration
    var expectedChunkCount: Int {
        guard totalDuration > 0 else { return 0 }
        return Int(ceil(totalDuration / 600.0))  // 10-minute chunks
    }

    func waveform(forAudioStream streamIndex: Int?) -> URL? {
        guard let streamIndex else { return waveform }
        return audioWaveforms[streamIndex] ?? waveform
    }

    func waveformChunks(forAudioStream streamIndex: Int?) -> [WaveformChunk] {
        guard let streamIndex else { return waveformChunks }
        return audioWaveformChunks[streamIndex] ?? waveformChunks
    }

    func nativeWaveform(forAudioStream streamIndex: Int?) -> NSImage? {
        guard let streamIndex else { return nativeWaveformImage?.image }
        return nativePerStreamWaveformImages[streamIndex]?.image ?? nativeWaveformImage?.image
    }

    func nativeChannelWaveforms(forAudioStream streamIndex: Int?) -> SendableChannelWaveform? {
        guard let streamIndex else { return nativeChannelWaveform }
        // Don't fall back to the default (stream 0) waveform — return nil so
        // on-demand generation triggers for the requested stream.
        if let perStream = nativePerStreamChannelWaveforms[streamIndex] {
            return perStream
        }
        // Stream 0 data is stored in nativeChannelWaveform, not in the per-stream dict
        if streamIndex == 0 { return nativeChannelWaveform }
        return nil
    }
}

enum PreviewAssetError: Error, LocalizedError {
    case ffmpegBinaryMissing
    case durationUnavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegBinaryMissing:
            return "FFmpeg binary not found in application bundle."
        case .durationUnavailable:
            return "Unable to determine media duration for preview generation."
        case .generationFailed(let message):
            return "Failed to generate preview assets: \(message)"
        }
    }
}

struct PreviewMediaFacts: Sendable {
    let metadata: VideoMetadata?
    let duration: Double
    let hasVideoStream: Bool
}

/// A data-only frame request. Workers never receive cache destinations, so a decoder
/// completing after its deadline cannot overwrite a fallback or a newer generation.
struct PreviewThumbnailRequest: Sendable {
    let index: Int
    let position: Double
    let width: CGFloat
    let tolerance: Double
}

/// Only AVFoundation's cancellation entry points cross executors. Configuration and
/// image generation stay on the one rendering worker; the generator itself is never
/// exposed to other work as a generally Sendable object.
private final class NativePreviewCancellation: @unchecked Sendable {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    init(asset: AVURLAsset, generator: AVAssetImageGenerator) {
        self.asset = asset
        self.generator = generator
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
        asset.cancelLoading()
    }
}

actor PreviewAssetGenerator {
    static let shared = PreviewAssetGenerator()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewAssets")
    private let fileManager = FileManager.default
    private let subprocessRunner: any SubprocessRunning
    private let thumbnailTimeout: Duration
    private let thumbnailRenderer: @Sendable (URL, [PreviewThumbnailRequest]) async throws -> [Int: Data]
    private let metadataTimeout: Duration
    private let metadataProbe: @Sendable (URL) async throws -> VideoMetadata
    private let essentialInfoProbe: @Sendable (URL) async throws -> EssentialVideoInfo
    private let thumbnailCount = 6
    private let waveformSize = "1000x90"
    private let rowThumbnailSize = "640:-1"  // 640px width for row thumbnail
    private let waveformFilename = "waveform.png"
    private let legacyWaveformFilename = "waveform.png"
    private func waveformFilename(for streamIndex: Int) -> String { "waveform_a\(streamIndex).png" }

    // Chunked waveform settings
    private let chunkDurationSeconds: Double = 600  // 10 minutes per chunk
    private let chunkHeight: Int = 90
    private let totalWaveformWidth: Int = 1000  // Target total width for all chunks combined
    private func waveformChunkFilename(chunkIndex: Int) -> String { "waveform_chunk_\(chunkIndex).png" }
    private func waveformChunkFilename(for streamIndex: Int, chunkIndex: Int) -> String { "waveform_a\(streamIndex)_chunk_\(chunkIndex).png" }

    /// Tracks all running preview subprocess tasks for cleanup on app termination.
    private var runningProcessTasks: [UUID: Task<SubprocessResult, Error>] = [:]

    /// Tracks running subprocess tasks by source URL for targeted cancellation.
    private var processTasksPerURL: [URL: Set<UUID>] = [:]

    private struct InProgressGeneration {
        let id: UUID
        let task: Task<PreviewAssets, Error>
    }

    /// Tracks in-progress asset generation tasks to prevent duplicate work.
    /// The identity prevents cleanup from an older cancelled attempt removing its replacement.
    private var inProgressGenerations: [URL: InProgressGeneration] = [:]

    /// In-memory cache for per-channel waveforms (keyed by URL, then stream index)
    /// Survives across trim view open/close cycles since PreviewAssetGenerator is a singleton actor
    private var channelWaveformCache: [URL: [Int: SendableChannelWaveform]] = [:]

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        metadataTimeout: Duration = BoundedVideoMetadataProbe.defaultTimeout,
        thumbnailTimeout: Duration = .seconds(15),
        thumbnailRenderer: @escaping @Sendable (URL, [PreviewThumbnailRequest]) async throws -> [Int: Data] = {
            try await PreviewAssetGenerator.renderNativeThumbnails(url: $0, requests: $1)
        },
        metadataProbe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        },
        essentialInfoProbe: @escaping @Sendable (URL) async throws -> EssentialVideoInfo = {
            try await VideoMetadataService.shared.fetchEssentialInfo(for: $0)
        }
    ) {
        self.subprocessRunner = subprocessRunner
        self.metadataTimeout = metadataTimeout
        self.thumbnailTimeout = thumbnailTimeout
        self.thumbnailRenderer = thumbnailRenderer
        self.metadataProbe = metadataProbe
        self.essentialInfoProbe = essentialInfoProbe
    }

    /// Resolves the media facts needed by both preview entry points without allowing a
    /// non-cooperative parser to pin the preview actor. Video containers normally resolve
    /// everything in one rich metadata read; unsupported/audio-only inputs use the bounded
    /// essential-info fallback instead.
    func resolveMediaFacts(for url: URL) async throws -> PreviewMediaFacts {
        var resolvedMetadata: VideoMetadata?
        do {
            let metadata = try await BoundedVideoMetadataProbe.metadata(
                for: url,
                timeout: metadataTimeout,
                probe: metadataProbe
            )
            resolvedMetadata = metadata
            if let duration = metadata.duration, duration > 0 {
                return PreviewMediaFacts(
                    metadata: metadata,
                    duration: duration,
                    hasVideoStream: !metadata.videoStreams.isEmpty
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Do not immediately re-enter the same potentially stalled parser through the
            // fallback. The caller can fail or fall back after this one deadline window.
            throw NonJoiningTaskDeadlineError.timedOut
        } catch {
            // Unsupported containers and ordinary read failures may still have useful
            // duration/topology information through the essential-info path.
        }

        let info = try await BoundedVideoMetadataProbe.essentialInfo(
            for: url,
            timeout: metadataTimeout,
            probe: essentialInfoProbe
        )
        guard info.duration > 0 else {
            throw PreviewAssetError.durationUnavailable
        }
        return PreviewMediaFacts(
            metadata: resolvedMetadata,
            duration: info.duration,
            hasVideoStream: resolvedMetadata.map { !$0.videoStreams.isEmpty }
                ?? info.hasVideoStream
        )
    }

    /// Terminates all running FFmpeg/FFprobe processes
    /// Call this when the app is about to quit to prevent orphaned processes
    func terminateAllProcesses() {
        logger.info("Terminating \(self.runningProcessTasks.count) running preview processes")
        for generation in inProgressGenerations.values {
            generation.task.cancel()
        }
        for task in runningProcessTasks.values {
            task.cancel()
        }
    }

    /// Cancels asset generation for a specific URL
    /// Active subprocesses for the URL are cancelled through the shared runner so their
    /// descendants cannot outlive the preview request.
    func cancelGeneration(for url: URL) {
        logger.info("Cancelling asset generation for \(url.lastPathComponent, privacy: .public)")

        if let generation = inProgressGenerations[url] {
            generation.task.cancel()
            inProgressGenerations.removeValue(forKey: url)
        }

        for taskID in processTasksPerURL[url] ?? [] {
            runningProcessTasks[taskID]?.cancel()
        }
    }

    /// Clears the entire preview cache directory.
    func cleanupAllCache() async {
        let baseDirectory = AppConstants.previewCacheDirectory
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            logger.info("Cache directory does not exist, nothing to clear")
            return
        }

        do {
            var totalSize: Int64 = 0
            if let enumerator = fileManager.enumerator(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                while let entry = enumerator.nextObject() as? URL {
                    if let size = try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalSize += Int64(size)
                    }
                }
            }

            try fileManager.removeItem(at: baseDirectory)
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

            let sizeMB = Double(totalSize) / (1024 * 1024)
            logger.info("Cleared preview cache directory, freed \(sizeMB, format: .fixed(precision: 1)) MB")
        } catch {
            logger.error("Failed to clear preview cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Calculates the current on-disk size of the preview cache directory in bytes.
    func cacheDirectorySizeInBytes() async -> Int64 {
        let baseDirectory = AppConstants.previewCacheDirectory
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return 0
        }

        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            while let entry = enumerator.nextObject() as? URL {
                if let size = try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }

        return totalSize
    }

    /// Applies a cleanup policy by triggering the corresponding cleanup routine.
    func applyCleanupPolicy(_ policy: PreviewCacheCleanupPolicy) async {
        switch policy {
        case .purgeOnLaunch:
            await cleanupAllCache()
        case .keepOneDay:
            await cleanupOldCache(olderThanDays: 1)
        case .keepThreeDays:
            await cleanupOldCache(olderThanDays: 3)
        case .keepSevenDays:
            await cleanupOldCache(olderThanDays: 7)
        case .manual:
            logger.info("Preview cache cleanup set to manual; automatic cleanup skipped")
        }
    }

    /// Returns the asset directory for a given video URL, creating it if needed
    func getAssetDirectory(for url: URL) throws -> URL {
        try ensureAssetDirectory(for: url)
    }

    /// Returns cached assets if all required files already exist on disk
    func cachedAssetsIfPresent(for url: URL) async -> PreviewAssets? {
        do {
            let assetDirectory = try ensureAssetDirectory(for: url)

            // Check for row thumbnail (prefer .png, fallback to legacy .jpg)
            let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.png", isDirectory: false)
            let legacyRowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg", isDirectory: false)
            let rowURL: URL? = fileManager.fileExists(atPath: rowThumbnailURL.path) ? rowThumbnailURL :
                               (fileManager.fileExists(atPath: legacyRowThumbnailURL.path) ? legacyRowThumbnailURL : nil)

            // Check for filmstrip thumbnails (prefer .png, fallback to legacy .jpg)
            let thumbnailURLs: [URL] = (0..<thumbnailCount).compactMap { index in
                let pngURL = assetDirectory.appendingPathComponent("thumb_\(index).png", isDirectory: false)
                let jpgURL = assetDirectory.appendingPathComponent("thumb_\(index).jpg", isDirectory: false)
                if fileManager.fileExists(atPath: pngURL.path) { return pngURL }
                if fileManager.fileExists(atPath: jpgURL.path) { return jpgURL }
                return nil
            }

            let waveformURL = assetDirectory.appendingPathComponent(waveformFilename, isDirectory: false)
            let legacyWaveformURL = assetDirectory.appendingPathComponent(legacyWaveformFilename, isDirectory: false)
            // Also check for legacy .jpg waveforms
            let legacyJpgWaveformURL = assetDirectory.appendingPathComponent("waveform.jpg", isDirectory: false)
            let waveform = [waveformURL, legacyWaveformURL, legacyJpgWaveformURL].first { fileManager.fileExists(atPath: $0.path) }

            // Check for existing per-stream waveforms WITHOUT fetching metadata
            // Scan the directory for waveform_a*.png/jpg files to avoid spawning ffprobe
            var audioWaveforms: [Int: URL] = [:]
            var waveformChunks: [WaveformChunk] = []
            var audioWaveformChunks: [Int: [WaveformChunk]] = [:]

            if let contents = try? fileManager.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    let filename = fileURL.lastPathComponent

                    // Match pattern: waveform_chunk_{index}.png (default stream chunks)
                    if filename.hasPrefix("waveform_chunk_") && filename.hasSuffix(".png") {
                        let indexPart = filename
                            .replacingOccurrences(of: "waveform_chunk_", with: "")
                            .replacingOccurrences(of: ".png", with: "")
                        if let chunkIndex = Int(indexPart) {
                            let startTime = Double(chunkIndex) * chunkDurationSeconds
                            let chunk = WaveformChunk(
                                id: chunkIndex,
                                url: fileURL,
                                startTime: startTime,
                                duration: chunkDurationSeconds  // Estimated; last chunk may be shorter
                            )
                            waveformChunks.append(chunk)
                        }
                    }
                    // Match pattern: waveform_a{stream}_chunk_{index}.png (per-stream chunks)
                    else if filename.hasPrefix("waveform_a") && filename.contains("_chunk_") && filename.hasSuffix(".png") {
                        // Extract stream index and chunk index
                        // Format: waveform_a{stream}_chunk_{index}.png
                        let withoutPrefix = filename.replacingOccurrences(of: "waveform_a", with: "")
                        let parts = withoutPrefix.split(separator: "_")
                        if parts.count >= 3,
                           let streamIndex = Int(parts[0]),
                           parts[1] == "chunk",
                           let chunkIndex = Int(parts[2].replacingOccurrences(of: ".png", with: "")) {
                            let startTime = Double(chunkIndex) * chunkDurationSeconds
                            let chunk = WaveformChunk(
                                id: chunkIndex,
                                url: fileURL,
                                startTime: startTime,
                                duration: chunkDurationSeconds
                            )
                            if audioWaveformChunks[streamIndex] == nil {
                                audioWaveformChunks[streamIndex] = []
                            }
                            audioWaveformChunks[streamIndex]?.append(chunk)
                        }
                    }
                    // Match pattern: waveform_a{index}.png or .jpg (legacy per-stream single waveforms)
                    else if filename.hasPrefix("waveform_a") && !filename.contains("_chunk_") &&
                            (filename.hasSuffix(".png") || filename.hasSuffix(".jpg")) {
                        let indexPart = filename
                            .replacingOccurrences(of: "waveform_a", with: "")
                            .replacingOccurrences(of: ".png", with: "")
                            .replacingOccurrences(of: ".jpg", with: "")
                        if let index = Int(indexPart) {
                            // Prefer .png over .jpg if both exist
                            if audioWaveforms[index] == nil || filename.hasSuffix(".png") {
                                audioWaveforms[index] = fileURL
                            }
                        }
                    }
                }
            }

            // Sort chunks by id
            waveformChunks.sort { $0.id < $1.id }
            for key in audioWaveformChunks.keys {
                audioWaveformChunks[key]?.sort { $0.id < $1.id }
            }

            // Estimate total duration from chunk count (actual duration may vary)
            let estimatedDuration = waveformChunks.isEmpty ? 0 : Double(waveformChunks.count) * chunkDurationSeconds

            // Merge in-memory channel waveform cache
            let cachedChannelWaveforms = channelWaveformCache[url] ?? [:]
            let channelWaveform = cachedChannelWaveforms[0]
            let perStreamChannelWaveforms = cachedChannelWaveforms.filter { $0.key != 0 || channelWaveform == nil }

            if rowURL == nil && thumbnailURLs.isEmpty && waveform == nil && audioWaveforms.isEmpty && waveformChunks.isEmpty && channelWaveform == nil {
                return nil
            }

            return PreviewAssets(
                rowThumbnail: rowURL,
                thumbnails: thumbnailURLs,
                waveform: waveform,
                audioWaveforms: audioWaveforms,
                waveformChunks: waveformChunks,
                audioWaveformChunks: audioWaveformChunks,
                totalDuration: estimatedDuration,
                nativeWaveformImage: nil,
                nativePerStreamWaveformImages: [:],
                nativeChannelWaveform: channelWaveform,
                nativePerStreamChannelWaveforms: perStreamChannelWaveforms
            )
        } catch {
            logger.debug("Failed to load cached assets for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    /// Cleans up all cached assets for a given video URL
    func cleanupAssets(for url: URL) {
        do {
            let directory = try ensureAssetDirectory(for: url)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
                logger.info("Cleaned up asset directory for \(url.lastPathComponent, privacy: .public)")
            }
        } catch {
            logger.error("Failed to cleanup assets for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Cleans up old cached assets that haven't been accessed in the specified number of days
    func cleanupOldCache(olderThanDays days: Int = 7) async {
        let baseDirectory = AppConstants.previewCacheDirectory
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            logger.info("Cache directory does not exist, no cleanup needed")
            return
        }
        
        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        logger.info("Cleaning up cache older than \(cutoffDate, privacy: .public)")
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.contentAccessDateKey],
                options: []
            )
            
            var removedCount = 0
            var totalSize: Int64 = 0
            
            for itemURL in contents {
                guard itemURL.hasDirectoryPath else { continue }
                
                do {
                    let resourceValues = try itemURL.resourceValues(forKeys: [.contentAccessDateKey])
                    let accessDate = resourceValues.contentAccessDate ?? Date.distantPast
                    
                    if accessDate < cutoffDate {
                        // Calculate size before removal using recursive directory listing
                        var directorySize: Int64 = 0
                        if let fileURLs = fileManager.enumerator(at: itemURL, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] {
                            for fileURL in fileURLs {
                                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                    directorySize += Int64(size)
                                }
                            }
                        }
                        totalSize += directorySize
                        
                        try fileManager.removeItem(at: itemURL)
                        removedCount += 1
                        logger.debug("Removed old cache directory: \(itemURL.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    logger.warning("Failed to check/remove cache item \(itemURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            
            if removedCount > 0 {
                let sizeMB = Double(totalSize) / (1024 * 1024)
                logger.info("Cleaned up \(removedCount) old cache directories, freed \(String(format: "%.1f", sizeMB)) MB")
            } else {
                logger.info("No old cache directories to clean up")
            }
        } catch {
            logger.error("Failed to enumerate cache directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    func generateAssets(for url: URL) async throws -> PreviewAssets {
        // Check if there's already an in-progress generation for this URL
        // If so, await the existing task instead of starting a duplicate
        if let existingGeneration = inProgressGenerations[url] {
            logger.info("Reusing in-progress asset generation for \(url.lastPathComponent, privacy: .public)")
            return try await existingGeneration.task.value
        }

        logger.info("Starting asset generation for \(url.lastPathComponent, privacy: .public)")

        // Create a task for this generation and store it in the dictionary
        let generationID = UUID()
        let generationTask = Task<PreviewAssets, Error> {
            try await self.performAssetGeneration(for: url)
        }
        inProgressGenerations[url] = InProgressGeneration(id: generationID, task: generationTask)

        do {
            let result = try await generationTask.value
            if inProgressGenerations[url]?.id == generationID {
                inProgressGenerations.removeValue(forKey: url)
            }
            return result
        } catch {
            if inProgressGenerations[url]?.id == generationID {
                inProgressGenerations.removeValue(forKey: url)
            }
            throw error
        }
    }

    /// Generates per-channel waveform for a specific audio stream on demand.
    /// Called when the user switches to an audio track that hasn't been generated yet.
    /// Returns nil if generation fails (non-fatal).
    func generateChannelWaveformForStream(
        url: URL,
        streamIndex: Int,
        channelCount: Int,
        channelLayout: String?,
        duration: Double
    ) async -> SendableChannelWaveform? {
        // Check cache first
        if let cached = channelWaveformCache[url]?[streamIndex] {
            return cached
        }

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else { return nil }

        let access = startAccessingSecurityScope(for: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let width = max(800, min(12000, Int(duration * 8.0)))
        let height = 160

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let (images, labels) = try await NativeWaveformRenderer.generatePerChannelWaveforms(
                url: url,
                ffmpegPath: ffmpegPath,
                streamIndex: streamIndex,
                channelCount: channelCount,
                channelLayout: channelLayout,
                duration: duration,
                width: width,
                heightPerChannel: height
            )
            let waveform = SendableChannelWaveform(channelImages: images, channelLabels: labels)

            // Cache the result
            var urlCache = channelWaveformCache[url] ?? [:]
            urlCache[streamIndex] = waveform
            channelWaveformCache[url] = urlCache

            let t1 = CFAbsoluteTimeGetCurrent()
            logger.info("On-demand per-channel waveform for stream \(streamIndex) generated in \(String(format: "%.2f", t1 - t0))s (\(channelCount) channels) for \(url.lastPathComponent, privacy: .public)")
            return waveform
        } catch {
            logger.warning("On-demand per-channel waveform failed for stream \(streamIndex) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Internal implementation of asset generation, called only once per URL
    private func performAssetGeneration(for url: URL) async throws -> PreviewAssets {
        let access = startAccessingSecurityScope(for: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            logger.error("FFmpeg binary not found")
            throw PreviewAssetError.ffmpegBinaryMissing
        }

        let assetDirectory = try ensureAssetDirectory(for: url)
        logger.info("Asset directory: \(assetDirectory.path, privacy: .public)")
        let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.png", isDirectory: false)
        let expectedThumbnailURLs = (0..<thumbnailCount).map { index in
            assetDirectory.appendingPathComponent("thumb_\(index).png", isDirectory: false)
        }
        let waveformURL = assetDirectory.appendingPathComponent(waveformFilename, isDirectory: false)
        let legacyWaveformURL = assetDirectory.appendingPathComponent(legacyWaveformFilename, isDirectory: false)

        let mediaFacts: PreviewMediaFacts
        do {
            mediaFacts = try await resolveMediaFacts(for: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Media information unavailable while preparing preview assets for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw PreviewAssetError.durationUnavailable
        }
        let metadata = mediaFacts.metadata
        let hasVideoStream = mediaFacts.hasVideoStream
        let duration = mediaFacts.duration

        let rowThumbnailMissing = !fileManager.fileExists(atPath: rowThumbnailURL.path)
        let missingThumbnailIndices: [Int] = hasVideoStream ? expectedThumbnailURLs.enumerated().compactMap { index, url in
            fileManager.fileExists(atPath: url.path) ? nil : index
        } : []
        let existingWaveformURL = [waveformURL, legacyWaveformURL].first { fileManager.fileExists(atPath: $0.path) }
        var existingPerStreamWaveforms: [Int: URL] = [:]
        if let metadata {
            metadata.audioStreams.enumerated().forEach { index, _ in
                let customURL = assetDirectory.appendingPathComponent(waveformFilename(for: index), isDirectory: false)
                if fileManager.fileExists(atPath: customURL.path) {
                    existingPerStreamWaveforms[index] = customURL
                }
            }
        }
        let waveformMissing = existingWaveformURL == nil

        // Check for existing waveform chunks
        var existingWaveformChunks: [WaveformChunk] = []
        var existingPerStreamWaveformChunks: [Int: [WaveformChunk]] = [:]
        if let contents = try? fileManager.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                let filename = fileURL.lastPathComponent
                if filename.hasPrefix("waveform_chunk_") && filename.hasSuffix(".png") {
                    let indexPart = filename
                        .replacingOccurrences(of: "waveform_chunk_", with: "")
                        .replacingOccurrences(of: ".png", with: "")
                    if let chunkIndex = Int(indexPart) {
                        let startTime = Double(chunkIndex) * chunkDurationSeconds
                        let chunk = WaveformChunk(id: chunkIndex, url: fileURL, startTime: startTime, duration: chunkDurationSeconds)
                        existingWaveformChunks.append(chunk)
                    }
                } else if filename.hasPrefix("waveform_a") && filename.contains("_chunk_") && filename.hasSuffix(".png") {
                    let withoutPrefix = filename.replacingOccurrences(of: "waveform_a", with: "")
                    let parts = withoutPrefix.split(separator: "_")
                    if parts.count >= 3,
                       let streamIndex = Int(parts[0]),
                       parts[1] == "chunk",
                       let chunkIndex = Int(parts[2].replacingOccurrences(of: ".png", with: "")) {
                        let startTime = Double(chunkIndex) * chunkDurationSeconds
                        let chunk = WaveformChunk(id: chunkIndex, url: fileURL, startTime: startTime, duration: chunkDurationSeconds)
                        if existingPerStreamWaveformChunks[streamIndex] == nil {
                            existingPerStreamWaveformChunks[streamIndex] = []
                        }
                        existingPerStreamWaveformChunks[streamIndex]?.append(chunk)
                    }
                }
            }
            existingWaveformChunks.sort { $0.id < $1.id }
            for key in existingPerStreamWaveformChunks.keys {
                existingPerStreamWaveformChunks[key]?.sort { $0.id < $1.id }
            }
        }

        // We no longer check waveformMissing for early return since we're using chunks now
        // Chunks need duration to determine if complete, so we always proceed to get duration
        if !rowThumbnailMissing && missingThumbnailIndices.isEmpty {
            // For now, continue to get duration to check chunk completion
        }

        logger.info("Row thumbnail missing: \(rowThumbnailMissing), filmstrip thumbnails missing: \(missingThumbnailIndices.count), waveform missing: \(waveformMissing)")

        let hdrType = hasVideoStream
            ? detectHDRRequirement(from: metadata?.primaryVideoStream)
            : .none

        if rowThumbnailMissing {
            if hasVideoStream {
                try await generateRowThumbnail(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    duration: duration,
                    destination: rowThumbnailURL,
                    hdrType: hdrType
                )
            } else {
                try await generateAudioRowThumbnail(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    duration: duration,
                    destination: rowThumbnailURL
                )
            }
        }

        if hasVideoStream && !missingThumbnailIndices.isEmpty {
            await generateThumbnails(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: duration,
                assetDirectory: assetDirectory,
                missingIndices: missingThumbnailIndices,
                expectedFiles: expectedThumbnailURLs,
                hdrType: hdrType
            )

            var remainingMissing = expectedThumbnailURLs.enumerated().compactMap { index, url in
                fileManager.fileExists(atPath: url.path) ? nil : index
            }

            if !remainingMissing.isEmpty {
                logger.warning("Retrying filmstrip generation with simplified pipeline for \(remainingMissing.count) thumbnails of \(url.lastPathComponent, privacy: .public)")
                await generateThumbnails(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    duration: duration,
                    assetDirectory: assetDirectory,
                    missingIndices: remainingMissing,
                    expectedFiles: expectedThumbnailURLs,
                    hdrType: .none,
                    useSimplifiedFilter: true
                )

                remainingMissing = expectedThumbnailURLs.enumerated().compactMap { index, url in
                    fileManager.fileExists(atPath: url.path) ? nil : index
                }

                if !remainingMissing.isEmpty {
                    logger.error("Unable to generate \(remainingMissing.count) filmstrip thumbnails for \(url.lastPathComponent, privacy: .public) after fallback attempts")
                }
            }
        } else if !hasVideoStream {
            logger.info("Skipping filmstrip thumbnails for \(url.lastPathComponent, privacy: .public) because no video stream was detected")
        }

        // Generate native waveform images (fast: single FFmpeg PCM decode + Swift render)
        var nativeWaveformImage: SendableImage?
        var nativePerStreamImages: [Int: SendableImage] = [:]

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = try await NativeWaveformRenderer.generateWaveform(
                url: url,
                ffmpegPath: ffmpegPath,
                streamIndex: 0,
                duration: duration,
                width: totalWaveformWidth,
                height: chunkHeight
            )
            nativeWaveformImage = SendableImage(image: image)
            let t1 = CFAbsoluteTimeGetCurrent()
            logger.info("Native waveform generated in \(String(format: "%.2f", t1 - t0))s for \(url.lastPathComponent, privacy: .public)")

            // Generate per-stream waveforms for files with multiple audio tracks
            if let metadata, metadata.audioStreams.count > 1 {
                for (index, _) in metadata.audioStreams.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let streamImage = try await NativeWaveformRenderer.generateWaveform(
                            url: url,
                            ffmpegPath: ffmpegPath,
                            streamIndex: index,
                            duration: duration,
                            width: totalWaveformWidth,
                            height: chunkHeight
                        )
                        nativePerStreamImages[index] = SendableImage(image: streamImage)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logger.warning("Native waveform failed for stream \(index) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Native waveform generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to FFmpeg showwavespic.")

            // Fallback: generate chunked waveforms using legacy showwavespic approach
            let expectedChunkCount = Int(ceil(duration / chunkDurationSeconds))
            let chunksAreMissing = existingWaveformChunks.count < expectedChunkCount

            if chunksAreMissing {
                do {
                    try await generateChunkedWaveform(
                        url: url,
                        ffmpegPath: ffmpegPath,
                        assetDirectory: assetDirectory,
                        duration: duration,
                        audioStreamIndex: 0,
                        existingChunks: &existingWaveformChunks
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning("Chunked waveform fallback also failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            if let metadata, metadata.audioStreams.count > 1 {
                let perStreamChunksAreMissing = metadata.audioStreams.enumerated().contains { index, _ in
                    (existingPerStreamWaveformChunks[index]?.count ?? 0) < expectedChunkCount
                }
                if perStreamChunksAreMissing {
                    await generatePerStreamChunkedWaveforms(
                        url: url,
                        ffmpegPath: ffmpegPath,
                        assetDirectory: assetDirectory,
                        duration: duration,
                        metadata: metadata,
                        existingChunks: &existingPerStreamWaveformChunks
                    )
                }
            }
        }

        // Generate per-channel waveform images for the first audio stream only.
        // Additional streams are generated on demand when the user switches audio tracks.
        let perChannelWidth = max(800, min(12000, Int(duration * 8.0)))
        let perChannelHeight = 160
        var nativeChannelWaveform: SendableChannelWaveform?
        let nativePerStreamChannelWaveforms: [Int: SendableChannelWaveform] = [:]

        if let metadata, !metadata.audioStreams.isEmpty {
            let stream0 = metadata.audioStreams[0]
            let channels0 = stream0.channels ?? 2
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let (images, labels) = try await NativeWaveformRenderer.generatePerChannelWaveforms(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    streamIndex: 0,
                    channelCount: channels0,
                    channelLayout: stream0.channelLayout,
                    duration: duration,
                    width: perChannelWidth,
                    heightPerChannel: perChannelHeight
                )
                let waveform = SendableChannelWaveform(channelImages: images, channelLabels: labels)
                nativeChannelWaveform = waveform
                // Cache for persistence across trim view open/close cycles
                var urlCache = channelWaveformCache[url] ?? [:]
                urlCache[0] = waveform
                channelWaveformCache[url] = urlCache
                let t1 = CFAbsoluteTimeGetCurrent()
                logger.info("Per-channel waveform generated in \(String(format: "%.2f", t1 - t0))s (\(channels0) channels) for \(url.lastPathComponent, privacy: .public)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Per-channel waveform failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let generatedRowThumbnail = fileManager.fileExists(atPath: rowThumbnailURL.path) ? rowThumbnailURL : nil
        let availableThumbnails = expectedThumbnailURLs.filter { fileManager.fileExists(atPath: $0.path) }
        if availableThumbnails.count < expectedThumbnailURLs.count {
            logger.warning("Only \(availableThumbnails.count) / \(expectedThumbnailURLs.count) filmstrip thumbnails available for \(url.lastPathComponent, privacy: .public)")
        }
        let generatedWaveformURL = existingWaveformURL
        logger.info("Asset generation complete. Row thumbnail: \(generatedRowThumbnail != nil), filmstrip: \(availableThumbnails.count), native waveform: \(nativeWaveformImage != nil), per-stream: \(nativePerStreamImages.count), per-channel: \(nativeChannelWaveform != nil)")
        return PreviewAssets(
            rowThumbnail: generatedRowThumbnail,
            thumbnails: availableThumbnails,
            waveform: generatedWaveformURL,
            audioWaveforms: existingPerStreamWaveforms,
            waveformChunks: existingWaveformChunks,
            audioWaveformChunks: existingPerStreamWaveformChunks,
            totalDuration: duration,
            nativeWaveformImage: nativeWaveformImage,
            nativePerStreamWaveformImages: nativePerStreamImages,
            nativeChannelWaveform: nativeChannelWaveform,
            nativePerStreamChannelWaveforms: nativePerStreamChannelWaveforms
        )
    }

    /// Generates only the row thumbnail (fast, no waveform or filmstrip)
    /// Returns the thumbnail data if successful
    func generateRowThumbnail(for url: URL) async throws -> Data? {
        logger.info("Generating row thumbnail on-demand for \(url.lastPathComponent, privacy: .public)")
        let access = startAccessingSecurityScope(for: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let assetDirectory = try ensureAssetDirectory(for: url)
        let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.png", isDirectory: false)

        // Also check for legacy .jpg format
        let legacyRowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg", isDirectory: false)
        if fileManager.fileExists(atPath: rowThumbnailURL.path) {
            logger.info("Row thumbnail already cached")
            return try? Data(contentsOf: rowThumbnailURL)
        } else if fileManager.fileExists(atPath: legacyRowThumbnailURL.path) {
            logger.info("Legacy row thumbnail found")
            return try? Data(contentsOf: legacyRowThumbnailURL)
        }

        // AV2 .ivf: no decoder (AVFoundation/FFmpeg) can read it — decode a frame with avmdec.
        if url.pathExtension.lowercased() == "ivf" {
            return try await generateAV2RowThumbnail(url: url, destination: rowThumbnailURL)
        }

        let mediaFacts: PreviewMediaFacts
        do {
            mediaFacts = try await resolveMediaFacts(for: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Media information unavailable while generating a row thumbnail for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw PreviewAssetError.durationUnavailable
        }
        let hasVideoStream = mediaFacts.hasVideoStream

        if hasVideoStream {
            // Try AVFoundation first (in-process, fast for Apple-native formats)
            if let data = try await generateRowThumbnailWithAVFoundation(url: url, duration: mediaFacts.duration, destination: rowThumbnailURL) {
                return data
            }

            // Fall back to FFmpeg for formats AVFoundation can't handle (MKV, MXF, etc.)
            logger.info("AVFoundation thumbnail failed for \(url.lastPathComponent, privacy: .public); falling back to FFmpeg")

            guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
                logger.error("FFmpeg binary not found")
                throw PreviewAssetError.ffmpegBinaryMissing
            }

            let duration = mediaFacts.duration
            let hdrType = detectHDRRequirement(from: mediaFacts.metadata?.primaryVideoStream)

            try await generateRowThumbnail(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: duration,
                destination: rowThumbnailURL,
                hdrType: hdrType
            )
        } else {
            guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
                logger.error("FFmpeg binary not found")
                throw PreviewAssetError.ffmpegBinaryMissing
            }

            try await generateAudioRowThumbnail(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: mediaFacts.duration,
                destination: rowThumbnailURL
            )
        }

        if fileManager.fileExists(atPath: rowThumbnailURL.path) {
            logger.info("Row thumbnail generated successfully")
            return try? Data(contentsOf: rowThumbnailURL)
        }

        return nil
    }

    /// Extensions where AVFoundation cannot open the container at all — skip to FFmpeg directly.
    private static let avFoundationUnsupportedExtensions: Set<String> = [
        "avi", "asf", "dv", "flv", "gxf", "mkv", "mk3d", "mxf",
        "ogv", "ogm", "ogg", "oga", "rm", "rmvb", "roq", "ts",
        "mts", "m2ts", "m2t", "trp", "vob", "webm", "wmv", "wtv", "y4m"
    ]

    /// Generates a row thumbnail for an AV2 `.ivf` source by decoding a single frame with
    /// avmdec to a temporary Y4M file, then converting it to PNG with FFmpeg. Returns nil on
    /// any failure (the caller then falls back to the generic placeholder).
    private func generateAV2RowThumbnail(url: URL, destination: URL) async throws -> Data? {
        guard IVFHeaderParser.parse(url: url)?.isAV2 == true,
              let avmdecPath = BinaryPathResolver.avmdecPath,
              let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            return nil
        }
        let tempY4M = fileManager.temporaryDirectory.appendingPathComponent("av2thumb-\(UUID().uuidString).y4m")
        defer { try? fileManager.removeItem(at: tempY4M) }
        do {
            // Decode one frame to self-describing Y4M (native chroma / bit depth).
            try await runProcess(
                executable: URL(fileURLWithPath: avmdecPath),
                arguments: [url.path, "--limit=1", "-o", tempY4M.path],
                forURL: url,
                outputURL: tempY4M
            )

            let rawSize = ((try? fileManager.attributesOfItem(atPath: tempY4M.path))?[.size] as? Int) ?? 0
            guard rawSize > 0 else { return nil }

            let maxDim = max(2, Int(AppConstants.maxThumbnailSize.width))
            // Convert the decoded frame to a PNG thumbnail (FFmpeg reads Y4M format/depth itself).
            try await runProcess(
                executable: URL(fileURLWithPath: ffmpegPath),
                arguments: [
                    "-y", "-nostdin",
                    "-i", tempY4M.path,
                    "-frames:v", "1",
                    "-vf", "scale=\(maxDim):-2",
                    destination.path
                ],
                forURL: url,
                outputURL: destination
            )

            return try? Data(contentsOf: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("AV2 thumbnail generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Publishes only the result accepted by the deadline. The detached worker retains
    /// its own source access until it exits, even if the caller has already fallen back.
    /// Module-visible for deadline and publication tests with an injected renderer.
    func generateNativeThumbnails(
        url: URL,
        requests: [PreviewThumbnailRequest],
        destinations: [URL]
    ) async throws -> [Int: Data] {
        try Task.checkCancellation()
        let renderer = thumbnailRenderer
        let images = try await NonJoiningTaskDeadline.run(timeout: thumbnailTimeout) {
            let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
            defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
            return try await renderer(url, requests)
        }
        try Task.checkCancellation()
        var published: [Int: Data] = [:]
        for request in requests {
            try Task.checkCancellation()
            guard destinations.indices.contains(request.index),
                  let data = images[request.index], !data.isEmpty else { continue }
            try data.write(to: destinations[request.index], options: .atomic)
            published[request.index] = data
        }
        return published
    }

    private func generateRowThumbnailWithAVFoundation(
        url: URL,
        duration: Double,
        destination: URL
    ) async throws -> Data? {
        guard !Self.avFoundationUnsupportedExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        do {
            let images = try await generateNativeThumbnails(
                url: url,
                requests: [PreviewThumbnailRequest(
                    index: 0, position: min(10, max(duration * 0.1, 0.5)), width: 640, tolerance: 2
                )],
                destinations: [destination]
            )
            return images[0]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("AVFoundation thumbnail failed or timed out for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Runs wholly outside the preview actor, including track loading and PNG encoding.
    /// Cancellation asks AVFoundation to stop; the non-joining deadline remains the
    /// guarantee for callers when a system decoder does not promptly cooperate.
    nonisolated static func renderNativeThumbnails(
        url: URL,
        requests: [PreviewThumbnailRequest]
    ) async throws -> [Int: Data] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cancellation = NativePreviewCancellation(asset: asset, generator: generator)
        return try await withTaskCancellationHandler {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return [:]
            }
            try Task.checkCancellation()
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            try Task.checkCancellation()
            let isProResRAW = descriptions.contains {
                let code = CMFormatDescriptionGetMediaSubType($0)
                return code == 0x6170726E || code == 0x61707268
            }
            let context = CIContext()
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            var images: [Int: Data] = [:]
            for request in requests {
                try Task.checkCancellation()
                generator.maximumSize = CGSize(width: request.width, height: 0)
                generator.requestedTimeToleranceBefore = CMTime(seconds: request.tolerance, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
                do {
                    let (image, _) = try await generator.image(at: CMTime(seconds: request.position, preferredTimescale: 600))
                    try Task.checkCancellation()
                    var ciImage = CIImage(cgImage: image)
                    if isProResRAW, let filter = CIFilter(name: "CIToneMapHeadroom", parameters: [
                        kCIInputImageKey: ciImage,
                        "inputSourceHeadroom": 8.0,
                        "inputTargetHeadroom": 1.0
                    ]), let tonemapped = filter.outputImage {
                        ciImage = tonemapped
                    }
                    if let data = context.pngRepresentation(of: ciImage, format: .RGBA8, colorSpace: srgb) {
                        images[request.index] = data
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // An individual decode failure leaves this index for FFmpeg fallback.
                }
            }
            try Task.checkCancellation()
            return images
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func generateAudioRowThumbnail(
        url: URL,
        ffmpegPath: String,
        duration: Double,
        destination: URL
    ) async throws {
        let prefs = AudioWaveformPreferences.loadConfig()
        let width = Int(prefs.resolution.width)
        let height = Int(prefs.resolution.height)
        let colorHex = prefs.foregroundFFmpegColor.replacingOccurrences(of: "0x", with: "")

        // Try native rendering first (fast)
        do {
            let image = try await NativeWaveformRenderer.generateWaveform(
                url: url,
                ffmpegPath: ffmpegPath,
                streamIndex: 0,
                duration: duration,
                width: width,
                height: height,
                colorHex: colorHex
            )

            // Save NSImage as PNG to disk for queue row caching
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw PreviewAssetError.generationFailed("Failed to encode waveform image as PNG")
            }
            try pngData.write(to: destination)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Native audio row thumbnail failed, falling back to FFmpeg showwavespic: \(error.localizedDescription, privacy: .public)")
        }

        // Fallback: use FFmpeg showwavespic
        var filterChain = "[0:a]aformat=channel_layouts=mono,"
        if prefs.normalizeAudio {
            filterChain += "dynaudnorm=f=250:g=30:p=0.9,"
        }
        filterChain += "showwavespic=s=\(width)x\(height):colors=\(colorHex),"
        filterChain += "format=yuv420p[out]"

        let arguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", url.path,
            "-filter_complex", filterChain,
            "-map", "[out]",
            "-an",
            "-frames:v", "1",
            "-f", "image2",
            "-c:v", "mjpeg",
            "-q:v", "2",
            "-pix_fmt", "yuvj420p",
            "-y",
            destination.path
        ]

        try await runProcess(
            executable: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            forURL: url,
            outputURL: destination
        )
    }

    private func ensureAssetDirectory(for url: URL) throws -> URL {
        let fingerprint = try assetFingerprint(for: url)
        let baseDirectory = AppConstants.previewCacheDirectory
        logger.info("Base preview cache directory: \(baseDirectory.path, privacy: .public)")
        let directory = baseDirectory.appendingPathComponent(fingerprint, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                logger.info("Created asset directory: \(directory.path, privacy: .public)")
            } catch {
                logger.error("Failed to create asset directory at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        return directory
    }

    private func assetFingerprint(for url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modification = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprintSource = "\(url.path)::\(size)::\(modification)"
        let digest = SHA256.hash(data: Data(fingerprintSource.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func generateThumbnails(
        url: URL,
        ffmpegPath: String,
        duration: Double,
        assetDirectory: URL,
        missingIndices: [Int],
        expectedFiles: [URL],
        hdrType: HDRType,
        useSimplifiedFilter: Bool = false
    ) async {
        guard !missingIndices.isEmpty else { return }

        // Try AVFoundation first (batch, in-process, no subprocess spawning)
        if !useSimplifiedFilter {
            let remaining = await generateFilmstripWithAVFoundation(
                url: url,
                duration: duration,
                missingIndices: missingIndices,
                expectedFiles: expectedFiles
            )
            if remaining.isEmpty { return }

            // Fall back to ffmpeg only for indices AVFoundation couldn't generate
            await generateFilmstripWithFFmpeg(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: duration,
                missingIndices: remaining,
                expectedFiles: expectedFiles,
                hdrType: hdrType
            )
        } else {
            await generateFilmstripWithFFmpeg(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: duration,
                missingIndices: missingIndices,
                expectedFiles: expectedFiles,
                hdrType: .none
            )
        }
    }

    /// Generates filmstrip thumbnails using AVFoundation (batch, in-process).
    /// Returns the indices that could not be generated (for ffmpeg fallback).
    private func generateFilmstripWithAVFoundation(
        url: URL,
        duration: Double,
        missingIndices: [Int],
        expectedFiles: [URL]
    ) async -> [Int] {
        let ext = url.pathExtension.lowercased()
        if Self.avFoundationUnsupportedExtensions.contains(ext) {
            return missingIndices
        }

        let requests = missingIndices.map { index in
            PreviewThumbnailRequest(
                index: index,
                position: positionForThumbnail(at: index, total: thumbnailCount, duration: duration),
                width: 320,
                tolerance: 1
            )
        }
        do {
            let images = try await generateNativeThumbnails(
                url: url, requests: requests, destinations: expectedFiles
            )
            return missingIndices.filter { images[$0] == nil }
        } catch is CancellationError {
            // The parent is cancelled; returning no remaining work prevents fallback.
            return []
        } catch {
            logger.debug("AVFoundation filmstrip failed or timed out for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return missingIndices
        }
    }

    /// Generates filmstrip thumbnails using ffmpeg (one subprocess per frame).
    private func generateFilmstripWithFFmpeg(
        url: URL,
        ffmpegPath: String,
        duration: Double,
        missingIndices: [Int],
        expectedFiles: [URL],
        hdrType: HDRType
    ) async {
        for index in missingIndices {
            if Task.isCancelled { return }
            let destination = expectedFiles[index]
            let position = positionForThumbnail(at: index, total: thumbnailCount, duration: duration)

            var videoFilter = "scale=iw*sar:ih,scale=320:-1"

            switch hdrType {
            case .none:
                break
            case .proresRAW:
                videoFilter += ",format=yuv420p"
            case .hdr10Bit:
                videoFilter += ",format=yuv420p"
            }

            let arguments: [String] = [
                "-hide_banner",
                "-loglevel", "error",
                "-ss", String(format: "%.3f", position),
                "-i", url.path,
                "-frames:v", "1",
                "-vf", videoFilter,
                "-pix_fmt", "yuvj420p",
                "-y",
                destination.path
            ]

            do {
                try await runProcess(
                    executable: URL(fileURLWithPath: ffmpegPath),
                    arguments: arguments,
                    forURL: url,
                    outputURL: destination
                )
                logger.debug("Generated thumbnail #\(index) for \(url.lastPathComponent, privacy: .public) at position \(position, privacy: .public)s")
            } catch is CancellationError {
                try? fileManager.removeItem(at: destination)
                return
            } catch {
                logger.error("Thumbnail generation failed for index \(index) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? fileManager.removeItem(at: destination)
            }
        }
    }

    private func generateWaveform(
        url: URL,
        ffmpegPath: String,
        destination: URL,
        audioStreamIndex: Int = 0
    ) async throws {
        let primaryArguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", url.path,
            "-filter_complex", "[0:a:\(audioStreamIndex)]aformat=channel_layouts=mono,showwavespic=s=\(waveformSize):colors=FFFFFF,format=yuv420p[out]",
            "-map", "[out]",
            "-an",
            "-frames:v", "1",
            "-f", "image2",
            "-c:v", "mjpeg",
            "-q:v", "2",
            "-pix_fmt", "yuvj420p",
            "-y",
            destination.path
        ]
        do {
            try await runProcess(
                executable: URL(fileURLWithPath: ffmpegPath),
                arguments: primaryArguments,
                forURL: url,
                outputURL: destination
            )
            logger.debug("Waveform primary pipeline succeeded for \(url.lastPathComponent, privacy: .public)")
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Primary waveform generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Retrying with fallback pipeline.")
        }

        let fallbackArguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", url.path,
            "-filter_complex", "[0:a:\(audioStreamIndex)]aresample=48000,aformat=channel_layouts=mono,showwavespic=s=\(waveformSize):colors=FFFFFF,format=yuv420p[out]",
            "-map", "[out]",
            "-an",
            "-frames:v", "1",
            "-f", "image2",
            "-c:v", "mjpeg",
            "-q:v", "2",
            "-pix_fmt", "yuvj420p",
            "-y",
            destination.path
        ]
        try await runProcess(
            executable: URL(fileURLWithPath: ffmpegPath),
            arguments: fallbackArguments,
            forURL: url,
            outputURL: destination
        )
        logger.debug("Waveform fallback pipeline succeeded for \(url.lastPathComponent, privacy: .public)")
    }

    private func generatePerStreamWaveforms(
        url: URL,
        ffmpegPath: String,
        assetDirectory: URL,
        metadata: VideoMetadata,
        fallbackWaveform: URL?
    ) async {
        guard metadata.audioStreams.count > 1 else { return }

        // Process waveforms sequentially to avoid spawning too many FFmpeg processes
        // For files with many audio tracks (e.g., Interstellar with 10+ tracks),
        // parallel generation would overwhelm the system
        logger.info("Generating per-stream waveforms for \(metadata.audioStreams.count) audio tracks (sequential)")

        for (index, stream) in metadata.audioStreams.enumerated() {
            if Task.isCancelled { return }
            let destination = assetDirectory.appendingPathComponent(waveformFilename(for: index), isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                continue
            }

            await generateWaveformForStream(
                url: url,
                ffmpegPath: ffmpegPath,
                destination: destination,
                streamIndex: index,
                stream: stream,
                fallbackWaveform: fallbackWaveform
            )
        }
    }

    private func generateWaveformForStream(
        url: URL,
        ffmpegPath: String,
        destination: URL,
        streamIndex: Int,
        stream: VideoMetadata.AudioStream,
        fallbackWaveform: URL?
    ) async {
        do {
            try await generateWaveform(
                url: url,
                ffmpegPath: ffmpegPath,
                destination: destination,
                audioStreamIndex: streamIndex
            )
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Waveform generation failed for audio stream #\(streamIndex) (\(stream.channelLayout ?? "unknown")) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        guard let fallbackWaveform else { return }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: fallbackWaveform, to: destination)
        } catch {
            logger.warning("Failed to copy fallback waveform for audio stream #\(streamIndex) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Chunked Waveform Generation

    /// Calculates chunk parameters for a given duration
    /// Returns array of (index, startTime, chunkDuration, pixelWidth) tuples
    private func calculateChunkParameters(duration: Double) -> [(index: Int, start: Double, chunkDuration: Double, width: Int)] {
        guard duration > 0 else { return [] }

        let chunkCount = Int(ceil(duration / chunkDurationSeconds))
        var chunks: [(index: Int, start: Double, chunkDuration: Double, width: Int)] = []

        for i in 0..<chunkCount {
            let start = Double(i) * chunkDurationSeconds
            let end = min(start + chunkDurationSeconds, duration)
            let thisChunkDuration = end - start

            // Calculate proportional width (minimum 20px per chunk for visibility)
            let proportionalWidth = Int((thisChunkDuration / duration) * Double(totalWaveformWidth))
            let width = max(20, proportionalWidth)

            chunks.append((index: i, start: start, chunkDuration: thisChunkDuration, width: width))
        }

        return chunks
    }

    /// Generates a single waveform chunk using FFmpeg with -ss and -t for time bounds
    private func generateWaveformChunk(
        url: URL,
        ffmpegPath: String,
        destination: URL,
        audioStreamIndex: Int,
        startTime: Double,
        chunkDuration: Double,
        width: Int
    ) async throws {
        // Use -ss before input for fast seeking, -t for duration limit
        let filterChain = "[0:a:\(audioStreamIndex)]aformat=channel_layouts=mono,showwavespic=s=\(width)x\(chunkHeight):colors=FFFFFF,format=yuv420p[out]"

        let arguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-ss", String(format: "%.3f", startTime),
            "-t", String(format: "%.3f", chunkDuration),
            "-i", url.path,
            "-filter_complex", filterChain,
            "-map", "[out]",
            "-an",
            "-frames:v", "1",
            "-f", "image2",
            "-c:v", "png",  // Use PNG for better quality
            "-y",
            destination.path
        ]

        try await runProcess(
            executable: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            forURL: url,
            outputURL: destination
        )
    }

    /// Generates chunked waveform for a media file, generating chunks sequentially
    /// Updates existingChunks array as each chunk completes for progressive loading
    func generateChunkedWaveform(
        url: URL,
        ffmpegPath: String,
        assetDirectory: URL,
        duration: Double,
        audioStreamIndex: Int = 0,
        existingChunks: inout [WaveformChunk]
    ) async throws {
        let chunkParams = calculateChunkParameters(duration: duration)
        logger.info("Generating \(chunkParams.count) waveform chunks for \(url.lastPathComponent, privacy: .public) (duration: \(duration)s)")

        for param in chunkParams {
            try Task.checkCancellation()

            let filename = audioStreamIndex == 0
                ? waveformChunkFilename(chunkIndex: param.index)
                : waveformChunkFilename(for: audioStreamIndex, chunkIndex: param.index)
            let destination = assetDirectory.appendingPathComponent(filename, isDirectory: false)

            // Skip if already exists (from previous partial generation)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try await generateWaveformChunk(
                        url: url,
                        ffmpegPath: ffmpegPath,
                        destination: destination,
                        audioStreamIndex: audioStreamIndex,
                        startTime: param.start,
                        chunkDuration: param.chunkDuration,
                        width: param.width
                    )
                    logger.debug("Generated waveform chunk \(param.index)/\(chunkParams.count) for \(url.lastPathComponent, privacy: .public)")
                } catch is CancellationError {
                    try? fileManager.removeItem(at: destination)
                    throw CancellationError()
                } catch {
                    logger.warning("Failed to generate waveform chunk \(param.index) for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    try? fileManager.removeItem(at: destination)
                    // Continue with next chunk instead of failing entirely
                    continue
                }
            }

            // Add to existing chunks if file exists
            if fileManager.fileExists(atPath: destination.path) {
                let chunk = WaveformChunk(
                    id: param.index,
                    url: destination,
                    startTime: param.start,
                    duration: param.chunkDuration
                )
                // Avoid duplicates
                if !existingChunks.contains(where: { $0.id == param.index }) {
                    existingChunks.append(chunk)
                    existingChunks.sort { $0.id < $1.id }
                }
            }
        }
    }

    /// Generates chunked waveforms for all audio streams
    func generatePerStreamChunkedWaveforms(
        url: URL,
        ffmpegPath: String,
        assetDirectory: URL,
        duration: Double,
        metadata: VideoMetadata,
        existingChunks: inout [Int: [WaveformChunk]]
    ) async {
        guard metadata.audioStreams.count > 1 else { return }

        logger.info("Generating chunked waveforms for \(metadata.audioStreams.count) audio streams")

        for (index, _) in metadata.audioStreams.enumerated() {
            if Task.isCancelled { return }
            var streamChunks = existingChunks[index] ?? []

            do {
                try await generateChunkedWaveform(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    assetDirectory: assetDirectory,
                    duration: duration,
                    audioStreamIndex: index,
                    existingChunks: &streamChunks
                )
                existingChunks[index] = streamChunks
            } catch is CancellationError {
                return
            } catch {
                logger.warning("Failed to generate chunked waveform for stream \(index): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// HDR processing requirement types
    private enum HDRType {
        case none           // Standard SDR content
        case proresRAW      // ProRes RAW (needs simple decoding, no tonemapping)
        case hdr10Bit       // 10-bit+ HDR content (previously tonemapped; now handled without zscale)
    }
    
    /// Detects HDR processing requirement (ProRes RAW or content with explicit HDR colour metadata)
    /// from the already-bounded preview metadata result.
    private func detectHDRRequirement(from stream: VideoMetadata.VideoStream?) -> HDRType {
        guard let stream else {
            return .none
        }

        let codec = (stream.codec ?? stream.codecLongName ?? "").lowercased()
        let pixFmt = (stream.pixelFormat ?? "").lowercased()
        let primaries = stream.colorPrimaries?.lowercased() ?? ""
        let matrix = stream.colorSpace?.lowercased() ?? ""
        let transfer = stream.colorTransfer?.lowercased() ?? ""

        if codec.contains("prores") {
            if pixFmt.contains("rgb") || pixFmt.contains("bayer") {
                logger.info("Detected ProRes RAW - using simple color conversion")
                return .proresRAW
            }
        }

        let hasHDRColorSpace = matrix.contains("bt2020") || primaries.contains("bt2020")
        let hasHDRTransfer = transfer.contains("smpte2084") || transfer.contains("arib-std-b67")

        if hasHDRColorSpace || hasHDRTransfer {
            logger.info("Detected HDR content with explicit color metadata - proceeding without zscale")
            return .hdr10Bit
        }

        return .none
    }
    
    /// Generates the large row thumbnail with HDR support
    private func generateRowThumbnail(
        url: URL,
        ffmpegPath: String,
        duration: Double,
        destination: URL,
        hdrType: HDRType
    ) async throws {
        let position = min(10, max(duration * 0.1, 0.5))

        // Apply SAR scaling, then scale to target size
        var videoFilter = "scale=iw*sar:ih,scale=\(rowThumbnailSize)"

        switch hdrType {
        case .none:
            // Standard SDR content - just scale
            break
        case .proresRAW:
            // ProRes RAW - let decoder handle color, just ensure proper output format
            videoFilter += ",format=yuv420p"
        case .hdr10Bit:
            // Remove zscale/tonemap; output a compatible pixel format
            videoFilter += ",format=yuv420p"
        }

        let arguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-ss", String(format: "%.3f", position),
            "-i", url.path,
            "-frames:v", "1",
            "-vf", videoFilter,
            "-q:v", "2",
            "-y",
            destination.path
        ]

        try await runProcess(
            executable: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            forURL: url,
            outputURL: destination
        )
    }

    private func positionForThumbnail(at index: Int, total: Int, duration: Double) -> Double {
        guard total > 1 else { return duration / 2 }
        let fraction = Double(index) / Double(total - 1)
        // Leave 0.2 second margin from the end to ensure we can extract a valid frame
        let safeDuration = max(0, duration - 0.2)
        return max(0, min(safeDuration, safeDuration * fraction))
    }

    /// Module-visible so the subprocess policy can be verified without invoking media probes.
    func runProcess(
        executable: URL,
        arguments: [String],
        forURL url: URL? = nil,
        outputURL: URL
    ) async throws {
        try Task.checkCancellation()

        let privatePaths = arguments.filter { $0.hasPrefix("/") }
        let request = SubprocessRequest(
            executableURL: executable,
            arguments: arguments,
            timeout: .seconds(30 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: Set(
                [executable.path, outputURL.path] + privatePaths + [url?.path].compactMap { $0 }
            )
        )
        logger.info("Spawning preview subprocess: \(request.redactedCommandDescription, privacy: .public)")

        let taskID = UUID()
        let executionTask = Task<SubprocessResult, Error> { [subprocessRunner] in
            try await subprocessRunner.run(request)
        }
        runningProcessTasks[taskID] = executionTask
        if let url {
            processTasksPerURL[url, default: []].insert(taskID)
        }
        defer {
            runningProcessTasks.removeValue(forKey: taskID)
            if let url {
                processTasksPerURL[url]?.remove(taskID)
                if processTasksPerURL[url]?.isEmpty == true {
                    processTasksPerURL.removeValue(forKey: url)
                }
            }
        }

        let result: SubprocessResult
        do {
            result = try await withTaskCancellationHandler {
                try await executionTask.value
            } onCancel: {
                executionTask.cancel()
            }
        } catch is CancellationError {
            try? fileManager.removeItem(at: outputURL)
            throw CancellationError()
        } catch SubprocessRunnerError.timedOut {
            try? fileManager.removeItem(at: outputURL)
            throw PreviewAssetError.generationFailed("Preview subprocess timed out after 30 minutes.")
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw PreviewAssetError.generationFailed(
                request.redactedDiagnostic(error.localizedDescription)
            )
        }

        guard result.succeeded else {
            try? fileManager.removeItem(at: outputURL)
            let diagnostic = request.redactedDiagnostic(result.standardErrorText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = diagnostic.isEmpty
                ? "\(executable.lastPathComponent) exited with status \(result.terminationStatus)."
                : diagnostic
            throw PreviewAssetError.generationFailed(message)
        }

        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard outputSize > 0 else {
            try? fileManager.removeItem(at: outputURL)
            throw PreviewAssetError.generationFailed(
                "\(executable.lastPathComponent) did not produce a valid preview file."
            )
        }
    }

    private func startAccessingSecurityScope(for url: URL) -> SecurityScopedAccess {
        return SecurityScopedBookmarkManager.shared.startAccessing(url: url)
    }

    private func makeAudioWaveformRequest(for url: URL) -> WaveformVideoRequest {
        let prefs = AudioWaveformPreferences.loadConfig()
        return WaveformVideoRequest(
            width: Int(prefs.resolution.width),
            height: Int(prefs.resolution.height),
            backgroundHex: prefs.backgroundHex,
            foregroundHex: prefs.foregroundHex,
            normalizeAudio: prefs.normalizeAudio,
            style: prefs.style,
            frameRate: prefs.frameRate,
            renderingEngine: prefs.renderingEngine,
            swiftStyle: prefs.swiftStyle,
            bandCount: prefs.bandCount,
            frequencyDistribution: prefs.frequencyDistribution,
            foregroundGradientEnabled: prefs.foregroundGradientEnabled,
            foregroundGradientEndHex: prefs.foregroundGradientEndHex,
            backgroundGradientEnabled: prefs.backgroundGradientEnabled,
            backgroundGradientEndHex: prefs.backgroundGradientEndHex,
            waveformOpacity: prefs.waveformOpacity
        )
    }
}
