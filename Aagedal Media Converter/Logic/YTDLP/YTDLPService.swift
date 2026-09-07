// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol YTDLPUpdating: Sendable {
    func resolveYTDLPPath() async -> String?
    func ensureDenoInstalled() async -> String?
}

extension YTDLPUpdateService: YTDLPUpdating {}

/// Per-download cancellation handle. Keeping this outside the service actor lets the UI
/// stop the correct download immediately even while several actor calls are suspended in
/// subprocess work.
final class YTDLPDownloadControl: @unchecked Sendable {
    fileprivate enum StopReason {
        case userRequested
        case liveRecordingStop
        case stalled
    }

    private let lock = NSLock()
    private var executionID: UUID?
    private var cancelAction: (@Sendable () -> Void)?
    private var stopReason: StopReason?

    @discardableResult
    func cancel() -> Bool {
        terminate(reason: .userRequested)
    }

    @discardableResult
    func stopLiveRecording() -> Bool {
        terminate(reason: .liveRecordingStop)
    }

    fileprivate func install(id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        executionID = id
        cancelAction = cancel
        let shouldCancelImmediately = stopReason != nil
        lock.unlock()
        if shouldCancelImmediately {
            cancel()
        }
    }

    fileprivate func markStalled() -> Bool {
        terminate(reason: .stalled)
    }

    fileprivate func finish(id: UUID) -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        guard executionID == id else { return nil }
        let reason = stopReason
        executionID = nil
        cancelAction = nil
        stopReason = nil
        return reason
    }

    fileprivate func reason(id: UUID) -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        guard executionID == id else { return nil }
        return stopReason
    }

    private func terminate(reason: StopReason) -> Bool {
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        let cancelAction = cancelAction
        lock.unlock()
        cancelAction?()
        return cancelAction != nil
    }
}

/// Metadata fetched from yt-dlp for a video URL
struct YTDLPMetadata: Sendable {
    let title: String
    let duration: Double?
    let thumbnailURL: URL?
    let uploader: String?
    let description: String?
}

/// Result of a successful download
struct YTDLPDownloadResult: Sendable {
    let outputURL: URL
    let title: String
}

/// One entry from a flat-playlist probe — enough to populate a queue row before
/// the actual video is downloaded. Fields beyond `url` are best-effort: yt-dlp
/// often omits duration/thumbnail in flat-playlist mode for performance.
struct YTDLPPlaylistEntry: Sendable {
    let url: String
    let title: String
    let duration: Double?
    let thumbnailURL: URL?
}

/// How aggressively yt-dlp should sanitize downloaded filenames.
enum YTDLPFilenameRestrictionMode: String, CaseIterable, Identifiable {
    /// Default — yt-dlp only strips characters illegal on the current OS (just `/` and NUL on macOS).
    case off
    /// Adds `--windows-filenames` so filenames are also safe on Windows / NTFS / cloud sync.
    /// Strips `< > : " / \ | ? *`, control chars, and trailing space/period. Keeps Unicode letters.
    case windowsSafe = "windows_safe"
    /// Adds `--restrict-filenames` — ASCII letters/digits/`_.-` only. Drops non-Latin scripts and many accents.
    case asciiOnly = "ascii_only"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .windowsSafe: return "Windows-safe (keeps Unicode letters)"
        case .asciiOnly: return "ASCII only (strips non-Latin scripts)"
        }
    }

    static var current: YTDLPFilenameRestrictionMode {
        let raw = UserDefaults.standard.string(forKey: AppConstants.ytdlpFilenameRestrictionModeKey)
            ?? AppConstants.defaultYTDLPFilenameRestrictionMode
        return YTDLPFilenameRestrictionMode(rawValue: raw) ?? .off
    }
}

