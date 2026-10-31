// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// A watch-folder file that has been seen but not imported yet, for the toolbar's status list.
struct WatchFolderPendingFile: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Size or modification date changed since the previous scan.
        case copying
        /// Unchanged, waiting out the settling time (`readyAt` when known).
        case settling
        /// Stable; checking that the file can be read.
        case checking
        /// Stable but not readable yet; retried automatically.
        case unreadable
    }

    let url: URL
    /// Path below the watch folder, e.g. "Card 1/C0001.MP4".
    let relativePath: String
    let size: Int64
    let state: State
    let readyAt: Date?

    var id: URL { url }
}

/// Manages watch folder monitoring with file growth detection
actor WatchFolderManager {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WatchFolder")

    private var monitorTask: Task<Void, Never>?
    private var trackedFiles: [URL: WatchFolderObservation] = [:]
    private var isMonitoring = false
    private var monitoringGeneration: UInt64 = 0
    private var reportedFailures = WatchFolderFailureTracker()
    private let defaults: UserDefaults
    private let trashItem: @Sendable (URL) throws -> Void
    private let settlingInterval: TimeInterval?
    private let readinessProbe: @Sendable (URL) async -> Bool
    private let now: @Sendable () -> Date
    /// Test override; production waits for file-system events with a polling fallback.
    private let pollingWait: (@Sendable () async throws -> Void)?

    private let readResourceValues: @Sendable (URL) throws -> URLResourceValues

    /// Loaded on first use and kept across stop/start, so neither toggling watch mode nor a
    /// relaunch re-imports files already handled.
    private let historyStore: WatchFolderImportHistoryStore
    private var importLedger: WatchFolderImportLedger?
    private var ledgerNeedsSave = false

    private var eventSource: WatchFolderEventSource?
    /// FSEvents misses changes made on network volumes by other machines; poll those often.
    private var folderIsLocal = false
    private var pendingFiles: [WatchFolderPendingFile] = []
    private var unreadableFiles: Set<URL> = []
    private var onPendingFilesChanged: @Sendable ([WatchFolderPendingFile]) -> Void = { _ in }

    init(
        defaults: UserDefaults = .standard,
        settlingInterval: TimeInterval? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        readinessProbe: @escaping @Sendable (URL) async -> Bool = { url in
            switch await VideoFileUtils.fetchVideoMetadataWithFallback(for: url) {
            case .full, .essentialOnly: return true
            case .failed, .cancelled: return false
            }
        },
        trashItem: @escaping @Sendable (URL) throws -> Void = { try FileSafetyUtils.trashWatchFolderItem($0) },
        pollingWait: (@Sendable () async throws -> Void)? = nil,
        readResourceValues: @escaping @Sendable (URL) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        },
        historyStore: WatchFolderImportHistoryStore = .inMemory
    ) {
        self.defaults = defaults
        self.settlingInterval = settlingInterval
        self.now = now
        self.readinessProbe = readinessProbe
        self.trashItem = trashItem
        self.pollingWait = pollingWait
        self.readResourceValues = readResourceValues
        self.historyStore = historyStore
    }

    /// Replaces monitoring atomically; late commands from older sessions are ignored.
    func startMonitoring(
        folderPath: String,
        generation: UInt64,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        protectedFiles: @escaping @MainActor @Sendable () -> Set<URL> = { [] },
        excludedFolders: @escaping @MainActor @Sendable () -> Set<URL> = { [] },
        onPendingFilesChanged: @escaping @Sendable ([WatchFolderPendingFile]) -> Void = { _ in },
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        guard generation >= monitoringGeneration, !Task.isCancelled else { return }
        stopMonitoring(generation: generation)

        isMonitoring = true
        self.onPendingFilesChanged = onPendingFilesChanged
        Self.logger.info("Starting watch folder monitoring: \(folderPath, privacy: .public)")

        let wait: @Sendable () async throws -> Void
        if let pollingWait {
            wait = pollingWait
        } else {
            let signal = WatchFolderWakeSignal()
            let resolved = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath()
            eventSource = WatchFolderEventSource(path: resolved.path) {
                Task { await signal.signal() }
            }
            folderIsLocal = (try? resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
            if eventSource == nil {
                Self.logger.warning("File-system events unavailable for watch folder; polling instead")
            }
            wait = { [weak self] in
                let interval = await self?.nextScanDelay() ?? 5
                await signal.wait(timeout: .seconds(interval))
                try Task.checkCancellation()
            }
        }

        monitorTask = Task { [weak self] in
            await WatchFolderPollingLoop.run(wait: wait) { [weak self] in
                guard let self else { return false }
                return await self.scanIfMonitoring(
                    folderPath: folderPath, protectedFiles: protectedFiles,
                    excludedFolders: excludedFolders, onNewFiles: onNewFiles, onError: onError
                )
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring(generation: UInt64) {
        guard generation >= monitoringGeneration else { return }
        monitoringGeneration = generation
        Self.logger.info("Stopping watch folder monitoring")
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        eventSource?.stop()
        eventSource = nil
        trackedFiles.removeAll()
        unreadableFiles.removeAll()
        reportedFailures = WatchFolderFailureTracker()
        if !pendingFiles.isEmpty {
            pendingFiles = []
            onPendingFilesChanged([])
        }
        onPendingFilesChanged = { _ in }
        saveLedgerIfNeeded()
    }

    /// Wake up soon while files are settling, otherwise rely on file-system events and
    /// fall back to polling (frequently on network volumes, which report no remote changes).
    private func nextScanDelay() -> Double {
        let current = now()
        var delay = eventSource != nil && folderIsLocal ? 30.0 : 5.0
        for file in pendingFiles {
            switch file.state {
            case .copying, .checking:
                delay = min(delay, 2)
            case .settling:
                let untilReady = file.readyAt.map { $0.timeIntervalSince(current) + 0.25 } ?? 2
                delay = min(delay, max(1, min(5, untilReady)))
            case .unreadable:
                delay = min(delay, 5)
            }
        }
        return delay
    }

    /// Scan the folder and detect stable files (not growing)
    private func scanIfMonitoring(
        folderPath: String,
        protectedFiles: @escaping @MainActor @Sendable () -> Set<URL>,
        excludedFolders: @escaping @MainActor @Sendable () -> Set<URL>,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        // Check on the manager actor, after the polling task's actor hop: Stop
        // may have cancelled an older task and started a replacement meanwhile.
        guard isMonitoring, !Task.isCancelled else { return false }
        await scanFolder(
            folderPath: folderPath, protectedFiles: protectedFiles,
            excludedFolders: excludedFolders, onNewFiles: onNewFiles, onError: onError
        )
        return true
    }

    private func scanFolder(
        folderPath: String,
        protectedFiles: @escaping @MainActor @Sendable () -> Set<URL>,
        excludedFolders: @escaping @MainActor @Sendable () -> Set<URL>,
        onNewFiles: @escaping @Sendable ([URL]) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async {
        let generation = monitoringGeneration
        let folderURL = URL(fileURLWithPath: folderPath)
        var ledger = loadLedger()
        defer { saveLedgerIfNeeded() }

        // Restore the selected folder grant before enumeration. Report access
        // failures through the same recovery path as disconnected drives.
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: folderURL)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        let includeSubfolders = defaults.bool(forKey: AppConstants.watchFolderIncludeSubfoldersKey)
        let excluded = includeSubfolders ? await excludedFolders() : []
        guard monitoringGeneration == generation, !Task.isCancelled else { return }

        let listing: WatchFolderListing
        do {
            listing = includeSubfolders
                ? try WatchFolderDirectoryContents.listRecursively(in: folderURL, excluding: excluded)
                : WatchFolderListing(urls: try WatchFolderDirectoryContents.list(in: folderURL), isComplete: true)
        } catch {
            // Lost visibility breaks every stability streak. After recovery,
            // require two successful observations before importing any file.
            trackedFiles.removeAll()
            Self.logger.error("Failed to enumerate watch folder \(folderPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if reportedFailures.shouldReportScanFailure() {
                onError(String(localized: "The watch folder could not be scanned. Reconnect its drive or select the folder again in Settings. Monitoring will retry automatically. \(error.localizedDescription)"))
            }
            return
        }
        let fileURLs = listing.urls
        reportedFailures.scanSucceeded(currentFiles: Set(fileURLs))
        unreadableFiles.formIntersection(fileURLs)
        var cleanupFailures: [String] = []
        var metadataFailures: [String] = []
        var metadataFailureCount = 0
        defer {
            if metadataFailureCount > 0 {
                var detail = metadataFailures.joined(separator: "\n")
                if metadataFailureCount > metadataFailures.count {
                    detail += "\n" + String(localized: "Additional files affected: \(metadataFailureCount - metadataFailures.count)")
                }
                onError(String(localized: "Some watch-folder files could not be inspected. Check their permissions or reconnect the drive. Monitoring will retry automatically. \(detail)"))
            }
            if !cleanupFailures.isEmpty {
                let detail = cleanupFailures.joined(separator: "\n")
                onError(String(localized: "Some old watch-folder files could not be moved to Trash. Check folder permissions or select the folder again in Settings. Cleanup will retry automatically. \(detail)"))
            }
        }

        let settings = loadDurationSettings()
        // Old watch-folder bookmarks may carry read-only grants. A bookmark cannot
        // upgrade its own sandbox permission: require a fresh user selection before
        // cleanup, while leaving ordinary monitoring available.
        let cleanupNeedsRenewal = settings.deleteEnabled && WatchFolderSelectionService.cleanupAccessNeedsRenewal(for: folderPath, defaults: defaults)
        if cleanupNeedsRenewal {
            if reportedFailures.shouldReportCleanupAccessFailure() {
                onError(String(localized: "Automatic cleanup needs renewed folder access. Select Renew Access in Watch Folder Settings and select the folder again. Monitoring continues; cleanup will resume after selection."))
            }
        } else {
            reportedFailures.cleanupAccessSucceeded()
        }
        let now = now()
        let interval = settlingInterval ?? WatchFolderObservation.settlingInterval(defaults: defaults)
        var currentFiles: [URL: WatchFolderObservation] = [:]
        var stableFiles: [URL] = []
        var pending: [URL: WatchFolderPendingFile] = [:]
        var alreadyImported: [URL] = []

        for fileURL in fileURLs {
            guard AppConstants.supportedVideoExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            let resourceValues: URLResourceValues
            let fileSize: Int
            do {
                resourceValues = try readResourceValues(fileURL)
                // Directories and other non-regular entries are intentionally skipped.
                if resourceValues.isRegularFile == false {
                    reportedFailures.metadataSucceeded(for: fileURL)
                    continue
                }
                guard resourceValues.isRegularFile == true,
                      let size = resourceValues.fileSize, size >= 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
                fileSize = size
                reportedFailures.metadataSucceeded(for: fileURL)
            } catch {
                if reportedFailures.shouldReportMetadataFailure(for: fileURL) {
                    Self.logger.error("Failed to inspect watch folder file \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    metadataFailureCount += 1
                    if metadataFailures.count < 5 {
                        metadataFailures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                // Failed observations must break the stability streak. A recovered
                // file needs two successful scans before it can be imported.
                continue
            }

            let previous = trackedFiles[fileURL]
            let observation = WatchFolderObservation(
                size: Int64(fileSize), modifiedAt: resourceValues.contentModificationDate,
                observedAt: now, previous: previous
            )
            currentFiles[fileURL] = observation
            let isStable = observation.isStable(at: now, interval: interval)
            let relevantDate = resourceValues.addedToDirectoryDate ?? resourceValues.creationDate ?? resourceValues.contentModificationDate ?? now
            let fileAge = now.timeIntervalSince(relevantDate)

            if settings.deleteEnabled, let deleteThreshold = settings.deleteThreshold, fileAge > deleteThreshold {
                guard !cleanupNeedsRenewal, isStable else { continue }
                do {
                    let trashItem = trashItem
                    let readResourceValues = readResourceValues
                    // Queue protection and the move share one main-actor turn, so
                    // a newly queued source cannot race the cleanup decision.
                    let trashed = try await MainActor.run {
                        guard !Task.isCancelled else { return false }
                        let protectedPaths = Set(protectedFiles().map {
                            $0.resolvingSymlinksInPath().standardizedFileURL
                        })
                        guard !protectedPaths.contains(fileURL.resolvingSymlinksInPath().standardizedFileURL) else { return false }
                        let latest = try readResourceValues(fileURL)
                        guard latest.isRegularFile == true, latest.fileSize == fileSize,
                              latest.contentModificationDate == resourceValues.contentModificationDate else { return false }
                        try trashItem(fileURL)
                        return true
                    }
                    guard monitoringGeneration == generation, !Task.isCancelled else { return }
                    guard trashed else { continue }
                    currentFiles.removeValue(forKey: fileURL)
                    reportedFailures.cleanupSucceeded(for: fileURL)
                    if let description = settings.deleteDescription {
                        Self.logger.info("Trashed watch folder file older than \(description, privacy: .public): \(fileURL.lastPathComponent, privacy: .public)")
                    } else {
                        Self.logger.info("Trashed watch folder file exceeding delete threshold: \(fileURL.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    Self.logger.error("Failed to trash old watch folder file \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if reportedFailures.shouldReportCleanupFailure(for: fileURL), cleanupFailures.count < 5 {
                        cleanupFailures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                currentFiles.removeValue(forKey: fileURL)
                continue
            }

            if settings.ignoreEnabled, let ignoreThreshold = settings.ignoreThreshold, fileAge > ignoreThreshold {
                if let description = settings.ignoreDescription {
                    Self.logger.info("Ignoring watch folder file older than \(description, privacy: .public): \(fileURL.lastPathComponent, privacy: .public)")
                } else {
                    Self.logger.info("Ignoring watch folder file exceeding ignore threshold: \(fileURL.lastPathComponent, privacy: .public)")
                }
                currentFiles.removeValue(forKey: fileURL)
                continue
            }

            // Already imported (or already queued) in this form: a rewrite or replacement
            // changes size or date and is imported again.
            if ledger.contains(fileURL, size: observation.size, modifiedAt: observation.modifiedAt) {
                alreadyImported.append(fileURL)
                continue
            }
            if isStable {
                stableFiles.append(fileURL)
            } else {
                let isChanging = previous != nil && !observation.hasPreviousObservation
                pending[fileURL] = WatchFolderPendingFile(
                    url: fileURL, relativePath: Self.relativePath(of: fileURL, in: folderURL),
                    size: observation.size, state: isChanging ? .copying : .settling,
                    readyAt: observation.hasPreviousObservation ? observation.unchangedSince.addingTimeInterval(interval) : nil
                )
            }
        }

        // Update tracked files
        trackedFiles = currentFiles

        if ledger.markSeen(alreadyImported, at: now) { ledgerNeedsSave = true }
        // An unreadable subfolder hides its files; don't let their entries expire meanwhile.
        if listing.isComplete,
           ledger.expire(retention: WatchFolderImportHistoryStore.retention(defaults: defaults), now: now) {
            ledgerNeedsSave = true
        }
        importLedger = ledger

        guard !stableFiles.isEmpty else {
            reportPending(pending, generation: generation)
            return
        }
        let protected = await protectedFiles()
        guard monitoringGeneration == generation, !Task.isCancelled else { return }
        let protectedPaths = Set(protected.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        var candidates: [URL] = []
        for url in stableFiles {
            if protectedPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL) {
                // Queued by hand (or an output of a queued item): removing it from the
                // queue later must not trigger an import.
                if let observation = trackedFiles[url] {
                    recordImported(url, observation: observation, at: now)
                }
            } else {
                candidates.append(url)
                pending[url] = WatchFolderPendingFile(
                    url: url, relativePath: Self.relativePath(of: url, in: folderURL),
                    size: trackedFiles[url]?.size ?? 0,
                    state: unreadableFiles.contains(url) ? .unreadable : .checking, readyAt: nil
                )
            }
        }
        reportPending(pending, generation: generation)

        let readinessProbe = readinessProbe
        // Probe a bounded number concurrently and publish healthy files as soon
        // as they are ready; one stalled parser must not delay every import.
        await withTaskGroup(of: (URL, Bool).self) { group in
            var remaining = candidates.makeIterator()
            for _ in 0..<4 {
                guard let url = remaining.next() else { break }
                group.addTask { (url, await readinessProbe(url)) }
            }
            while let (url, readable) = await group.next() {
                guard monitoringGeneration == generation, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if readable {
                    reportedFailures.readinessSucceeded(for: url)
                    unreadableFiles.remove(url)
                    pending.removeValue(forKey: url)
                    let latest = try? readResourceValues(url)
                    if let observation = trackedFiles[url],
                       latest?.isRegularFile == true,
                       latest?.fileSize.map(Int64.init) == observation.size,
                       latest?.contentModificationDate == observation.modifiedAt {
                        recordImported(url, observation: observation, at: now)
                        trackedFiles.removeValue(forKey: url)
                        onNewFiles([url])
                    } else {
                        // A probe may take time; restart settling if the source changed.
                        trackedFiles.removeValue(forKey: url)
                    }
                } else {
                    unreadableFiles.insert(url)
                    if let file = pending[url] {
                        pending[url] = WatchFolderPendingFile(
                            url: url, relativePath: file.relativePath, size: file.size, state: .unreadable, readyAt: nil
                        )
                    }
                    if reportedFailures.shouldReportReadinessFailure(for: url) {
                        onError(String(localized: "A watch-folder file could not be read yet. It will be retried automatically: \(url.lastPathComponent)"))
                    }
                }
                reportPending(pending, generation: generation)
                if let next = remaining.next() {
                    group.addTask { (next, await readinessProbe(next)) }
                }
            }
        }
    }

    func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }

    // MARK: - Import history

    private func loadLedger() -> WatchFolderImportLedger {
        var ledger = importLedger ?? historyStore.load()
        if applyForget(to: &ledger) {
            ledgerNeedsSave = true
        }
        importLedger = ledger
        return ledger
    }

    /// "Forget Imported Files" in Settings deletes the saved file and records when it was used.
    /// Dropping everything imported before then also covers a history that a scan running at
    /// that moment loaded earlier and wrote back afterwards.
    private func applyForget(to ledger: inout WatchFolderImportLedger) -> Bool {
        let clearedAt = defaults.double(forKey: AppConstants.watchFolderImportHistoryClearedAtKey)
        guard clearedAt > 0 else { return false }
        return ledger.forget(importedThrough: Date(timeIntervalSince1970: clearedAt))
    }

    private func recordImported(_ url: URL, observation: WatchFolderObservation, at date: Date) {
        var ledger = importLedger ?? WatchFolderImportLedger()
        ledger.record(url, size: observation.size, modifiedAt: observation.modifiedAt, at: date)
        importLedger = ledger
        ledgerNeedsSave = true
    }

    private func saveLedgerIfNeeded() {
        guard ledgerNeedsSave, var importLedger else { return }
        ledgerNeedsSave = false
        // Forget may have been used while this scan ran; never write the old history back.
        _ = applyForget(to: &importLedger)
        self.importLedger = importLedger
        historyStore.save(importLedger)
    }

    // MARK: - Pending status

    private func reportPending(_ pending: [URL: WatchFolderPendingFile], generation: UInt64) {
        guard monitoringGeneration == generation else { return }
        let sorted = pending.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        guard sorted != pendingFiles else { return }
        pendingFiles = sorted
        onPendingFilesChanged(sorted)
    }

    static func relativePath(of url: URL, in folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(folderPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(folderPath.count + 1))
    }
}

/// Files found in the watch folder. Incomplete when a subfolder could not be read.
struct WatchFolderListing {
    let urls: [URL]
    let isComplete: Bool
}

/// Enumerates a directory symlink's target while keeping child URLs beneath the
/// selected folder, so later import operations can find its saved bookmark.
enum WatchFolderDirectoryContents {
    static func list(in folder: URL, fileManager: FileManager = .default) throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.map { folder.appendingPathComponent($0.lastPathComponent) }
    }

    /// Lists files in the folder and all subfolders, skipping hidden items, package contents
    /// and `excluded` folders (e.g. an output folder inside the watch folder). Throws only
    /// when the folder itself cannot be read; unreadable subfolders mark the listing incomplete.
    static func listRecursively(
        in folder: URL,
        excluding excluded: Set<URL> = [],
        fileManager: FileManager = .default
    ) throws -> WatchFolderListing {
        let root = folder.resolvingSymlinksInPath()
        // Surface a missing or unreadable root the same way as the flat listing.
        _ = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        final class ErrorFlag: @unchecked Sendable { var failed = false }
        let errorFlag = ErrorFlag()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                errorFlag.failed = true
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let rootPath = root.standardizedFileURL.path
        let excludedPaths = Set(excluded.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .subtracting([rootPath])
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if excludedPaths.contains(path) { enumerator.skipDescendants() }
                continue
            }
            // Keep URLs beneath the selected (possibly symlinked) folder, like `list(in:)`.
            if path.hasPrefix(rootPath + "/") {
                urls.append(folder.appendingPathComponent(String(path.dropFirst(rootPath.count + 1))))
            } else {
                urls.append(url)
            }
        }
        return WatchFolderListing(urls: urls, isComplete: !errorFlag.failed)
    }
}

/// Each polling task owns its cancellation state, so a newer monitor cannot
/// reactivate an old task by changing the manager's shared monitoring flag.
enum WatchFolderPollingLoop {
    static func run(
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) },
        scan: @escaping @Sendable () async -> Bool
    ) async {
        while !Task.isCancelled {
            guard await scan(), !Task.isCancelled else { return }
            do { try await wait() }
            catch { return }
        }
    }
}

private extension WatchFolderManager {
    struct DurationSettings {
        var ignoreEnabled: Bool
        var ignoreThreshold: TimeInterval?
        var ignoreDescription: String?
        var deleteEnabled: Bool
        var deleteThreshold: TimeInterval?
        var deleteDescription: String?
    }
    
    func loadDurationSettings() -> DurationSettings {
        let ignoreEnabled = defaults.bool(forKey: AppConstants.watchFolderIgnoreOlderThan24hKey)
        let deleteEnabled = defaults.bool(forKey: AppConstants.watchFolderAutoDeleteOlderThanWeekKey)
        let ignoreValueRaw = defaults.object(forKey: AppConstants.watchFolderIgnoreDurationValueKey) as? NSNumber
        let ignoreValue: Int
        if let raw = ignoreValueRaw?.intValue, AppConstants.watchFolderDurationValues.contains(raw) {
            ignoreValue = raw
        } else {
            ignoreValue = AppConstants.defaultWatchFolderIgnoreDurationValue
        }
        let ignoreUnitRaw = defaults.string(forKey: AppConstants.watchFolderIgnoreDurationUnitKey) ?? AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
        let deleteValueRaw = defaults.object(forKey: AppConstants.watchFolderDeleteDurationValueKey) as? NSNumber
        let deleteValue: Int
        if let raw = deleteValueRaw?.intValue, AppConstants.watchFolderDurationValues.contains(raw) {
            deleteValue = raw
        } else {
            deleteValue = AppConstants.defaultWatchFolderDeleteDurationValue
        }
        let deleteUnitRaw = defaults.string(forKey: AppConstants.watchFolderDeleteDurationUnitKey) ?? AppConstants.defaultWatchFolderDeleteDurationUnitRaw
        let ignoreUnit = WatchFolderDurationUnit(rawValue: ignoreUnitRaw) ?? .hours
        let deleteUnit = WatchFolderDurationUnit(rawValue: deleteUnitRaw) ?? .days
        let ignoreThreshold: TimeInterval? = ignoreEnabled ? TimeInterval(ignoreValue) * ignoreUnit.secondsMultiplier : nil
        let deleteThreshold: TimeInterval? = deleteEnabled ? TimeInterval(deleteValue) * deleteUnit.secondsMultiplier : nil
        return DurationSettings(
            ignoreEnabled: ignoreEnabled,
            ignoreThreshold: ignoreThreshold,
            ignoreDescription: ignoreEnabled ? describeThreshold(value: ignoreValue, unit: ignoreUnit) : nil,
            deleteEnabled: deleteEnabled,
            deleteThreshold: deleteThreshold,
            deleteDescription: deleteEnabled ? describeThreshold(value: deleteValue, unit: deleteUnit) : nil
        )
    }
    
    func describeThreshold(value: Int, unit: WatchFolderDurationUnit) -> String {
        let unitName: String
        switch unit {
        case .minutes: unitName = value == 1 ? "minute" : "minutes"
        case .hours: unitName = value == 1 ? "hour" : "hours"
        case .days: unitName = value == 1 ? "day" : "days"
        }
        return "\(value) \(unitName)"
    }
}

/// Alerts once per continuous failure, while allowing a recovered operation to
/// report a later failure. Missing files no longer retain cleanup failure state.
struct WatchFolderFailureTracker {
    private var scanFailed = false
    private var cleanupAccessFailed = false
    private var cleanupFailures: Set<URL> = []
    private var metadataFailures: Set<URL> = []
    private var readinessFailures: Set<URL> = []

    mutating func shouldReportReadinessFailure(for url: URL) -> Bool {
        readinessFailures.insert(url).inserted
    }

    mutating func readinessSucceeded(for url: URL) {
        readinessFailures.remove(url)
    }

    mutating func shouldReportCleanupAccessFailure() -> Bool {
        defer { cleanupAccessFailed = true }
        return !cleanupAccessFailed
    }

    mutating func cleanupAccessSucceeded() {
        cleanupAccessFailed = false
    }

    mutating func shouldReportScanFailure() -> Bool {
        defer { scanFailed = true }
        return !scanFailed
    }

    mutating func scanSucceeded(currentFiles: Set<URL>) {
        scanFailed = false
        cleanupFailures.formIntersection(currentFiles)
        metadataFailures.formIntersection(currentFiles)
        readinessFailures.formIntersection(currentFiles)
    }

    mutating func shouldReportMetadataFailure(for url: URL) -> Bool {
        metadataFailures.insert(url).inserted
    }

    mutating func metadataSucceeded(for url: URL) {
        metadataFailures.remove(url)
    }

    mutating func shouldReportCleanupFailure(for url: URL) -> Bool {
        cleanupFailures.insert(url).inserted
    }

    mutating func cleanupSucceeded(for url: URL) {
        cleanupFailures.remove(url)
    }
}

/// A quiet interval must include unchanged size and modification time, with at
/// least two successful observations. Failed scans discard the previous observation.
struct WatchFolderObservation {
    let size: Int64
    let modifiedAt: Date?
    let unchangedSince: Date
    let hasPreviousObservation: Bool

    init(size: Int64, modifiedAt: Date?, observedAt: Date, previous: Self?) {
        self.size = size
        self.modifiedAt = modifiedAt
        let unchanged = previous?.size == size && previous?.modifiedAt == modifiedAt
        unchangedSince = unchanged ? (previous?.unchangedSince ?? observedAt) : observedAt
        hasPreviousObservation = unchanged
    }

    func isStable(at date: Date, interval: TimeInterval) -> Bool {
        size > 0 && hasPreviousObservation && date.timeIntervalSince(unchangedSince) >= interval
    }

    static func settlingInterval(defaults: UserDefaults) -> TimeInterval {
        let value = defaults.double(forKey: AppConstants.watchFolderSettlingSecondsKey)
        return AppConstants.watchFolderSettlingSecondsValues.map(Double.init).contains(value)
            ? value : AppConstants.defaultWatchFolderSettlingSeconds
    }
}
