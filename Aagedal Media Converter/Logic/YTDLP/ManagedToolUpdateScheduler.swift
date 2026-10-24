// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Runs automatic yt-dlp / deno / yt-dlp-rs updates shortly after launch and
/// periodically while the app runs. Each tool is checked at most once per
/// `AppConstants.managedToolUpdateCheckInterval`; nothing starts while web
/// downloads are running, and a verified update waits until they finish.
@MainActor
final class ManagedToolUpdateScheduler {
    static let shared = ManagedToolUpdateScheduler()

    static let launchDelay: Duration = .seconds(45)
    static let tickInterval: Duration = .seconds(60 * 60)
    static let idlePollInterval: Duration = .seconds(30)
    /// Give up on activating a staged update after this long; the next check retries.
    static let maximumIdleWait: Duration = .seconds(6 * 60 * 60)

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ManagedToolUpdates")
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil, Self.isEnabledForProcess else { return }
        loop = Task { [logger] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                logger.debug("Running scheduled tool update check")
                await YTDLPUpdateService.shared.runScheduledUpdates(
                    isBusy: { await Self.downloadsAreActive() },
                    waitUntilIdle: { try await Self.waitUntilDownloadsFinish() }
                )
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Unit-test hosts and UI-test sessions must not touch the network or the
    /// fixture tools directory.
    private static var isEnabledForProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["AMC_UI_TEST_SESSION"] == "1" {
            return false
        }
        return NSClassFromString("XCTestCase") == nil
    }

    /// Web downloads (including queued playlist entries) use yt-dlp, deno or
    /// yt-dlp-rs; tool versions are never switched underneath them.
    static func downloadsAreActive() async -> Bool {
        await MainActor.run {
            guard let items = DownloadManager.shared.videoItems?.wrappedValue else { return false }
            return items.contains { $0.isDownloading || $0.isQueuedForDownload }
        }
    }

    static func waitUntilDownloadsFinish() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + maximumIdleWait
        while await downloadsAreActive() {
            guard clock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: idlePollInterval)
        }
    }
}
