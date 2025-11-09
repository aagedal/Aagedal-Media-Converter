// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog
import CryptoKit

struct PreviewAssets: Sendable {
    let rowThumbnail: URL?  // Large thumbnail for video row display
    let thumbnails: [URL]  // Filmstrip thumbnails for timeline
    let waveform: URL?
}

enum PreviewAssetError: Error, LocalizedError {
    case ffmpegBinaryMissing
    case ffprobeBinaryMissing
    case durationUnavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegBinaryMissing:
            return "FFmpeg binary not found in application bundle."
        case .ffprobeBinaryMissing:
            return "FFprobe binary not found in application bundle."
        case .durationUnavailable:
            return "Unable to determine media duration for preview generation."
        case .generationFailed(let message):
            return "Failed to generate preview assets: \(message)"
        }
    }
}

actor PreviewAssetGenerator {
    static let shared = PreviewAssetGenerator()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewAssets")
    private let fileManager = FileManager.default
    private let thumbnailCount = 6
    private let waveformSize = "1000x90"
    private let rowThumbnailSize = "640:-1"  // 640px width for row thumbnail

    /// Returns the asset directory for a given video URL, creating it if needed
    func getAssetDirectory(for url: URL) throws -> URL {
        try ensureAssetDirectory(for: url)
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
        logger.info("Starting asset generation for \(url.lastPathComponent, privacy: .public)")
        let accessGranted = self.startAccessingSecurityScope(for: url)
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            logger.error("FFmpeg binary not found in bundle")
            throw PreviewAssetError.ffmpegBinaryMissing
        }
        guard let ffprobePath = Bundle.main.path(forResource: "ffprobe", ofType: nil) else {
            logger.error("FFprobe binary not found in bundle")
            throw PreviewAssetError.ffprobeBinaryMissing
        }

        let assetDirectory = try ensureAssetDirectory(for: url)
        logger.info("Asset directory: \(assetDirectory.path, privacy: .public)")
        let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg", isDirectory: false)
        let expectedThumbnailURLs = (0..<thumbnailCount).map { index in
            assetDirectory.appendingPathComponent("thumb_\(index).jpg", isDirectory: false)
        }
        let waveformURL = assetDirectory.appendingPathComponent("waveform.png", isDirectory: false)

        let rowThumbnailMissing = !fileManager.fileExists(atPath: rowThumbnailURL.path)
        let missingThumbnailIndices = expectedThumbnailURLs.enumerated().compactMap { index, url in
            fileManager.fileExists(atPath: url.path) ? nil : index
        }
        let waveformMissing = !fileManager.fileExists(atPath: waveformURL.path)

        // Short-circuit if everything already exists
        if !rowThumbnailMissing && missingThumbnailIndices.isEmpty && !waveformMissing {
            logger.info("All assets already cached")
            return PreviewAssets(rowThumbnail: rowThumbnailURL, thumbnails: expectedThumbnailURLs, waveform: waveformURL)
        }
        
        logger.info("Row thumbnail missing: \(rowThumbnailMissing), filmstrip thumbnails missing: \(missingThumbnailIndices.count), waveform missing: \(waveformMissing)")

        guard let duration = try await determineDuration(for: url, ffprobePath: ffprobePath) else {
            throw PreviewAssetError.durationUnavailable
        }
        
        // Detect if this is HDR/high bit depth content without color metadata
        let hdrType = try await detectHDRRequirement(for: url, ffprobePath: ffprobePath)

        // Generate row thumbnail first (priority for UI responsiveness)
        if rowThumbnailMissing {
            try await generateRowThumbnail(
                url: url,
                ffmpegPath: ffmpegPath,
                duration: duration,
                destination: rowThumbnailURL,
                hdrType: hdrType
            )
        }

        // Generate filmstrip thumbnails in background (async, non-blocking)
        if !missingThumbnailIndices.isEmpty {
            Task.detached(priority: .background) {
                do {
                    try await self.generateThumbnails(
                        url: url,
                        ffmpegPath: ffmpegPath,
                        duration: duration,
                        assetDirectory: assetDirectory,
                        missingIndices: missingThumbnailIndices,
                        expectedFiles: expectedThumbnailURLs,
                        hdrType: hdrType
                    )
                } catch {
                    self.logger.error("Background filmstrip generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if waveformMissing {
            do {
                try await generateWaveform(
                    url: url,
                    ffmpegPath: ffmpegPath,
                    destination: waveformURL
                )
            } catch {
                logger.warning("Waveform generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let generatedRowThumbnail = fileManager.fileExists(atPath: rowThumbnailURL.path) ? rowThumbnailURL : nil
        let generatedWaveformURL = fileManager.fileExists(atPath: waveformURL.path) ? waveformURL : nil
        logger.info("Asset generation complete. Row thumbnail: \(generatedRowThumbnail != nil), filmstrip: \(expectedThumbnailURLs.count), waveform: \(generatedWaveformURL != nil)")
        return PreviewAssets(rowThumbnail: generatedRowThumbnail, thumbnails: expectedThumbnailURLs, waveform: generatedWaveformURL)
    }
    
    /// Generates only the row thumbnail (fast, no waveform or filmstrip)
    /// Returns the thumbnail data if successful
    func generateRowThumbnail(for url: URL) async throws -> Data? {
        logger.info("Generating row thumbnail on-demand for \(url.lastPathComponent, privacy: .public)")
        let accessGranted = self.startAccessingSecurityScope(for: url)
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            logger.error("FFmpeg binary not found in bundle")
            throw PreviewAssetError.ffmpegBinaryMissing
        }
        guard let ffprobePath = Bundle.main.path(forResource: "ffprobe", ofType: nil) else {
            logger.error("FFprobe binary not found in bundle")
            throw PreviewAssetError.ffprobeBinaryMissing
        }
        
        let assetDirectory = try ensureAssetDirectory(for: url)
        let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg", isDirectory: false)
        
        // Check if already exists
        if fileManager.fileExists(atPath: rowThumbnailURL.path) {
            logger.info("Row thumbnail already cached")
            return try? Data(contentsOf: rowThumbnailURL)
        }
        
        guard let duration = try await determineDuration(for: url, ffprobePath: ffprobePath) else {
            throw PreviewAssetError.durationUnavailable
        }
        
        let hdrType = try await detectHDRRequirement(for: url, ffprobePath: ffprobePath)
        
        try await generateRowThumbnail(
            url: url,
            ffmpegPath: ffmpegPath,
            duration: duration,
            destination: rowThumbnailURL,
            hdrType: hdrType
        )
        
        if fileManager.fileExists(atPath: rowThumbnailURL.path) {
            logger.info("Row thumbnail generated successfully")
            return try? Data(contentsOf: rowThumbnailURL)
        }
        
        return nil
    }

    // MARK: - Helpers

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

    private func determineDuration(for url: URL, ffprobePath: String) async throws -> Double? {
        if let duration = await FFMPEGConverter.getVideoDuration(url: url), duration > 0 {
            return duration
        }

        // Fallback: use ffprobe manually (in case getVideoDuration returns nil but still accessible)
        return try await runProcess(
            executable: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ]
        ) { stdoutData, _ in
            guard
                let string = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                let value = Double(string),
                value > 0
            else {
                return nil
            }
            return value
        }
    }

    private func generateThumbnails(
        url: URL,
        ffmpegPath: String,
        duration: Double,
        assetDirectory: URL,
        missingIndices: [Int],
        expectedFiles: [URL],
        hdrType: HDRType
    ) async throws {
        for index in missingIndices {
            let destination = expectedFiles[index]
            let position = positionForThumbnail(at: index, total: thumbnailCount, duration: duration)
            
            // Apply SAR scaling, then scale to target width
            var videoFilter = "scale=iw*sar:ih,scale=320:-1"
            
            switch hdrType {
            case .none:
                // Standard SDR content - just scale
                break
            case .proresRAW:
                // ProRes RAW - let decoder handle color, ensure proper output format
                videoFilter += ",format=yuv420p"
            case .hdr10Bit:
                // 10-bit+ HDR - apply full tonemapping chain
                videoFilter += ",zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
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
                    arguments: arguments
                )
            } catch {
                logger.error("Thumbnail generation failed for index \(index) of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw PreviewAssetError.generationFailed("thumbnail #\(index)")
            }
        }
    }

    private func generateWaveform(
        url: URL,
        ffmpegPath: String,
        destination: URL
    ) async throws {
        let arguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", url.path,
            "-filter_complex", "aformat=channel_layouts=mono,showwavespic=s=\(waveformSize):colors=FFFFFF",
            "-frames:v", "1",
            "-y",
            destination.path
        ]

        try await runProcess(
            executable: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments
        )
    }
    
    /// HDR processing requirement types
    private enum HDRType {
        case none           // Standard SDR content
        case proresRAW      // ProRes RAW (needs simple decoding, no tonemapping)
        case hdr10Bit       // 10-bit+ HDR content (needs tonemapping)
    }
    
    /// Detects HDR processing requirement (ProRes RAW, 10-bit+ without color metadata)
    private func detectHDRRequirement(for url: URL, ffprobePath: String) async throws -> HDRType {
        return try await runProcess(
            executable: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_name,pix_fmt,color_space,color_primaries,color_transfer",
                "-of", "default=noprint_wrappers=1",
                url.path
            ]
        ) { stdoutData, _ in
            guard let output = String(data: stdoutData, encoding: .utf8) else { return .none }
            
            let lines = output.components(separatedBy: .newlines)
            var codecName = ""
            var pixFmt = ""
            var colorSpace = ""
            var colorPrimaries = ""
            var colorTransfer = ""
            
            for line in lines {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let value = String(parts[1])
                
                switch key {
                case "codec_name": codecName = value
                case "pix_fmt": pixFmt = value
                case "color_space": colorSpace = value
                case "color_primaries": colorPrimaries = value
                case "color_transfer": colorTransfer = value
                default: break
                }
            }
            
            // ProRes RAW requires special handling (simple decode, no tonemapping)
            if codecName.contains("prores_ks") || codecName.contains("prores") {
                if pixFmt.contains("rgb") || pixFmt.contains("bayer") {
                    self.logger.info("Detected ProRes RAW - using simple color conversion")
                    return .proresRAW
                }
            }
            
            // 10-bit or higher without color metadata needs tonemapping
            let is10BitPlus = pixFmt.contains("10") || pixFmt.contains("12") || pixFmt.contains("16") || 
                             pixFmt.contains("p010") || pixFmt.contains("p016")
            let hasNoColorInfo = (colorSpace.isEmpty || colorSpace == "unknown") && 
                                (colorPrimaries.isEmpty || colorPrimaries == "unknown") &&
                                (colorTransfer.isEmpty || colorTransfer == "unknown")
            
            if is10BitPlus && hasNoColorInfo {
                self.logger.info("Detected 10-bit+ content without color metadata - using HDR tonemapping")
                return .hdr10Bit
            }
            
            return .none
        }
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
            // 10-bit+ HDR - apply full tonemapping chain
            videoFilter += ",zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
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
            arguments: arguments
        )
    }

    private func positionForThumbnail(at index: Int, total: Int, duration: Double) -> Double {
        guard total > 1 else { return duration / 2 }
        let fraction = Double(index) / Double(total - 1)
        // Leave 0.2 second margin from the end to ensure we can extract a valid frame
        let safeDuration = max(0, duration - 0.2)
        return max(0, min(safeDuration, safeDuration * fraction))
    }

    private func runProcess(
        executable: URL,
        arguments: [String]
    ) async throws {
        try await runProcess(executable: executable, arguments: arguments) { (_: Data, _: Data) in () }
    }

    private func runProcess<T>(
        executable: URL,
        arguments: [String],
        transform: @Sendable @escaping (Data, Data) -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    let result = transform(stdoutData, stderrData)
                    continuation.resume(returning: result)
                } else {
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: PreviewAssetError.generationFailed(message))
                }
            }
        }
    }

    @discardableResult
    private func startAccessingSecurityScope(for url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource() ||
            SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
    }
}
