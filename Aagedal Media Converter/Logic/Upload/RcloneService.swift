// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol RcloneUpdating: Sendable {
    func resolveRclonePath() async -> String?
}

extension RcloneUpdateService: RcloneUpdating {}

/// Service for executing rclone uploads
actor RcloneService {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneService")
    private let updateService: any RcloneUpdating
    private let subprocessRunner: any SubprocessRunning

    /// In-memory remote name used to define the upload destination via env vars.
    /// rclone reads RCLONE_CONFIG_<NAME>_* from the environment, so the secret never appears on argv.
    private static let remoteName = "upload"

    /// Hard upper bounds for rclone subprocess runtime. Cancels the process if exceeded.
    private static let uploadTimeout: Duration = .seconds(6 * 60 * 60) // 6h — large media uploads
    private static let testTimeout: Duration = .seconds(60)             // listing one dir
    private static let obscureTimeout: Duration = .seconds(5)           // pure local CPU

    init(
        updateService: any RcloneUpdating = RcloneUpdateService.shared,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) {
        self.updateService = updateService
        self.subprocessRunner = subprocessRunner
    }

    /// Uploads a file to a remote server using rclone
    /// - Parameters:
    ///   - localFile: The local file URL to upload
    ///   - config: The upload configuration (server, credentials, etc.)
    ///   - progress: Callback for progress updates (0-1, speed string)
    /// - Returns: The upload result
    func upload(
        localFile: URL,
        config: UploadConfig,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> UploadResult {
        guard let rclonePath = await updateService.resolveRclonePath() else {
            throw UploadError.rcloneNotFound
        }

        guard config.isConfigured else {
            throw UploadError.configurationMissing
        }

        let remoteEnv = try await buildRemoteEnvironment(config: config, rclonePath: rclonePath)
        let destination = uploadDestination(for: config)

        var args: [String] = ["copy", localFile.path, destination]
        args.append(contentsOf: [
            "--config=/dev/null",     // Don't read user's ~/.config/rclone/rclone.conf
            "--progress",
            "--stats=1s",
            "--stats-one-line",
            "--contimeout=30s",
            "--timeout=300s",
            "--retries=1"
        ])

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: rclonePath),
            arguments: args,
            environment: mergedEnvironment(with: remoteEnv),
            timeout: Self.uploadTimeout,
            standardOutputCaptureLimit: 64 * 1024,
            standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: sensitiveValues(
                arguments: [localFile.path, destination],
                remoteEnvironment: remoteEnv
            )
        )
        let state = RcloneOutputState()

        logger.info("[rclone] Starting upload: \(localFile.lastPathComponent, privacy: .private) -> \(destination, privacy: .private)")
        logger.info("[rclone] Command: \(request.redactedCommandDescription, privacy: .public)")

        let logger = self.logger
        let handleLine: @Sendable (SubprocessOutputStream, String) -> Void = { stream, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            switch stream {
            case .standardOutput:
                logger.debug("[rclone stdout] \(trimmed, privacy: .private)")
            case .standardError:
                logger.debug("[rclone stderr] \(trimmed, privacy: .private)")
            }

            if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                state.record(bytesTransferred: uploadProgress.bytesTransferred)
                progress(uploadProgress.percentage, uploadProgress.speed)
            }

            if stream == .standardError,
               let error = RcloneProgressParser.parseError(trimmed) {
                state.record(error: error)
                logger.error("[rclone] error category: \(categorizeError(error), privacy: .public)")
            }
        }

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request) { chunk in
                state.consume(chunk, handler: handleLine)
            }
            state.finish(handler: handleLine)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw UploadError.connectionFailed("Upload exceeded time limit and was cancelled")
            case .failedToStart:
                throw UploadError.uploadFailed("Failed to launch rclone")
            }
        } catch {
            throw UploadError.uploadFailed(request.redactedDiagnostic(error.localizedDescription, limit: 500))
        }

        if !result.succeeded {
            let raw = state.snapshot().lastError ?? "Upload failed with exit code \(result.terminationStatus)"
            let safeMessage = sanitizeErrorMessage(request.redactedDiagnostic(raw, limit: 500))

            if categorizeError(raw) == .authentication {
                throw UploadError.authenticationFailed
            }
            if categorizeError(raw) == .connection {
                throw UploadError.connectionFailed(safeMessage)
            }
            throw UploadError.uploadFailed(safeMessage)
        }

        progress(1.0, nil)

        let remotePath = config.remotePath + "/" + localFile.lastPathComponent
        logger.info("Upload complete: \(localFile.lastPathComponent, privacy: .private)")

        return UploadResult.success(
            remotePath: remotePath,
            bytes: state.snapshot().bytesTransferred,
            duration: result.duration.timeInterval
        )
    }

    /// Tests connection to the remote server
    func testConnection(config: UploadConfig) async throws -> Bool {
        guard let rclonePath = await updateService.resolveRclonePath() else {
            throw UploadError.rcloneNotFound
        }

        guard config.isConfigured else {
            throw UploadError.configurationMissing
        }

        let remoteEnv = try await buildRemoteEnvironment(config: config, rclonePath: rclonePath)
        let destination = uploadDestination(for: config)

        let args: [String] = [
            "lsd", destination,
            "--config=/dev/null",
            "--contimeout=15s",
            "--timeout=30s",
            "--retries=1"
        ]

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: rclonePath),
            arguments: args,
            environment: mergedEnvironment(with: remoteEnv),
            timeout: Self.testTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: sensitiveValues(
                arguments: [destination],
                remoteEnvironment: remoteEnv
            )
        )
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw UploadError.connectionFailed("Connection test timed out")
            case .failedToStart:
                throw UploadError.connectionFailed("Failed to launch rclone")
            }
        } catch {
            throw UploadError.connectionFailed(request.redactedDiagnostic(error.localizedDescription, limit: 500))
        }

        if !result.succeeded {
            let raw = request.redactedDiagnostic(result.standardErrorText, limit: 500)

            if categorizeError(raw) == .authentication {
                throw UploadError.authenticationFailed
            }
            throw UploadError.connectionFailed(sanitizeErrorMessage(raw))
        }

        return true
    }
    // MARK: - Private Methods

    /// Builds the destination path for an upload using the in-memory remote name.
    /// Returns e.g. "upload:/uploads/videos", "upload:share/path", "upload:bucket/path".
    private func uploadDestination(for config: UploadConfig) -> String {
        let name = Self.remoteName
        switch config.backendType {
        case .ftp, .sftp:
            let path = config.remotePath.hasPrefix("/") ? config.remotePath : "/\(config.remotePath)"
            return "\(name):\(path)"
        case .smb:
            let share = config.smbShare ?? ""
            let stripped = config.remotePath.hasPrefix("/") ? String(config.remotePath.dropFirst()) : config.remotePath
            return stripped.isEmpty ? "\(name):\(share)" : "\(name):\(share)/\(stripped)"
        case .s3:
            let bucket = config.s3Bucket ?? ""
            let stripped = config.remotePath.hasPrefix("/") ? String(config.remotePath.dropFirst()) : config.remotePath
            return stripped.isEmpty ? "\(name):\(bucket)" : "\(name):\(bucket)/\(stripped)"
        case .gdrive:
            let path = config.remotePath.hasPrefix("/") ? config.remotePath : "/\(config.remotePath)"
            return "\(name):\(path)"
        }
    }

    /// Builds the RCLONE_CONFIG_<NAME>_* environment variables that define the upload remote in-memory.
    /// Secrets travel through environment variables, never through process arguments — `ps` cannot see them.
    private func buildRemoteEnvironment(
        config: UploadConfig,
        rclonePath: String
    ) async throws -> [String: String] {
        let prefix = "RCLONE_CONFIG_\(Self.remoteName.uppercased())_"
        var env: [String: String] = [:]

        switch config.backendType {
        case .ftp:
            // try? on `throws -> String?` flattens to `String?` (SE-0230) — single unwrap is correct.
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscured = try await obscurePassword(password, rclonePath: rclonePath)

            env["\(prefix)TYPE"] = "ftp"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username
            env["\(prefix)PASS"] = obscured
            if config.useFTPS {
                env["\(prefix)TLS"] = "true"
            }

        case .sftp:
            env["\(prefix)TYPE"] = "sftp"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username

            if let keyFilePath = config.sftpKeyFilePath, !keyFilePath.isEmpty {
                env["\(prefix)KEY_FILE"] = keyFilePath
            } else {
                guard let password = try? KeychainCredentialManager.shared.getCredential(
                    server: config.server,
                    username: config.username
                ) else {
                    throw UploadError.passwordNotFound
                }
                let obscured = try await obscurePassword(password, rclonePath: rclonePath)
                env["\(prefix)PASS"] = obscured
            }

        case .smb:
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscured = try await obscurePassword(password, rclonePath: rclonePath)

            env["\(prefix)TYPE"] = "smb"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username
            env["\(prefix)PASS"] = obscured
            if let domain = config.smbDomain, !domain.isEmpty {
                env["\(prefix)DOMAIN"] = domain
            }

        case .s3:
            guard let accessKeyID = config.s3AccessKeyID, !accessKeyID.isEmpty else {
                throw UploadError.configurationMissing
            }
            guard let secretKey = try? KeychainCredentialManager.shared.getS3SecretKey(accessKeyID: accessKeyID) else {
                throw UploadError.passwordNotFound
            }

            env["\(prefix)TYPE"] = "s3"
            if let endpoint = config.s3Endpoint, !endpoint.isEmpty {
                env["\(prefix)PROVIDER"] = "Other"
                env["\(prefix)ENDPOINT"] = endpoint
            } else {
                env["\(prefix)PROVIDER"] = "AWS"
            }
            if let region = config.s3Region, !region.isEmpty {
                env["\(prefix)REGION"] = region
            }
            env["\(prefix)ACCESS_KEY_ID"] = accessKeyID
            env["\(prefix)SECRET_ACCESS_KEY"] = secretKey

        case .gdrive:
            throw UploadError.uploadFailed("Google Drive backend not yet implemented")
        }

        return env
    }

    /// Merges our remote-config env vars on top of the parent process environment.
    /// Replacing the env wholesale would strip PATH and other runtime settings that rclone
    /// needs. Existing rclone config variables are removed first so a parent shell cannot
    /// inject fields into the in-memory remote used for this request.
    private func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
        Self.sanitizedEnvironment(
            base: ProcessInfo.processInfo.environment,
            overrides: overrides
        )
    }

    static func sanitizedEnvironment(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var env = base.filter { key, _ in
            key != "RCLONE_CONFIG" && !key.hasPrefix("RCLONE_CONFIG_")
        }
        for (k, v) in overrides { env[k] = v }
        env["RCLONE_CONFIG"] = "/dev/null"
        return env
    }

    /// Paths, remote destinations, and credentials must not appear in runner-generated
    /// command descriptions or diagnostics. Environment variable names are harmless, but
    /// their values are not.
    private func sensitiveValues(
        arguments: [String],
        remoteEnvironment: [String: String]
    ) -> Set<String> {
        let sensitiveEnvironmentValues = remoteEnvironment.compactMap { key, value -> String? in
            let key = key.uppercased()
            guard key.hasSuffix("PASS")
                    || key.hasSuffix("ACCESS_KEY_ID")
                    || key.hasSuffix("SECRET_ACCESS_KEY")
                    || key.hasSuffix("KEY_FILE") else {
                return nil
            }
            return value
        }
        return Set(arguments + sensitiveEnvironmentValues)
    }

    /// Obscures a password using rclone's `obscure` subcommand.
    /// Reads the password from stdin (`rclone obscure -`) so it never appears on argv / `ps` output.
    func obscurePassword(_ password: String, rclonePath: String) async throws -> String {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: rclonePath),
            arguments: ["obscure", "-"],
            environment: Self.sanitizedEnvironment(
                base: ProcessInfo.processInfo.environment,
                overrides: [:]
            ),
            standardInput: Data((password + "\n").utf8),
            timeout: Self.obscureTimeout,
            standardOutputCaptureLimit: 16 * 1024,
            standardErrorCaptureLimit: 16 * 1024,
            sensitiveValues: [password]
        )
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw UploadError.uploadFailed("Failed to obscure password: timed out")
            case .failedToStart:
                throw UploadError.uploadFailed("Failed to launch rclone")
            }
        } catch {
            throw UploadError.uploadFailed("Failed to obscure password")
        }

        guard result.succeeded,
              result.discardedStandardOutputBytes == 0,
              let obscured = String(data: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !obscured.isEmpty else {
            throw UploadError.uploadFailed("Failed to obscure password")
        }
        return obscured
    }
}

