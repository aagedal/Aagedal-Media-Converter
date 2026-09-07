// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct WhisperCapabilitySnapshot: Sendable, Equatable {
    let isAvailable: Bool
    let ffmpegVersion: String

    var installationStatus: WhisperInstallationStatus {
        guard isAvailable else { return .notInstalled }
        return .installed(version: String(localized: "FFmpeg \(ffmpegVersion) (built-in)"))
    }
}

enum WhisperCapabilityProbeState: Sendable, Equatable {
    case loading
    case ready(WhisperCapabilitySnapshot)

    var installationStatus: WhisperInstallationStatus? {
        switch self {
        case .loading:
            return nil
        case .ready(let snapshot):
            return snapshot.installationStatus
        }
    }

    var isAvailable: Bool {
        installationStatus?.isAvailable ?? false
    }
}

/// Asynchronously probes the FFmpeg build that provides Whisper transcription.
/// One bounded probe is shared by all concurrent callers and UI subscribers.
actor WhisperUpdateService {
    static let shared = WhisperUpdateService()

    static let probeTimeout: Duration = .seconds(5)
    static let standardOutputCaptureLimit = 256 * 1024
    static let standardErrorCaptureLimit = 16 * 1024

    private let subprocessRunner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    private var cachedSnapshot: WhisperCapabilitySnapshot?
    private var probeTask: Task<WhisperCapabilitySnapshot, Never>?
    private var probeID: UUID?
    private var waiters: [UUID: CheckedContinuation<WhisperCapabilitySnapshot, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<WhisperCapabilityProbeState>.Continuation] = [:]

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.subprocessRunner = subprocessRunner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    /// Returns the cached capability snapshot or joins the single in-flight probe.
    /// Cancelling one waiter does not cancel work needed by other callers or subscribers.
    func capabilitySnapshot() async throws -> WhisperCapabilitySnapshot {
        try Task.checkCancellation()

        if let cachedSnapshot {
            return cachedSnapshot
        }

        startProbeIfNeeded()
        let waiterID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let cachedSnapshot {
                    continuation.resume(returning: cachedSnapshot)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func isWhisperAvailable() async throws -> Bool {
        try await capabilitySnapshot().isAvailable
    }

    func getInstallationStatus() async throws -> WhisperInstallationStatus {
        try await capabilitySnapshot().installationStatus
    }

    /// Invalidates the cached snapshot, publishes a loading transition, and joins
    /// the next shared probe. Useful when the selected FFmpeg binary changes.
    func refreshCapabilitySnapshot() async throws -> WhisperCapabilitySnapshot {
        probeTask?.cancel()
        probeTask = nil
        probeID = nil
        cachedSnapshot = nil
        for subscriber in subscribers.values {
            subscriber.yield(.loading)
        }
        return try await capabilitySnapshot()
    }

    /// Emits the current loading/ready state and keeps the subscription alive for
    /// future cache refreshes. Stream termination only removes that subscriber.
    func stateUpdates() -> AsyncStream<WhisperCapabilityProbeState> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<WhisperCapabilityProbeState>.makeStream()

        subscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }

        if let cachedSnapshot {
            continuation.yield(.ready(cachedSnapshot))
        } else {
            continuation.yield(.loading)
            startProbeIfNeeded()
        }
        return stream
    }

    private func startProbeIfNeeded() {
        guard cachedSnapshot == nil, probeTask == nil else { return }

        guard let ffmpegPath = ffmpegPathProvider() else {
            completeProbe(
                .init(isAvailable: false, ffmpegVersion: "unknown"),
                id: nil
            )
            return
        }

        let id = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.performProbe(ffmpegPath: ffmpegPath, subprocessRunner: runner)
        }
        probeID = id
        probeTask = task

        Task { [weak self] in
            let snapshot = await task.value
            await self?.completeProbe(snapshot, id: id)
        }
    }

    private func completeProbe(_ snapshot: WhisperCapabilitySnapshot, id: UUID?) {
        if let id, id != probeID {
            return
        }

        cachedSnapshot = snapshot
        probeTask = nil
        probeID = nil

        let pendingWaiters = Array(waiters.values)
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: snapshot)
        }
        for subscriber in subscribers.values {
            subscriber.yield(.ready(snapshot))
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private nonisolated static func performProbe(
        ffmpegPath: String,
        subprocessRunner: any SubprocessRunning
    ) async -> WhisperCapabilitySnapshot {
        async let filtersResult = run(
            ffmpegPath: ffmpegPath,
            arguments: ["-hide_banner", "-filters"],
            subprocessRunner: subprocessRunner
        )
        async let versionResult = run(
            ffmpegPath: ffmpegPath,
            arguments: ["-version"],
            subprocessRunner: subprocessRunner
        )

        let (filters, version) = await (filtersResult, versionResult)
        let isAvailable = filters.map { result in
            result.succeeded
                && result.discardedStandardOutputBytes == 0
                && result.standardOutputText.contains("whisper")
        } ?? false

        let versionString: String = {
            guard let version,
                  version.succeeded,
                  version.discardedStandardOutputBytes == 0,
                  let firstLine = version.standardOutputText.split(separator: "\n").first,
                  let match = firstLine.range(
                    of: #"ffmpeg version (\S+)"#,
                    options: .regularExpression
                  ) else {
                return "unknown"
            }
            return String(firstLine[match])
                .replacingOccurrences(of: "ffmpeg version ", with: "")
        }()

        return WhisperCapabilitySnapshot(
            isAvailable: isAvailable,
            ffmpegVersion: versionString
        )
    }

    private nonisolated static func run(
        ffmpegPath: String,
        arguments: [String],
        subprocessRunner: any SubprocessRunning
    ) async -> SubprocessResult? {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: probeTimeout,
            standardOutputCaptureLimit: standardOutputCaptureLimit,
            standardErrorCaptureLimit: standardErrorCaptureLimit,
            sensitiveValues: [ffmpegPath]
        )

        do {
            return try await subprocessRunner.run(request)
        } catch {
            return nil
        }
    }
}
