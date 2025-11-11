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
    private let audioStreamIndices: [Int]

    private var process: Process?
    private var isCancelled = false

    init(sourceURL: URL, cacheDirectory: URL, audioStreamIndices: [Int]) {
        self.sourceURL = sourceURL
        self.cacheDirectory = cacheDirectory
        self.outputURL = cacheDirectory.appendingPathComponent("preview.mp4")
        var seen = Set<Int>()
        self.audioStreamIndices = audioStreamIndices.filter { value in
            let inserted = seen.insert(value).inserted
            return inserted
        }

        // Ensure chunk/section subdirectories exist for cleaner cache cleanup
        let fileManager = FileManager.default
        let chunksDir = cacheDirectory.appendingPathComponent("chunks", isDirectory: true)
        let sectionsDir = cacheDirectory.appendingPathComponent("sections", isDirectory: true)
        if !fileManager.fileExists(atPath: chunksDir.path) {
            try? fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: sectionsDir.path) {
            try? fileManager.createDirectory(at: sectionsDir, withIntermediateDirectories: true)
        }
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
        // Note: Audio/video chunk files persist for reuse across sessions. Call cleanupAllChunks() explicitly when removing video from queue or use app-wide cache cleanup.
    }
    
    /// Explicitly clean up all preview files for this video (chunks and audio)
    /// Call this when removing the video from queue or during app-wide cache cleanup
    func cleanupAllChunks() {
        let fileManager = FileManager.default
        do {
            let chunksDir = cacheDirectory.appendingPathComponent("chunks", isDirectory: true)
            if fileManager.fileExists(atPath: chunksDir.path) {
                try fileManager.removeItem(at: chunksDir)
            }
            try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)

            let previewFile = outputURL
            if fileManager.fileExists(atPath: previewFile.path) {
                try? fileManager.removeItem(at: previewFile)
            }
            logger.info("Cleaned up all preview files for \(self.sourceURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up preview files: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Generates a preview chunk for a specific time range (duration varies by caller)
    func generatePreviewChunk(chunkIndex: Int, startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int = 720) async throws -> PreviewResult {
        let chunkURL = chunkURL(for: chunkIndex)
        
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
        cacheDirectory.appendingPathComponent("chunks/preview_chunk_\(index).mp4")
    }
    
    // MARK: - Helpers

    private func buildArguments(startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int, outputPath: String? = nil) -> [String] {
        let safeStart = max(0, startTime)
        let limitedDuration = max(1, durationLimit)

        let scaleFilter = "scale='if(gt(a,1),-2,\(maxShortEdge))':'if(gt(a,1),\(maxShortEdge),-2)'"
        let output = outputPath ?? self.outputURL.path

        var arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-ss", String(format: "%.3f", safeStart),
            "-i", sourceURL.path,
            "-t", String(format: "%.3f", limitedDuration),
            "-analyzeduration", "5M",
            "-probesize", "10M",
            "-vf", scaleFilter,
            "-map", "0:v:0",
            "-c:v", "h264_videotoolbox",
            "-b:v", "3M",
            "-maxrate", "3M",
            "-bufsize", "6M",
            "-pix_fmt", "yuv420p"
        ]

        let targetAudioIndices = audioStreamIndices.isEmpty ? [0] : audioStreamIndices
        for (outputIndex, streamIndex) in targetAudioIndices.enumerated() {
            arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)?"])
            arguments.append(contentsOf: ["-c:a:\(outputIndex)", "aac"])
            arguments.append(contentsOf: ["-b:a:\(outputIndex)", "128k"])
            arguments.append(contentsOf: ["-ac:a:\(outputIndex)", "2"])
        }

        arguments.append(output)
        return arguments
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