/// Service for executing yt-dlp downloads
actor YTDLPService {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "YTDLPService")
    private let updateService: any YTDLPUpdating
    private let subprocessRunner: any SubprocessRunning

    private static let probeTimeout: Duration = .seconds(300)
    private static let probeOutputLimit = 16 * 1024 * 1024

    private struct ProbeResult {
        let subprocess: SubprocessResult
        let safeStandardError: String
    }

    init(
        updateService: any YTDLPUpdating = YTDLPUpdateService.shared,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) {
        self.updateService = updateService
        self.subprocessRunner = subprocessRunner
    }

    /// How long yt-dlp may produce no output before the stall watchdog kills it.
    /// Generous enough to cover slow Python startup and post-processing lulls.
    private static let stallThresholdSeconds: TimeInterval = 300
    private static let stallCheckIntervalNanos: UInt64 = 30_000_000_000 // 30s

    private final class DateBox: @unchecked Sendable {
        var value: Date

        init(value: Date) {
            self.value = value
        }
    }

    /// Reassembles arbitrary runner chunks into complete UTF-8 lines independently for
    /// stdout and stderr. yt-dlp progress lines can be split across pipe reads.
    private final class LineAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()

        func consume(
            _ chunk: SubprocessOutputChunk,
            handler: (String, Bool) -> Void
        ) {
            lock.lock()
            let lines: [String]
            switch chunk.stream {
            case .standardOutput:
                standardOutput.append(chunk.data)
                lines = Self.removeCompleteLines(from: &standardOutput)
            case .standardError:
                standardError.append(chunk.data)
                lines = Self.removeCompleteLines(from: &standardError)
            }
            lock.unlock()
            for line in lines {
                handler(line, chunk.stream == .standardError)
            }
        }

        func finish(handler: (String, Bool) -> Void) {
            lock.lock()
            let remaining = [
                (String(decoding: standardOutput, as: UTF8.self), false),
                (String(decoding: standardError, as: UTF8.self), true)
            ].filter { !$0.0.isEmpty }
            standardOutput.removeAll()
            standardError.removeAll()
            lock.unlock()
            for (line, isStandardError) in remaining {
                handler(line, isStandardError)
            }
        }

        private static func removeCompleteLines(from buffer: inout Data) -> [String] {
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
                buffer.removeSubrange(...newline)
            }
            return lines
        }
    }

    /// Path to ffmpeg for post-processing
    private var ffmpegPath: String? {
        BinaryPathResolver.ffmpegPath
    }

    private func runProbe(ytdlpPath: String, arguments: [String]) async throws -> ProbeResult {
        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: ytdlpPath,
            arguments: arguments
        )

        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            timeout: Self.probeTimeout,
            standardOutputCaptureLimit: Self.probeOutputLimit,
            standardErrorCaptureLimit: SubprocessRequest.defaultCaptureLimit,
            sensitiveArgumentNames: ["--cookies", "--cookies-from-browser"]
        )

        do {
            let result = try await subprocessRunner.run(request)
            return ProbeResult(
                subprocess: result,
                safeStandardError: request.redactedDiagnostic(result.standardErrorText)
            )
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw YTDLPError.metadataFetchFailed("yt-dlp request timed out after five minutes")
            case .failedToStart:
                throw YTDLPError.metadataFetchFailed(error.localizedDescription)
            }
        }
    }

    /// Fetches video metadata without downloading
    func fetchMetadata(url: String) async throws -> YTDLPMetadata {
        let startTime = Date()
        logger.info("[TIMING] fetchMetadata started")

        let pathResolveStart = Date()
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        let pathResolveElapsed = Date().timeIntervalSince(pathResolveStart)
        logger.info("[TIMING] yt-dlp path resolved in \(String(format: "%.3f", pathResolveElapsed))s: \(ytdlpPath)")

        let denoPath = await updateService.ensureDenoInstalled()

        let processStartTime = Date()
        var arguments = [
            "--ignore-config",
            "--remote-components", "ejs:github",
            "--cache-dir", AppConstants.ytdlpCacheDirectory.path
        ]
        if let denoPath {
            arguments.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
        }
        let cookiesBrowser = UserDefaults.standard.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
        if !cookiesBrowser.isEmpty {
            arguments.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
        }
        arguments.append(contentsOf: ["-j", "--no-download", "--no-warnings", "--", url])

        let probe = try await runProbe(ytdlpPath: ytdlpPath, arguments: arguments)
        let result = probe.subprocess

        let processElapsed = Date().timeIntervalSince(processStartTime)
        logger.info("[TIMING] yt-dlp metadata process completed in \(String(format: "%.2f", processElapsed))s, exit status: \(result.terminationStatus)")

        guard result.succeeded else {
            let errorMessage = probe.safeStandardError.isEmpty ? "Unknown error" : probe.safeStandardError
            logger.error("yt-dlp metadata fetch failed: \(errorMessage)")
            throw YTDLPError.metadataFetchFailed(errorMessage)
        }

        guard result.discardedStandardOutputBytes == 0 else {
            throw YTDLPError.metadataFetchFailed("yt-dlp metadata response exceeded the 16 MB safety limit")
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            throw YTDLPError.metadataFetchFailed("Failed to parse JSON response")
        }

        let title = json["title"] as? String ?? "Unknown Title"
        let duration = json["duration"] as? Double
        let thumbnailURLString = json["thumbnail"] as? String
        let thumbnailURL = thumbnailURLString.flatMap { URL(string: $0) }
        let uploader = json["uploader"] as? String
        let description = json["description"] as? String

        let totalElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] fetchMetadata completed in \(String(format: "%.2f", totalElapsed))s for: \(title)")

        return YTDLPMetadata(
            title: title,
            duration: duration,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            description: description
        )
    }

    /// Probes a URL with `--flat-playlist -J` and returns its entries. Works for
    /// playlists, channels, and single-video URLs (the latter returns a single entry).
    func fetchPlaylistEntries(url: String) async throws -> [YTDLPPlaylistEntry] {
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        let denoPath = await updateService.ensureDenoInstalled()

        var arguments = [
            "--ignore-config",
            "--remote-components", "ejs:github",
            "--cache-dir", AppConstants.ytdlpCacheDirectory.path
        ]
        if let denoPath {
            arguments.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
        }
        let cookiesBrowser = UserDefaults.standard.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
        if !cookiesBrowser.isEmpty {
            arguments.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
        }
        arguments.append(contentsOf: ["--flat-playlist", "-J", "--no-warnings", "--", url])

        let probe = try await runProbe(ytdlpPath: ytdlpPath, arguments: arguments)
        let result = probe.subprocess

        guard result.succeeded else {
            let errorMessage = probe.safeStandardError.isEmpty ? "Unknown error" : probe.safeStandardError
            throw YTDLPError.metadataFetchFailed(errorMessage)
        }

        guard result.discardedStandardOutputBytes == 0 else {
            throw YTDLPError.metadataFetchFailed("yt-dlp playlist response exceeded the 16 MB safety limit")
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            throw YTDLPError.metadataFetchFailed("Failed to parse playlist JSON")
        }

        // Pull a single entry's url/title/duration/thumbnail from a JSON object.
        // yt-dlp's flat-playlist sometimes uses `url` and sometimes `webpage_url`
        // depending on the extractor; fall back across both.
        func makeEntry(from obj: [String: Any]) -> YTDLPPlaylistEntry? {
            let entryURL = (obj["webpage_url"] as? String) ?? (obj["url"] as? String)
            guard let entryURL else { return nil }
            let title = (obj["title"] as? String) ?? "Untitled"
            let duration = obj["duration"] as? Double
            let thumbnailURL: URL? = {
                if let thumbStr = obj["thumbnail"] as? String,
                   let u = URL(string: thumbStr) {
                    return u
                }
                if let thumbnails = obj["thumbnails"] as? [[String: Any]],
                   let last = thumbnails.last,
                   let thumbStr = last["url"] as? String {
                    return URL(string: thumbStr)
                }
                return nil
            }()
            return YTDLPPlaylistEntry(url: entryURL, title: title, duration: duration, thumbnailURL: thumbnailURL)
        }

        if let entries = json["entries"] as? [[String: Any]] {
            let parsed = entries.compactMap { makeEntry(from: $0) }
            logger.info("[YTDLPService] Playlist probe returned \(parsed.count) entries")
            return parsed
        }

        // Single video — return as a one-element list so the caller can handle
        // both shapes the same way.
        if let entry = makeEntry(from: json) {
            return [entry]
        }
        return []
    }

    /// Downloads a video using yt-dlp
    /// - Parameters:
    ///   - url: The video URL to download
    ///   - outputFolder: The folder to save the downloaded video
    ///   - forceOverwrite: If true, overwrites existing files instead of skipping
    ///   - liveFromStart: Whether to rewind live streams to the beginning
    ///   - audioOnly: Whether to download only the audio track (no video)
    ///   - progress: Callback for progress updates (progress 0-1, speed string, isLiveStream)
    ///   - titleUpdate: Callback when video title is discovered
    /// - Returns: The path to the downloaded file
    func download(
        url: String,
        outputFolder: URL,
        forceOverwrite: Bool = false,
        liveFromStart: Bool = false,
        audioOnly: Bool = false,
        control: YTDLPDownloadControl = YTDLPDownloadControl(),
        progress: @escaping @Sendable (Double, String?, Bool) -> Void,
        titleUpdate: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> YTDLPDownloadResult {
        let downloadStartTime = Date()
        logger.info("[TIMING] download() started")

        let pathResolveStart = Date()
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        let pathResolveElapsed = Date().timeIntervalSince(pathResolveStart)
        logger.info("[TIMING] yt-dlp path resolved in \(String(format: "%.3f", pathResolveElapsed))s")

        // Build arguments array
        // Note: --ignore-config prevents yt-dlp from reading user config files
        // Note: --remote-components ejs:github is required for YouTube JS challenge solving
        var args: [String] = [
            "--ignore-config",
            "--remote-components", "ejs:github",
            "--cache-dir", AppConstants.ytdlpCacheDirectory.path
        ]
        if let denoPath = await updateService.ensureDenoInstalled() {
            args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            logger.info("[YTDLPService] Using deno runtime at: \(denoPath)")
        }
        logger.info("[YTDLPService] Using cache dir: \(AppConstants.ytdlpCacheDirectory.path)")

        // Add ffmpeg location if available
        let ffmpegResolveStart = Date()
        let resolvedFFmpegPath = BinaryPathResolver.ffmpegPath
        let ffmpegResolveElapsed = Date().timeIntervalSince(ffmpegResolveStart)
        logger.info("[TIMING] ffmpeg path resolved in \(String(format: "%.3f", ffmpegResolveElapsed))s: \(resolvedFFmpegPath ?? "nil")")
        if let ffmpegPath = resolvedFFmpegPath {
            // yt-dlp needs the directory containing ffmpeg, not the binary itself
            let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
            logger.debug("Using ffmpeg dir: \(ffmpegDir)")
            args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        } else {
            logger.warning("No ffmpeg path available for yt-dlp postprocessing")
        }

        // Add browser cookies if configured
        let cookiesBrowser = UserDefaults.standard.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
        if !cookiesBrowser.isEmpty {
            args.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
            logger.info("[YTDLPService] Using cookies from browser: \(cookiesBrowser)")
        }

        if liveFromStart {
            args.append(contentsOf: ["--live-from-start", "--no-part"])
            logger.info("[YTDLPService] Downloading live stream from start (no-part)")
        }

        switch YTDLPFilenameRestrictionMode.current {
        case .off:
            break
        case .windowsSafe:
            args.append("--windows-filenames")
            logger.info("[YTDLPService] Filename restriction: windows-safe")
        case .asciiOnly:
            args.append("--restrict-filenames")
            logger.info("[YTDLPService] Filename restriction: ASCII only")
        }

        // Format selector: prefer audio-only stream when in audio-only mode, otherwise
        // grab best video+audio. `-x` (--extract-audio) makes yt-dlp post-process to a
        // standalone audio file when the chosen stream is muxed; with `--audio-format
        // best` the original codec is preserved (no re-encoding when avoidable).
        let formatSelector = audioOnly ? "bestaudio/best" : "bestvideo+bestaudio/best"
        args.append(contentsOf: ["-f", formatSelector])
        if audioOnly {
            args.append(contentsOf: ["-x", "--audio-format", "best"])
            logger.info("[YTDLPService] Audio-only download requested")
        }

        args.append(contentsOf: [
            "--no-playlist",
            "--trim-filenames", "200",
            "--newline",
            "--progress",
            "--verbose",  // Enable verbose output to ensure we get stderr
            forceOverwrite ? "--force-overwrites" : "--no-overwrites",
            "--print", "after_move:filepath",
            "-o", "%(title)s.%(ext)s",
            // "--" ends flag parsing so a URL that somehow starts with "-" can't be
            // interpreted as an option.
            "--",
            url
        ])

        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: ytdlpPath,
            arguments: args
        )
        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            currentDirectoryURL: outputFolder,
            sensitiveArgumentNames: ["--cookies", "--cookies-from-browser"]
        )

        // Use a class to hold mutable state for thread-safe access from the handler
        final class ParsedState: @unchecked Sendable {
            var outputPath: String?
            var videoTitle: String = "Downloaded Video"
            var firstError: String?
            var fileAlreadyExists: Bool = false
            var existingFilePath: String?
            var firstStdoutLogged: Bool = false
            var firstStderrLogged: Bool = false
            var firstProgressLogged: Bool = false
            /// Timestamp of the last non-empty line seen on stdout/stderr.
            /// The stall watchdog compares against this to decide whether yt-dlp
            /// has gone silent.
            var lastActivity: Date = Date()
            let lock = NSLock()

            func read<T>(_ block: (ParsedState) -> T) -> T {
                lock.lock()
                defer { lock.unlock() }
                return block(self)
            }

            func markActivity() {
                lock.lock()
                lastActivity = Date()
                lock.unlock()
            }

            func markFirstStdout() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStdoutLogged {
                    return false
                }
                firstStdoutLogged = true
                return true
            }

            func markFirstStderr() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStderrLogged {
                    return false
                }
                firstStderrLogged = true
                return true
            }

            func markFirstProgress() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstProgressLogged {
                    return false
                }
                firstProgressLogged = true
                return true
            }
        }
        let parsedState = ParsedState()
        let lineAccumulator = LineAccumulator()
        let processStartBox = DateBox(value: Date())

        // Capture logger for use in @Sendable closures and local functions
        let logger = self.logger

        // Helper to process a line of output
        @Sendable func processLine(_ trimmed: String, isStderr: Bool) {
            guard !trimmed.isEmpty else { return }

            // Feed the stall watchdog: any non-empty stdout/stderr line counts
            // as activity, including fragment-download progress for live streams.
            parsedState.markActivity()

            if isStderr {
                if parsedState.markFirstStderr() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stderr after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stderr: \(request.redactedDiagnostic(trimmed), privacy: .public)")
            } else {
                if parsedState.markFirstStdout() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stdout after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stdout: \(request.redactedDiagnostic(trimmed), privacy: .public)")
            }

            // Parse progress from either stream
            if let progressInfo = YTDLPProgressParser.parse(trimmed) {
                logger.debug("Progress parsed: \(progressInfo.progress * 100)%, isLive: \(progressInfo.isLiveStream)")
                if parsedState.markFirstProgress() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp progress after \(String(format: "%.3f", delta))s")
                }
                progress(progressInfo.progress, progressInfo.speed, progressInfo.isLiveStream)
            }

            // Parse title from either stream
            if let title = YTDLPProgressParser.parseTitle(trimmed) {
                parsedState.lock.lock()
                let previousTitle = parsedState.videoTitle
                parsedState.videoTitle = title
                parsedState.lock.unlock()
                if title != previousTitle && title != "Downloaded Video" {
                    logger.info("Title discovered: \(title, privacy: .public)")
                    titleUpdate(title)
                }
            }

            // Parse output path (from merger or download destination)
            if let path = YTDLPProgressParser.parseOutputPath(trimmed) {
                parsedState.lock.lock()
                parsedState.outputPath = path
                parsedState.lock.unlock()
            }

            // Capture the FIRST error line we see — yt-dlp's initial ERROR: message
            // is the actionable summary ("Sign in to confirm you're not a bot",
            // "Video unavailable", etc.); subsequent lines are stack/detail that
            // look more alarming than they are in the UI.
            if let error = YTDLPProgressParser.parseError(trimmed) {
                parsedState.lock.lock()
                if parsedState.firstError == nil {
                    parsedState.firstError = request.redactedDiagnostic(error, limit: 2 * 1024)
                }
                parsedState.lock.unlock()
            }

            // Check for "already been downloaded" message (stdout only)
            if !isStderr && trimmed.contains("has already been downloaded") {
                logger.info("File already exists detected")
                parsedState.lock.lock()
                parsedState.fileAlreadyExists = true
                if let range = trimmed.range(of: "] "),
                   let endRange = trimmed.range(of: " has already been downloaded") {
                    let filename = String(trimmed[range.upperBound..<endRange.lowerBound])
                    parsedState.existingFilePath = filename
                }
                parsedState.lock.unlock()
            }

            // Parse output path from stdout (--print after_move:filepath).
            // yt-dlp prints an absolute path here, so require a leading slash.
            // This avoids capturing stray verbose/debug stdout (e.g. a raw title or
            // a warning line that happens to lack a "[" prefix) as the output path.
            if !isStderr && trimmed.hasPrefix("/") {
                parsedState.lock.lock()
                parsedState.outputPath = trimmed
                parsedState.lock.unlock()
            }
        }

        let processSetupElapsed = Date().timeIntervalSince(downloadStartTime)
        logger.info("[TIMING] Process setup completed in \(String(format: "%.3f", processSetupElapsed))s, starting download process...")

        processStartBox.value = Date()
        parsedState.markActivity()

        let executionID = UUID()
        let subprocessTask = Task { [subprocessRunner] in
            try await subprocessRunner.run(request) { chunk in
                lineAccumulator.consume(chunk) { line, isStandardError in
                    processLine(
                        line.trimmingCharacters(in: .whitespacesAndNewlines),
                        isStderr: isStandardError
                    )
                }
            }
        }
        control.install(id: executionID) {
            subprocessTask.cancel()
        }
        defer { _ = control.finish(id: executionID) }

        // Stall watchdog: if yt-dlp produces no output for `stallThresholdSeconds`,
        // terminate it so the UI isn't stuck forever on a dead connection. Fragment
        // progress for live streams keeps feeding the watchdog, so legitimate live
        // recordings are unaffected.
        let stallThreshold = Self.stallThresholdSeconds
        let stallCheckInterval = Self.stallCheckIntervalNanos
        let watchdogControl = control
        let watchdogState = parsedState
        let watchdogLogger = logger
        let watchdogTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: stallCheckInterval)
                if Task.isCancelled { break }
                let last = watchdogState.read { $0.lastActivity }
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > stallThreshold {
                    watchdogLogger.warning("yt-dlp appears stalled (no output for \(Int(elapsed))s) — terminating")
                    _ = watchdogControl.markStalled()
                    break
                }
            }
        }
        defer { watchdogTask.cancel() }

        func throwCancellation(_ reason: YTDLPDownloadControl.StopReason) throws -> Never {
            switch reason {
            case .userRequested:
                logger.info("Download cancelled")
                throw YTDLPError.cancelled
            case .liveRecordingStop:
                logger.info("Live stream recording stopped")
                throw YTDLPError.liveRecordingStopped
            case .stalled:
                logger.warning("Download terminated due to stall")
                throw YTDLPError.stalled
            }
        }

        let subprocessResult: SubprocessResult
        do {
            subprocessResult = try await withTaskCancellationHandler {
                try await subprocessTask.value
            } onCancel: {
                _ = control.cancel()
            }
            lineAccumulator.finish { line, isStandardError in
                processLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines),
                    isStderr: isStandardError
                )
            }
        } catch {
            lineAccumulator.finish { line, isStandardError in
                processLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines),
                    isStderr: isStandardError
                )
            }
            if let reason = control.reason(id: executionID) {
                try throwCancellation(reason)
            }
            if error is CancellationError {
                throw error
            }
            throw YTDLPError.downloadFailed(request.redactedDiagnostic(error.localizedDescription))
        }

        let processRunElapsed = Date().timeIntervalSince(processStartBox.value)
        logger.info("[TIMING] Download process completed in \(String(format: "%.2f", processRunElapsed))s")

        if let reason = control.reason(id: executionID) {
            try throwCancellation(reason)
        }

        let terminationStatus = subprocessResult.terminationStatus

        // Read final state
        let firstError = parsedState.read { $0.firstError }
        let outputPath = parsedState.read { $0.outputPath }
        let videoTitle = parsedState.read { $0.videoTitle }
        let fileAlreadyExists = parsedState.read { $0.fileAlreadyExists }
        let existingFilePath = parsedState.read { $0.existingFilePath }

        // Check if file already exists (detected via --no-overwrites)
        if fileAlreadyExists {
            let existingPath = existingFilePath ?? outputFolder.appendingPathComponent(videoTitle).path
            logger.info("File already exists at: \(existingPath, privacy: .auto)")
            throw YTDLPError.fileAlreadyExists(path: existingPath, title: videoTitle)
        }

        // Check exit status
        guard terminationStatus == 0 else {
            let diagnostic = request.redactedDiagnostic(subprocessResult.standardErrorText)
            let errorMessage = firstError
                ?? (diagnostic.isEmpty ? "Download failed with exit code \(terminationStatus)" : diagnostic)
            throw YTDLPError.downloadFailed(errorMessage)
        }

        // Note: Output path is captured from stdout via the readabilityHandler above
        // The --print after_move:filepath outputs the final path which we parse there
        logger.info("Final output path from parsing: \(outputPath ?? "nil", privacy: .auto)")

        // Verify output file exists
        guard let finalPath = outputPath else {
            throw YTDLPError.outputNotFound
        }

        let outputURL: URL
        if finalPath.hasPrefix("/") {
            outputURL = URL(fileURLWithPath: finalPath)
        } else {
            outputURL = outputFolder.appendingPathComponent(finalPath)
        }

        // Defense-in-depth: yt-dlp normally sanitizes %(title)s and would not emit a path
        // outside outputFolder, but the post-download path here is whatever the subprocess
        // printed — confine it to the user's chosen folder before we touch the filesystem.
        let resolvedOutput = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFolder = outputFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedOutput.path == resolvedFolder.path
            || resolvedOutput.path.hasPrefix(resolvedFolder.path + "/") else {
            logger.error("yt-dlp output path \(resolvedOutput.path, privacy: .public) is outside chosen folder \(resolvedFolder.path, privacy: .public)")
            throw YTDLPError.outputNotFound
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw YTDLPError.outputNotFound
        }

        if Task.isCancelled {
            _ = control.cancel()
        }
        if let reason = control.reason(id: executionID) {
            try throwCancellation(reason)
        }

        // Report 100% progress
        progress(1.0, nil, false)

        return YTDLPDownloadResult(outputURL: outputURL, title: videoTitle)
    }

}

enum YTDLPError: Error, LocalizedError {
    case binaryNotFound
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case outputNotFound
    case cancelled
    case liveRecordingStopped
    case fileAlreadyExists(path: String, title: String)
    case stalled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "yt-dlp binary not found"
        case .metadataFetchFailed(let message):
            return "Failed to fetch metadata: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .outputNotFound:
            return "Downloaded file not found"
        case .cancelled:
            return "Download was cancelled"
        case .liveRecordingStopped:
            return "Live stream recording stopped"
        case .fileAlreadyExists(let path, _):
            return "File already exists: \(path)"
        case .stalled:
            return "Download stalled — no activity for several minutes"
        }
    }
}
