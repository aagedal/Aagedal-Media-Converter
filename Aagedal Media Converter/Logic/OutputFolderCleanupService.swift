// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import Observation

/// Periodically deletes files older than N days from the default output folder.
/// Runs on app launch and every hour while the app is running.
@MainActor
@Observable
final class OutputFolderCleanupService {
    static let shared = OutputFolderCleanupService()

    private let logger = Logger(subsystem: "me.aagedal.MediaConverter", category: "OutputFolderCleanup")
    private var timer: Timer?
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bookmarkManager: SecurityScopedBookmarkManager
    private let readResourceValues: (URL) throws -> URLResourceValues

    private(set) var lastError: String?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bookmarkManager: SecurityScopedBookmarkManager = .shared,
        readResourceValues: @escaping (URL) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
        }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.bookmarkManager = bookmarkManager
        self.readResourceValues = readResourceValues
    }

    /// Start the service: run cleanup immediately and schedule hourly repeats.
    func start() {
        performCleanupIfNeeded()
        scheduleHourlyTimer()
    }

    private func scheduleHourlyTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performCleanupIfNeeded()
            }
        }
    }

    func performCleanupIfNeeded() {
        lastError = nil
        guard defaults.bool(forKey: AppConstants.autoDeleteOldEncodesKey) else { return }

        let days = defaults.integer(forKey: AppConstants.autoDeleteOldEncodesDaysKey)
        guard days > 0 else { return }

        let outputFolder = defaults.string(forKey: "outputFolder") ?? AppConstants.defaultOutputDirectory.path
        let folderURL = URL(fileURLWithPath: outputFolder)

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let access = bookmarkManager.startAccessing(url: folderURL)
        defer { bookmarkManager.stopAccessing(access) }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            logger.error("Could not enumerate output folder at \(outputFolder): \(error.localizedDescription)")
            lastError = String(localized: "Automatic cleanup could not open the output folder. Check that it is available and select it again in Settings. \(error.localizedDescription)")
            return
        }

        var deletedCount = 0
        var failedCount = 0
        var firstFailure: String?
        for fileURL in contents {
            do {
                // A metadata failure must not make an unknown-age file eligible for deletion.
                let resourceValues = try readResourceValues(fileURL)
                guard resourceValues.isRegularFile == true,
                      let creationDate = resourceValues.creationDate,
                      creationDate < cutoffDate else { continue }
                try fileManager.removeItem(at: fileURL)
                deletedCount += 1
                logger.debug("Deleted old encode: \(fileURL.lastPathComponent)")
            } catch {
                failedCount += 1
                if firstFailure == nil {
                    firstFailure = "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                }
                logger.warning("Could not inspect or delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let firstFailure {
            lastError = String(localized: "Automatic cleanup could not inspect or delete \(failedCount) file(s). Check the output folder’s permissions. \(firstFailure)")
        }

        if deletedCount > 0 {
            logger.info("Auto-deleted \(deletedCount) file(s) older than \(days) day(s) from output folder")
        }
    }
}
