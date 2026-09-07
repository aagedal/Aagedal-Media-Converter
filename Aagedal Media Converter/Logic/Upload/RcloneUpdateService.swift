// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Resolves the rclone binary path. Three sources, mirroring how yt-dlp is handled:
///   - `.app`      → minimal binary bundled with the app (default; security-hardened)
///   - `.homebrew` → `/opt/homebrew/bin/rclone`
///   - `.custom`   → user-picked path, validated by running `--version`
actor RcloneUpdateService {
    static let shared = RcloneUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneUpdate")
    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    /// Cache key for custom-path validation: (path, mtime, size). If any of those change we re-validate.
    private struct CustomPathFingerprint: Equatable {
        let path: String
        let mtime: Date
        let size: Int64
    }
    private var lastValidatedCustomPath: CustomPathFingerprint?

    /// Path to the rclone binary bundled inside the app's Resources directory.
    /// This is the default source — a minimal build with only the backends this app uses,
    /// shipped to avoid pulling the full upstream binary at runtime.
    nonisolated var bundledPath: String? {
        guard let path = Bundle.main.path(forResource: "rclone", ofType: nil) else {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private nonisolated func selectedRcloneSource() -> BinarySourceSelection? {
        guard let raw = UserDefaults.standard.string(forKey: AppConstants.rcloneBinarySourceKey),
              !raw.isEmpty else {
            return nil
        }
        return BinarySourceSelection(rawValue: raw)
    }

    private func resolveRclonePath(for selection: BinarySourceSelection) async -> String? {
        switch selection {
        case .app:
            return resolveBundledPath()
        case .homebrew:
            return resolveHomebrewPath()
        case .custom:
            return await resolveCustomPath()
        }
    }

    private nonisolated func resolveBundledPath() -> String? {
        if let path = bundledPath {
            return path
        }
        return nil
    }

    private nonisolated func resolveHomebrewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/rclone"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func resolveCustomPath() async -> String? {
        guard let path = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
              !path.isEmpty else {
            return nil
        }
        guard await validateCustomRclonePath(path) else {
            logger.warning("Custom rclone path is missing or not a valid rclone binary: \(path, privacy: .private)")
            return nil
        }
        return path
    }

    /// Returns the path to the best available rclone binary.
    ///
    /// If the user has explicitly chosen a source via the settings picker, that source is honored.
    /// Otherwise we fall back to: bundled → custom (validated) → Homebrew. The bundled binary
    /// is always present in shipping builds, so the no-saved-choice case effectively means
    /// "use the minimal binary we shipped with the app."
    func resolveRclonePath() async -> String? {
        if let selection = selectedRcloneSource() {
            if let resolved = await resolveRclonePath(for: selection) {
                logger.info("Using \(selection.rawValue, privacy: .public) rclone")
                return resolved
            }
            logger.warning("Selected rclone source \(selection.rawValue, privacy: .public) is unavailable")
            return nil
        }

        if let path = resolveBundledPath() {
            logger.info("Using bundled rclone")
            return path
        }
        if let path = await resolveCustomPath() {
            logger.info("Using custom rclone at: \(path, privacy: .private)")
            return path
        }
        if let path = resolveHomebrewPath() {
            logger.info("Using Homebrew rclone at: \(path, privacy: .public)")
            return path
        }

        logger.warning("No rclone binary available")
        return nil
    }

    /// Validates that `path` exists and behaves like rclone (`--version` returns "rclone v..."). Caches per file fingerprint.
    private func validateCustomRclonePath(_ path: String) async -> Bool {
        guard let fingerprint = currentFingerprint(for: path) else {
            lastValidatedCustomPath = nil
            return false
        }

        if let cached = lastValidatedCustomPath, cached == fingerprint {
            return true
        }

        guard await RcloneBinaryVerifier.versionString(
            of: path,
            subprocessRunner: subprocessRunner
        ) != nil else {
            lastValidatedCustomPath = nil
            return false
        }

        lastValidatedCustomPath = fingerprint
        return true
    }

    /// Returns the (path, mtime, size) fingerprint for a file, or nil if it doesn't exist / isn't readable.
    private func currentFingerprint(for path: String) -> CustomPathFingerprint? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        guard let mtime = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return CustomPathFingerprint(path: path, mtime: mtime, size: size)
    }

    /// Checks if rclone is available
    func isRcloneAvailable() async -> Bool {
        await resolveRclonePath() != nil
    }

    /// Gets the current installation status. Mirrors the priority used by `resolveRclonePath`.
    nonisolated func getInstallationStatus() -> RcloneInstallationStatus {
        if let selection = selectedRcloneSource() {
            return installationStatus(for: selection)
        }

        if bundledPath != nil {
            return .bundled
        }
        if let custom = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return .customPath(custom)
        }
        if let homebrew = ["/opt/homebrew/bin/rclone"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return .systemAvailable(homebrew)
        }
        return .notInstalled
    }

    private nonisolated func installationStatus(for selection: BinarySourceSelection) -> RcloneInstallationStatus {
        switch selection {
        case .app:
            return bundledPath != nil ? .bundled : .notInstalled
        case .homebrew:
            if let path = ["/opt/homebrew/bin/rclone"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return .systemAvailable(path)
            }
            return .notInstalled
        case .custom:
            if let custom = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
               !custom.isEmpty,
               FileManager.default.fileExists(atPath: custom) {
                return .customPath(custom)
            }
            return .notInstalled
        }
    }

    /// Gets the version of the currently active rclone binary
    func getCurrentVersion() async -> String? {
        guard let rclonePath = await resolveRclonePath() else { return nil }
        guard let firstLine = await RcloneBinaryVerifier.versionString(
            of: rclonePath,
            subprocessRunner: subprocessRunner
        ) else { return nil }

        // First line is like: "rclone v1.68.2".
        if let range = firstLine.range(
            of: "v[0-9]+\\.[0-9]+\\.[0-9]+",
            options: .regularExpression
        ) {
            return String(firstLine[range])
        }
        return firstLine
    }

    // MARK: - Custom Path Management

    /// Saves a custom rclone path
    func saveCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppConstants.rcloneCustomPathKey)
        logger.info("Saved custom rclone path: \(path, privacy: .private)")
    }

    /// Gets the custom rclone path
    nonisolated func getCustomPath() -> String? {
        UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey)
    }

    /// Clears the custom rclone path
    func clearCustomPath() {
        UserDefaults.standard.removeObject(forKey: AppConstants.rcloneCustomPathKey)
        logger.info("Cleared custom rclone path")
    }
}

