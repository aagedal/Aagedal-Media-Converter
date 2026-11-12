//
//  EncodeHistorySync.swift
//  Aagedal Media Converter
//
//  Encode history sync between Macs. Each Mac writes only its own file,
//  `History/<device id>.json`, inside the settings-sync folder (iCloud Drive
//  or a custom folder) and reads everyone else's, merging on read. Nothing is
//  ever written to another Mac's file, so there are no write conflicts.
//
//  The synced file mirrors the local history minus security-scoped bookmarks
//  (they only resolve on the Mac that made them). The local file stays the
//  source of truth for this Mac's records.
//

import CryptoKit
import Foundation
import IOKit
import OSLog

extension AppConstants {
    /// Whether this Mac's encode history is synced through the sync folder. Per Mac, off by default.
    static let encodeHistorySyncEnabledKey = "encodeHistorySyncEnabled"
    static let defaultEncodeHistorySyncEnabled = false
    /// Random device id used when the hardware UUID can't be read.
    static let encodeHistoryFallbackDeviceIDKey = "encodeHistoryFallbackDeviceID"
}

// MARK: - Device identity

enum EncodeHistoryDevice {
    /// Stable id of this Mac, used for its history file name and stamped on
    /// its records and sessions. Derived from the hardware UUID, hashed so the
    /// raw identifier never leaves the Mac: it survives reinstalls and display
    /// name changes, and a Mac set up with Migration Assistant gets its own id
    /// rather than inheriting the old Mac's file.
    static let localID: String = hardwareDerivedID() ?? fallbackID(defaults: .standard)

    private static func hardwareDerivedID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !value.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("AagedalMediaConverter.history:\(value)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func fallbackID(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: AppConstants.encodeHistoryFallbackDeviceIDKey), !stored.isEmpty {
            return stored
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: AppConstants.encodeHistoryFallbackDeviceIDKey)
        return id
    }
}

// MARK: - Folder

/// One file found in the history sync folder.
struct HistorySyncFile: Sendable {
    enum Status: Equatable, Sendable {
        case loaded
        /// Only iCloud's `.<name>.icloud` placeholder is on disk; a download was requested.
        case notDownloaded
        /// Damaged, partially written or not a history file. Left untouched.
        case unreadable
    }

    /// The file on disk (the placeholder when not downloaded).
    var url: URL
    var deviceID: String
    var status: Status
    var content: EncodeHistoryFile?
    var modificationDate: Date?
    var size: Int?
}

/// Another Mac whose history file is in the sync folder.
struct HistorySyncDevice: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case synced
        case downloading
        case unreadable
        /// Written by a newer app version; read as far as this version understands it.
        case newerVersion
    }

    var id: String
    var name: String?
    var updatedAt: Date?
    var recordCount: Int
    var state: State
}

