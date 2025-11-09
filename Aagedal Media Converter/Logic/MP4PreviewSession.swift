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
    private let outputURL: URL

    private var process: Process?
    private var isCancelled = false

    init(sourceURL: URL, cacheDirectory: URL) {
        self.sourceURL = sourceURL
        self.outputURL = cacheDirectory.appendingPathComponent("preview.mp4")
    }

    /// Generates a low-resolution MP4 preview clip.
    /// - Parameters:
    ///   - startTime: Timestamp in seconds to start encoding from.
    ///   - durationLimit: Maximum duration of the preview.
    ///   - maxShortEdge: Maximum pixel length for the shorter video edge.
    func generatePreview(startTime: TimeInterval, durationLimit: TimeInterval = 30, maxShortEdge: Int = 480) async throws -> PreviewResult {
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

        let previewURL = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments)

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
    }

    // MARK: - Helpers

    private func buildArguments(startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int) -> [String] {
        let safeStart = max(0, startTime)
        let limitedDuration = max(1, durationLimit)

        let scaleFilter = "scale='if(gt(a,1),-2,\(maxShortEdge))':'if(gt(a,1),\(maxShortEdge),-2)'"

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
            "-preset", "veryfast",
            "-profile:v", "baseline",
            "-level", "3.0",
            "-pix_fmt", "yuv420p",
            "-crf", "28",
            "-maxrate", "1M",
            "-bufsize", "2M",
            "-c:a", "aac",
            "-ac", "2",
            "-b:a", "96k",
            self.outputURL.path
        ]
    }

    private func runFFmpeg(executablePath: String, arguments: [String]) async throws -> URL {
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
                let outputURL = self.outputURL

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
