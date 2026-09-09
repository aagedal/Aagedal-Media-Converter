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

/// Manages watch folder monitoring with file growth detection
actor WatchFolderManager {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WatchFolder")

    private var monitorTask: Task<Void, Never>?
    private var trackedFiles: [URL: Int64] = [:] // URL -> file size
    private var isMonitoring = false
    private var monitoringGeneration: UInt64 = 0
    private var reportedFailures = WatchFolderFailureTracker()
    private let pollingWait: @Sendable () async throws -> Void

    init(pollingWait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
        self.pollingWait = pollingWait
    }

    /// Replaces monitoring atomically; late commands from older sessions are ignored.
    func startMonitoring(
        folderPath: String,
        generation: UInt64,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        guard generation >= monitoringGeneration, !Task.isCancelled else { return }
        stopMonitoring(generation: generation)

        isMonitoring = true
        Self.logger.info("Starting watch folder monitoring: \(folderPath, privacy: .public)")
        
        monitorTask = Task { [weak self, pollingWait] in
            await WatchFolderPollingLoop.run(wait: pollingWait) { [weak self] in
                guard let self else { return false }
                return await self.scanIfMonitoring(folderPath: folderPath, onNewFiles: onNewFiles, onError: onError)
            }
        }
    }
    
    /// Stop monitoring
    func stopMonitoring(generation: UInt64) {
        guard generation >= monitoringGeneration else { return }
        monitoringGeneration = generation
        Self.logger.info("Stopping watch folder monitoring")
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        trackedFiles.removeAll()
        reportedFailures = WatchFolderFailureTracker()
    }
    
    /// Scan the folder and detect stable files (not growing)
    private func scanIfMonitoring(folderPath: String, onNewFiles: @escaping @Sendable ([URL]) -> Void, onError: @escaping @Sendable (String) -> Void) -> Bool {
        // Check on the manager actor, after the polling task's actor hop: Stop
        // may have cancelled an older task and started a replacement meanwhile.
        guard isMonitoring, !Task.isCancelled else { return false }
        scanFolder(folderPath: folderPath, onNewFiles: onNewFiles, onError: onError)
        return true
    }

    private func scanFolder(
        folderPath: String,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        let folderURL = URL(fileURLWithPath: folderPath)

        // Restore the selected folder grant before enumeration. Report access
        // failures through the same recovery path as disconnected drives.
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: folderURL)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        
        let fileURLs: [URL]
        do {
            fileURLs = try WatchFolderDirectoryContents.list(in: folderURL)
        } catch {
            Self.logger.error("Failed to enumerate watch folder \(folderPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if reportedFailures.shouldReportScanFailure() {
                onError(String(localized: "The watch folder could not be scanned. Reconnect its drive or select the folder again in Settings. Monitoring will retry automatically. \(error.localizedDescription)"))
            }
            return
        }
        reportedFailures.scanSucceeded(currentFiles: Set(fileURLs))
        var cleanupFailures: [String] = []
        defer {
            if !cleanupFailures.isEmpty {
                let detail = cleanupFailures.joined(separator: "\n")
                onError(String(localized: "Some old watch-folder files could not be moved to Trash. Check folder permissions or select the folder again in Settings. Cleanup will retry automatically. \(detail)"))
            }
        }

        let settings = loadDurationSettings()
        let now = Date()
        var currentFiles: [URL: Int64] = [:]
        var stableFiles: [URL] = []
        
        for fileURL in fileURLs {
            guard AppConstants.supportedVideoExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey]),
                  resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize else {
                continue
            }

            let relevantDate = resourceValues.addedToDirectoryDate ?? resourceValues.creationDate ?? resourceValues.contentModificationDate ?? now
            let fileAge = now.timeIntervalSince(relevantDate)
            
            if settings.deleteEnabled, let deleteThreshold = settings.deleteThreshold, fileAge > deleteThreshold {
                do {
                    // Use trash instead of permanent delete for safety (recoverable)
                    try FileSafetyUtils.trashWatchFolderItem(fileURL)
                    reportedFailures.cleanupSucceeded(for: fileURL)
                    if let description = settings.deleteDescription {
                        Self.logger.info("Trashed watch folder file older than \(description, privacy: .public): \(fileURL.lastPathComponent, privacy: .public)")
                    } else {
                        Self.logger.info("Trashed watch folder file exceeding delete threshold: \(fileURL.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    Self.logger.error("Failed to trash old watch folder file \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if reportedFailures.shouldReportCleanupFailure(for: fileURL), cleanupFailures.count < 5 {
                        cleanupFailures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                trackedFiles.removeValue(forKey: fileURL)
                continue
            }

            if settings.ignoreEnabled, let ignoreThreshold = settings.ignoreThreshold, fileAge > ignoreThreshold {
                if let description = settings.ignoreDescription {
                    Self.logger.info("Ignoring watch folder file older than \(description, privacy: .public): \(fileURL.lastPathComponent, privacy: .public)")
                } else {
                    Self.logger.info("Ignoring watch folder file exceeding ignore threshold: \(fileURL.lastPathComponent, privacy: .public)")
                }
                trackedFiles.removeValue(forKey: fileURL)
                continue
            }
            
            currentFiles[fileURL] = Int64(fileSize)
            
            if let previousSize = trackedFiles[fileURL] {
                if fileSize == previousSize && fileSize > 0 {
                    stableFiles.append(fileURL)
                    Self.logger.info("File stable and ready: \(fileURL.lastPathComponent, privacy: .public) (\(fileSize) bytes)")
                } else if fileSize > previousSize {
                    Self.logger.info("File still growing: \(fileURL.lastPathComponent, privacy: .public) (\(previousSize) -> \(fileSize) bytes)")
                }
            } else {
                Self.logger.info("New file detected (tracking): \(fileURL.lastPathComponent, privacy: .public) (\(fileSize) bytes)")
            }
        }
        
        // Update tracked files
        trackedFiles = currentFiles
        
        // Report stable files
        if !stableFiles.isEmpty {
            Self.logger.info("Reporting \(stableFiles.count) stable file(s)")
            onNewFiles(stableFiles)
            
            // Remove reported files from tracking
            for fileURL in stableFiles {
                trackedFiles.removeValue(forKey: fileURL)
            }
        }
    }
    
    func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }
}

