// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Remembers which files the watch folder already handed to the queue, by path plus the
/// size and modification date seen at the time. Without it a stable file would be imported
/// again two scans after the user removed it from the queue.
///
/// Entries stay while the file remains in the folder and expire a user-set time after it
/// was last seen there, so a file left in the folder is never re-imported when its entry
/// would otherwise age out. A replaced or rewritten file (new size or date) is imported again.
struct WatchFolderImportLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var size: Int64
        var modifiedAt: Date?
        var importedAt: Date
        var lastSeenAt: Date
    }

    /// How stale `lastSeenAt` may get before a scan refreshes it on disk. Keeps the
    /// history file from being rewritten on every scan while files sit in the folder.
    static let lastSeenRefreshInterval: TimeInterval = 60 * 60

    private(set) var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    func contains(_ url: URL, size: Int64, modifiedAt: Date?) -> Bool {
        guard let entry = entries[Self.key(for: url)], entry.size == size else { return false }
        switch (entry.modifiedAt, modifiedAt) {
        case (nil, nil): return true
        // File-system dates carry sub-microsecond precision; allow for JSON round-tripping.
        case let (saved?, current?): return abs(saved.timeIntervalSince(current)) < 0.001
        default: return false
        }
    }

    mutating func record(_ url: URL, size: Int64, modifiedAt: Date?, at now: Date) {
        entries[Self.key(for: url)] = Entry(size: size, modifiedAt: modifiedAt, importedAt: now, lastSeenAt: now)
    }

    /// Refreshes entries for files still in the folder. Returns true when an entry changed
    /// enough to be worth saving.
    mutating func markSeen(_ urls: some Sequence<URL>, at now: Date) -> Bool {
        var changed = false
        for url in urls {
            let key = Self.key(for: url)
            guard var entry = entries[key],
                  now.timeIntervalSince(entry.lastSeenAt) >= Self.lastSeenRefreshInterval else { continue }
            entry.lastSeenAt = now
            entries[key] = entry
            changed = true
        }
        return changed
    }

    /// Forgets files that have been gone from the folder for longer than `retention`.
    /// Returns true when anything was removed.
    mutating func expire(retention: TimeInterval, now: Date) -> Bool {
        let before = entries.count
        // Entries are refreshed at most hourly, so allow for that lag before expiring.
        let cutoff = now.addingTimeInterval(-(retention + Self.lastSeenRefreshInterval))
        entries = entries.filter { $0.value.lastSeenAt >= cutoff }
        return entries.count != before
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// Loads and saves the import ledger as JSON so it survives relaunches. An in-memory
/// store (no file) is used by tests and anywhere persistence is not wanted.
struct WatchFolderImportHistoryStore: Sendable {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WatchFolder")

    let fileURL: URL?

    static let inMemory = WatchFolderImportHistoryStore(fileURL: nil)

    static let applicationDefault: WatchFolderImportHistoryStore = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return WatchFolderImportHistoryStore(fileURL: supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("WatchFolder", isDirectory: true)
            .appendingPathComponent("ImportHistory.json"))
    }()

    private struct Envelope: Codable {
        var version: Int
        var ledger: WatchFolderImportLedger
    }

    func load() -> WatchFolderImportLedger {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return WatchFolderImportLedger() }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode(Envelope.self, from: data).ledger
        } catch {
            // A damaged history only costs re-imports of files still in the folder.
            Self.logger.error("Could not read watch folder import history: \(error.localizedDescription, privacy: .public)")
            return WatchFolderImportLedger()
        }
    }

    func save(_ ledger: WatchFolderImportLedger) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Envelope(version: 1, ledger: ledger))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Could not save watch folder import history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes the saved history and tells running monitors to drop theirs on their next scan.
    static func forgetAll(defaults: UserDefaults = .standard, store: WatchFolderImportHistoryStore = .applicationDefault) {
        if let fileURL = store.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.watchFolderImportHistoryClearedAtKey)
    }

    /// The configured memory length, falling back to the default for unknown values.
    static func retention(defaults: UserDefaults) -> TimeInterval {
        let days = defaults.integer(forKey: AppConstants.watchFolderImportMemoryDaysKey)
        let valid = AppConstants.watchFolderImportMemoryDaysValues.contains(days)
            ? days : AppConstants.defaultWatchFolderImportMemoryDays
        return TimeInterval(valid) * 24 * 60 * 60
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Exact reference-date seconds: modification dates must match after a relaunch.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()
}
