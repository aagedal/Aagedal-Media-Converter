// Aagedal VideoLoop Converter 2.0
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
    private var monitorTask: Task<Void, Never>?
    private var trackedFiles: [URL: Int64] = [:] // URL -> file size
    private var isMonitoring = false
    
    /// Start monitoring the specified folder
    func startMonitoring(
        folderPath: String,
        onNewFiles: @escaping @Sendable ([URL]) -> Void
    ) {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        Logger().info("Starting watch folder monitoring: \(folderPath)")
        
        monitorTask = Task { [weak self] in
            guard let self else { return }
            
            while await self.isMonitoring {
                await self.scanFolder(folderPath: folderPath, onNewFiles: onNewFiles)
                
                // Wait 5 seconds before next scan
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        Logger().info("Stopping watch folder monitoring")
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        trackedFiles.removeAll()
    }
    
    /// Scan the folder and detect stable files (not growing)
    private func scanFolder(
        folderPath: String,
        onNewFiles: @escaping @Sendable ([URL]) -> Void
    ) async {
        let folderURL = URL(fileURLWithPath: folderPath)
        
        // Check if folder exists
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            Logger().warning("Watch folder does not exist: \(folderPath)")
            return
        }
        
        // Access security-scoped resource
        let hasAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: folderURL)
        defer {
            if hasAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: folderURL)
            }
        }
        
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            Logger().error("Failed to create file enumerator for: \(folderPath)")
            return
        }

        let settings = loadDurationSettings()
        let now = Date()
        var currentFiles: [URL: Int64] = [:]
        var stableFiles: [URL] = []
        
        // Convert enumerator to array for async iteration
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
        
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
                    try FileManager.default.removeItem(at: fileURL)
                    if let description = settings.deleteDescription {
                        Logger().info("Deleted watch folder file older than \(description): \(fileURL.lastPathComponent)")
                    } else {
                        Logger().info("Deleted watch folder file exceeding delete threshold: \(fileURL.lastPathComponent)")
                    }
                } catch {
                    Logger().error("Failed to delete old watch folder file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
                trackedFiles.removeValue(forKey: fileURL)
                continue
            }

            if settings.ignoreEnabled, let ignoreThreshold = settings.ignoreThreshold, fileAge > ignoreThreshold {
                if let description = settings.ignoreDescription {
                    Logger().info("Ignoring watch folder file older than \(description): \(fileURL.lastPathComponent)")
                } else {
                    Logger().info("Ignoring watch folder file exceeding ignore threshold: \(fileURL.lastPathComponent)")
                }
                trackedFiles.removeValue(forKey: fileURL)
                continue
            }
            
            currentFiles[fileURL] = Int64(fileSize)
            
            if let previousSize = trackedFiles[fileURL] {
                if fileSize == previousSize && fileSize > 0 {
                    stableFiles.append(fileURL)
                    Logger().info("File stable and ready: \(fileURL.lastPathComponent) (\(fileSize) bytes)")
                } else if fileSize > previousSize {
                    Logger().info("File still growing: \(fileURL.lastPathComponent) (\(previousSize) -> \(fileSize) bytes)")
                }
            } else {
                Logger().info("New file detected (tracking): \(fileURL.lastPathComponent) (\(fileSize) bytes)")
            }
        }
        
        // Update tracked files
        trackedFiles = currentFiles
        
        // Report stable files
        if !stableFiles.isEmpty {
            Logger().info("Reporting \(stableFiles.count) stable file(s)")
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
        let ignoreValue = AppConstants.watchFolderDurationValues.contains(ignoreValueRaw?.intValue ?? 0)
            ? ignoreValueRaw!.intValue
            : AppConstants.defaultWatchFolderIgnoreDurationValue
        let ignoreUnitRaw = defaults.string(forKey: AppConstants.watchFolderIgnoreDurationUnitKey) ?? AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
        let deleteValueRaw = defaults.object(forKey: AppConstants.watchFolderDeleteDurationValueKey) as? NSNumber
        let deleteValue = AppConstants.watchFolderDurationValues.contains(deleteValueRaw?.intValue ?? 0)
            ? deleteValueRaw!.intValue
            : AppConstants.defaultWatchFolderDeleteDurationValue
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
