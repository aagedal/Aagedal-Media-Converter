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
    /// History folders this Mac's synced file was written to and not yet removed from.
    static let encodeHistorySyncWrittenDirectoriesKey = "encodeHistorySyncWrittenDirectories"
}

// MARK: - Device identity

enum EncodeHistoryDevice {
    /// Stable id of this Mac, used for its history file name and stamped on
    /// its records and sessions. Derived from the hardware UUID, hashed so the
    /// raw identifier never leaves the Mac: it survives reinstalls and display
    /// name changes, and a Mac set up with Migration Assistant gets its own id
    /// rather than inheriting the old Mac's file. Two limits: the fallback id
    /// lives in the app's preferences, which Migration Assistant copies, so two
    /// Macs that both can't read the hardware UUID could share it; and a
    /// virtual machine duplicated as a whole may keep its hardware UUID.
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
            // Only files that were read are reused. One that failed is tried
            // again: an evicted iCloud file keeps its name, size and date.
            if let cached = cache[name], cached.status == .loaded,
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

    /// The newest readable copy of each device's file. Every write holds that
    /// Mac's whole history, so an older iCloud conflict copy only adds stale
    /// data: taking records from one copy and rollups from another would count
    /// encodes folded in between twice.
    static func newestCopies(of files: [HistorySyncFile]) -> [HistorySyncFile] {
        var newest: [String: HistorySyncFile] = [:]
        for file in files where file.content != nil {
            if let existing = newest[file.deviceID], !isNewer(file, than: existing) { continue }
            newest[file.deviceID] = file
        }
        return newest.values.sorted { $0.deviceID < $1.deviceID }
    }

    /// By the header's write date; on a tie the file with the plain name wins.
    private static func isNewer(_ candidate: HistorySyncFile, than existing: HistorySyncFile) -> Bool {
        let a = candidate.content?.modifiedAt ?? candidate.modificationDate ?? .distantPast
        let b = existing.content?.modifiedAt ?? existing.modificationDate ?? .distantPast
        if a != b { return a > b }
        return candidate.url.lastPathComponent == "\(candidate.deviceID).json"
    }

