//
//  EncodeHistoryStore.swift
//  Aagedal Media Converter
//
//  Persists the encode history (sessions + records) as JSON. Records are
//  written when an encode starts, so a crash leaves a `running` record that is
//  marked `interrupted` on the next launch.
//
//  With history sync on, the same history (minus bookmarks) is mirrored to
//  this Mac's file in the sync folder and other Macs' files are merged into
//  `allRecords` / `allSessions` / `allRollups` (see `EncodeHistorySync`).
//

import AppKit
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
    static let shared = EncodeHistoryStore(observesSyncChanges: true)

    nonisolated private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "EncodeHistory")
    nonisolated static let fileName = "encode-history.json"

    /// This Mac's history, newest first. Only these are written to the local file.
    private(set) var records: [EncodeRecord] = []
    private(set) var sessions: [HistorySession] = []
    /// Statistics of records already removed by retention (see `EncodeStatistics`).
    private(set) var rollups: [MonthlyRollup] = []
    /// Every Mac's history: this Mac's plus synced files, deduplicated and
    /// with device ids filled in (`EncodeHistoryMerge`). Newest first. The
    /// same as this Mac's history while sync is off.
    private(set) var allRecords: [EncodeRecord] = []
    private(set) var allSessions: [HistorySession] = []
    private(set) var allRollups: [MonthlyRollup] = []
    private(set) var isSyncEnabled: Bool
    /// Other Macs that have a history file in the sync folder.
    private(set) var syncDevices: [HistorySyncDevice] = []
    private(set) var syncErrorMessage: String?
    /// Stable id of this Mac (`EncodeHistoryDevice.localID`).
    let deviceID: String
    let deviceName: String
    private(set) var currentSessionID: UUID?
    /// Number of encodes interrupted by the previous run (crash or quit mid-encode).
    /// Shown once in the history overlay until acknowledged.
    private(set) var interruptedAtLaunchCount = 0
    /// Rows encoding right now, tracked even when history recording is off.
    private(set) var runningItemCount = 0

    @ObservationIgnored private var tracker = EncodeHistoryTracker()
    @ObservationIgnored private var openRecordIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let syncFolder: @MainActor () -> URL?
    @ObservationIgnored private let observesSyncChanges: Bool
    /// Other Macs' files from the last scan, also the scan's decode cache.
    @ObservationIgnored private var remoteFiles: [HistorySyncFile] = []
    /// Sources relinked by the user for other Macs' records, which are never
    /// written back. Applied to the merged records for this run.
    @ObservationIgnored private var foreignRelinks: [UUID: HistoryFileReference] = [:]
    @ObservationIgnored private var cloudSaveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The last queued reload; reloads run one after another.
    @ObservationIgnored private var reloadChain: Task<Void, Never>?
    @ObservationIgnored private var directorySource: DispatchSourceFileSystemObject?

    /// - Parameters:
    ///   - syncFolder: The shared sync folder (`SettingsSyncService.syncFolderURL()`);
    ///     history goes in its `History` subfolder.
    ///   - observesSyncChanges: Watch the sync folder, app activation and sync
    ///     location changes. Off for tests, which reload explicitly.
    init(
        directory: URL = AppConstants.encodeHistoryDirectory,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        deviceID: String = EncodeHistoryDevice.localID,
        deviceName: String = EncodeHistoryFormat.deviceName,
        syncFolder: @escaping @MainActor () -> URL? = { SettingsSyncService.shared.syncFolderURL() },
        observesSyncChanges: Bool = false
    ) {
        self.directory = directory
        self.defaults = defaults
        self.calendar = calendar
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.syncFolder = syncFolder
        self.observesSyncChanges = observesSyncChanges
        isSyncEnabled = defaults.object(forKey: AppConstants.encodeHistorySyncEnabledKey) as? Bool
            ?? AppConstants.defaultEncodeHistorySyncEnabled
        if observesSyncChanges { observeSyncTriggers() }
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
            deviceName: deviceName,
            appVersion: EncodeHistoryFormat.appVersion,
            deviceID: deviceID
        )
        file.sessions.append(session)
        currentSessionID = session.id

        records = file.records.sorted { $0.startedAt > $1.startedAt }
        sessions = file.sessions
        rollups = file.rollups
        prune(now: now)
        writeNow()
        if isSyncEnabled {
            startMonitoring()
            reloadTask = Task { [weak self] in await self?.reloadRemote() }
        }
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
            deviceName: deviceName,
            deviceID: deviceID
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

    /// Removes this Mac's records. Other Macs' records can't be removed here.
    func removeRecords(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        openRecordIDs = openRecordIDs.filter { !ids.contains($0.value) }
        scheduleSave()
    }

    /// Clears this Mac's history and the statistics built from it (rollups
    /// and past sessions), keeping only the current session. With sync on,
    /// this Mac's synced file is rewritten accordingly; other Macs' files
    /// are not touched.
    func clearAll() {
        records.removeAll()
        openRecordIDs.removeAll()
        rollups.removeAll()
        sessions = sessions.filter { $0.id == currentSessionID }
        interruptedAtLaunchCount = 0
        scheduleSave()
    }

    /// Whether there is anything `clearAll()` would remove.
    var hasClearableData: Bool {
        !records.isEmpty || !rollups.isEmpty || sessions.contains { $0.id != currentSessionID }
    }

    /// Hides the "interrupted last time" notice.
    func acknowledgeInterruptedAtLaunch() {
        interruptedAtLaunchCount = 0
    }

    /// Statistics for a period, from live records plus rollups of every Mac,
    /// or only of the Mac with `deviceID`.
    func statistics(for period: StatisticsPeriod, deviceID filter: String? = nil, now: Date = Date()) -> EncodeStatisticsSummary {
        func included(_ id: String?) -> Bool { filter == nil || id == filter }
        return EncodeStatistics.summarize(
            records: allRecords.filter { included($0.deviceID) },
            sessions: allSessions.filter { included($0.deviceID) },
            rollups: allRollups.filter { included($0.deviceID) },
            period: period, currentSessionID: currentSessionID, now: now, calendar: calendar
        )
    }

    /// Detailed records of a period, oldest first, from every Mac or only the
    /// Mac with `deviceID` (the same records `statistics(for:)` counts).
    func records(for period: StatisticsPeriod, deviceID filter: String? = nil, now: Date = Date()) -> [EncodeRecord] {
        let start = period.start(now: now, calendar: calendar)
        return allRecords
            .filter { record in
                (filter == nil || record.deviceID == filter) && start.map { record.startedAt >= $0 } ?? true
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether a (merged) record was made on this Mac.
    func isFromThisMac(_ record: EncodeRecord) -> Bool {
        record.deviceID == nil || record.deviceID == deviceID
    }

    /// Display name of a Mac in the merged history.
    func deviceName(for id: String?) -> String? {
        guard let id, id != deviceID else { return deviceName }
        return syncDevices.first { $0.id == id }?.name
            ?? allRecords.first { $0.deviceID == id && !$0.deviceName.isEmpty }?.deviceName
            ?? allRollups.first { $0.deviceID == id && !$0.deviceName.isEmpty }?.deviceName
    }

    /// Macs with data in the merged history, this one first.
    var historyDeviceIDs: [String] {
        var others = Set(allRecords.compactMap(\.deviceID) + allRollups.compactMap(\.deviceID) + allSessions.compactMap(\.deviceID))
        others.remove(deviceID)
        return [deviceID] + others.sorted {
            (deviceName(for: $0) ?? $0).localizedStandardCompare(deviceName(for: $1) ?? $1) == .orderedAscending
        }
    }

    /// Re-applies the retention setting (called after it changes).
    func applyRetention(now: Date = Date()) {
        prune(now: now)
        scheduleSave()
    }

    /// Updates a record's source after the user relinked a moved file. Other
    /// Macs' records keep the new location for this run only.
    func relinkSource(of recordIDs: Set<UUID>, oldPath: String, to url: URL) {
        let reference = HistoryFileReference(url: url)
        var localIDs: Set<UUID> = []
        for index in records.indices where recordIDs.contains(records[index].id) {
            localIDs.insert(records[index].id)
            if records[index].source.path == oldPath { records[index].source = reference }
        }
        for record in allRecords where recordIDs.contains(record.id) && !localIDs.contains(record.id)
            && record.source.path == oldPath {
            foreignRelinks[record.id] = reference
        }
        scheduleSave()
    }

    /// Deletes records and sessions older than the retention period. They are
    /// folded into the monthly rollups first, in the same in-memory step and
    /// the same file write, so statistics count each exactly once. Running
    /// encodes, recent sessions (crash stats) and the current session stay.
    private func prune(now: Date) {
        guard let cutoff = EncodeHistoryRetention.cutoff(days: retentionDays, now: now) else { return }
        EncodeHistoryRetention.prune(
            records: &records, sessions: &sessions, rollups: &rollups,
            cutoff: cutoff, keepingSessionID: currentSessionID, calendar: calendar
        )
    }

    // MARK: - Sync

    /// `History` inside the sync folder, or nil when the location isn't available.
    var syncDirectory: URL? { syncFolder().map(HistorySyncFolder.directory(in:)) }

    /// Turning sync off also removes this Mac's file from the sync folder, so
    /// its paths and file names no longer sit in iCloud Drive.
    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != isSyncEnabled else { return }
        isSyncEnabled = enabled
        defaults.set(enabled, forKey: AppConstants.encodeHistorySyncEnabledKey)
        if enabled {
            writeCloud(synchronously: true)
            startMonitoring()
            reloadTask?.cancel()
            reloadTask = Task { [weak self] in await self?.reloadRemote() }
        } else {
            cloudSaveTask?.cancel()
            cloudSaveTask = nil
            reloadTask?.cancel()
            stopMonitoring()
            if let directory = syncDirectory {
                let id = deviceID
                Self.writeQueue.sync {
                    do {
                        try HistorySyncFolder.removeFiles(of: id, in: directory)
                    } catch {
                        Self.logger.error("Couldn't remove synced history: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            remoteFiles = []
            foreignRelinks = [:]
            syncDevices = []
            syncErrorMessage = nil
            rebuildMerged()
        }
    }

    /// Writes this Mac's file and reads the others ("Sync Now").
    func syncNow() async {
        guard isSyncEnabled else { return }
        if directorySource == nil { startMonitoring() }
        writeCloud(synchronously: true)
        await reloadRemote()
    }

    /// Reads other Macs' files off the main actor and re-merges. Reloads are
    /// serialized, so when this returns the folder has been read since the call.
    func reloadRemote() async {
        let previous = reloadChain
        let reload = Task { [weak self] in
            await previous?.value
            await self?.performReload()
        }
        reloadChain = reload
        await reload.value
    }

    private func performReload() async {
        guard isSyncEnabled, let directory = syncDirectory else {
            remoteFiles = []
            if !syncDevices.isEmpty { syncDevices = [] }
            syncErrorMessage = isSyncEnabled ? SettingsSyncService.SyncError.locationUnavailable.localizedDescription : nil
            rebuildMerged()
            return
        }
        let localID = deviceID
        let cache = Dictionary(remoteFiles.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        let files = await Task.detached(priority: .utility) {
            HistorySyncFolder.scan(directory: directory, excludingDeviceID: localID, cache: cache)
        }.value
        // Sync turned off or moved while this was reading.
        guard isSyncEnabled, syncDirectory == directory else { return }
        remoteFiles = files
        let devices = HistorySyncFolder.devices(from: files)
        if devices != syncDevices { syncDevices = devices }
        rebuildMerged()
    }

    /// Removes another Mac's file, e.g. of a Mac that's no longer used. A
    /// Mac that still syncs writes its file again on its next change.
    func removeSyncedDevice(_ id: String) async {
        guard isSyncEnabled, id != deviceID, let directory = syncDirectory else { return }
        do {
            try HistorySyncFolder.removeFiles(of: id, in: directory)
        } catch {
            syncErrorMessage = error.localizedDescription
        }
        await reloadRemote()
    }

    private func rebuildMerged(now: Date = Date()) {
        var merged = EncodeHistoryMerge.merge(
            localRecords: records, localSessions: sessions, localRollups: rollups,
            localDeviceID: deviceID, remote: remoteFiles,
            cutoff: EncodeHistoryRetention.cutoff(days: retentionDays, now: now), calendar: calendar
        )
        if !foreignRelinks.isEmpty {
            for index in merged.records.indices {
                if let reference = foreignRelinks[merged.records[index].id] { merged.records[index].source = reference }
            }
        }
        allRecords = merged.records
        allSessions = merged.sessions
        allRollups = merged.rollups
    }

    private func observeSyncTriggers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSyncEnabled, self.didBootstrap else { return }
                // The location may have come back (iCloud Drive turned on again).
                if self.directorySource == nil { self.startMonitoring() }
                self.scheduleRemoteReload()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .syncLocationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSyncEnabled, self.didBootstrap else { return }
                self.remoteFiles = []
                self.foreignRelinks = [:]
                self.startMonitoring()
                self.writeCloud(synchronously: true)
                self.scheduleRemoteReload()
            }
        }
    }

    /// Debounced: this Mac's own writes also change the folder.
    private func scheduleRemoteReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reloadRemote()
        }
    }

    private func startMonitoring() {
        stopMonitoring()
        guard observesSyncChanges, let directory = syncDirectory else { return }
        let fd: Int32
        do {
            fd = try SettingsSyncService.openMonitoringDirectory(directory)
        } catch {
            syncErrorMessage = error.localizedDescription
            Self.logger.error("Failed to monitor history sync folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRemoteReload() }
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
    }

    private func stopMonitoring() {
        directorySource?.cancel()
        directorySource = nil
    }

    // MARK: - Persistence

    /// Reads what it can. Damaged elements are dropped individually; the
    /// original file is copied aside before the first rewrite whenever it was
    /// damaged or written by a newer version, so nothing is lost silently.
    private func load() -> EncodeHistoryFile {
        guard let data = try? Data(contentsOf: fileURL) else { return EncodeHistoryFile() }
        let file: EncodeHistoryFile
        do {
            file = try Self.decoder.decode(EncodeHistoryFile.self, from: data)
        } catch {
            Self.logger.error("Unreadable encode history, starting fresh: \(error.localizedDescription, privacy: .public)")
            Self.backUp(fileURL, suffix: "corrupt")
            return EncodeHistoryFile()
        }
        if file.version > EncodeHistoryFile.currentVersion {
            // Written by a newer app; fields this version doesn't know would be
            // lost on the next write, so keep the original next to it.
            Self.logger.notice("Encode history is version \(file.version), newer than \(EncodeHistoryFile.currentVersion); keeping a backup")
            Self.backUp(fileURL, suffix: "v\(file.version)")
        } else if file.droppedElementCount > 0 {
            Self.logger.error("Dropped \(file.droppedElementCount) unreadable encode history entries; keeping a backup")
            Self.backUp(fileURL, suffix: "corrupt")
        }
        return file
    }

    /// Copies (never moves) a file aside as `<name>.<suffix>-<timestamp>.json`.
    nonisolated private static func backUp(_ url: URL, suffix: String) {
        let backup = url.deletingPathExtension()
            .appendingPathExtension("\(suffix)-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    private func snapshotData() -> Data? {
        let file = EncodeHistoryFile(sessions: sessions, records: records, rollups: rollups)
        return try? Self.encoder.encode(file)
    }

    /// Coalesces bursts of changes into one write on a serial queue, so writes
    /// land in order and `writeNow()` at quit runs after any pending write.
    /// Every persisted change also refreshes the merged view.
    private func scheduleSave() {
        rebuildMerged()
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            guard let data = self.snapshotData() else { return }
            let url = self.fileURL
            Self.writeQueue.async { Self.write(data, to: url) }
            self.scheduleCloudSave()
        }
    }

    /// Writes pending changes synchronously.
    func flush() { writeNow() }

    private func writeNow() {
        rebuildMerged()
        saveTask?.cancel()
        saveTask = nil
        guard let data = snapshotData() else { return }
        let url = fileURL
        Self.writeQueue.sync { Self.write(data, to: url) }
        writeCloud(synchronously: true)
    }

    /// The synced file changes on every encode start and finish; a longer
    /// debounce than the local file keeps iCloud uploads down.
    private func scheduleCloudSave() {
        guard isSyncEnabled, cloudSaveTask == nil else { return }
        cloudSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.cloudSaveTask = nil
            self.writeCloud(synchronously: false)
        }
    }

    /// Writes this Mac's file in the sync folder (atomically, on the write queue).
    private func writeCloud(synchronously: Bool) {
        cloudSaveTask?.cancel()
        cloudSaveTask = nil
        guard isSyncEnabled else { return }
        guard let directory = syncDirectory else {
            syncErrorMessage = SettingsSyncService.SyncError.locationUnavailable.localizedDescription
            return
        }
        let file = HistorySyncFolder.makeFile(
            records: records, sessions: sessions, rollups: rollups,
            deviceID: deviceID, deviceName: deviceName, now: Date()
        )
        guard let data = try? Self.encoder.encode(file) else { return }
        let url = HistorySyncFolder.fileURL(in: directory, deviceID: deviceID)
        if synchronously {
            let message = Self.writeQueue.sync { Self.write(data, to: url) }
            if syncErrorMessage != message { syncErrorMessage = message }
        } else {
            Self.writeQueue.async { [weak self] in
                let message = Self.write(data, to: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isSyncEnabled, self.syncErrorMessage != message else { return }
                        self.syncErrorMessage = message
                    }
                }
            }
        }
    }

    nonisolated static let writeQueue = DispatchQueue(label: "com.aagedal.MediaConverter.history-writes", qos: .utility)

    /// Returns the error message when the write failed.
    @discardableResult
    nonisolated private static func write(_ data: Data, to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            logger.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
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
