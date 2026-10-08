// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import Observation

/// Moves completed app outputs older than N days to Trash at launch and hourly.
@MainActor
@Observable
final class OutputFolderCleanupService {
    static let shared = OutputFolderCleanupService()

    private var timer: Timer?
    private var cleanupTask: Task<OutputCleanupResult, Never>?
    private let defaults: UserDefaults
    private let bookmarkManager: SecurityScopedBookmarkManager
    private let readResourceValues: @Sendable (URL) throws -> URLResourceValues
    private let trashItem: @Sendable (URL) throws -> Void

    private(set) var lastError: String?
    private(set) var isCleaning = false

    init(
        defaults: UserDefaults = .standard,
        bookmarkManager: SecurityScopedBookmarkManager = .shared,
        readResourceValues: @escaping @Sendable (URL) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        },
        trashItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.defaults = defaults
        self.bookmarkManager = bookmarkManager
        self.readResourceValues = readResourceValues
        self.trashItem = trashItem
    }

    func start() {
        Task { await performCleanupIfNeeded() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.performCleanupIfNeeded() }
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    func performCleanupIfNeeded() async {
        // A retry or timer tick must not start a second pass over the same files.
        if let cleanupTask {
            _ = await withTaskCancellationHandler { await cleanupTask.value } onCancel: { cleanupTask.cancel() }
            return
        }
        lastError = nil
        guard defaults.bool(forKey: AppConstants.autoDeleteOldEncodesKey) else { return }
        let days = defaults.integer(forKey: AppConstants.autoDeleteOldEncodesDaysKey)
        guard days > 0 else { return }
        let folderURL = URL(fileURLWithPath: defaults.string(forKey: "outputFolder") ?? AppConstants.defaultOutputDirectory.path)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let access = bookmarkManager.startAccessing(url: folderURL)
        defer { bookmarkManager.stopAccessing(access) }

        isCleaning = true
        let readResourceValues = readResourceValues
        let trashItem = trashItem
        let task = Task.detached(priority: .utility) {
            await OutputCleanupWorker.run(folder: folderURL, cutoff: cutoffDate,
                                          readResourceValues: readResourceValues, trashItem: trashItem,
                                          canContinue: { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return false }
                return self.defaults.bool(forKey: AppConstants.autoDeleteOldEncodesKey)
                    && self.defaults.integer(forKey: AppConstants.autoDeleteOldEncodesDaysKey) == days
                    && URL(fileURLWithPath: self.defaults.string(forKey: "outputFolder") ?? AppConstants.defaultOutputDirectory.path).standardizedFileURL == folderURL.standardizedFileURL
            })
        }
        cleanupTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        cleanupTask = nil
        isCleaning = false
        lastError = result.error
    }
}

private struct OutputCleanupResult: Sendable {
    let error: String?
}

private enum OutputCleanupWorker {
    private static let logger = Logger(subsystem: "me.aagedal.MediaConverter", category: "OutputFolderCleanup")

    static func run(
        folder: URL,
        cutoff: Date,
        readResourceValues: @Sendable (URL) throws -> URLResourceValues,
        trashItem: @Sendable (URL) throws -> Void,
        canContinue: @Sendable () async -> Bool
    ) async -> OutputCleanupResult {
        guard await canContinue() else { return OutputCleanupResult(error: nil) }
        let fileManager = FileManager()
        let contents: [URL]
        do {
            // Enumerate the target while retaining selected symlink paths and scope.
            contents = try fileManager.contentsOfDirectory(
                at: folder.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ).map { folder.appendingPathComponent($0.lastPathComponent) }
        } catch {
            guard await canContinue() else { return OutputCleanupResult(error: nil) }
            return OutputCleanupResult(error: String(localized: "Automatic cleanup could not open the output folder. Check that it is available and select it again in Settings. \(error.localizedDescription)"))
        }
        var trashedCount = 0
        var failedCount = 0
        var firstFailure: String?
        for url in contents {
            guard await canContinue() else { return OutputCleanupResult(error: nil) }
            do {
                let values = try readResourceValues(url)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let completedAt = FileSafetyUtils.completedOutputDate(url),
                      completedAt < cutoff else { continue }
                guard await canContinue() else { return OutputCleanupResult(error: nil) }
                try trashItem(url)
                FileSafetyUtils.unregisterCreatedFile(url)
                trashedCount += 1
            } catch {
                failedCount += 1
                if firstFailure == nil { firstFailure = "\(url.lastPathComponent): \(error.localizedDescription)" }
                logger.warning("Could not inspect or trash \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard await canContinue() else { return OutputCleanupResult(error: nil) }
        if trashedCount > 0 { logger.info("Moved \(trashedCount) completed output(s) to Trash") }
        let error = firstFailure.map {
            String(localized: "Automatic cleanup could not inspect or move \(failedCount) file(s) to Trash. Check the output folder’s permissions. \($0)")
        }
        return OutputCleanupResult(error: error)
    }
}
