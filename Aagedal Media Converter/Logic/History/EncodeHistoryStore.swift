//
//  EncodeHistoryStore.swift
//  Aagedal Media Converter
//
//  Persists the encode history (sessions + records) as JSON. Records are
//  written when an encode starts, so a crash leaves a `running` record that is
//  marked `interrupted` on the next launch.
//

import Foundation
import Observation
import OSLog

/// A queue row as seen by the history tracker.
struct HistoryObservedRow {
    var item: VideoItem
    var preset: ExportPreset
    var groupName: String?
    var merged: Bool
}

@MainActor
@Observable
final class EncodeHistoryStore {
    static let shared = EncodeHistoryStore()

    nonisolated private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "EncodeHistory")
    nonisolated static let fileName = "encode-history.json"

    /// Newest first.
    private(set) var records: [EncodeRecord] = []
    private(set) var sessions: [HistorySession] = []
    private(set) var currentSessionID: UUID?
    /// Number of encodes interrupted by the previous run (crash or quit mid-encode).
    private(set) var interruptedAtLaunchCount = 0
    /// Rows encoding right now, tracked even when history recording is off.
    private(set) var runningItemCount = 0

    @ObservationIgnored private var tracker = EncodeHistoryTracker()
    @ObservationIgnored private var openRecordIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults

    init(directory: URL = AppConstants.encodeHistoryDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    var isEnabled: Bool {
        defaults.object(forKey: AppConstants.encodeHistoryEnabledKey) as? Bool ?? AppConstants.defaultEncodeHistoryEnabled
    }

    var retentionDays: Int {
        defaults.object(forKey: AppConstants.encodeHistoryRetentionDaysKey) as? Int ?? AppConstants.defaultEncodeHistoryRetentionDays
    }

    // MARK: - Lifecycle

    /// Loads history, settles the previous run and opens a new session.
    func bootstrap(now: Date = Date()) {
        guard !didBootstrap else { return }
        didBootstrap = true

        var file = load()
        // Encodes still running belonged to a run that never finished them.
        for index in file.records.indices where file.records[index].outcome == .running {
            file.records[index].outcome = .interrupted
            interruptedAtLaunchCount += 1
        }
        // A session without an end was terminated abnormally.
        for index in file.sessions.indices where file.sessions[index].endedAt == nil {
            let sessionID = file.sessions[index].id
            let lastActivity = file.records
                .filter { $0.sessionID == sessionID }
                .map { $0.finishedAt ?? $0.startedAt }
                .max()
            file.sessions[index].endedAt = lastActivity ?? file.sessions[index].startedAt
            file.sessions[index].endedCleanly = false
        }

        let session = HistorySession(
            startedAt: now,
            deviceName: EncodeHistoryFormat.deviceName,
            appVersion: EncodeHistoryFormat.appVersion
        )
        file.sessions.append(session)
        currentSessionID = session.id

        records = file.records.sorted { $0.startedAt > $1.startedAt }
        sessions = file.sessions
        prune(now: now)
        writeNow()
    }

    /// Marks the current session as cleanly ended and writes synchronously.
    func endSession(now: Date = Date()) {
        guard let currentSessionID, let index = sessions.firstIndex(where: { $0.id == currentSessionID }) else { return }
        // Encodes still running at quit are interrupted, not crashed.
        for (_, recordID) in openRecordIDs {
            updateRecord(recordID) {
                $0.outcome = .interrupted
                $0.finishedAt = now
            }
        }
        openRecordIDs.removeAll()
        sessions[index].endedAt = now
        sessions[index].endedCleanly = true
        writeNow()
    }

    // MARK: - Observation

    /// Diffs row statuses and records starts/finishes. Cheap enough to call on
    /// every queue change (progress ticks included): full rows are only
    /// resolved for rows whose status changed.
    func observe(
        _ statuses: [(id: UUID, status: ConversionManager.ConversionStatus)],
        resolve: (UUID) -> HistoryObservedRow?,
        now: Date = Date()
    ) {
        let events = tracker.update(statuses)
        let running = tracker.convertingCount
        if running != runningItemCount { runningItemCount = running }
        for event in events {
            switch event {
            case .started(let itemID):
                guard let row = resolve(itemID) else { continue }
                recordStart(row, now: now)
            case .finished(let itemID, let outcome):
                recordFinish(itemID: itemID, row: resolve(itemID), outcome: outcome, now: now)
            }
        }
    }

    private func recordStart(_ row: HistoryObservedRow, now: Date) {
        guard isEnabled, let currentSessionID else { return }
        let item = row.item
        let record = EncodeRecord(
            sessionID: currentSessionID,
            startedAt: now,
            kind: item.isImageSequence ? .imageSequence : .file,
            source: HistoryFileReference(url: item.url),
            sourceFacts: SourceFacts(item: item),
            recipe: EncodeRecipe(item: item),
            presetRawValue: row.preset.rawValue,
            presetDisplayName: PresetManager.shared.displayName(for: row.preset),
            groupName: row.groupName,
            merged: row.merged,
            outputPath: item.outputURL?.path,
            deviceName: EncodeHistoryFormat.deviceName
        )
        openRecordIDs[item.id] = record.id
        records.insert(record, at: 0)
        scheduleSave()
    }

    private func recordFinish(itemID: UUID, row: HistoryObservedRow?, outcome: EncodeOutcome, now: Date) {
        guard let recordID = openRecordIDs.removeValue(forKey: itemID) else { return }
        updateRecord(recordID) { record in
            record.outcome = outcome
            record.finishedAt = now
            guard let item = row?.item else { return }
            record.errorMessage = outcome == .failed ? item.conversionError : nil
            if let output = item.outputURL { record.outputPath = output.path }
            if outcome == .completed {
                record.outputSizeBytes = item.outputFileSizeBytes ?? item.cachedOutputFileSize
            }
        }
        scheduleSave()
    }

    private func updateRecord(_ id: UUID, _ change: (inout EncodeRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    // MARK: - Editing

    func removeRecords(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        openRecordIDs = openRecordIDs.filter { !ids.contains($0.value) }
        scheduleSave()
    }

    func clearAll() {
        records.removeAll()
        openRecordIDs.removeAll()
        sessions = sessions.filter { $0.id == currentSessionID }
        scheduleSave()
    }

    /// Re-applies the retention setting (called after it changes).
    func applyRetention(now: Date = Date()) {
        prune(now: now)
        scheduleSave()
    }

    /// Updates a record's source after the user relinked a moved file.
    func relinkSource(of recordIDs: Set<UUID>, oldPath: String, to url: URL) {
        let reference = HistoryFileReference(url: url)
        for index in records.indices where recordIDs.contains(records[index].id) && records[index].source.path == oldPath {
            records[index].source = reference
        }
        scheduleSave()
    }

    private func prune(now: Date) {
        let days = retentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        records.removeAll { $0.startedAt < cutoff && $0.outcome != .running }
        let referenced = Set(records.map(\.sessionID))
        // Keep sessions that still own records, are recent (crash stats), or are current.
        sessions.removeAll { session in
            session.id != currentSessionID && !referenced.contains(session.id) && session.startedAt < cutoff
        }
    }

    // MARK: - Persistence

    private func load() -> EncodeHistoryFile {
        guard let data = try? Data(contentsOf: fileURL) else { return EncodeHistoryFile() }
        do {
            return try Self.decoder.decode(EncodeHistoryFile.self, from: data)
        } catch {
            Self.logger.error("Unreadable encode history, starting fresh: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file for inspection instead of overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return EncodeHistoryFile()
        }
    }

    private func snapshotData() -> Data? {
        let file = EncodeHistoryFile(sessions: sessions, records: records)
        return try? Self.encoder.encode(file)
    }

    /// Coalesces bursts of changes into one write on a serial queue, so writes
    /// land in order and `writeNow()` at quit runs after any pending write.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            guard let data = self.snapshotData() else { return }
            let url = self.fileURL
            Self.writeQueue.async { Self.write(data, to: url) }
        }
    }

    /// Writes pending changes synchronously.
    func flush() { writeNow() }

    private func writeNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = snapshotData() else { return }
        let url = fileURL
        Self.writeQueue.sync { Self.write(data, to: url) }
    }

    nonisolated static let writeQueue = DispatchQueue(label: "com.aagedal.MediaConverter.history-writes", qos: .utility)

    nonisolated private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
