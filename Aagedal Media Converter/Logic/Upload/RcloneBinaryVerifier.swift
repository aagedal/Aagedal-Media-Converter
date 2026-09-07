// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Identity check for rclone binaries used by the custom-path resolver.
///
/// Used by `RcloneUpdateService.validateCustomRclonePath` to confirm that a path the user
/// pointed at is actually rclone before we hand arguments and credentials to it.
enum RcloneBinaryVerifier {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneVerifier")

    /// Runs the binary with `--version` and returns its first line, or nil if it does not look like rclone.
    /// Used to validate user-provided custom paths point at an actual rclone binary.
    static func versionString(
        of binaryPath: String,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> String? {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["--version"],
            timeout: .seconds(5),
            standardOutputCaptureLimit: 8 * 1024,
            standardErrorCaptureLimit: 8 * 1024,
            sensitiveValues: [binaryPath]
        )
        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                let diagnostic = request.redactedDiagnostic(result.standardErrorText, limit: 512)
                logger.warning(
                    "rclone version probe exited \(result.terminationStatus): \(diagnostic, privacy: .public)"
                )
                return nil
            }

            let firstLine = result.standardOutputText.components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Real rclone always emits "rclone v<semver>" as the first line.
            guard firstLine.hasPrefix("rclone v") else { return nil }
            return firstLine
        } catch {
            if !(error is CancellationError) {
                let diagnostic = request.redactedDiagnostic(error.localizedDescription, limit: 512)
                logger.warning("rclone version probe failed: \(diagnostic, privacy: .public)")
            }
            return nil
        }
    }
}

// MARK: - Shared GitHub request constants

/// Centralizes the User-Agent we send to GitHub. GitHub's API requires one and rate-limits anonymous requests,
/// and a stable UA also makes it easier to identify our traffic in support investigations.
enum GitHubRequest {
    static let userAgent: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aagedal.MediaConverter"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "\(bundleID)/\(version)"
    }()
}
