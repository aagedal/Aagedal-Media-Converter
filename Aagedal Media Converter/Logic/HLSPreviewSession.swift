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

/// Manages an FFmpeg-backed HLS preview playlist for a specific video item.
/// Generates lightweight preview segments that AVPlayer can consume via a custom resource loader.
final class HLSPreviewSession: @unchecked Sendable {
    enum SessionError: Error, LocalizedError {
        case ffmpegNotFound
        case failedToStart(String)
        case playlistTimeout

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "Bundled FFmpeg binary could not be located."
            case .failedToStart(let message):
                return "Failed to start FFmpeg preview: \(message)."
            case .playlistTimeout:
                return "Timed out waiting for preview playlist."
            }
        }
    }

    let itemID: UUID
    let sourceURL: URL

    let sessionDirectory: URL
    let playlistURL: URL
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")

    private var process: Process?
    private var state: State = .idle
    private var securityScopeActive = false
    private var usedBookmarkForAccess = false

    private enum State {
        case idle
        case starting
        case streaming
        case stopped
    }

    init(itemID: UUID, sourceURL: URL, baseDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("AMCPreview", isDirectory: true)) {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.sessionDirectory = baseDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true)
        self.playlistURL = sessionDirectory.appendingPathComponent("preview.m3u8")
    }

    /// Resolves a relative path inside the session directory to an on-disk URL.
    func resolveResource(relativePath: String) -> URL {
        sessionDirectory.appendingPathComponent(relativePath)
    }

    deinit {
        stop()
        cleanup()
    }

    /// Starts (or restarts) the preview beginning at the requested timestamp.
    /// Returns the URL of the generated HLS playlist once it is ready for playback.
    func start(at startTime: TimeInterval) async throws -> URL {
        logger.debug("Starting preview for item \(self.itemID, privacy: .public) at time \(startTime, privacy: .public)")

        try ensureDirectoryExists()
        try await stopExistingProcess()

        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            logger.error("FFmpeg binary not found in bundle")
            throw SessionError.ffmpegNotFound
        }

        acquireSecurityScope()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.currentDirectoryURL = sessionDirectory
        process.arguments = buildArguments(startTime: startTime)
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch FFmpeg preview: \(error.localizedDescription, privacy: .public)")
            releaseSecurityScope()
            throw SessionError.failedToStart(error.localizedDescription)
        }

        self.process = process
        self.state = .starting

        if try await waitForPlaylistReady() {
            self.state = .streaming
            logger.debug("Preview playlist ready for item \(self.itemID, privacy: .public)")
            return playlistURL
        }

        logger.error("Preview playlist timed out for item \(self.itemID, privacy: .public)")
        throw SessionError.playlistTimeout
    }

    /// Stops the running FFmpeg process (if any) and releases security scope access.
    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
        releaseSecurityScope()
    }

    /// Deletes all temporary files created by the session.
    func cleanup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionDirectory.path) else { return }
        do {
            try fm.removeItem(at: sessionDirectory)
        } catch {
            logger.error("Failed to clean preview directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionDirectory.path) {
            try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        }
        // Remove any stale playlist to avoid confusing the readiness check
        if fm.fileExists(atPath: playlistURL.path) {
            try fm.removeItem(at: playlistURL)
        }
    }

    private func stopExistingProcess() async throws {
        guard let process else { return }
        logger.debug("Stopping existing preview process for item \(self.itemID, privacy: .public)")
        process.terminate()
        self.process = nil
        // Give the process a short moment to terminate before continuing
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
    }

    private func buildArguments(startTime: TimeInterval) -> [String] {
        let startString = String(format: "%.3f", max(startTime, 0))
        return [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-ss", startString,
            "-i", sourceURL.path,
            "-vf", "scale=min(1280,iw):-2",
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "32",
            "-c:a", "aac",
            "-b:a", "96k",
            "-hls_time", "6",
            "-hls_list_size", "0",
            "-hls_flags", "delete_segments+append_list",
            "-f", "hls",
            playlistURL.path
        ]
    }

    private func waitForPlaylistReady() async throws -> Bool {
        let timeout: TimeInterval = 8
        let pollInterval: UInt64 = 200_000_000 // 0.2 seconds
        var elapsed: TimeInterval = 0

        while elapsed < timeout {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: playlistURL.path) {
                if let contents = try? String(contentsOf: playlistURL, encoding: .utf8), contents.contains("#EXTINF") {
                    return true
                }
            }
            try await Task.sleep(nanoseconds: pollInterval)
            elapsed += Double(pollInterval) / 1_000_000_000
        }

        return false
    }

    private func acquireSecurityScope() {
        guard !securityScopeActive else { return }

        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: sourceURL) {
            securityScopeActive = true
            usedBookmarkForAccess = true
        } else if sourceURL.startAccessingSecurityScopedResource() {
            securityScopeActive = true
            usedBookmarkForAccess = false
        }
    }

    private func releaseSecurityScope() {
        guard securityScopeActive else { return }

        if usedBookmarkForAccess {
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: sourceURL)
        } else {
            sourceURL.stopAccessingSecurityScopedResource()
        }

        securityScopeActive = false
        usedBookmarkForAccess = false
    }
}