/// Enumerates a directory symlink's target while keeping child URLs beneath the
/// selected folder, so later import operations can find its saved bookmark.
enum WatchFolderDirectoryContents {
    static func list(in folder: URL, fileManager: FileManager = .default) throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.map { folder.appendingPathComponent($0.lastPathComponent) }
    }
}

/// Each polling task owns its cancellation state, so a newer monitor cannot
/// reactivate an old task by changing the manager's shared monitoring flag.
enum WatchFolderPollingLoop {
    static func run(
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) },
        scan: @escaping @Sendable () async -> Bool
    ) async {
        while !Task.isCancelled {
            guard await scan(), !Task.isCancelled else { return }
            do { try await wait() }
            catch { return }
        }
    }
}

private extension WatchFolderManager {
    struct DurationSettings {
        var ignoreEnabled: Bool
        var ignoreThreshold: TimeInterval?
        var ignoreDescription: String?
        var deleteEnabled: Bool
        var deleteThreshold: TimeInterval?
        var deleteDescription: String?
    }
    
    func loadDurationSettings() -> DurationSettings {
        let defaults = UserDefaults.standard
        let ignoreEnabled = defaults.bool(forKey: AppConstants.watchFolderIgnoreOlderThan24hKey)
        let deleteEnabled = defaults.bool(forKey: AppConstants.watchFolderAutoDeleteOlderThanWeekKey)
        let ignoreValueRaw = defaults.object(forKey: AppConstants.watchFolderIgnoreDurationValueKey) as? NSNumber
        let ignoreValue: Int
        if let raw = ignoreValueRaw?.intValue, AppConstants.watchFolderDurationValues.contains(raw) {
            ignoreValue = raw
        } else {
            ignoreValue = AppConstants.defaultWatchFolderIgnoreDurationValue
        }
        let ignoreUnitRaw = defaults.string(forKey: AppConstants.watchFolderIgnoreDurationUnitKey) ?? AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
        let deleteValueRaw = defaults.object(forKey: AppConstants.watchFolderDeleteDurationValueKey) as? NSNumber
        let deleteValue: Int
        if let raw = deleteValueRaw?.intValue, AppConstants.watchFolderDurationValues.contains(raw) {
            deleteValue = raw
        } else {
            deleteValue = AppConstants.defaultWatchFolderDeleteDurationValue
        }
        let deleteUnitRaw = defaults.string(forKey: AppConstants.watchFolderDeleteDurationUnitKey) ?? AppConstants.defaultWatchFolderDeleteDurationUnitRaw
        let ignoreUnit = WatchFolderDurationUnit(rawValue: ignoreUnitRaw) ?? .hours
        let deleteUnit = WatchFolderDurationUnit(rawValue: deleteUnitRaw) ?? .days
        let ignoreThreshold: TimeInterval? = ignoreEnabled ? TimeInterval(ignoreValue) * ignoreUnit.secondsMultiplier : nil
        let deleteThreshold: TimeInterval? = deleteEnabled ? TimeInterval(deleteValue) * deleteUnit.secondsMultiplier : nil
        return DurationSettings(
            ignoreEnabled: ignoreEnabled,
            ignoreThreshold: ignoreThreshold,
            ignoreDescription: ignoreEnabled ? describeThreshold(value: ignoreValue, unit: ignoreUnit) : nil,
            deleteEnabled: deleteEnabled,
            deleteThreshold: deleteThreshold,
            deleteDescription: deleteEnabled ? describeThreshold(value: deleteValue, unit: deleteUnit) : nil
        )
    }
    
    func describeThreshold(value: Int, unit: WatchFolderDurationUnit) -> String {
        let unitName: String
        switch unit {
        case .minutes: unitName = value == 1 ? "minute" : "minutes"
        case .hours: unitName = value == 1 ? "hour" : "hours"
        case .days: unitName = value == 1 ? "day" : "days"
        }
        return "\(value) \(unitName)"
    }
}

/// Alerts once per continuous failure, while allowing a recovered operation to
/// report a later failure. Missing files no longer retain cleanup failure state.
struct WatchFolderFailureTracker {
    private var scanFailed = false
    private var cleanupFailures: Set<URL> = []

    mutating func shouldReportScanFailure() -> Bool {
        defer { scanFailed = true }
        return !scanFailed
    }

    mutating func scanSucceeded(currentFiles: Set<URL>) {
        scanFailed = false
        cleanupFailures.formIntersection(currentFiles)
    }

    mutating func shouldReportCleanupFailure(for url: URL) -> Bool {
        cleanupFailures.insert(url).inserted
    }

    mutating func cleanupSucceeded(for url: URL) {
        cleanupFailures.remove(url)
    }
}
