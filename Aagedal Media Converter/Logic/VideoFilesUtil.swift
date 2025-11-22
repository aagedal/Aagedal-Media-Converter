// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Cocoa
import OSLog

struct VideoFileUtils: Sendable {
    struct VideoItemDetails: Sendable {
        let size: Int64
        let duration: String
        let durationSeconds: Double
        let thumbnailData: Data?
        let outputURL: URL?
        let hasVideoStream: Bool
    }

    static func isVideoFile(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return AppConstants.supportedVideoExtensions.contains(fileExtension)
    }

    static func createVideoItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop, comment: String = "") async -> VideoItem? {
        guard var placeholder = makePlaceholderItem(from: url, outputFolder: outputFolder, preset: preset, comment: comment) else {
            return nil
        }

        let details = await loadDetails(for: url, outputFolder: outputFolder, preset: preset)
        placeholder.apply(details: details)
        placeholder.detailsLoaded = true
        print(" [createVideoItem] VideoItem created successfully: \(placeholder.name)")
        return placeholder
    }

    static func makePlaceholderItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop, comment: String = "") -> VideoItem? {
        guard isVideoFile(url: url) else { return nil }

        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let includeDateTagByDefault = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)

        let waveformEnabledDefault = UserDefaults.standard.bool(forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)

        let placeholder = VideoItem(
            url: url,
            name: name,
            size: size,
            duration: "--:--",
            durationSeconds: 0.0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: makeOutputURL(for: url, outputFolder: outputFolder, preset: preset),
            comment: comment,
            includeDateTag: includeDateTagByDefault,
            metadata: nil,
            detailsLoaded: false,
            waveformVideoEnabled: waveformEnabledDefault
        )

        return placeholder
    }

    static func loadDetails(for url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop) async -> VideoItemDetails {
        let fileName = url.lastPathComponent
        print(" [loadDetails] ⏱️ Starting for: \(fileName)")

        // Compute size (cheap, but ensures we have up-to-date info)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        var durationSec: Double = 0.0
        let asset = AVURLAsset(url: url)

        if Bundle.main.path(forResource: "ffprobe", ofType: nil) != nil {
            Logger().info("Attempting to get duration using FFprobe for: \(fileName)")
            durationSec = await FFMPEGConverter.getVideoDuration(url: url) ?? 0.0

            if durationSec > 0 {
                Logger().info("Successfully got duration from FFprobe: \(durationSec) seconds for \(fileName)")
            } else {
                Logger().warning("FFprobe returned 0 duration for \(fileName), falling back to AVFoundation")
            }
        } else {
            Logger().info("FFprobe not found in bundle, using AVFoundation for \(fileName)")
        }

        if durationSec <= 0 {
            Logger().info("Using AVFoundation to get duration for: \(fileName)")
            let cmDuration = try? await asset.load(.duration)
            durationSec = CMTimeGetSeconds(cmDuration ?? CMTime.zero)
            Logger().info("AVFoundation returned duration: \(durationSec) seconds for \(fileName)")
        }

        let durationString = formatDuration(seconds: durationSec)

        var hasVideoStream = false
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            hasVideoStream = !videoTracks.isEmpty
        } catch {
            Logger().debug("AVFoundation failed to inspect video tracks for \(fileName): \(error.localizedDescription). Falling back to FFprobe")
        }

        if !hasVideoStream {
            if let metadata = try? await VideoMetadataService.shared.metadata(for: url) {
                hasVideoStream = metadata.videoStream != nil
                Logger().debug("FFprobe detected video stream: \(hasVideoStream) for \(fileName)")
            }
        }

        print(" [loadDetails] Getting cached thumbnail for: \(fileName)")
        let thumbnailData = await getCachedThumbnail(url: url)
        print(" [loadDetails] Thumbnail obtained (nil: \(thumbnailData == nil))")

        let outputURL = makeOutputURL(for: url, outputFolder: outputFolder, preset: preset)

        print(" [loadDetails] ✅ Completed for: \(fileName)")
        return VideoItemDetails(
            size: size,
            duration: durationString,
            durationSeconds: durationSec,
            thumbnailData: thumbnailData,
            outputURL: outputURL,
            hasVideoStream: hasVideoStream
        )
    }

    /// Schedules generation of heavy preview assets (filmstrip thumbnails, waveform, and first preview chunk)
    /// after the lightweight metadata and row thumbnail are complete.
    static func prefetchPreviewAssets(
        for url: URL,
        durationSeconds: Double,
        previewChunkDuration: TimeInterval = 5.0
    ) {
        Task.detached(priority: .background) {
            let fileName = url.lastPathComponent
            do {
                let generator = PreviewAssetGenerator.shared
                let assets = try await generator.generateAssets(for: url)
                print(" [prefetchPreviewAssets] ✅ Cached filmstrip/waveform for \(fileName) (\(assets.thumbnails.count) thumbnails, waveform: \(assets.waveform != nil))")
            } catch {
                print(" [prefetchPreviewAssets] ⚠️ Failed to generate preview assets for \(fileName): \(error.localizedDescription)")
            }

            guard durationSeconds > 0 else { return }

            // Only generate chunks for files that aren't supported by AVPlayer OR VLC
            // This means chunks are only for fallback chunk-based rendering
            let isNative = await isNativelySupported(url)
            let isVLC = await isVLCSupported(url)
            if isNative || isVLC {
                print(" [prefetchPreviewAssets] File is supported by AVPlayer or VLC, skipping chunk generation for \(fileName)")
                return
            }

            do {
                let cacheDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: url)
                
                // Determine if file has video stream for correct FFmpeg mapping
                let asset = AVURLAsset(url: url)
                let videoTracks = try? await asset.loadTracks(withMediaType: .video)
                let hasVideo = !(videoTracks ?? []).isEmpty
                
                let session = MP4PreviewSession(
                    sourceURL: url,
                    cacheDirectory: cacheDirectory,
                    audioStreamIndices: [],
                    hasVideoStream: hasVideo
                )

                let chunkIndex = 0
                let chunkPath = session.chunkURL(for: chunkIndex)
                if FileManager.default.fileExists(atPath: chunkPath.path) {
                    print(" [prefetchPreviewAssets] Chunk #0 already cached for \(fileName)")
                    return
                }

                let chunkDuration = min(previewChunkDuration, durationSeconds)
                _ = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: 0,
                    durationLimit: chunkDuration
                )
                print(" [prefetchPreviewAssets] ✅ Cached initial preview chunk for \(fileName)")
            } catch {
                print(" [prefetchPreviewAssets] ⚠️ Failed to prefetch preview chunk for \(fileName): \(error.localizedDescription)")
            }
        }
    }

    static func loadDetailsAsync(
        for url: URL,
        outputFolder: String? = nil,
        preset: ExportPreset = .videoLoop,
        completion: @MainActor @escaping (VideoItemDetails) -> Void
    ) {
        Task.detached(priority: .utility) {
            let details = await loadDetails(for: url, outputFolder: outputFolder, preset: preset)
            await completion(details)
        }
    }

    private static func makeOutputURL(for url: URL, outputFolder: String?, preset: ExportPreset) -> URL? {
        guard let outputFolder else { return nil }
        let sanitizedBaseName = FileNameProcessor.processFileName(url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: url)
        let outputFileName = sanitizedBaseName + preset.fileSuffix + "." + resolvedExtension
        return URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)
    }
    
    /// Fetches metadata for a video item in the background
    /// This allows the UI to be responsive while heavy operations complete
    static func fetchMetadata(for url: URL) async -> VideoMetadata? {
        let fileName = url.lastPathComponent
        let startTime = Date()
        
        print(" [fetchMetadata] ⏱️ Starting for: \(fileName) at \(startTime)")
        
        // Fetch metadata with timeout
        let metadata: VideoMetadata?
        do {
            metadata = try await withThrowingTaskGroup(of: VideoMetadata?.self) { group in
                group.addTask {
                    print(" [fetchMetadata] 🔄 Calling VideoMetadataService for: \(fileName)")
                    let result = try await VideoMetadataService.shared.metadata(for: url)
                    let elapsed = Date().timeIntervalSince(startTime)
                    print(" [fetchMetadata] ✅ VideoMetadataService returned after \(String(format: "%.2f", elapsed))s for: \(fileName)")
                    return result
                }
                
                group.addTask {
                    for i in 1...15 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        print(" [fetchMetadata] ⏳ Waiting... \(i)s elapsed for: \(fileName)")
                    }
                    print(" [fetchMetadata] ⏰ Timeout reached (15s) for: \(fileName)")
                    throw CancellationError()
                }
                
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }
            let totalElapsed = Date().timeIntervalSince(startTime)
            print(" [fetchMetadata] ✅ Metadata fetched successfully after \(String(format: "%.2f", totalElapsed))s for: \(fileName)")
        } catch is CancellationError {
            let totalElapsed = Date().timeIntervalSince(startTime)
            Logger().warning("Metadata fetch timed out for \(fileName) after \(String(format: "%.2f", totalElapsed)) seconds")
            print(" [fetchMetadata] ⏰ Metadata fetch timed out after \(String(format: "%.2f", totalElapsed))s for: \(fileName)")
            metadata = nil
        } catch {
            let totalElapsed = Date().timeIntervalSince(startTime)
            Logger().warning("Failed to fetch metadata for \(fileName): \(error.localizedDescription)")
            print(" [fetchMetadata] ❌ Metadata fetch failed after \(String(format: "%.2f", totalElapsed))s: \(error.localizedDescription) for: \(fileName)")
            metadata = nil
        }
        
        let totalElapsed = Date().timeIntervalSince(startTime)
        print(" [fetchMetadata] 🏁 Completed for: \(fileName) after \(String(format: "%.2f", totalElapsed))s (metadata: \(metadata != nil))")
        return metadata
    }
    // utility to format seconds into hh:mm:ss or mm:ss
    private static func formatDuration(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    @available(macOS 13.0, *)
    private static func getDurationFromAVFoundation(url: URL) async -> Double? {
        do {
            let asset = AVURLAsset(url: url)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)
            Logger().info("AVFoundation duration: \(duration) seconds for \(url.lastPathComponent)")
            return duration
        } catch {
            Logger().error("Error getting duration from AVFoundation: \(error.localizedDescription) for \(url.lastPathComponent)")
            return nil
        }
    }
    
    static func getVideoDuration(url: URL) async -> String {
        let fileName = url.lastPathComponent
        var duration: Double = 0.0
        
        if Bundle.main.path(forResource: "ffprobe", ofType: nil) != nil {
            Logger().info("[getVideoDuration] Attempting FFprobe for: \(fileName)")
            let ffprobeDuration = await FFMPEGConverter.getVideoDuration(url: url)
            
            if let ffprobeDuration = ffprobeDuration, ffprobeDuration > 0 {
                duration = ffprobeDuration
                Logger().info("[getVideoDuration] FFprobe success: \(duration) seconds for \(fileName)")
            } else {
                Logger().warning("[getVideoDuration] FFprobe failed or returned 0, falling back to AVFoundation for \(fileName)")
                if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                    duration = durationFromAV
                }
            }
        } else {
            Logger().info("[getVideoDuration] FFprobe not found, using AVFoundation for \(fileName)")
            if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                duration = durationFromAV
            }
        }
        
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    /// Gets cached thumbnail or generates row thumbnail if needed (fast, no waveform)
    static func getCachedThumbnail(url: URL) async -> Data? {
        let fileName = url.lastPathComponent
        do {
            // Get the asset directory where thumbnails are cached
            let assetDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: url)
            print(" [getCachedThumbnail] Asset directory: \(assetDirectory.path)")
            
            // Try to load row thumbnail first (correct filename: row_thumb.jpg)
            let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg")
            let rowExists = FileManager.default.fileExists(atPath: rowThumbnailURL.path)
            print(" [getCachedThumbnail] Row thumbnail exists: \(rowExists)")
            
            if rowExists {
                do {
                    let thumbnailData = try Data(contentsOf: rowThumbnailURL)
                    print(" [getCachedThumbnail] ✅ Loaded cached row thumbnail (\(thumbnailData.count) bytes) for: \(fileName)")
                    return thumbnailData
                } catch {
                    print(" [getCachedThumbnail] ❌ Failed to read row thumbnail: \(error.localizedDescription)")
                }
            }
            
            // If row thumbnail doesn't exist, generate it now (fast, just the thumbnail)
            print(" [getCachedThumbnail] 🔨 Generating row thumbnail on-demand for: \(fileName)")
            if let thumbnailData = try? await PreviewAssetGenerator.shared.generateRowThumbnail(for: url) {
                print(" [getCachedThumbnail] ✅ Generated row thumbnail (\(thumbnailData.count) bytes) for: \(fileName)")
                return thumbnailData
            }
            
            // Fallback to first filmstrip thumbnail if row thumbnail generation failed (correct filename: thumb_0.jpg)
            let firstThumbnailURL = assetDirectory.appendingPathComponent("thumb_0.jpg")
            let filmstripExists = FileManager.default.fileExists(atPath: firstThumbnailURL.path)
            print(" [getCachedThumbnail] Filmstrip thumbnail exists: \(filmstripExists)")
            
            if filmstripExists {
                do {
                    let thumbnailData = try Data(contentsOf: firstThumbnailURL)
                    print(" [getCachedThumbnail] ✅ Loaded filmstrip thumbnail (\(thumbnailData.count) bytes) for: \(fileName)")
                    return thumbnailData
                } catch {
                    print(" [getCachedThumbnail] ❌ Failed to read filmstrip thumbnail: \(error.localizedDescription)")
                }
            }
            
            print(" [getCachedThumbnail] ⚠️ No thumbnails available for: \(fileName)")
            return nil
        } catch {
            print(" [getCachedThumbnail] ❌ Error loading thumbnail for \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    static func getVideoThumbnail(url: URL) async -> Data? {
        // Use unified PreviewAssetGenerator for consistent thumbnail generation
        // with HDR support for ProRes RAW and high bit depth content
        do {
            let assets = try await PreviewAssetGenerator.shared.generateAssets(for: url)
            
            // Use row thumbnail if available
            if let rowThumbnailURL = assets.rowThumbnail,
               let thumbnailData = try? Data(contentsOf: rowThumbnailURL) {
                return thumbnailData
            }
            
            // Fallback to first filmstrip thumbnail if row thumbnail failed
            if let firstThumbnail = assets.thumbnails.first,
               let thumbnailData = try? Data(contentsOf: firstThumbnail) {
                return thumbnailData
            }
            
            return nil
        } catch {
            print("Error generating thumbnail via PreviewAssetGenerator for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func isNativelySupported(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return false }
            
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if tracks.isEmpty { return true }
            
            for track in tracks {
                let formats = try await track.load(.formatDescriptions) as [CMFormatDescription]
                for desc in formats {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    let codecBytes: [UInt8] = [
                        UInt8((codec >> 24) & 0xFF),
                        UInt8((codec >> 16) & 0xFF),
                        UInt8((codec >> 8) & 0xFF),
                        UInt8(codec & 0xFF)
                    ]
                    if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) {
                        if fourCC == "apv1" || fourCC == "apvx" { return false }
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }
    
    private static func isVLCSupported(_ url: URL) async -> Bool {
        // VLC supports most formats that AVPlayer doesn't, EXCEPT APV
        // Check if it's APV first (APV needs chunk fallback)
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            for track in tracks {
                let formats = try await track.load(.formatDescriptions) as [CMFormatDescription]
                for desc in formats {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    let codecBytes: [UInt8] = [
                        UInt8((codec >> 24) & 0xFF),
                        UInt8((codec >> 16) & 0xFF),
                        UInt8((codec >> 8) & 0xFF),
                        UInt8(codec & 0xFF)
                    ]
                   if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) {
                        // APV is NOT supported by VLC
                        if fourCC == "apv1" || fourCC == "apvx" {
                            return false
                        }
                    }
                }
            }
        } catch {
            // If we can't inspect, assume VLC can handle it
            return true
        }
        
        // If it's not natively supported and not APV, VLC can likely play it
        let isNative = await isNativelySupported(url)
        return !isNative
    }
}

struct VideoItem: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    var url: URL
    var name: String
    var size: Int64
    var duration: String
    var durationSeconds: Double = 0.0
    var thumbnailData: Data?
    var status: ConversionManager.ConversionStatus
    var progress: Double
    var eta: String?
    var outputURL: URL?
    var comment: String = ""
    var includeDateTag: Bool = true
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var loopPlayback: Bool = false
    var metadata: VideoMetadata?
    var detailsLoaded: Bool = false
    var waveformVideoEnabled: Bool = false
    var hasVideoStream: Bool = true

    mutating func apply(details: VideoFileUtils.VideoItemDetails) {
        size = details.size
        duration = details.duration
        durationSeconds = details.durationSeconds
        thumbnailData = details.thumbnailData
        outputURL = details.outputURL
        hasVideoStream = details.hasVideoStream
    }
    
    /// Human-readable file size string (<1 MB ⇒ KB, 1–600 MB ⇒ MB, ≥600 MB ⇒ GB)
    var formattedSize: String {
        let bytes = Double(size)
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        
        if bytes < mb {
            return String(format: "%.0f KB", bytes / kb)
        } else if bytes < 600 * mb {
            return String(format: "%.1f MB", bytes / mb)
        } else {
            return String(format: "%.1f GB", bytes / gb)
        }
    }
    
    /// Effective trim-in point in seconds (defaults to 0 when unset).
    var effectiveTrimStart: Double {
        trimStart ?? 0
    }
    
    /// Effective trim-out point in seconds (defaults to full duration when unset).
    var effectiveTrimEnd: Double {
        let end = trimEnd ?? durationSeconds
        return max(end, effectiveTrimStart)
    }
    
    /// Duration of the trimmed range in seconds.
    var trimmedDuration: Double {
        max(effectiveTrimEnd - effectiveTrimStart, 0)
    }

    var outputFileExists: Bool {
        guard let outputURL = outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    var requiresWaveformVideo: Bool {
        !hasVideoStream && waveformVideoEnabled
    }

    var metadataComment: String? {
        guard let raw = metadata?.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    var videoDisplayAspectRatio: Double? {
        if let ratioValue = metadata?.videoStream?.displayAspectRatio?.doubleValue {
            return ratioValue
        }
        if
            let width = metadata?.videoStream?.width,
            let height = metadata?.videoStream?.height,
            width > 0,
            height > 0
        {
            return Double(width) / Double(height)
        }
        return nil
    }

    var videoResolutionDescription: String? {
        guard let width = metadata?.videoStream?.width, let height = metadata?.videoStream?.height else {
            return nil
        }
        return "\(width) × \(height)"
    }
}