/// Reassembles arbitrary stdout/stderr chunks into lines while keeping upload result
/// state synchronized. Runner callbacks can arrive concurrently from both pipes.
private final class RcloneOutputState: @unchecked Sendable {
    struct Snapshot {
        let lastError: String?
        let bytesTransferred: Int64
    }

    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()
    private var lastError: String?
    private var bytesTransferred: Int64 = 0

    func consume(
        _ chunk: SubprocessOutputChunk,
        handler: (SubprocessOutputStream, String) -> Void
    ) {
        let lines = lock.withLock { () -> [String] in
            switch chunk.stream {
            case .standardOutput:
                standardOutput.append(chunk.data)
                return Self.removeCompleteLines(from: &standardOutput)
            case .standardError:
                standardError.append(chunk.data)
                return Self.removeCompleteLines(from: &standardError)
            }
        }
        for line in lines {
            handler(chunk.stream, line)
        }
    }

    func finish(handler: (SubprocessOutputStream, String) -> Void) {
        let remaining = lock.withLock { () -> [(SubprocessOutputStream, String)] in
            defer {
                standardOutput.removeAll()
                standardError.removeAll()
            }
            return [
                (.standardOutput, String(decoding: standardOutput, as: UTF8.self)),
                (.standardError, String(decoding: standardError, as: UTF8.self))
            ]
        }
        for (stream, line) in remaining where !line.isEmpty {
            handler(stream, line)
        }
    }

