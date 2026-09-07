// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import AppKit
import OSLog

/// Where the settings-sync snapshot file lives.
enum SettingsSyncLocationMode: String, CaseIterable, Identifiable {
    /// A file inside the user's iCloud Drive folder on disk
    /// (`~/Library/Mobile Documents/com~apple~CloudDocs/…`), synced by the OS.
    case iCloudDrive
    /// A user-chosen folder (e.g. a Dropbox or network share).
    case customFolder

    var id: String { rawValue }
}

/// Keeps an allowlisted slice of `UserDefaults` in two-way sync with a single
/// JSON snapshot file, and powers manual export/import of the same format.
///
/// "iCloud sync" here means writing into the iCloud Drive folder on disk — this
/// is a non-App-Store, non-sandboxed build, so Apple's iCloud entitlement APIs
/// (`NSUbiquitousKeyValueStore`, ubiquity containers, CloudKit) aren't available.
/// Writing to the CloudDocs path lets the system iCloud daemon do the syncing
/// with no entitlement required.
@MainActor
@Observable
final class SettingsSyncService {
    static let shared = SettingsSyncService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "SettingsSync")
    private let defaults = UserDefaults.standard

    // MARK: - Observable state (read by SyncSettingsView)

    private(set) var syncEnabled: Bool
    private(set) var locationMode: SettingsSyncLocationMode
    private(set) var customFolderPath: String?
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?

    /// Whether the iCloud Drive folder exists on this Mac (iCloud Drive turned on).
    var isICloudDriveAvailable: Bool { iCloudDriveBaseURL != nil }

    // MARK: - Private sync bookkeeping

    /// `true` while we are writing imported keys back into `UserDefaults`, so the
    /// change observer doesn't bounce them straight back out to the file.
    private var isApplyingRemote = false
    /// `modifiedAt` of the snapshot this Mac last wrote or applied. Anything with a
    /// newer timestamp on disk is a genuine remote change worth importing.
    private var lastAppliedModifiedAt: Date?
    /// The `defaults` payload we last wrote, used to skip no-op rewrites triggered
    /// by unrelated `UserDefaults` churn.
    private var lastWrittenDefaults: [String: JSONValue]?
    /// A snapshot that exists but could not be validated must not be replaced by
    /// a local-change debounce or the write half of "Sync Now".
    private var protectedUnreadableSnapshotURL: URL?

    private var writeDebounce: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?
    private var monitoringErrorMessage: String?

    private static let writeDebounceInterval: TimeInterval = 2.0

    // MARK: - Init

    private init() {
        syncEnabled = defaults.bool(forKey: AppConstants.settingsSyncEnabledKey)
        let modeRaw = defaults.string(forKey: AppConstants.settingsSyncLocationModeKey)
        locationMode = SettingsSyncLocationMode(rawValue: modeRaw ?? "") ?? .iCloudDrive
        customFolderPath = defaults.string(forKey: AppConstants.settingsSyncCustomFolderPathKey)
        if let stored = defaults.object(forKey: AppConstants.lastSettingsSyncDateKey) as? Date {
            lastAppliedModifiedAt = stored
            lastSyncDate = stored
        }

        observeLocalChanges()
        observeAppActivation()

        if syncEnabled {
            startMonitoring()
            // Pull anything newer that synced in while we were closed.
            checkForRemoteChanges()
        }
    }

    /// No-op accessor so `Aagedal_Media_Converter_App.init()` can force the
    /// singleton (and its observers) to come alive at launch.
    func activate() {}

    // MARK: - Public configuration API

    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != syncEnabled else { return }
        syncEnabled = enabled
        defaults.set(enabled, forKey: AppConstants.settingsSyncEnabledKey)
        lastErrorMessage = nil

        if enabled {
            reconcileOnEnable()
            startMonitoring()
        } else {
            stopMonitoring()
            cancelPendingWrite()
        }
    }

    func setLocationMode(_ mode: SettingsSyncLocationMode) {
        guard mode != locationMode else { return }
        locationMode = mode
        defaults.set(mode.rawValue, forKey: AppConstants.settingsSyncLocationModeKey)
        guard syncEnabled else { return }
        // Re-point monitoring and reconcile against the new location.
        stopMonitoring()
        reconcileOnEnable()
        startMonitoring()
    }

    /// Records the user's chosen custom sync folder and (if sync is on and the
    /// custom mode is active) reconciles against it.
    func setCustomFolder(_ url: URL) {
        _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
        customFolderPath = url.path
        defaults.set(url.path, forKey: AppConstants.settingsSyncCustomFolderPathKey)
        guard syncEnabled, locationMode == .customFolder else { return }
        stopMonitoring()
        reconcileOnEnable()
        startMonitoring()
    }

    /// Manual push + pull for the "Sync Now" button.
    func syncNow() {
        guard syncEnabled else { return }
        checkForRemoteChanges()
        writeSnapshot()
    }

    // MARK: - Manual export / import (any file, independent of sync state)

    func exportSnapshot(to url: URL) throws {
        let snapshot = makeSnapshot(modifiedAt: Date())
        let data = try Self.makeEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Imports a snapshot from an arbitrary file (manual "Import Settings…").
    @discardableResult
    func importSnapshot(from url: URL, notify: Bool) throws -> SettingsSnapshot {
        let snapshot = try readSnapshot(at: url)
        apply(snapshot, notify: notify)
        return snapshot
    }

    // MARK: - Snapshot construction

    private func makeSnapshot(modifiedAt: Date) -> SettingsSnapshot {
        var captured: [String: JSONValue] = [:]
        for key in SettingsSyncKeys.all {
            guard let raw = defaults.object(forKey: key) else { continue }
            if let value = JSONValue.from(raw) {
                captured[key] = value
            }
        }
        return SettingsSnapshot(defaults: captured, modifiedAt: modifiedAt)
    }

    /// Writes the snapshot's allowlisted keys back into `UserDefaults`, then
    /// refreshes the UI. Guarded so it doesn't trigger a write-back loop.
    private func apply(_ snapshot: SettingsSnapshot, notify: Bool) {
        // Preserve the current local settings before we overwrite them, so a bad
        // remote/imported snapshot can always be recovered from a backup.
        backupCurrentSettings()
        isApplyingRemote = true
        for (key, value) in snapshot.defaults {
            // Defensive: never write a key that isn't on the allowlist, even if a
            // hand-edited file contains one.
            guard SettingsSyncKeys.all.contains(key) else { continue }
            if case .null = value {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(value.propertyListValue, forKey: key)
            }
        }
        isApplyingRemote = false

        // Treat the applied payload as our baseline so the local-change observer
        // doesn't immediately rewrite the file.
        lastWrittenDefaults = snapshot.defaults
        lastAppliedModifiedAt = snapshot.modifiedAt
        persistLastSyncDate(snapshot.modifiedAt)

        // Refresh derived UI state.
        PresetManager.shared.reloadVisibilitySettings()
        PresetManager.shared.reloadCustomPresetNames()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)

        if notify {
            NotificationCenter.default.post(
                name: .settingsSyncedFromRemote,
                object: nil,
                userInfo: ["deviceName": snapshot.deviceName]
            )
        }
    }

    // MARK: - Writing (local → file)

    private func observeLocalChanges() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.syncEnabled, !self.isApplyingRemote else { return }
                self.scheduleWrite()
            }
        }
    }

    private func scheduleWrite() {
        writeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeSnapshot() }
        }
        writeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounceInterval, execute: work)
    }

    private func cancelPendingWrite() {
        writeDebounce?.cancel()
        writeDebounce = nil
    }

    private func writeSnapshot() {
        guard syncEnabled else { return }
        guard let fileURL = snapshotFileURL() else {
            // Most commonly: iCloud Drive turned off. Surface it instead of failing
            // silently; writes resume automatically once the location returns.
            lastErrorMessage = SyncError.locationUnavailable.localizedDescription
            return
        }
        guard protectedUnreadableSnapshotURL?.standardizedFileURL != fileURL.standardizedFileURL else {
            return
        }
        // Do not seed over an iCloud placeholder while the remote snapshot is
        // still downloading. The directory monitor will retry after it arrives.
        guard !hasUndownloadedICloudFile(fileURL) else { return }
        let snapshot = makeSnapshot(modifiedAt: Date())
        // Never clobber a good file with an empty snapshot — that only happens via
        // a bug, and a remote copy could otherwise be wiped out.
        guard !snapshot.defaults.isEmpty else { return }
        // Skip if nothing the allowlist cares about actually changed.
        if let previous = lastWrittenDefaults, previous == snapshot.defaults { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            lastWrittenDefaults = snapshot.defaults
            lastAppliedModifiedAt = snapshot.modifiedAt
            persistLastSyncDate(snapshot.modifiedAt)
            lastSyncDate = snapshot.modifiedAt
            lastErrorMessage = monitoringErrorMessage
        } catch {
            lastErrorMessage = error.localizedDescription
            logger.error("Failed to write settings snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading (file → local)

    private func checkForRemoteChanges() {
        guard syncEnabled, !isApplyingRemote, let fileURL = snapshotFileURL() else { return }
        ensureDownloaded(fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            protectedUnreadableSnapshotURL = nil
            return
        }
        let snapshot: SettingsSnapshot
        do {
            snapshot = try readSnapshot(at: fileURL)
        } catch {
            reportSnapshotReadFailure(error, at: fileURL)
            return
        }
        protectedUnreadableSnapshotURL = nil
        lastErrorMessage = monitoringErrorMessage
        // Newest-wins: only import a strictly newer snapshot. This also filters out
        // our own writes (whose timestamp we record in lastAppliedModifiedAt).
        if let applied = lastAppliedModifiedAt, snapshot.modifiedAt <= applied { return }
        apply(snapshot, notify: true)
        lastSyncDate = snapshot.modifiedAt
    }

    /// If iCloud has only a placeholder on disk, request the real file and report
    /// download failures. This is a no-op for plain (non-iCloud) folders.
    private func ensureDownloaded(_ fileURL: URL) {
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              hasUndownloadedICloudFile(fileURL) else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        } catch {
            lastErrorMessage = SyncError.downloadFailed(error.localizedDescription).localizedDescription
            logger.error("Failed to download settings snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `true` when iCloud has a remote snapshot for `fileURL` that hasn't been
    /// downloaded to this Mac yet (only the `.<name>.icloud` placeholder exists).
    private func hasUndownloadedICloudFile(_ fileURL: URL) -> Bool {
        let placeholder = fileURL.deletingLastPathComponent()
            .appendingPathComponent("." + fileURL.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// On first enabling (or switching location), pull a newer remote snapshot if
    /// one exists, otherwise seed the file from the current local settings.
    private func reconcileOnEnable() {
        guard let fileURL = snapshotFileURL() else {
            lastErrorMessage = SyncError.locationUnavailable.localizedDescription
            return
        }
        ensureDownloaded(fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let snapshot = try readSnapshot(at: fileURL)
                apply(snapshot, notify: true)
                lastSyncDate = snapshot.modifiedAt
                protectedUnreadableSnapshotURL = nil
                lastErrorMessage = monitoringErrorMessage
            } catch {
                // Preserve the existing file. Treating a malformed or temporarily
                // unreadable snapshot as "missing" would let writeSnapshot() replace
                // the only remote copy with this Mac's settings.
                reportSnapshotReadFailure(error, at: fileURL)
            }
        } else if hasUndownloadedICloudFile(fileURL) {
            // A remote snapshot exists but hasn't downloaded yet. Don't seed over
            // it — wait for the download; the directory monitor and app-activation
            // re-check will import it once it lands.
            return
        } else {
            protectedUnreadableSnapshotURL = nil
            writeSnapshot()
        }
    }

    // MARK: - File-system monitoring

    private func startMonitoring() {
        stopMonitoring()
        guard let fileURL = snapshotFileURL() else {
            lastErrorMessage = SyncError.locationUnavailable.localizedDescription
            return
        }
        let fd: Int32
        do {
            fd = try Self.openMonitoringDirectory(fileURL.deletingLastPathComponent())
        } catch {
            monitoringErrorMessage = error.localizedDescription
            lastErrorMessage = monitoringErrorMessage
            logger.error("Failed to monitor settings folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkForRemoteChanges() }
        }
        // Cancellation is asynchronous. Close this source's descriptor, never a
        // shared property that may already belong to a replacement monitor.
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
    }

    /// Creates the sync folder and opens it for monitoring. Kept independent of
    /// service state so filesystem failures can be tested without user defaults.
    nonisolated static func openMonitoringDirectory(_ directory: URL) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return fd
        } catch {
            throw SyncError.monitoringFailed(error.localizedDescription)
        }
    }

    private func stopMonitoring() {
        if lastErrorMessage == monitoringErrorMessage { lastErrorMessage = nil }
        monitoringErrorMessage = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.syncEnabled else { return }
                // If the location came back (e.g. iCloud Drive re-enabled) after
                // the monitor was torn down, re-establish it and seed/pull as needed.
                if self.directorySource == nil, self.snapshotFileURL() != nil {
                    self.lastErrorMessage = nil
                    self.reconcileOnEnable()
                    self.startMonitoring()
                }
                self.checkForRemoteChanges()
            }
        }
    }

    // MARK: - Location resolution

    /// The resolved snapshot file URL for the active location, or `nil` if the
    /// location isn't usable yet (iCloud Drive off, or no custom folder chosen).
    func snapshotFileURL() -> URL? {
        switch locationMode {
        case .iCloudDrive:
            guard let base = iCloudDriveBaseURL else { return nil }
            return base
                .appendingPathComponent(AppConstants.settingsSyncFolderName, isDirectory: true)
                .appendingPathComponent(AppConstants.settingsSyncFileName)
        case .customFolder:
            guard let path = customFolderPath, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(AppConstants.settingsSyncFileName)
        }
    }

    private var iCloudDriveBaseURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? url : nil
    }

    // MARK: - Local backups (corruption / bad-overwrite safety net)

    /// How many timestamped backups to keep before pruning the oldest.
    private static let maxBackups = 10

    /// Local (never-synced) folder holding rolling snapshots of past settings, so
    /// a corrupted file or a bad overwrite can be recovered via manual import.
    private var backupsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("SettingsBackups", isDirectory: true)
    }

    /// Snapshots the *current* local settings into a rolling local backup. Called
    /// before any apply() so the pre-change state is always recoverable.
    private func backupCurrentSettings() {
        let snapshot = makeSnapshot(modifiedAt: Date())
        guard !snapshot.defaults.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            // timeIntervalSinceReferenceDate gives a sortable, collision-resistant name.
            let stamp = String(format: "%018.3f", Date().timeIntervalSinceReferenceDate)
            let url = backupsDirectory.appendingPathComponent("settings-\(stamp).json")
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            pruneBackups()
        } catch {
            logger.error("Failed to write settings backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneBackups() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let backups = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for stale in backups.dropFirst(Self.maxBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Opens the local backups folder in Finder so the user can recover a past
    /// settings file via "Import Settings…".
    func revealBackupsInFinder() throws {
        do {
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(backupsDirectory) else {
                throw SyncError.backupsOpenFailed
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            logger.error("Failed to open settings backups: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Whether the active sync location is currently usable (iCloud Drive on, or a
    /// custom folder chosen).
    var isLocationAvailable: Bool { snapshotFileURL() != nil }

    // MARK: - Helpers

    private func persistLastSyncDate(_ date: Date) {
        defaults.set(date, forKey: AppConstants.lastSettingsSyncDateKey)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Decodes and validates the portable settings format without applying it.
    /// Kept internal so format failures can be covered without mutating user defaults.
    nonisolated static func decodeSnapshot(_ data: Data) throws -> SettingsSnapshot {
        let snapshot: SettingsSnapshot
        do {
            snapshot = try makeDecoder().decode(SettingsSnapshot.self, from: data)
        } catch {
            throw SyncError.invalidFile
        }
        guard snapshot.schemaVersion <= SettingsSnapshot.currentSchemaVersion else {
            throw SyncError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    private func readSnapshot(at url: URL) throws -> SettingsSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SyncError.fileReadFailed(error.localizedDescription)
        }
        return try Self.decodeSnapshot(data)
    }

    private func reportSnapshotReadFailure(_ error: Error, at url: URL) {
        protectedUnreadableSnapshotURL = url
        lastErrorMessage = error.localizedDescription
        logger.error("Failed to read settings snapshot: \(error.localizedDescription, privacy: .public)")
    }

    enum SyncError: LocalizedError {
        case unsupportedSchema(Int)
        case locationUnavailable
        case invalidFile
        case fileReadFailed(String)
        case monitoringFailed(String)
        case downloadFailed(String)
        case backupsOpenFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return String(
                    localized: "This settings file (format \(version)) was created by a newer version of the app. Update to import it.",
                    comment: "Settings sync import error."
                )
            case .locationUnavailable:
                return String(
                    localized: "The sync location isn't available. Turn on iCloud Drive or choose a custom folder.",
                    comment: "Settings sync location error."
                )
            case .invalidFile:
                return String(
                    localized: "The settings file is damaged or isn't a valid Aagedal Media Converter settings file. Choose another file or restore a backup.",
                    comment: "Settings sync import error for malformed JSON or an invalid settings snapshot."
                )
            case .monitoringFailed(let details):
                return String(
                    localized: "The settings sync folder couldn't be monitored. Check folder access or choose another sync location: \(details)",
                    comment: "Settings sync monitoring error followed by the filesystem diagnostic."
                )
            case .downloadFailed(let details):
                return String(
                    localized: "The settings file couldn't be downloaded from iCloud Drive. Check your connection and try Sync Now again: \(details)",
                    comment: "Settings sync download error followed by the iCloud diagnostic."
                )
            case .backupsOpenFailed:
                return String(
                    localized: "The settings backups folder couldn't be opened in Finder. Try again.",
                    comment: "Settings sync backup folder reveal error."
                )
            case .fileReadFailed(let details):
                return String(
                    localized: "The settings file couldn't be read: \(details)",
                    comment: "Settings sync read error followed by the filesystem diagnostic."
                )
            }
        }
    }
}