    /// One entry per device, by name.
    static func devices(from files: [HistorySyncFile]) -> [HistorySyncDevice] {
        let byDevice = Dictionary(grouping: files, by: \.deviceID)
        return byDevice.map { id, files in
            let loaded = files.filter { $0.status == .loaded }
            let newest = newestCopies(of: loaded).first?.content
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
            return HistorySyncDevice(id: id, name: name, updatedAt: newest?.modifiedAt ?? loaded.first?.modificationDate,
                                     recordCount: newest?.records.count ?? 0, state: state)
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

    /// Gives this Mac's history without a device id (written by 4.7, before
    /// sync) the id of this Mac, so it's stored once with the right owner and
    /// another Mac doesn't have to guess. Rollups that then share a month,
    /// device and name are added up: each holds different encodes (an encode
    /// is folded once, under the one id it had).
    ///
    /// History that Migration Assistant carried over from a Mac that ran 4.7
    /// is claimed too; it can't be told apart from this Mac's own. If the old
    /// Mac also keeps syncing, its old records and sessions are still counted
    /// once (same ids), but encodes both Macs already folded into rollups are
    /// counted by both.
    static func attributeUnattributed(
        records: inout [EncodeRecord],
        sessions: inout [HistorySession],
        rollups: inout [MonthlyRollup],
        to deviceID: String
    ) {
        for index in records.indices where records[index].deviceID == nil { records[index].deviceID = deviceID }
        for index in sessions.indices where sessions[index].deviceID == nil { sessions[index].deviceID = deviceID }
        guard rollups.contains(where: { $0.deviceID == nil }) else { return }
        for index in rollups.indices where rollups[index].deviceID == nil { rollups[index].deviceID = deviceID }
        rollups = coalesced(rollups)
    }

    /// Rollups with the same month, device and name added up, in a stable order.
    static func coalesced(_ rollups: [MonthlyRollup]) -> [MonthlyRollup] {
        var byKey: [String: MonthlyRollup] = [:]
        for rollup in rollups {
            let key = rollupKey(rollup)
            if byKey[key] == nil { byKey[key] = rollup } else { byKey[key]?.merge(rollup) }
        }
        return byKey.values.sorted { $0.month != $1.month ? $0.month < $1.month : $0.deviceName < $1.deviceName }
    }

    private static func rollupKey(_ rollup: MonthlyRollup) -> String {
        "\(rollup.deviceID ?? "")|\(rollup.month)|\(rollup.deviceName)"
    }

    /// Every element in the result carries a device id: local data without
    /// one gets `localDeviceID`, remote data the id of the file it came from.
    ///
    /// - This Mac's history comes only from the local file. Remote data that
    ///   claims this Mac's id (a Mac set up from this one with Migration
    ///   Assistant syncs the copies it got) is ignored: whatever is missing
    ///   locally was pruned into a local rollup or removed on purpose.
    /// - Of each other device only the newest copy of its file is read
    ///   (`HistorySyncFolder.newestCopies`).
    /// - Records and sessions are deduplicated by id. The local copy wins; of
    ///   two remote copies (history carried over by Migration Assistant, in the
    ///   old and the new Mac's file) the more finished one wins.
    /// - Rollups: within one file, entries for the same device, month and name
    ///   are added up (see `attributeUnattributed`). Across files they are
    ///   copies of the same rollup taken at different times, so the larger
    ///   wins (folding only ever grows a rollup). Local rollups of another Mac,
    ///   carried over by Migration Assistant, take part in that comparison as
    ///   one more file. Until both Macs have folded the carried-over records,
    ///   ones this Mac still keeps while the other already folded them count
    ///   twice; that settles once this Mac's retention folds them as well.
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
        let stampedRollups = localRollups.map { rollup in
            var rollup = rollup
            if rollup.deviceID == nil { rollup.deviceID = localDeviceID }
            return rollup
        }
        result.rollups = stampedRollups.filter { $0.deviceID == localDeviceID }
        let carriedOverRollups = stampedRollups.filter { $0.deviceID != localDeviceID }
        let files = HistorySyncFolder.newestCopies(of: remote)
        guard !files.isEmpty || !carriedOverRollups.isEmpty else { return result }

        let localRecordIDs = Set(localRecords.map(\.id))
        let localSessionIDs = Set(localSessions.map(\.id))
        var records: [UUID: EncodeRecord] = [:]
        var sessions: [UUID: HistorySession] = [:]
        var rollups: [String: MonthlyRollup] = [:]
        func addRollups(of copy: [MonthlyRollup]) {
            for rollup in coalesced(copy) {
                let key = rollupKey(rollup)
                if let existing = rollups[key],
                   existing.encodeCount + existing.sessionCount >= rollup.encodeCount + rollup.sessionCount { continue }
                rollups[key] = rollup
            }
        }
        addRollups(of: carriedOverRollups)
        for file in files {
            guard let content = file.content else { continue }
            let name = content.deviceName ?? ""
            for var record in content.records where !localRecordIDs.contains(record.id) {
                if record.deviceID == nil { record.deviceID = file.deviceID }
                guard record.deviceID != localDeviceID else { continue }
                if record.deviceName.isEmpty { record.deviceName = name }
                if let existing = records[record.id], !isMoreFinished(record, than: existing) { continue }
                records[record.id] = record
            }
            for var session in content.sessions where !localSessionIDs.contains(session.id) {
                if session.deviceID == nil { session.deviceID = file.deviceID }
                guard session.deviceID != localDeviceID else { continue }
                if session.deviceName.isEmpty { session.deviceName = name }
                if let existing = sessions[session.id], !isMoreFinished(session, than: existing) { continue }
                sessions[session.id] = session
            }
            addRollups(of: content.rollups.compactMap { rollup in
                var rollup = rollup
                if rollup.deviceID == nil { rollup.deviceID = file.deviceID }
                guard rollup.deviceID != localDeviceID else { return nil }
                if rollup.deviceName.isEmpty { rollup.deviceName = name }
                return rollup
            })
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
