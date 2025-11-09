// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import AVFoundation
import OSLog

/// Manages creation and lifecycle of a temporary low-resolution MP4 preview clip.
actor MP4PreviewSession {
    struct PreviewResult: Sendable {
        let url: URL
        let startTime: TimeInterval
        let duration: TimeInterval
    }
    enum PreviewError: Error, LocalizedError {
        case ffmpegNotFound
        case failedToStart(String)
        case cancelled
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg binary not found in application bundle."
            case .failedToStart(let message):
                return "Failed to start FFmpeg preview: \(message)."
            case .cancelled:
                return "Preview generation was cancelled."
            case .outputMissing:
                return "Preview output file was not created."
            }
        }
    }

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
    private let sourceURL: URL
    private let cacheDirectory: URL
    private let outputURL: URL
    private let audioTrackURL: URL
    private let audioChunkURL: URL

    private var process: Process?
    private var isCancelled = false

    init(sourceURL: URL, cacheDirectory: URL) {
        self.sourceURL = sourceURL
        self.cacheDirectory = cacheDirectory
        self.outputURL = cacheDirectory.appendingPathComponent("preview.mp4")
        self.audioTrackURL = cacheDirectory.appendingPathComponent("preview_audio.m4a")
        self.audioChunkURL = cacheDirectory.appendingPathComponent("preview_audio_chunk.m4a")
    }

    /// Generates a low-resolution MP4 preview clip.
    /// - Parameters:
    ///   - startTime: Timestamp in seconds to start encoding from.
    ///   - durationLimit: Maximum duration of the preview.
    ///   - maxShortEdge: Maximum pixel length for the shorter video edge.
    func generatePreview(startTime: TimeInterval, durationLimit: TimeInterval = 30, maxShortEdge: Int = 720) async throws -> PreviewResult {
        logger.info("Transcoding MP4 preview for \(self.sourceURL.lastPathComponent, privacy: .public)")

        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }

        if FileManager.default.fileExists(atPath: self.outputURL.path) {
            try FileManager.default.removeItem(at: self.outputURL)
        }

        self.isCancelled = false

        let safeStart = max(0, startTime)

        let arguments = self.buildArguments(
            startTime: startTime,
            durationLimit: durationLimit,
            maxShortEdge: maxShortEdge
        )

        try Task.checkCancellation()

        let previewURL = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: self.outputURL)

        let asset = AVURLAsset(url: previewURL)
        let loadedDuration = try await asset.load(.duration)
        let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit

        return PreviewResult(
            url: previewURL,
            startTime: safeStart,
            duration: max(0, durationSeconds)
        )
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    func previewFileURL() -> URL {
        outputURL
    }

    func cleanup() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: outputURL)
        // Note: Audio files, chunks, and sections are NOT cleaned up here - they persist for reuse across sessions
        // Call cleanupAllChunks() explicitly when removing video from queue or use app-wide cache cleanup
    }
    
    /// Explicitly clean up all preview files for this video (chunks, sections, and audio)
    /// Call this when removing the video from queue or during app-wide cache cleanup
    func cleanupAllChunks() {
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for fileURL in contents {
                let filename = fileURL.lastPathComponent
                if filename.hasPrefix("preview_chunk_") || 
                   filename.hasPrefix("preview_section_") ||
                   filename.hasPrefix("preview_audio") {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
            logger.info("Cleaned up all preview files for \(self.sourceURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up preview files: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Generates a preview chunk for a specific time range (15 seconds)
    func generatePreviewChunk(chunkIndex: Int, durationLimit: TimeInterval = 15, maxShortEdge: Int = 720) async throws -> PreviewResult {
        let chunkURL = chunkURL(for: chunkIndex)
        let startTime = Double(chunkIndex) * durationLimit
        
        // Skip if already exists
        if FileManager.default.fileExists(atPath: chunkURL.path) {
            logger.info("Using cached chunk \(chunkIndex, privacy: .public) from: \(chunkURL.path, privacy: .public)")
            let asset = AVURLAsset(url: chunkURL)
            let loadedDuration = try await asset.load(.duration)
            let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit
            return PreviewResult(
                url: chunkURL,
                startTime: startTime,
                duration: max(0, durationSeconds)
            )
        }
        
        logger.info("Generating preview chunk \(chunkIndex, privacy: .public) (\(durationLimit, privacy: .public)s starting at \(startTime, privacy: .public)s) for \(self.sourceURL.lastPathComponent, privacy: .public)")
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        let arguments = self.buildArguments(
            startTime: startTime,
            durationLimit: durationLimit,
            maxShortEdge: maxShortEdge,
            outputPath: chunkURL.path
        )
        
        try Task.checkCancellation()
        
        let previewURL = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: chunkURL)
        
        let asset = AVURLAsset(url: previewURL)
        let loadedDuration = try await asset.load(.duration)
        let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit
        
        return PreviewResult(
            url: previewURL,
            startTime: startTime,
            duration: max(0, durationSeconds)
        )
    }
    
    /// Returns URL for a specific preview chunk (15 seconds each)
    nonisolated func chunkURL(for index: Int) -> URL {
        cacheDirectory.appendingPathComponent("preview_chunk_\(index).mp4")
    }
    
    /// Returns URL for a concatenated section (60 seconds)
    nonisolated func sectionURL(for sectionIndex: Int) -> URL {
        cacheDirectory.appendingPathComponent("preview_section_\(sectionIndex).mp4")
    }
    
    /// Returns URL for the 15-second audio chunk (for quick start)
    func audioChunkFileURL() -> URL {
        audioChunkURL
    }
    
    /// Returns URL for the full audio track (for continuous playback)
    func audioTrackFileURL() -> URL {
        audioTrackURL
    }
    
    /// Generates the initial 15-second audio chunk for quick playback start
    func generateAudioChunk(durationLimit: TimeInterval = 15) async throws -> URL {
        // Skip if already exists
        if FileManager.default.fileExists(atPath: self.audioChunkURL.path) {
            logger.info("Using cached audio chunk from: \(self.audioChunkURL.path, privacy: .public)")
            return self.audioChunkURL
        }
        
        logger.info("Generating 15s audio chunk for \(self.sourceURL.lastPathComponent, privacy: .public)")
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        let arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-t", String(format: "%.3f", durationLimit),
            "-i", sourceURL.path,
            "-vn",  // No video
            "-c:a", "aac",
            "-ac", "2",
            "-b:a", "128k",
            self.audioChunkURL.path
        ]
        
        try Task.checkCancellation()
        return try await runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: self.audioChunkURL)
    }
    
    /// Generates the full audio track for continuous playback (runs in background)
    func generateFullAudioTrack() async throws -> URL {
        // Skip if already exists
        if FileManager.default.fileExists(atPath: self.audioTrackURL.path) {
            logger.info("Using cached full audio track from: \(self.audioTrackURL.path, privacy: .public)")
            return self.audioTrackURL
        }
        
        logger.info("Generating full audio track for \(self.sourceURL.lastPathComponent, privacy: .public)")
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        let arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-vn",  // No video
            "-c:a", "aac",
            "-ac", "2",
            "-b:a", "128k",
            self.audioTrackURL.path
        ]
        
        try Task.checkCancellation()
        return try await runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: self.audioTrackURL)
    }
    
    /// Concatenates multiple chunks into a single section file using FFmpeg concat demuxer (very fast - no re-encoding)
    func concatenateSection(chunkIndices: [Int], sectionIndex: Int) async throws -> URL {
        let sectionURL = self.sectionURL(for: sectionIndex)
        
        // Skip if already exists
        if FileManager.default.fileExists(atPath: sectionURL.path) {
            logger.info("Using cached section \(sectionIndex, privacy: .public) from: \(sectionURL.path, privacy: .public)")
            return sectionURL
        }
        
        logger.info("Concatenating \(chunkIndices.count, privacy: .public) chunks into section \(sectionIndex, privacy: .public)")
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        // Create concat list file
        let concatListURL = cacheDirectory.appendingPathComponent("concat_section_\(sectionIndex).txt")
        var concatList = ""
        for chunkIndex in chunkIndices.sorted() {
            let chunkURL = self.chunkURL(for: chunkIndex)
            concatList += "file '\(chunkURL.path)'\n"
        }
        
        try concatList.write(to: concatListURL, atomically: true, encoding: .utf8)
        
        // Use FFmpeg concat demuxer - just copies streams, no re-encoding (very fast!)
        let arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", concatListURL.path,
            "-c", "copy",  // Copy streams without re-encoding
            sectionURL.path
        ]
        
        try Task.checkCancellation()
        let result = try await runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: sectionURL)
        
        // Clean up concat list file
        try? FileManager.default.removeItem(at: concatListURL)
        
        logger.info("Section \(sectionIndex, privacy: .public) concatenated successfully")
        return result
    }

    // MARK: - Helpers

    private func buildArguments(startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int, outputPath: String? = nil) -> [String] {
        let safeStart = max(0, startTime)
        let limitedDuration = max(1, durationLimit)

        let scaleFilter = "scale='if(gt(a,1),-2,\(maxShortEdge))':'if(gt(a,1),\(maxShortEdge),-2)'"
        let output = outputPath ?? self.outputURL.path

        return [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-ss", String(format: "%.3f", safeStart),
            "-i", sourceURL.path,
            "-t", String(format: "%.3f", limitedDuration),
            "-analyzeduration", "5M",
            "-probesize", "10M",
            "-vf", scaleFilter,
            "-c:v", "libx264",
            "-preset", "fast",
            "-profile:v", "main",
            "-level", "4.0",
            "-pix_fmt", "yuv420p",
            "-crf", "23",
            "-maxrate", "3M",
            "-bufsize", "6M",
            "-an",  // No audio (audio played separately for smooth playback)
            output
        ]
    }

    private func runFFmpeg(executablePath: String, arguments: [String], outputURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
                self.process = process
            } catch {
                continuation.resume(throwing: PreviewError.failedToStart(error.localizedDescription))
                return
            }

            Task.detached(priority: .userInitiated) { [weak self] in
                process.waitUntilExit()

                guard let self else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: PreviewError.failedToStart(message))
                    return
                }

                let cancelled = await self.isCancelled

                if cancelled {
                    continuation.resume(throwing: PreviewError.cancelled)
                    return
                }

                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) {
                    continuation.resume(returning: outputURL)
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: PreviewError.failedToStart(message))
                }
            }
        }
    }
}