enum HistorySyncFolder {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "EncodeHistorySync")
    static let directoryName = "History"
    private static let placeholderSuffix = ".icloud"

    static func directory(in syncFolder: URL) -> URL {
        syncFolder.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(in directory: URL, deviceID: String) -> URL {
        directory.appendingPathComponent("\(deviceID).json")
    }

    /// The device a file belongs to, from its name: `<id>.json`, an iCloud
    /// conflict copy such as `<id> 2.json`, or a placeholder `.<id>.json.icloud`.
    /// Nil for anything else (temporary files, `.DS_Store`).
    static func deviceID(forFileName name: String) -> (id: String, isPlaceholder: Bool)? {
        var name = name
        var isPlaceholder = false
        if name.hasPrefix("."), name.hasSuffix(".json" + placeholderSuffix) {
            name = String(name.dropFirst().dropLast(placeholderSuffix.count))
            isPlaceholder = true
        }
        guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(".json".count)
        guard let id = stem.split(separator: " ").first, !id.isEmpty else { return nil }
        return (String(id), isPlaceholder)
    }

    /// Reads every other device's file. Files whose modification date and size
    /// match `cache` (keyed by file name) aren't decoded again, so a scan after
    /// this Mac's own write is cheap. Placeholders get a download request.
    static func scan(directory: URL, excludingDeviceID localID: String, cache: [String: HistorySyncFile] = [:]) -> [HistorySyncFile] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var files: [HistorySyncFile] = []
        for name in names.sorted() {
            guard let (id, isPlaceholder) = deviceID(forFileName: name), id != localID else { continue }
            let url = directory.appendingPathComponent(name)
            if isPlaceholder {
                let realURL = directory.appendingPathComponent(String(name.dropFirst().dropLast(placeholderSuffix.count)))
                do {
                    try fileManager.startDownloadingUbiquitousItem(at: realURL)
                } catch {
                    logger.error("Couldn't request download of \(realURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                files.append(HistorySyncFile(url: url, deviceID: id, status: .notDownloaded))
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let cached = cache[name], cached.status != .notDownloaded,
               cached.modificationDate == values?.contentModificationDate, cached.size == values?.fileSize {
                files.append(cached)
                continue
            }
            var file = HistorySyncFile(url: url, deviceID: id, status: .unreadable,
                                       modificationDate: values?.contentModificationDate, size: values?.fileSize)
            do {
                let content = try decode(try Data(contentsOf: url))
                // A conflict copy of this Mac's own file has another name but our header.
                if content.deviceID == localID { continue }
                file.deviceID = content.deviceID ?? id
                file.content = content
                file.status = .loaded
            } catch {
                logger.error("Unreadable history file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            files.append(file)
        }
        return files
    }

    /// Tolerant like the local file: damaged elements are dropped, unknown
    /// fields ignored, newer versions read as far as possible. Bookmarks are
    /// dropped even if a file carries them; they never resolve on another Mac.
    static func decode(_ data: Data) throws -> EncodeHistoryFile {
        var file = try EncodeHistoryStore.decoder.decode(EncodeHistoryFile.self, from: data)
        for index in file.records.indices { file.records[index].source.bookmark = nil }
        return file
    }

    /// The synced copy of this Mac's history.
    static func makeFile(records: [EncodeRecord], sessions: [HistorySession], rollups: [MonthlyRollup],
                         deviceID: String, deviceName: String, now: Date) -> EncodeHistoryFile {
        var file = EncodeHistoryFile(sessions: sessions, records: records, rollups: rollups)
        for index in file.records.indices { file.records[index].source.bookmark = nil }
        file.deviceID = deviceID
        file.deviceName = deviceName
        file.modifiedAt = now
        file.appVersion = EncodeHistoryFormat.appVersion
        return file
    }

    /// Removes a device's files (including conflict copies and placeholders).
    static func removeFiles(of deviceID: String, in directory: URL) throws {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where self.deviceID(forFileName: name)?.id == deviceID {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// One entry per device, by name.
    static func devices(from files: [HistorySyncFile]) -> [HistorySyncDevice] {
        let byDevice = Dictionary(grouping: files, by: \.deviceID)
        return byDevice.map { id, files in
            let loaded = files.filter { $0.status == .loaded }
                .sorted { ($0.content?.modifiedAt ?? .distantPast) > ($1.content?.modifiedAt ?? .distantPast) }
            let newest = loaded.first?.content
            let state: HistorySyncDevice.State
            if loaded.isEmpty {
                state = files.contains { $0.status == .notDownloaded } ? .downloading : .unreadable
            } else if loaded.contains(where: { ($0.content?.version ?? 0) > EncodeHistoryFile.currentVersion }) {
                state = .newerVersion
            } else {
                state = .synced
            }
            let name = newest?.deviceName.flatMap { $0.isEmpty ? nil : $0 }
                ?? newest?.records.first(where: { !$0.deviceName.isEmpty })?.deviceName
            let recordCount = Set(loaded.flatMap { $0.content?.records.map(\.id) ?? [] }).count
            return HistorySyncDevice(id: id, name: name, updatedAt: newest?.modifiedAt ?? loaded.first?.modificationDate,
                                     recordCount: recordCount, state: state)
        }
        .sorted { ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending }
    }
}

// MARK: - Retention

enum EncodeHistoryRetention {
    /// Start of the kept period, or nil when everything is kept (0 days).
    static func cutoff(days: Int, now: Date) -> Date? {
        days > 0 ? now.addingTimeInterval(-Double(days) * 86_400) : nil
    }

    /// Deletes records and sessions older than `cutoff`, folding them into the
    /// monthly rollups in the same step so statistics count each exactly once.
    /// Sessions that still own records, are recent or are `keepingSessionID` stay.
    static func prune(
        records: inout [EncodeRecord],
        sessions: inout [HistorySession],
        rollups: inout [MonthlyRollup],
        cutoff: Date,
        keepingSessionID: UUID?,
        keepRunning: Bool = true,
        calendar: Calendar
    ) {
        let isExpired: (EncodeRecord) -> Bool = { $0.startedAt < cutoff && !(keepRunning && $0.outcome == .running) }
        let expiredRecords = records.filter(isExpired)
        records.removeAll(where: isExpired)
        let referenced = Set(records.map(\.sessionID))
        let isExpiredSession: (HistorySession) -> Bool = { session in
            session.id != keepingSessionID && !referenced.contains(session.id) && session.startedAt < cutoff
        }
        let expiredSessions = sessions.filter(isExpiredSession)
        sessions.removeAll(where: isExpiredSession)
        EncodeStatistics.fold(records: expiredRecords, sessions: expiredSessions, into: &rollups, calendar: calendar)
    }
}

// MARK: - Merge

/// Combines this Mac's history with the files of other Macs.
enum EncodeHistoryMerge {
    struct Result: Equatable, Sendable {
        /// Newest first.
        var records: [EncodeRecord] = []
        var sessions: [HistorySession] = []
        var rollups: [MonthlyRollup] = []
    }

    /// Every element in the result carries a device id: local data without
    /// one gets `localDeviceID`, remote data the id of the file it came from.
    ///
    /// - Records and sessions are deduplicated by id. The local copy wins; of
    ///   two remote copies (an iCloud conflict copy, or history carried over by
    ///   Migration Assistant) the more finished one wins.
    /// - Rollups are deduplicated per device, month and name, keeping the larger
    ///   (folding only ever grows a rollup).
    /// - Remote data follows this Mac's retention (`cutoff`): older records and
    ///   sessions are folded into that device's rollups in memory, so a Mac
    ///   that stopped syncing ages out of the browser but stays in statistics.
    static func merge(
        localRecords: [EncodeRecord],
        localSessions: [HistorySession],
        localRollups: [MonthlyRollup],
        localDeviceID: String,
        remote: [HistorySyncFile],
        cutoff: Date?,
        calendar: Calendar = .current
    ) -> Result {
        var result = Result()
        result.records = localRecords.map { record in
            var record = record
            if record.deviceID == nil { record.deviceID = localDeviceID }
            return record
        }
        result.sessions = localSessions.map { session in
            var session = session
            if session.deviceID == nil { session.deviceID = localDeviceID }
            return session
        }
        result.rollups = localRollups.map { rollup in
            var rollup = rollup
            if rollup.deviceID == nil { rollup.deviceID = localDeviceID }
            return rollup
        }
        guard remote.contains(where: { $0.content != nil }) else { return result }

        let localRecordIDs = Set(localRecords.map(\.id))
        let localSessionIDs = Set(localSessions.map(\.id))
        var records: [UUID: EncodeRecord] = [:]
        var sessions: [UUID: HistorySession] = [:]
        var rollups: [String: MonthlyRollup] = [:]
        for file in remote {
            guard let content = file.content else { continue }
            let name = content.deviceName ?? ""
            for var record in content.records where !localRecordIDs.contains(record.id) {
                if record.deviceID == nil { record.deviceID = file.deviceID }
                if record.deviceName.isEmpty { record.deviceName = name }
                if let existing = records[record.id], !isMoreFinished(record, than: existing) { continue }
                records[record.id] = record
            }
            for var session in content.sessions where !localSessionIDs.contains(session.id) {
                if session.deviceID == nil { session.deviceID = file.deviceID }
                if session.deviceName.isEmpty { session.deviceName = name }
                if let existing = sessions[session.id], !isMoreFinished(session, than: existing) { continue }
                sessions[session.id] = session
            }
            for var rollup in content.rollups {
                if rollup.deviceID == nil { rollup.deviceID = file.deviceID }
                if rollup.deviceName.isEmpty { rollup.deviceName = name }
                let key = "\(rollup.deviceID ?? "")|\(rollup.month)|\(rollup.deviceName)"
                if let existing = rollups[key],
                   existing.encodeCount + existing.sessionCount >= rollup.encodeCount + rollup.sessionCount { continue }
                rollups[key] = rollup
            }
        }

        var remoteRecords = Array(records.values)
        var remoteSessions = Array(sessions.values)
        var remoteRollups = Array(rollups.values)
        if let cutoff {
            // A remote encode still "running" past the cutoff belongs to a Mac
            // that never came back to finish it.
            EncodeHistoryRetention.prune(
                records: &remoteRecords, sessions: &remoteSessions, rollups: &remoteRollups,
                cutoff: cutoff, keepingSessionID: nil, keepRunning: false, calendar: calendar
            )
        }
        result.records += remoteRecords
        result.records.sort { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString < $1.id.uuidString }
        result.sessions += remoteSessions.sorted { $0.startedAt < $1.startedAt }
        result.rollups += remoteRollups.sorted { $0.month != $1.month ? $0.month < $1.month : $0.deviceName < $1.deviceName }
        return result
    }

    private static func isMoreFinished(_ candidate: EncodeRecord, than existing: EncodeRecord) -> Bool {
        switch (candidate.finishedAt, existing.finishedAt) {
        case (.some(let a), .some(let b)): return a > b
        case (.some, nil): return true
        default: return false
        }
    }

    private static func isMoreFinished(_ candidate: HistorySession, than existing: HistorySession) -> Bool {
        switch (candidate.endedAt, existing.endedAt) {
        case (.some(let a), .some(let b)): return a > b
        case (.some, nil): return true
        default: return false
        }
    }
}
