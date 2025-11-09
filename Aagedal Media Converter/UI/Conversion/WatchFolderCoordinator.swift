//
//  WatchFolderCoordinator.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import SwiftUI

/// Coordinates watch-folder monitoring and automatic encoding scheduling for the ContentView.
@MainActor
final class WatchFolderCoordinator: ObservableObject {
    private let manager = WatchFolderManager()
    private var monitoringTask: Task<Void, Never>?
    private var autoEncodeTask: Task<Void, Never>?

    /// Enables watch mode, prompting the user for a folder if needed and starting monitoring.
    /// - Parameters:
    ///   - currentPath: The currently stored watch folder path (may be empty).
    ///   - promptForFolder: Closure returning a user-selected folder URL.
    ///   - updatePath: Closure invoked when a new folder path is chosen.
    ///   - onNewFiles: Callback invoked when stable files are detected.
    /// - Returns: `true` when monitoring started, `false` if the user cancelled folder selection.
    func enableWatchMode(
        currentPath: String,
        promptForFolder: @escaping @Sendable () async -> URL?,
        updatePath: @escaping @Sendable (String) async -> Void,
        onNewFiles: @escaping @Sendable ([URL]) async -> Void
    ) async -> Bool {
        var folderPath = currentPath

        if folderPath.isEmpty {
            guard let folderURL = await promptForFolder() else {
                return false
            }
            folderPath = folderURL.path
            await updatePath(folderPath)
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: folderURL)
        }

        monitoringTask?.cancel()
        monitoringTask = Task { [manager] in
            await manager.startMonitoring(folderPath: folderPath) { urls in
                Task {
                    await onNewFiles(urls)
                }
            }
        }

        return true
    }

    /// Stops monitoring and clears any scheduled auto-encode tasks.
    func disableWatchMode() async {
        monitoringTask?.cancel()
        monitoringTask = nil
        autoEncodeTask?.cancel()
        autoEncodeTask = nil
        await manager.stopMonitoring()
    }

    /// Cancels any pending auto-encode task and schedules a new one that runs after a delay.
    func scheduleAutoEncode(action: @escaping @Sendable () async -> Void) {
        autoEncodeTask?.cancel()
        autoEncodeTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    /// Cancels pending auto-encode work when conversion starts.
    func startConversion() {
        autoEncodeTask?.cancel()
        autoEncodeTask = nil
    }

    /// Placeholder for symmetry—retained for future coordination if needed.
    func cancelConversion() {
        // No-op for now; kept for API symmetry.
    }
}
