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
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            Logger().error("Failed to create file enumerator for: \(folderPath)")
            return
        }
        
        var currentFiles: [URL: Int64] = [:]
        var stableFiles: [URL] = []
        
        // Convert enumerator to array for async iteration
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
        
        // Scan current files in folder
        for fileURL in fileURLs {
            // Check if it's a regular file
            guard let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegularFile else {
                continue
            }
            
            // Check if it's a supported video file
            let fileExtension = fileURL.pathExtension.lowercased()
            guard AppConstants.supportedVideoExtensions.contains(fileExtension) else {
                continue
            }
            
            // Get file size
            guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                continue
            }
            
            currentFiles[fileURL] = Int64(fileSize)
            
            // Check if file was tracked before and hasn't grown
            if let previousSize = trackedFiles[fileURL] {
                if fileSize == previousSize && fileSize > 0 {
                    // File size hasn't changed - it's stable
                    stableFiles.append(fileURL)
                    Logger().info("File stable and ready: \(fileURL.lastPathComponent) (\(fileSize) bytes)")
                } else if fileSize > previousSize {
                    Logger().info("File still growing: \(fileURL.lastPathComponent) (\(previousSize) -> \(fileSize) bytes)")
                }
            } else {
                // New file detected - track it but don't add yet
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
