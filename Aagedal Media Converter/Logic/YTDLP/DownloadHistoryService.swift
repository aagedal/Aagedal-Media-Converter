// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Represents a single download history entry
struct DownloadHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let url: String
    let title: String
    let downloadedAt: Date
    let outputFileName: String?

    init(url: String, title: String, outputFileName: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.downloadedAt = Date()
        self.outputFileName = outputFileName
    }
}

/// Service for managing download history persistence
@MainActor
enum DownloadHistoryService {
    static let historyDefaults: UserDefaults = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["AMC_UI_TEST_SESSION"] == "1",
           environment["AMC_UI_TEST_DAMAGED_HISTORY"] == "1",
           let defaults = UserDefaults(suiteName: "com.aagedal.MediaConverter.UITestHistory") {
            defaults.removePersistentDomain(forName: "com.aagedal.MediaConverter.UITestHistory")
            defaults.set(Data("Damaged UI test history".utf8), forKey: AppConstants.downloadHistoryKey)
            return defaults
        }
#endif
        return .standard
    }()

    static func hasUnreadableHistory(defaults: UserDefaults = historyDefaults) -> Bool {
        do {
            _ = try loadHistory(defaults: defaults)
            return false
        } catch {
            return true
        }
    }

    /// Gets the download history, most recent first
    static func getHistory(defaults: UserDefaults = historyDefaults) -> [DownloadHistoryEntry] {
        (try? loadHistory(defaults: defaults)) ?? []
    }

    /// A missing history is empty; damaged history must remain available for
    /// recovery rather than being overwritten by the next completed download.
    private static func loadHistory(defaults: UserDefaults) throws -> [DownloadHistoryEntry] {
        guard let stored = defaults.object(forKey: AppConstants.downloadHistoryKey) else { return [] }
        guard let data = stored as? Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode([DownloadHistoryEntry].self, from: data)
    }

    /// Adds a new entry to the history
    /// - Parameters:
    ///   - url: The downloaded URL
    ///   - title: The video title
    ///   - outputFileName: The output file name (optional)
    static func addEntry(url: String, title: String, outputFileName: String? = nil, defaults: UserDefaults = historyDefaults) {
        guard var history = try? loadHistory(defaults: defaults) else { return }

        // Remove any existing entry with the same URL (to avoid duplicates)
        history.removeAll { $0.url == url }

        // Add new entry at the beginning
        let entry = DownloadHistoryEntry(url: url, title: title, outputFileName: outputFileName)
        history.insert(entry, at: 0)

        // Keep only the most recent entries
        if history.count > AppConstants.downloadHistoryMaxItems {
            history = Array(history.prefix(AppConstants.downloadHistoryMaxItems))
        }

        // Save
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: AppConstants.downloadHistoryKey)
        }
    }

    /// Removes an entry from the history
    static func removeEntry(id: UUID, defaults: UserDefaults = historyDefaults) {
        guard var history = try? loadHistory(defaults: defaults) else { return }
        history.removeAll { $0.id == id }

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: AppConstants.downloadHistoryKey)
        }
    }

    /// Clears all history
    static func clearHistory(defaults: UserDefaults = historyDefaults) {
        defaults.removeObject(forKey: AppConstants.downloadHistoryKey)
    }
}