// MARK: - GitHub redirect guard

/// Refuses HTTP redirects to hosts outside GitHub's release-serving infrastructure.
/// Used by the app's update checker (see `UpdateChecker`) — kept here for historical reasons.
final class GitHubRedirectGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(GitHubHostAllowlist.allow(request: request))
    }
}

/// Whitelist of hosts that GitHub legitimately uses for the API and release artifacts.
/// A redirect to anything else is treated as suspicious and refused.
enum GitHubHostAllowlist {
    private static let suffixes: [String] = [
        "github.com",
        "githubusercontent.com",
        "githubassets.com"
    ]

    static func allow(request: URLRequest) -> URLRequest? {
        guard let host = request.url?.host?.lowercased() else { return nil }
        for suffix in suffixes {
            if host == suffix || host.hasSuffix("." + suffix) {
                return request
            }
        }
        return nil
    }
}

// MARK: - Installation Status

/// Status of rclone installation
enum RcloneInstallationStatus {
    case notInstalled
    case bundled
    case customPath(String)
    case systemAvailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .bundled:
            return "Bundled"
        case .customPath(let path):
            return "Custom: \(path)"
        case .systemAvailable(let path):
            return "Homebrew: \(path)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .bundled, .customPath, .systemAvailable:
            return true
        }
    }
}