    func record(error: String) {
        lock.withLock {
            lastError = error
        }
    }

    func record(bytesTransferred: Int64) {
        lock.withLock {
            self.bytesTransferred = bytesTransferred
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(lastError: lastError, bytesTransferred: bytesTransferred)
        }
    }

    private static func removeCompleteLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let delimiter = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: buffer[..<delimiter], as: UTF8.self))
            buffer.removeSubrange(...delimiter)
        }
        return lines
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Error sanitization

private enum RcloneErrorCategory: String, CustomStringConvertible {
    case authentication
    case connection
    case other

    var description: String { rawValue }
}

/// Categorize an rclone error string into a small enum so we can surface a generic UploadError
/// without including the raw message (which can contain hostnames, paths, or partial credentials).
private func categorizeError(_ message: String) -> RcloneErrorCategory {
    let lower = message.lowercased()
    if lower.contains("authentication") || lower.contains("530")
        || lower.contains("logon_failure") || lower.contains("accessdenied")
        || lower.contains("invalidaccesskeyid") || lower.contains("login") {
        return .authentication
    }
    if lower.contains("connection") || lower.contains("timeout")
        || lower.contains("no such host") || lower.contains("network is unreachable")
        || lower.contains("no route to host") {
        return .connection
    }
    return .other
}

/// Strips embedded credentials from URLs and bounds the length so error messages stay safe to log/display.
private func sanitizeErrorMessage(_ message: String) -> String {
    var sanitized = message
    // Strip user:pass@ from URLs.
    if let regex = try? NSRegularExpression(pattern: #"(https?|ftp|sftp)://[^/\s:]+:[^@\s]+@"#, options: []) {
        sanitized = regex.stringByReplacingMatches(
            in: sanitized,
            options: [],
            range: NSRange(sanitized.startIndex..., in: sanitized),
            withTemplate: "$1://[redacted]@"
        )
    }
    sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    if sanitized.count > 500 {
        sanitized = String(sanitized.prefix(500)) + "…"
    }
    return sanitized
}
