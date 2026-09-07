// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation
import OSLog

/// Bounded subprocess boundary for the lightweight version checks used by the
/// yt-dlp settings UI. Keeping parsing here makes the updater independently
/// testable without changing its binary-selection or download policy.
struct YTDLPVersionProbe: Sendable {
    static let timeout: Duration = .seconds(3)
    static let captureLimit = 64 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func denoVersion(at path: String) async -> String? {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["--version"],
            timeout: Self.timeout,
            standardOutputCaptureLimit: Self.captureLimit,
            standardErrorCaptureLimit: Self.captureLimit,
            sensitiveValues: [path]
        )
        guard let output = await successfulOutput(for: request) else { return nil }

        let firstLine = output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(whereSeparator: \.isWhitespace)
        if parts.count >= 2 {
            return String(parts[1])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ytdlpVersion(at path: String) async -> String? {
        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: path,
            arguments: ["--version"]
        )

        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            timeout: Self.timeout,
            standardOutputCaptureLimit: Self.captureLimit,
            standardErrorCaptureLimit: Self.captureLimit,
            sensitiveValues: [path]
        )
        guard let output = await successfulOutput(for: request) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func successfulOutput(for request: SubprocessRequest) async -> String? {
        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded,
                  result.discardedStandardOutputBytes == 0 else { return nil }
            return result.standardOutputText
        } catch {
            return nil
        }
    }
}

/// Runs the intentionally slow first launch of an app-downloaded yt-dlp binary
/// behind the shared subprocess boundary.
struct YTDLPWarmUpRunner: Sendable {
    static let timeout: Duration = .seconds(30)

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func run(at path: String) async throws -> SubprocessResult {
        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: path,
            arguments: ["--version"]
        )

        return try await subprocessRunner.run(
            SubprocessRequest(
                executableURL: configuration.executableURL,
                arguments: configuration.arguments,
                environment: configuration.environment,
                timeout: Self.timeout,
                standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: 0,
                sensitiveValues: [path]
            )
        )
    }
}

struct DenoArchiveExtraction: Sendable {
    let binaryURL: URL
    let workingDirectoryURL: URL
}

/// Prepares a Deno binary in its destination directory before atomically
/// publishing it. A failed or cancelled publication leaves the prior runtime
/// untouched.
struct DenoRuntimeInstaller: Sendable {
    private let beforePublication: @Sendable () throws -> Void

    init(beforePublication: @escaping @Sendable () throws -> Void = {}) {
        self.beforePublication = beforePublication
    }

    func install(_ extraction: DenoArchiveExtraction, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let stagedURL = destinationDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent)-install-\(UUID().uuidString)"
        )

        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagedURL) }

        try fileManager.moveItem(at: extraction.binaryURL, to: stagedURL)
        _ = removexattr(stagedURL.path, "com.apple.quarantine", 0)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stagedURL.path
        )

        try beforePublication()
        try Task.checkCancellation()

        let renameResult = stagedURL.path.withCString { stagedPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(stagedPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            let errorCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(errorCode)
        }
    }
}

struct DenoArchiveHasher: Sendable {
    private let beforeChunk: @Sendable () throws -> Void

    init(beforeChunk: @escaping @Sendable () throws -> Void = {}) {
        self.beforeChunk = beforeChunk
    }

    func hash(_ fileURL: URL) async throws -> String {
        let beforeChunk = beforeChunk
        let hashingTask = Task.detached {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            var hasher = SHA256()
            while true {
                try beforeChunk()
                try Task.checkCancellation()
                guard let chunk = try fileHandle.read(upToCount: 1024 * 1024),
                      !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
            try Task.checkCancellation()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        return try await withTaskCancellationHandler {
            try await hashingTask.value
        } onCancel: {
            hashingTask.cancel()
        }
    }
}

/// Extracts the downloaded Deno archive behind the shared subprocess boundary.
/// The caller owns `workingDirectoryURL` after success and must remove it after
/// moving the returned binary into its final location.
struct DenoArchiveExtractor: Sendable {
    static let timeout: Duration = .seconds(5 * 60)
    static let diagnosticCaptureLimit = 64 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func extract(
        from archiveURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> DenoArchiveExtraction {
        let fileManager = FileManager.default
        let extractionDirectory = temporaryDirectory
            .appendingPathComponent("DenoArchiveExtraction-\(UUID().uuidString)", isDirectory: true)
        var callerOwnsExtractionDirectory = false

        try fileManager.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )
        defer {
            if !callerOwnsExtractionDirectory {
                try? fileManager.removeItem(at: extractionDirectory)
            }
        }

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-xk", archiveURL.path, extractionDirectory.path],
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [archiveURL.path, extractionDirectory.path]
        )

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YTDLPUpdateError.extractionFailed
        }

        guard result.succeeded else {
            throw YTDLPUpdateError.extractionFailed
        }
        try Task.checkCancellation()

        let directBinaryURL = extractionDirectory.appendingPathComponent("deno")
        let binaryURL: URL
        if fileManager.fileExists(atPath: directBinaryURL.path) {
            binaryURL = directBinaryURL
        } else {
            let contents = try fileManager.contentsOfDirectory(
                at: extractionDirectory,
                includingPropertiesForKeys: nil
            )
            guard let nestedBinaryURL = contents
                .map({ $0.appendingPathComponent("deno") })
                .first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                throw YTDLPUpdateError.binaryNotFound
            }
            binaryURL = nestedBinaryURL
        }

