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
    @Published var errorMessage: String?
    private let manager: WatchFolderManager
    private var monitoringTask: Task<Void, Never>?
    private var autoEncodeTask: Task<Void, Never>?
    private var powerAssertion: UUID?
    private var monitoringGeneration: UInt64 = 0

    init(manager: WatchFolderManager = WatchFolderManager()) {
        self.manager = manager
    }

    /// Enables watch mode, prompting the user for a folder if needed and starting monitoring.
    /// - Parameters:
    ///   - currentPath: The currently stored watch folder path (may be empty).
    ///   - promptForFolder: Closure returning a user-selected folder URL.
    ///   - updatePath: Closure invoked when a new folder path is chosen.
    ///   - onNewFiles: Callback invoked when stable files are detected.
    /// - Returns: `true` when monitoring started, `false` on cancellation or inaccessible folders.
    func enableWatchMode(
        currentPath: String,
        promptForFolder: @escaping @Sendable () async -> URL?,
        updatePath: @escaping @Sendable (String) async -> Void,
        onNewFiles: @escaping @Sendable ([URL]) async -> Void
    ) async -> Bool {
        monitoringGeneration += 1
        let generation = monitoringGeneration
        // A replacement owns the session immediately, including while its picker
        // or validation is pending. Stop all prior work before validating it.
        cancelSessionTasks()
        await manager.stopMonitoring(generation: generation)
        guard monitoringGeneration == generation, !Task.isCancelled else { return false }
        var folderPath = currentPath
        errorMessage = nil
        let selection = WatchFolderSelectionService()

        do {
            if folderPath.isEmpty {
                guard let folderURL = await promptForFolder() else {
                    return false
                }
                guard monitoringGeneration == generation, !Task.isCancelled else { return false }
                try selection.select(folderURL)
                folderPath = folderURL.path
                await updatePath(folderPath)
            } else {
                try selection.validate(URL(fileURLWithPath: folderPath))
            }
        } catch {
            guard monitoringGeneration == generation, !Task.isCancelled else { return false }
            errorMessage = error.localizedDescription
            return false
        }

        guard monitoringGeneration == generation, !Task.isCancelled else { return false }
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self, manager] in
            guard self?.monitoringGeneration == generation, !Task.isCancelled else { return }
            await manager.startMonitoring(folderPath: folderPath, generation: generation, onNewFiles: { [weak self] urls in
                Task { @MainActor [weak self] in
                    guard self?.monitoringGeneration == generation else { return }
                    await onNewFiles(urls)
                }
            }, onError: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.monitoringGeneration == generation else { return }
                    // Preserve any error already awaiting acknowledgement.
                    self.errorMessage = [self.errorMessage, message].compactMap { $0 }.joined(separator: "\n\n")
                }
            })
        }

        if UserDefaults.standard.bool(forKey: AppConstants.watchFolderKeepAwakeKey),
           powerAssertion == nil {
            powerAssertion = PowerAssertion.shared.acquire(reason: "Watch folder monitoring")
        }

        return true
    }

    /// Stops monitoring and clears any scheduled auto-encode tasks.
    func disableWatchMode() async {
        monitoringGeneration += 1
        cancelSessionTasks()
        await manager.stopMonitoring(generation: monitoringGeneration)
    }

    private func cancelSessionTasks() {
        monitoringTask?.cancel()
        monitoringTask = nil
        autoEncodeTask?.cancel()
        autoEncodeTask = nil
        PowerAssertion.shared.release(powerAssertion)
        powerAssertion = nil
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