        try Task.checkCancellation()
        callerOwnsExtractionDirectory = true
        return DenoArchiveExtraction(
            binaryURL: binaryURL,
            workingDirectoryURL: extractionDirectory
        )
    }
}

/// Manages yt-dlp binary resolution with priority: custom path > downloaded > bundled
actor YTDLPUpdateService {
    static let shared = YTDLPUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "YTDLPUpdate")
    private let versionProbe: YTDLPVersionProbe
    private let warmUpRunner: YTDLPWarmUpRunner
    private let denoArchiveExtractor: DenoArchiveExtractor
    private let denoRuntimeInstaller: DenoRuntimeInstaller
    private var denoInstallTask: Task<String?, Never>?
    private var activeWarmUp: (
        id: UUID,
        task: Task<SubprocessResult, Error>
    )?
    private var activeDenoExtraction: (
        id: UUID,
        task: Task<DenoArchiveExtraction, Error>
    )?
    private var activeDenoUpdate: (
        id: UUID,
        task: Task<String, Error>
    )?
    private var cachedDenoPath: String?
    private var activeDownloadTasks: [YTDLPDownloadKind: URLSessionDownloadTask] = [:]

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        denoRuntimeInstaller: DenoRuntimeInstaller = DenoRuntimeInstaller()
    ) {
        versionProbe = YTDLPVersionProbe(subprocessRunner: subprocessRunner)
        warmUpRunner = YTDLPWarmUpRunner(subprocessRunner: subprocessRunner)
        denoArchiveExtractor = DenoArchiveExtractor(subprocessRunner: subprocessRunner)
        self.denoRuntimeInstaller = denoRuntimeInstaller
    }

    /// Path to bundled yt-dlp binary in app bundle
    /// Note: We don't bundle yt-dlp anymore because PyInstaller binaries
    /// don't work with Hardened Runtime (semctl blocked). Users should
    /// install via Homebrew: brew install yt-dlp
    var bundledPath: String? {
        nil
    }

    /// Path to downloaded yt-dlp binary in Application Support
    var downloadedPath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("yt-dlp")
    }

    /// Path to version file for downloaded binary
    private var versionFilePath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("version.txt")
    }

    /// Path to downloaded deno binary in Application Support
    private var denoDownloadedPath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("deno")
    }

    private func selectedYTDLPSource() -> BinarySourceSelection? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.ytdlpBinarySourceKey),
              !rawValue.isEmpty else {
            return nil
        }
        return BinarySourceSelection(rawValue: rawValue)
    }

    private func selectedDenoSource() -> BinarySourceSelection? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.denoBinarySourceKey),
              !rawValue.isEmpty else {
            return nil
        }
        return BinarySourceSelection(rawValue: rawValue)
    }

    private func resolveYTDLPPath(for selection: BinarySourceSelection) -> String? {
        switch selection {
        case .custom:
            return resolveCustomYTDLPPath()
        case .homebrew:
            return resolveHomebrewYTDLPPath()
        case .app:
            return resolveDownloadedYTDLPPath() ?? resolveBundledYTDLPPath()
        }
    }

    private func resolveCustomYTDLPPath() -> String? {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.ytdlpCustomPathKey),
              !customPath.isEmpty else {
            return nil
        }
        if FileManager.default.fileExists(atPath: customPath) {
            logger.info("Using custom yt-dlp at: \(customPath)")
            return customPath
        }
        logger.warning("Custom yt-dlp path no longer exists: \(customPath)")
        return nil
    }

    private func resolveHomebrewYTDLPPath() -> String? {
        let homebrewPaths = [
            "/opt/homebrew/bin/yt-dlp"
        ]
        for path in homebrewPaths where FileManager.default.fileExists(atPath: path) {
            logger.info("Using Homebrew yt-dlp at: \(path)")
            return path
        }
        return nil
    }

    private func resolveDownloadedYTDLPPath() -> String? {
        let downloadedPathString = downloadedPath.path
        let fileExists = FileManager.default.fileExists(atPath: downloadedPathString)
        var isExecutable = FileManager.default.isExecutableFile(atPath: downloadedPathString)
        logger.debug("Checking downloaded path: \(downloadedPathString), exists: \(fileExists), executable: \(isExecutable)")

        if fileExists && !isExecutable {
            logger.info("Fixing executable permissions for downloaded yt-dlp")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloadedPathString)
            isExecutable = FileManager.default.isExecutableFile(atPath: downloadedPathString)
            logger.debug("After chmod: executable: \(isExecutable)")
        }

        if fileExists {
            logger.info("Using downloaded yt-dlp at: \(downloadedPathString)")
            return downloadedPathString
        }

        return nil
    }

    private func resolveBundledYTDLPPath() -> String? {
        if let bundled = bundledPath,
           FileManager.default.isExecutableFile(atPath: bundled) {
            logger.info("Using bundled yt-dlp at: \(bundled)")
            return bundled
        }
        return nil
    }

    private func resolveDenoPath(for selection: BinarySourceSelection) -> String? {
        switch selection {
        case .custom:
            return resolveCustomDenoPath()
        case .homebrew:
            return resolveSystemDenoPath()
        case .app:
            return resolveDownloadedDenoPath()
        }
    }

    private func resolveCustomDenoPath() -> String? {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.denoCustomPathKey),
              !customPath.isEmpty else {
            return nil
        }
        if FileManager.default.fileExists(atPath: customPath) {
            cachedDenoPath = customPath
            return customPath
        }
        return nil
    }

    private func resolveDownloadedDenoPath() -> String? {
        let downloadedPathString = denoDownloadedPath.path
        if FileManager.default.fileExists(atPath: downloadedPathString) {
            cachedDenoPath = downloadedPathString
            return downloadedPathString
        }
        return nil
    }

    private func resolveSystemDenoPath() -> String? {
        let systemPaths = [
            "/opt/homebrew/bin/deno",
            "/usr/bin/deno"
        ]
        for path in systemPaths where FileManager.default.fileExists(atPath: path) {
            cachedDenoPath = path
            return path
        }
        return nil
    }

    private func ytdlpInstallationStatus(for selection: BinarySourceSelection) -> YTDLPInstallationStatus {
        switch selection {
        case .custom:
            if let customPath = resolveCustomYTDLPPath() {
                return .customPath(customPath)
            }
            return .notInstalled
        case .homebrew:
            if let homebrewPath = resolveHomebrewYTDLPPath() {
                return .homebrewAvailable(homebrewPath)
            }
            return .notInstalled
        case .app:
            if FileManager.default.fileExists(atPath: downloadedPath.path) {
                let version = UserDefaults.standard.string(forKey: AppConstants.ytdlpVersionKey)
                return .downloaded(version: version)
            }
            return .notInstalled
        }
    }

    private func denoInstallationStatus(for selection: BinarySourceSelection) -> DenoInstallationStatus {
        switch selection {
        case .custom:
            if let customPath = resolveCustomDenoPath() {
                return .customPath(customPath)
            }
            return .notInstalled
        case .homebrew:
            if let systemPath = resolveSystemDenoPath() {
                return .systemAvailable(systemPath)
            }
            return .notInstalled
        case .app:
            if FileManager.default.fileExists(atPath: denoDownloadedPath.path) {
                let version = UserDefaults.standard.string(forKey: AppConstants.denoVersionKey)
                return .downloaded(version: version)
            }
            return .notInstalled
        }
    }

    /// Returns the path to the best available yt-dlp binary
    /// Priority: 1) Custom path, 2) Homebrew, 3) Downloaded, 4) Bundled
    func resolveYTDLPPath() -> String? {
        if let selection = selectedYTDLPSource() {
            return resolveYTDLPPath(for: selection)
        }

        if let customPath = resolveCustomYTDLPPath() {
            return customPath
        }

        if let homebrewPath = resolveHomebrewYTDLPPath() {
            return homebrewPath
        }

        if let downloaded = resolveDownloadedYTDLPPath() {
            return downloaded
        }

        if let bundled = resolveBundledYTDLPPath() {
            return bundled
        }

        logger.warning("No yt-dlp binary available")
        return nil
    }

    // MARK: - Deno Runtime Management

    /// Returns the best available deno path (downloaded or system)
    func resolveDenoPath() -> String? {
        if let selection = selectedDenoSource() {
            return resolveDenoPath(for: selection)
        }

        if let customPath = resolveCustomDenoPath() {
            return customPath
        }

        if let downloadedPath = resolveDownloadedDenoPath() {
            return downloadedPath
        }

        if let cached = cachedDenoPath,
           FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        if let systemPath = resolveSystemDenoPath() {
            return systemPath
        }

        return nil
    }

    /// Ensures deno is available (auto-downloads if missing)
    func ensureDenoInstalled() async -> String? {
        if let selection = selectedDenoSource(), selection != .app {
            return resolveDenoPath()
        }

        if let resolved = resolveDenoPath() {
            return resolved
        }

        if let task = denoInstallTask {
            return await task.value
        }

        let logger = logger
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                let path = try await self.runDenoUpdate(progress: { _ in })
                return path
            } catch {
                logger.error("Failed to auto-download deno: \(error.localizedDescription)")
                return nil
            }
        }
        denoInstallTask = task
        let path = await task.value
        denoInstallTask = nil
        if let path {
            cachedDenoPath = path
        }
        return path
    }

    /// Gets the current deno version from the resolved runtime
    func getCurrentDenoVersion() async -> String? {
        guard let denoPath = resolveDenoPath() else { return nil }
        if denoPath == denoDownloadedPath.path,
           let cached = UserDefaults.standard.string(forKey: AppConstants.denoVersionKey) {
            return cached
        }

        return await versionProbe.denoVersion(at: denoPath)
    }

    /// Checks if a deno update is available
    func checkForDenoUpdates() async -> Bool {
        do {
            guard let currentVersion = await getCurrentDenoVersion(),
                  let (latestVersion, _) = try await getLatestDenoRelease() else {
                return false
            }

            let normalizedCurrent = currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let normalizedLatest = latestVersion.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let isNewer = normalizedLatest.compare(normalizedCurrent, options: .numeric) == .orderedDescending
            logger.info("deno - Current: \(currentVersion), Latest: \(latestVersion), Update available: \(isNewer)")
            return isNewer
        } catch {
            logger.error("Failed to check for deno updates: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and installs the latest deno release
    func downloadDenoUpdate() async throws {
        _ = try await runDenoUpdate(progress: { _ in })
        cachedDenoPath = denoDownloadedPath.path
    }

    /// Downloads and installs the latest deno release
    /// - Parameter progress: Callback for download progress (0.0 to 1.0)
    func downloadDenoUpdate(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await runDenoUpdate(progress: progress)
        cachedDenoPath = denoDownloadedPath.path
    }

    /// Gets the current installation status for deno
    func getDenoInstallationStatus() -> DenoInstallationStatus {
        if let selection = selectedDenoSource() {
            return denoInstallationStatus(for: selection)
        }

        if let customPath = resolveCustomDenoPath() {
            return .customPath(customPath)
        }

        if FileManager.default.fileExists(atPath: denoDownloadedPath.path) {
            let version = UserDefaults.standard.string(forKey: AppConstants.denoVersionKey)
            return .downloaded(version: version)
        }

        if let systemPath = resolveSystemDenoPath() {
            return .systemAvailable(systemPath)
        }

        return .notInstalled
    }

    // MARK: - Custom Path Management

    /// Saves a custom yt-dlp path
    func saveCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppConstants.ytdlpCustomPathKey)
        logger.info("Saved custom yt-dlp path: \(path)")
    }

    /// Gets the custom yt-dlp path
    nonisolated func getCustomPath() -> String? {
        UserDefaults.standard.string(forKey: AppConstants.ytdlpCustomPathKey)
    }

    /// Clears the custom yt-dlp path
    func clearCustomPath() {
        UserDefaults.standard.removeObject(forKey: AppConstants.ytdlpCustomPathKey)
        logger.info("Cleared custom yt-dlp path")
    }

    /// Saves a custom deno path
    func saveDenoCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppConstants.denoCustomPathKey)
        logger.info("Saved custom deno path: \(path)")
    }

    /// Gets the custom deno path
    nonisolated func getDenoCustomPath() -> String? {
        UserDefaults.standard.string(forKey: AppConstants.denoCustomPathKey)
    }

    /// Clears the custom deno path
    func clearDenoCustomPath() {
        UserDefaults.standard.removeObject(forKey: AppConstants.denoCustomPathKey)
        logger.info("Cleared custom deno path")
    }

    /// Checks if yt-dlp is available
    func isYTDLPAvailable() -> Bool {
        resolveYTDLPPath() != nil
    }

    /// Downloads yt-dlp if not already installed
    /// Returns true if yt-dlp is available after this call
    func ensureYTDLPInstalled() async -> Bool {
        if let selection = selectedYTDLPSource(), selection != .app {
            return resolveYTDLPPath() != nil
        }

        // Check if already available
        if resolveYTDLPPath() != nil {
            return true
        }

        logger.info("No yt-dlp found, attempting to download...")

        do {
            try await downloadUpdate()
            return resolveYTDLPPath() != nil
        } catch {
            logger.error("Failed to auto-download yt-dlp: \(error.localizedDescription)")
            return false
        }
    }

    /// Gets the current installation status
    func getInstallationStatus() -> YTDLPInstallationStatus {
        if let selection = selectedYTDLPSource() {
            return ytdlpInstallationStatus(for: selection)
        }

        if let customPath = resolveCustomYTDLPPath() {
            return .customPath(customPath)
        }

        if let homebrewPath = resolveHomebrewYTDLPPath() {
            return .homebrewAvailable(homebrewPath)
        }

        if FileManager.default.fileExists(atPath: downloadedPath.path) {
            let version = UserDefaults.standard.string(forKey: AppConstants.ytdlpVersionKey)
            return .downloaded(version: version)
        }

        return .notInstalled
    }

    /// Gets the version of the currently active yt-dlp binary
    func getCurrentVersion() async -> String? {
        guard let ytdlpPath = resolveYTDLPPath() else { return nil }
        if ytdlpPath == downloadedPath.path,
           let cached = UserDefaults.standard.string(forKey: AppConstants.ytdlpVersionKey) {
            return cached
        }

        return await versionProbe.ytdlpVersion(at: ytdlpPath)
    }

    /// Pre-warms the yt-dlp binary by running it once in the background.
    /// This is useful for PyInstaller-frozen binaries (darwin_exe) which have slow startup
    /// due to extracting the embedded Python environment. Running --version once caches
    /// the extraction, making subsequent runs faster (~6 seconds improvement).
    /// Only warms up if using the app-downloaded binary (not Homebrew or custom).
    @discardableResult
    nonisolated func warmUp() -> Task<Void, Never> {
        Task {
            await _warmUp()
        }
    }

    private func _warmUp() async {
        // Only warm up if using the app-downloaded binary
        guard let selection = selectedYTDLPSource(), selection == .app else {
            return
        }

        let downloadedPathString = downloadedPath.path
        guard FileManager.default.isExecutableFile(atPath: downloadedPathString) else {
            return
        }

        logger.debug("Warming up yt-dlp binary...")

        do {
            let result = try await runYTDLPWarmUp(at: downloadedPathString)
            if result.succeeded {
                logger.debug("yt-dlp warm-up completed")
            } else {
                logger.warning("yt-dlp warm-up exited with status \(result.terminationStatus)")
            }
        } catch is CancellationError {
            logger.debug("yt-dlp warm-up cancelled")
        } catch {
            logger.warning("yt-dlp warm-up failed: \(error.localizedDescription)")
        }
    }

    /// Owns the current warm-up so repeated launches supersede earlier work and
    /// cancellation reaches the child process managed by the shared runner.
    func runYTDLPWarmUp(at path: String) async throws -> SubprocessResult {
        if let previousWarmUp = activeWarmUp {
            activeWarmUp = nil
            previousWarmUp.task.cancel()
        }

        let warmUpID = UUID()
        let runner = warmUpRunner
        let warmUpTask = Task {
            try await runner.run(at: path)
        }
        activeWarmUp = (warmUpID, warmUpTask)

        defer {
            if activeWarmUp?.id == warmUpID {
                activeWarmUp = nil
            }
        }

        return try await withTaskCancellationHandler {
            let result = try await warmUpTask.value
            try Task.checkCancellation()
            guard activeWarmUp?.id == warmUpID else {
                throw CancellationError()
            }
            return result
        } onCancel: {
            warmUpTask.cancel()
        }
    }

    /// Checks GitHub for the latest yt-dlp release version
    func getLatestReleaseVersion() async throws -> (version: String, downloadURL: URL, checksumURL: URL?)? {
        guard let url = URL(string: AppConstants.ytdlpGitHubReleasesURL) else {
            throw YTDLPUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YTDLPUpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw YTDLPUpdateError.parseError
        }

        // Find the macOS asset and, if present, the SHA256 checksum manifest
        // yt-dlp publishes alongside it.
        var binaryURL: URL?
        var checksumURL: URL?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let assetURL = URL(string: downloadURLString) else {
                continue
            }
            if name == AppConstants.ytdlpMacOSAssetName {
                binaryURL = assetURL
            } else if name == "SHA2-256SUMS" {
                checksumURL = assetURL
            }
        }

        guard let binaryURL else { throw YTDLPUpdateError.assetNotFound }
        return (version: tagName, downloadURL: binaryURL, checksumURL: checksumURL)
    }

    // MARK: - Deno Download

    /// Owns the complete Deno update, including release lookup, checksum fetch,
    /// extraction, and publication, so Settings cancellation reaches every phase.
    private func runDenoUpdate(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        if let previousUpdate = activeDenoUpdate {
            activeDenoUpdate = nil
            previousUpdate.task.cancel()
            activeDownloadTasks[.deno]?.cancel()
            activeDenoExtraction?.task.cancel()
            _ = try? await previousUpdate.task.value
        }

        let updateID = UUID()
        let updateTask = Task {
            try await self.downloadDenoRuntime(progress: progress)
        }
        activeDenoUpdate = (updateID, updateTask)

        defer {
            if activeDenoUpdate?.id == updateID {
                activeDenoUpdate = nil
            }
        }

        return try await withTaskCancellationHandler {
            let path = try await updateTask.value
            try Task.checkCancellation()
            guard activeDenoUpdate?.id == updateID else {
                throw CancellationError()
            }
            return path
        } onCancel: {
            updateTask.cancel()
        }
    }

    private func getLatestDenoRelease() async throws -> (version: String, downloadURL: URL)? {
        guard let url = URL(string: AppConstants.denoGitHubReleasesURL) else {
            throw YTDLPUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YTDLPUpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw YTDLPUpdateError.parseError
        }

        let assetNames = [
            "deno-aarch64-apple-darwin.zip",
            "deno-arm64-apple-darwin.zip"
        ]

        for asset in assets {
            if let name = asset["name"] as? String,
               assetNames.contains(name),
               let downloadURLString = asset["browser_download_url"] as? String,
               let downloadURL = URL(string: downloadURLString) {
                return (version: tagName, downloadURL: downloadURL)
            }
        }

        throw YTDLPUpdateError.assetNotFound
    }

    private func downloadDenoRuntime(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard let (version, downloadURL) = try await getLatestDenoRelease() else {
            throw YTDLPUpdateError.assetNotFound
        }

        logger.info("Auto-downloading deno \(version) from \(downloadURL)")

        let (tempZipURL, response) = try await downloadWithProgress(from: downloadURL, kind: .deno, progress: progress)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempZipURL)
            throw YTDLPUpdateError.downloadFailed
        }

        // Verify SHA256 against the `<asset>.sha256sum` file denoland publishes
        // as a sibling of every release asset.
        let checksumURL = URL(string: downloadURL.absoluteString + ".sha256sum") ?? downloadURL
        do {
            try await verifyChecksum(
                of: tempZipURL,
                expectedFilename: downloadURL.lastPathComponent,
                checksumFileURL: checksumURL
            )
        } catch {
            try? FileManager.default.removeItem(at: tempZipURL)
            throw error
        }

        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempZipURL) }

        let extraction = try await extractDenoArchive(from: tempZipURL)
        defer { try? fm.removeItem(at: extraction.workingDirectoryURL) }

        let destinationPath = denoDownloadedPath
        let installer = denoRuntimeInstaller
        let installTask = Task.detached {
            try installer.install(extraction, at: destinationPath)
        }
        try await withTaskCancellationHandler {
            try await installTask.value
        } onCancel: {
            installTask.cancel()
        }
        UserDefaults.standard.set(Date(), forKey: AppConstants.denoLastUpdateCheckKey)
        UserDefaults.standard.set(version, forKey: AppConstants.denoVersionKey)

        logger.info("Installed deno at \(destinationPath.path)")
        cachedDenoPath = destinationPath.path
        return destinationPath.path
    }

    /// Runs extraction in an explicitly owned task so the Settings cancel action
    /// can stop `ditto` after the URLSession download has already completed.
    func extractDenoArchive(
        from archiveURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> DenoArchiveExtraction {
        if let previousExtraction = activeDenoExtraction {
            activeDenoExtraction = nil
            previousExtraction.task.cancel()
        }

        let extractionID = UUID()
        let extractor = denoArchiveExtractor
        let extractionTask = Task {
            try await extractor.extract(
                from: archiveURL,
                temporaryDirectory: temporaryDirectory
            )
        }
        activeDenoExtraction = (extractionID, extractionTask)

        defer {
            if activeDenoExtraction?.id == extractionID {
                activeDenoExtraction = nil
            }
        }

        return try await withTaskCancellationHandler {
            let extraction = try await extractionTask.value
            do {
                try Task.checkCancellation()
                guard activeDenoExtraction?.id == extractionID else {
                    throw CancellationError()
                }
                return extraction
            } catch {
                try? FileManager.default.removeItem(at: extraction.workingDirectoryURL)
                throw error
            }
        } onCancel: {
            extractionTask.cancel()
        }
    }

    /// Checks if an update is available
    func checkForUpdates() async -> Bool {
        do {
            guard let currentVersion = await getCurrentVersion(),
                  let (latestVersion, _, _) = try await getLatestReleaseVersion() else {
                return false
            }

            let isNewer = latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
            logger.info("Current: \(currentVersion), Latest: \(latestVersion), Update available: \(isNewer)")
            return isNewer
        } catch {
            logger.error("Failed to check for updates: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and installs the latest yt-dlp release (without progress)
    func downloadUpdate() async throws {
        try await downloadUpdate(progress: { _ in })
    }

    /// Downloads and installs the latest yt-dlp release
    /// - Parameter progress: Callback for download progress (0.0 to 1.0)
    func downloadUpdate(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let (version, downloadURL, checksumURL) = try await getLatestReleaseVersion() else {
            throw YTDLPUpdateError.assetNotFound
        }

        logger.info("Downloading yt-dlp \(version) from \(downloadURL)")

        // Download the binary with progress tracking
        let (tempURL, response) = try await downloadWithProgress(from: downloadURL, kind: .ytdlp, progress: progress)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw YTDLPUpdateError.downloadFailed
        }

        // Verify SHA256 against the checksum manifest published alongside the release.
        // If the manifest is missing we fail closed rather than installing an unverified
        // binary — running unverified yt-dlp is the worst outcome we can avoid here.
        guard let checksumURL else {
            logger.error("No SHA2-256SUMS asset found for yt-dlp \(version); refusing to install unverified binary")
            try? FileManager.default.removeItem(at: tempURL)
            throw YTDLPUpdateError.checksumNotFoundForAsset
        }
        do {
            try await verifyChecksum(
                of: tempURL,
                expectedFilename: AppConstants.ytdlpMacOSAssetName,
                checksumFileURL: checksumURL
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Move to final location
        let fm = FileManager.default
        let destinationPath = downloadedPath
        let destinationDir = destinationPath.deletingLastPathComponent()

        logger.info("Tools directory: \(destinationDir.path)")
        logger.info("Destination file: \(destinationPath.path)")

        // Ensure destination directory exists
        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
            logger.info("Created/verified tools directory")
        } catch {
            logger.error("Failed to create tools directory: \(error.localizedDescription)")
            throw YTDLPUpdateError.installFailed
        }

        logger.info("Installing yt-dlp to: \(destinationPath.path)")

        // Remove existing file if present
        if fm.fileExists(atPath: destinationPath.path) {
            try fm.removeItem(at: destinationPath)
        }

        try fm.moveItem(at: tempURL, to: destinationPath)

        // Verify file exists after move
        guard fm.fileExists(atPath: destinationPath.path) else {
            logger.error("File not found after move!")
            throw YTDLPUpdateError.installFailed
        }

        // Remove quarantine attribute (critical for sandbox)
        removeQuarantine(at: destinationPath.path)

        // Set executable permission
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath.path)

        // Verify file is executable
        let isExec = fm.isExecutableFile(atPath: destinationPath.path)
        logger.info("File exists: true, isExecutable: \(isExec)")

        // Save version info
        try version.write(to: versionFilePath, atomically: true, encoding: .utf8)

        // Update last check date
        UserDefaults.standard.set(Date(), forKey: AppConstants.ytdlpLastUpdateCheckKey)
        UserDefaults.standard.set(version, forKey: AppConstants.ytdlpVersionKey)

        logger.info("Successfully installed yt-dlp \(version) at \(destinationPath.path)")
    }

    /// Verifies that the file at `fileURL` matches the SHA256 hash published for
    /// `expectedFilename` in the checksum manifest at `checksumFileURL`.
    ///
    /// The manifest is expected to contain lines of the form `<hex-hash>  <filename>`
    /// (two-space separator is the GNU coreutils convention, but we tolerate any run
    /// of whitespace). Throws if the manifest can't be fetched/parsed, the asset
    /// isn't listed, or the hashes don't match.
    private func verifyChecksum(
        of fileURL: URL,
        expectedFilename: String,
        checksumFileURL: URL
    ) async throws {
        logger.info("Fetching SHA256 manifest for \(expectedFilename) from \(checksumFileURL)")
        let (data, response) = try await URLSession.shared.data(from: checksumFileURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YTDLPUpdateError.checksumFetchFailed
        }
        guard let manifest = String(data: data, encoding: .utf8) else {
            throw YTDLPUpdateError.checksumFetchFailed
        }

        var expectedHash: String?
        for rawLine in manifest.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Split on the first run of whitespace
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]).trimmingCharacters(in: .whitespaces)
            // File column may be prefixed with "*" (binary-mode marker from coreutils)
            let filename = String(parts[parts.count - 1]).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            if filename == expectedFilename {
                expectedHash = hash
                break
            }
        }

        guard let expected = expectedHash else {
            logger.error("No SHA256 entry for \(expectedFilename) in manifest")
            throw YTDLPUpdateError.checksumNotFoundForAsset
        }

        let actual = try await computeSHA256(of: fileURL)
        guard actual.lowercased() == expected.lowercased() else {
            logger.error("SHA256 mismatch for \(expectedFilename): expected \(expected), got \(actual)")
            throw YTDLPUpdateError.checksumMismatch
        }
        logger.info("SHA256 verified for \(expectedFilename)")
    }

    /// Hashes the archive off the updater actor and checks cancellation between
    /// bounded reads so Settings remains responsive for large downloads.
    private func computeSHA256(of fileURL: URL) async throws -> String {
        try await DenoArchiveHasher().hash(fileURL)
    }

    /// Removes the quarantine extended attribute from a file
    private func removeQuarantine(at path: String) {
        let result = removexattr(path, "com.apple.quarantine", 0)
        // ENOATTR (93) means attribute doesn't exist, which is fine
        // EPERM (1) can happen if file doesn't have quarantine attribute
        if result != 0 && errno != 93 && errno != 1 {
            logger.warning("Failed to remove quarantine attribute: \(errno)")
        }
    }

    /// Cancels the active download for the given kind, if any. No-op otherwise.
    func cancelDownload(_ kind: YTDLPDownloadKind) {
        var cancelledWork = false
        if let task = activeDownloadTasks[kind] {
            task.cancel()
            activeDownloadTasks[kind] = nil
            cancelledWork = true
        }
        if kind == .deno, let extraction = activeDenoExtraction {
            activeDenoExtraction = nil
            extraction.task.cancel()
            cancelledWork = true
        }
        if kind == .deno, let update = activeDenoUpdate {
            activeDenoUpdate = nil
            update.task.cancel()
            cancelledWork = true
        }
        if cancelledWork {
            logger.info("Cancelled \(String(describing: kind)) download")
        }
    }

    /// Downloads a file with progress tracking. Registers the task for
    /// cooperative cancellation via `cancelDownload(_:)`.
    private func downloadWithProgress(
        from url: URL,
        kind: YTDLPDownloadKind,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let request = URLRequest(url: url)

        let delegate = YTDLPDownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        defer { activeDownloadTasks[kind] = nil }

        let cancellation = URLSessionTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { tempURL, response, error in
                    // Release the session's strong reference to its delegate once the
                    // task finishes, preventing a per-download leak.
                    defer { session.finishTasksAndInvalidate() }

                    if let error = error {
                        if (error as? URLError)?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let tempURL = tempURL, let response = response else {
                        continuation.resume(throwing: YTDLPUpdateError.downloadFailed)
                        return
                    }

                    // Move to a more permanent temp location
                    let persistentTemp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: persistentTemp)
                        continuation.resume(returning: (persistentTemp, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                cancellation.register(task)
                activeDownloadTasks[kind] = task
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Performs update check and downloads if available (called on app launch)
    func performUpdateCheckIfNeeded() async {
        // Check if we should check for updates (once per day)
        let lastCheck = UserDefaults.standard.object(forKey: AppConstants.ytdlpLastUpdateCheckKey) as? Date
        let shouldCheck: Bool
        if let lastCheck = lastCheck {
            shouldCheck = Date().timeIntervalSince(lastCheck) > 86400 // 24 hours
        } else {
            shouldCheck = true
        }

        guard shouldCheck else {
            logger.info("Skipping yt-dlp update check (checked recently)")
            return
        }

        logger.info("Checking for yt-dlp updates...")

        do {
            if await checkForUpdates() {
                try await downloadUpdate()
            } else {
                // Update last check date even if no update needed
                UserDefaults.standard.set(Date(), forKey: AppConstants.ytdlpLastUpdateCheckKey)
            }
        } catch {
            logger.error("yt-dlp update failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Download Progress Delegate

final class URLSessionTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func register(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

private final class YTDLPDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressHandler(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled in the completion handler
    }
}

/// Identifies which download slot is active so callers can cancel the right one.
enum YTDLPDownloadKind: Sendable {
    case ytdlp
    case deno
}

enum YTDLPUpdateError: Error, LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case assetNotFound
    case downloadFailed
    case extractionFailed
    case binaryNotFound
    case installFailed
    case checksumFetchFailed
    case checksumNotFoundForAsset
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GitHub API URL"
        case .networkError: return "Network error while checking for updates"
        case .parseError: return "Failed to parse GitHub release info"
        case .assetNotFound: return "macOS binary not found in release"
        case .downloadFailed: return "Failed to download binary"
        case .extractionFailed: return "Failed to extract binary from archive"
        case .binaryNotFound: return "Binary not found in archive"
        case .installFailed: return "Failed to install binary"
        case .checksumFetchFailed: return "Could not download the SHA256 checksum manifest"
        case .checksumNotFoundForAsset: return "The release's checksum manifest did not list this asset"
        case .checksumMismatch: return "Downloaded binary failed SHA256 verification; refusing to install"
        }
    }
}

/// Status of deno installation
enum DenoInstallationStatus {
    case notInstalled
    case downloaded(version: String?)
    case customPath(String)
    case systemAvailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloaded(let version):
            if let version = version {
                return "Downloaded (\(version))"
            }
            return "Downloaded"
        case .customPath(let path):
            return "Custom: \(path)"
        case .systemAvailable(let path):
            if path.contains("/opt/homebrew/") {
                return "Homebrew: \(path)"
            }
            return "System: \(path)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .downloaded, .customPath, .systemAvailable:
            return true
        }
    }
}

/// Status of yt-dlp installation
enum YTDLPInstallationStatus {
    case notInstalled
    case downloaded(version: String?)
    case customPath(String)
    case homebrewAvailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloaded(let version):
            if let version = version {
                return "Downloaded (v\(version))"
            }
            return "Downloaded"
        case .customPath(let path):
            return "Custom: \(path)"
        case .homebrewAvailable(let path):
            return "Homebrew: \(path)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .downloaded, .customPath, .homebrewAvailable:
            return true
        }
    }

    var isCustomPath: Bool {
        switch self {
        case .customPath, .homebrewAvailable:
            return true
        case .notInstalled, .downloaded:
            return false
        }
    }
}
