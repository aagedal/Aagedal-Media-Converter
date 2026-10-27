// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import OSLog
import SwiftUI

/// Manages yt-dlp downloads and coordinates with the video queue
@MainActor
@Observable
class DownloadManager {
    static let shared: DownloadManager = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["AMC_UI_TEST_SESSION"] == "1",
           environment["AMC_UI_TEST_DAMAGED_SCHEDULES"] == "1",
           let defaults = UserDefaults(suiteName: "com.aagedal.MediaConverter.UITestSchedules") {
            defaults.removePersistentDomain(forName: "com.aagedal.MediaConverter.UITestSchedules")
            defaults.set(Data("Damaged UI test schedules".utf8), forKey: ScheduledDownloadStore.key)
            return DownloadManager(defaults: defaults)
        }
#endif
        return DownloadManager()
    }()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "DownloadManager")
    private let ytdlpService: YTDLPService
    private let ytdlpAvailability: Bool?
    private let scheduleStore: ScheduledDownloadStore

    /// Keep recovery visible until the user explicitly replaces unreadable saved schedules.
    private(set) var hasScheduledDownloadStorageError = false

    /// Active download tasks keyed by VideoItem ID
    private var downloadTasks: [UUID: (control: YTDLPDownloadControl, task: Task<Void, Never>)] = [:]

    /// Per-item subprocess cancellation, kept separate so concurrent downloads cannot
    /// stop whichever yt-dlp process happened to register most recently.
    private var downloadControls: [UUID: YTDLPDownloadControl] = [:]

    /// Sequential "Download all" playlist runs keyed by `VideoItem.playlistDownloadBatchID`.
    private var playlistBatchTasks: [UUID: Task<Void, Never>] = [:]

    /// Live recording stat update tasks keyed by VideoItem ID
    private var liveRecordingStatTasks: [UUID: Task<Void, Never>] = [:]
    private let thumbnailTasks = DownloadAuxiliaryTaskStore()
    private let detailsTasks = DownloadAuxiliaryTaskStore()
    private let detailsLoader: @Sendable (URL) async -> VideoFileUtils.VideoItemDetails

    /// Queue of video items (bound from ContentView)
    var videoItems: Binding<[VideoItem]>?

    /// Output folder for downloads
    var outputFolder: URL?

    /// Callback to trigger encoding for a specific item (set by ContentView)
    var onAutoEncode: ((UUID) -> Void)?

    init(defaults: UserDefaults = .standard, ytdlpService: YTDLPService = YTDLPService(), ytdlpAvailability: Bool? = nil, detailsLoader: @escaping @Sendable (URL) async -> VideoFileUtils.VideoItemDetails = {
        await VideoFileUtils.loadDetails(for: $0)
    }) {
        self.ytdlpService = ytdlpService
        self.ytdlpAvailability = ytdlpAvailability
        self.detailsLoader = detailsLoader
        self.scheduleStore = ScheduledDownloadStore(defaults: defaults)
    }

    /// Own post-download probes separately: the subprocess has already completed,
    /// but cancellation or a retry must still invalidate metadata and auto-encoding.
    @discardableResult
    func loadDownloadedFileDetails(
        itemID: UUID,
        fileURL: URL,
        autoEncode: Bool,
        section: DownloadSection? = nil,
        sourceDuration: Double? = nil
    ) -> Task<Void, Never> {
        let loader = detailsLoader
        return detailsTasks.start(itemID: itemID, timeout: .seconds(60)) {
            await loader(fileURL)
        } completion: { [weak self] result in
            guard let self, self.findItem(itemID)?.url == fileURL else { return }
            switch result {
            case .success(let details):
                self.updateItem(itemID) { item in
                    item.apply(details: details)
                    item.detailsLoaded = true
                    // Section downloads carry padding; trim to the exact requested range.
                    if let section {
                        let trim = section.trimRange(
                            fileDuration: details.durationSeconds, sourceDuration: sourceDuration
                        )
                        item.trimStart = trim.start
                        item.trimEnd = trim.end
                    }
                }
                if autoEncode {
                    self.onAutoEncode?(itemID)
                }
            case .failure(let error):
                self.logger.warning("Downloaded file details unavailable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Live Recording Stats

    /// Starts periodic updates of file size and duration for live stream recording
    private func startLiveRecordingStatUpdates(itemID: UUID, outputFolder: URL, control: YTDLPDownloadControl) {
        // Cancel any existing stat task for this item
        liveRecordingStatTasks[itemID]?.cancel()

        logger.info("[LiveStats] Starting live recording stat updates for item: \(itemID)")

        let task = Task {
            // Poll at 1s for the first minute (responsive feedback while the
            // recording spins up), then back off to 5s. For multi-hour live
            // recordings sub-second precision isn't useful and SwiftExif duration
            // reads on a growing file aren't free.
            let fastCadenceNanos: UInt64 = 1_000_000_000
            let slowCadenceNanos: UInt64 = 5_000_000_000
            let fastUpdateCount = 60

            var updateCount = 0
            while !Task.isCancelled {
                updateCount += 1

                // Read only the destination reported by this download.
                if let partialFile = control.partialFile(in: outputFolder) {
                    // Update file size. `--live-from-start` records each format to
                    // its own file until they are merged, so add them up.
                    let fileSizes = control.reportedFiles(in: outputFolder).compactMap {
                        (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64
                    }
                    if !fileSizes.isEmpty {
                        let fileSize = fileSizes.reduce(0, +)
                        // Log every 10 updates
                        if updateCount % 10 == 1 {
                            logger.info("[LiveStats] Update #\(updateCount): file size = \(fileSize) bytes")
                        }
                        updateItem(itemID) { item in
                            item.liveRecordingFileSize = fileSize
                        }
                    }

                    // Get duration from the partial file
                    let duration = await getDurationUsingFFprobe(for: partialFile)
                    guard !Task.isCancelled else { break }
                    if let duration = duration {
                        if updateCount % 10 == 1 {
                            logger.info("[LiveStats] Update #\(updateCount): duration = \(String(format: "%.1f", duration))s")
                        }
                        self.updateItem(itemID) { item in
                            item.liveRecordingDuration = duration
                        }
                    }
                } else if updateCount == 1 {
                    logger.info("[LiveStats] Update #\(updateCount): no partial file found yet")
                }

                let sleepNanos = updateCount < fastUpdateCount ? fastCadenceNanos : slowCadenceNanos
                try? await Task.sleep(nanoseconds: sleepNanos)
                guard !Task.isCancelled else { break }
            }
            logger.info("[LiveStats] Stat updates stopped for item: \(itemID)")
        }
        liveRecordingStatTasks[itemID] = task
    }

    /// Stops live recording stat updates for an item
    private func stopLiveRecordingStatUpdates(itemID: UUID) {
        liveRecordingStatTasks[itemID]?.cancel()
        liveRecordingStatTasks.removeValue(forKey: itemID)
    }

    /// Fetches thumbnail from yt-dlp metadata in parallel with download
    private func fetchThumbnailInBackground(itemID: UUID, urlString: String) {
        let service = ytdlpService
        thumbnailTasks.start(itemID: itemID, timeout: .seconds(30)) {
            let metadata = try await service.fetchMetadata(url: urlString)
            try Task.checkCancellation()
            var thumbnailData: Data?
            if let thumbnailURL = metadata.thumbnailURL {
                do {
                    let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
                    if let response = response as? HTTPURLResponse,
                       response.statusCode == 200, !data.isEmpty {
                        thumbnailData = data
                    }
                } catch {
                    try Task.checkCancellation()
                    // A failed optional image request still leaves a useful title.
                }
            }
            return DownloadThumbnailResult(title: metadata.title, data: thumbnailData)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let thumbnail):
                self.updateItem(itemID) { item in
                    if !thumbnail.title.isEmpty,
                       item.name == "Fetching info..." || item.name.isEmpty {
                        item.name = thumbnail.title
                    }
                    if let data = thumbnail.data {
                        item.thumbnailData = data
                    }
                }
            case .failure(let error):
                self.logger.info("Could not fetch thumbnail: \(error.localizedDescription)")
            }
        }
    }

    /// Gets the duration of a file via SwiftExif (AVFoundation fallback).
    private func getDurationUsingFFprobe(for url: URL) async -> Double? {
        await SwiftExifMediaProbe.duration(for: url)
    }

    /// Starts a download using stored videoItems and outputFolder references
    /// Used for scheduled downloads where we can't capture fresh bindings
    @discardableResult
    func startDownloadWithStoredReferences(url urlString: String) async -> UUID? {
        guard let items = videoItems, let folder = outputFolder else {
            logger.error("Cannot start scheduled download: videoItems or outputFolder not set")
            return nil
        }
        return await startDownload(url: urlString, items: items, outputFolder: folder)
    }

    /// Schedules a download for a future time - creates an item in the queue immediately
    /// - Parameters:
    ///   - urlString: The video URL to download
    ///   - scheduledTime: When the download should start
    ///   - items: Binding to the video items array
    ///   - outputFolder: The folder to save downloads
    /// - Returns: The UUID of the created VideoItem
    @discardableResult
    func scheduleDownload(
        url urlString: String,
        at scheduledTime: Date,
        items: Binding<[VideoItem]>,
        outputFolder: URL,
        liveFromStart: Bool = false,
        audioOnly: Bool = false,
        section: DownloadSection? = nil
    ) async -> UUID? {
        self.videoItems = items
        self.outputFolder = outputFolder

        // Create a placeholder VideoItem with scheduled time
        let placeholderURL = URL(fileURLWithPath: "/tmp/scheduled-\(UUID().uuidString)")
        var item = VideoItem(
            url: placeholderURL,
            name: "Scheduled download",
            size: 0,
            duration: "--:--",
            durationSeconds: 0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        item.sourceURL = urlString
        item.scheduledDownloadTime = scheduledTime
        // Apply default automation settings
        item.autoEncodeAfterDownload = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        item.uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)
        item.downloadLiveFromStart = liveFromStart
        item.downloadAudioOnly = audioOnly
        item.downloadSection = section

        let itemID = item.id

        // Add to queue
        items.wrappedValue.append(item)

        // Debug timezone info
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = .current
        let localTimeStr = formatter.string(from: scheduledTime)
        logger.info("Scheduled download for \(localTimeStr) (local time), URL: \(urlString)")

        // Register with ScheduledDownloadService
        ScheduledDownloadService.shared.registerScheduledItem(itemID: itemID, scheduledTime: scheduledTime)

        // Persist so the schedule survives relaunches
        appendPersistedSchedule(PersistedScheduledDownload(
            itemID: itemID,
            url: urlString,
            scheduledTime: scheduledTime,
            liveFromStart: liveFromStart,
            autoEncode: item.autoEncodeAfterDownload,
            uploadEnabled: item.uploadEnabled,
            audioOnly: audioOnly,
            section: section
        ))

        return itemID
    }

    /// Cancels a scheduled (not-yet-started) download and removes it from persistence.
    /// Callers should also remove the item from the queue.
    func cancelScheduledDownload(itemID: UUID) {
        ScheduledDownloadService.shared.cancelScheduledItem(itemID: itemID)
        removePersistedSchedule(itemID: itemID)
    }

    /// Re-adds previously scheduled downloads to the queue on app launch.
    /// Must be called after `videoItems`/`outputFolder` have been wired up.
    func restoreScheduledDownloads(items: Binding<[VideoItem]>, outputFolder: URL) {
        let persisted: [PersistedScheduledDownload]
        do {
            persisted = try scheduleStore.load()
        } catch {
            hasScheduledDownloadStorageError = true
            logger.error("Cannot restore scheduled downloads; saved data retained: \(error.localizedDescription)")
            return
        }
        guard !persisted.isEmpty else { return }

        self.videoItems = items
        self.outputFolder = outputFolder

        var rewritten: [PersistedScheduledDownload] = []
        rewritten.reserveCapacity(persisted.count)

        for entry in persisted {
            let placeholderURL = URL(fileURLWithPath: "/tmp/scheduled-\(UUID().uuidString)")
            var item = VideoItem(
                url: placeholderURL,
                name: "Scheduled download",
                size: 0,
                duration: "--:--",
                durationSeconds: 0,
                thumbnailData: nil,
                status: .waiting,
                progress: 0,
                eta: nil,
                outputURL: nil
            )
            item.sourceURL = entry.url
            item.scheduledDownloadTime = entry.scheduledTime
            item.autoEncodeAfterDownload = entry.autoEncode
            item.uploadEnabled = entry.uploadEnabled
            item.downloadLiveFromStart = entry.liveFromStart
            item.downloadAudioOnly = entry.audioOnly
            item.downloadSection = entry.section

            let newItemID = item.id
            items.wrappedValue.append(item)
            ScheduledDownloadService.shared.registerScheduledItem(itemID: newItemID, scheduledTime: entry.scheduledTime)

            rewritten.append(PersistedScheduledDownload(
                itemID: newItemID,
                url: entry.url,
                scheduledTime: entry.scheduledTime,
                liveFromStart: entry.liveFromStart,
                autoEncode: entry.autoEncode,
                uploadEnabled: entry.uploadEnabled,
                audioOnly: entry.audioOnly,
                section: entry.section
            ))
        }

        // Rewrite persistence so the stored itemIDs match the freshly-created VideoItems.
        do {
            try scheduleStore.save(rewritten)
        } catch {
            hasScheduledDownloadStorageError = true
            logger.error("Cannot save restored scheduled downloads: \(error.localizedDescription)")
        }
        logger.info("Restored \(rewritten.count) scheduled download(s) from persistence")
    }

    /// Starts a previously scheduled download (called by ScheduledDownloadService when time is reached)
    func startScheduledDownload(itemID: UUID) async {
        let startTime = Date()
        logger.info("[TIMING] startScheduledDownload entered")

        // The schedule has fired — drop it from persistence so it doesn't re-fire on relaunch.
        removePersistedSchedule(itemID: itemID)

        guard videoItems != nil, let folder = outputFolder else {
            logger.error("Cannot start scheduled download: videoItems or outputFolder not set")
            return
        }

        guard let item = findItem(itemID), let sourceURL = item.sourceURL else {
            logger.error("Cannot find scheduled item or source URL")
            return
        }

        let findItemElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] Found item in \(String(format: "%.3f", findItemElapsed))s")

        // Clear the scheduled time and mark as downloading
        updateItem(itemID) { item in
            item.scheduledDownloadTime = nil
            item.isDownloading = true
            item.name = "Fetching info..."
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
        }

        let setupElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] Item setup completed in \(String(format: "%.3f", setupElapsed))s, starting download task...")

        // Start download task
        launchDownloadTask(
            itemID: itemID,
            urlString: sourceURL,
            outputFolder: folder,
            liveFromStart: item.downloadLiveFromStart,
            audioOnly: item.downloadAudioOnly,
            section: item.downloadSection
        )
    }

    /// Checks if yt-dlp is available and configured
    func isYTDLPConfigured() async -> Bool {
        if let ytdlpAvailability { return ytdlpAvailability }
        return await YTDLPUpdateService.shared.isYTDLPAvailable()
    }

    /// Starts a download for a URL and adds it to the video queue
    /// - Parameters:
    ///   - urlString: The video URL to download
    ///   - items: Binding to the video items array
    ///   - outputFolder: The folder to save downloads
    /// - Returns: The UUID of the created VideoItem, or nil if yt-dlp is not configured
    @discardableResult
    func startDownload(
        url urlString: String,
        items: Binding<[VideoItem]>,
        outputFolder: URL,
        liveFromStart: Bool = false,
        audioOnly: Bool = false,
        section: DownloadSection? = nil
    ) async -> UUID? {
        // Check if yt-dlp is available
        guard await isYTDLPConfigured() else {
            logger.error("yt-dlp not configured. Please configure in Settings > General > Video Downloads.")
            return nil
        }

        self.videoItems = items
        self.outputFolder = outputFolder

        // Create a placeholder VideoItem
        let placeholderURL = URL(fileURLWithPath: "/tmp/downloading-\(UUID().uuidString)")
        var item = VideoItem(
            url: placeholderURL,
            name: "Fetching info...",
            size: 0,
            duration: "--:--",
            durationSeconds: 0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        item.isDownloading = true
        item.sourceURL = urlString
        item.downloadProgress = 0
        item.downloadHasProgress = false
        item.downloadSpeed = nil
        item.downloadLiveFromStart = liveFromStart
        item.downloadAudioOnly = audioOnly
        item.downloadSection = section

        // Apply default automation settings
        item.autoEncodeAfterDownload = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        item.uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)

        let itemID = item.id

        // Add to queue
        items.wrappedValue.append(item)

        // Start download task (using unowned self since DownloadManager is a singleton)
        launchDownloadTask(
            itemID: itemID,
            urlString: urlString,
            outputFolder: outputFolder,
            liveFromStart: liveFromStart,
            audioOnly: audioOnly,
            section: section
        )

        return itemID
    }

    /// Adds one queue item per already-probed playlist entry (e.g. the subset the
    /// user picked in the URL overlay), then downloads them one after another in a
    /// batch task owned by the manager. Unavailable entries are never queued.
    /// Returns as soon as the rows exist; use `waitForPlaylistBatch(_:)` to await
    /// the downloads.
    /// - Returns: IDs of every queue item that was created (in entry order).
    @discardableResult
    func startPlaylistDownload(
        entries: [YTDLPPlaylistEntry],
        items: Binding<[VideoItem]>,
        outputFolder: URL,
        audioOnly: Bool = false
    ) -> [UUID] {
        let entries = entries.filter(\.isAvailable)
        guard !entries.isEmpty else { return [] }
        self.videoItems = items
        self.outputFolder = outputFolder

        logger.info("Spawning \(entries.count) queue item(s) from playlist")

        // Snap the automation defaults once so every spawned item shares the same
        // value — toggling "Encode" mid-playlist shouldn't affect already-queued items.
        let autoEncode = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        let uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)
        let batchID = UUID()

        var itemIDs: [UUID] = []
        for entry in entries {
            let placeholderURL = URL(fileURLWithPath: "/tmp/downloading-\(UUID().uuidString)")
            var item = VideoItem(
                url: placeholderURL,
                name: entry.title,
                size: 0,
                duration: Self.formatDuration(entry.duration),
                durationSeconds: entry.duration ?? 0,
                thumbnailData: nil,
                status: .waiting,
                progress: 0,
                eta: nil,
                outputURL: nil
            )
            item.sourceURL = entry.url
            item.downloadAudioOnly = audioOnly
            item.autoEncodeAfterDownload = autoEncode
            item.uploadEnabled = uploadEnabled
            item.isDownloading = false
            item.isQueuedForDownload = true
            item.playlistDownloadBatchID = batchID
            item.downloadProgress = 0
            item.downloadHasProgress = false

            items.wrappedValue.append(item)
            itemIDs.append(item.id)
        }

        playlistBatchTasks[batchID] = Task { [weak self] in
            await self?.runPlaylistBatch(batchID: batchID, itemIDs: itemIDs, outputFolder: outputFolder)
        }
        return itemIDs
    }

    /// Waits until a playlist batch has finished or been cancelled.
    func waitForPlaylistBatch(_ batchID: UUID) async {
        await playlistBatchTasks[batchID]?.value
    }

    /// Cancels the running download of a playlist batch and every entry still
    /// queued behind it. Rows that already finished are left alone.
    func cancelPlaylistBatch(_ batchID: UUID) {
        logger.info("Cancel playlist batch requested: \(batchID)")
        playlistBatchTasks[batchID]?.cancel()
        let rows = videoItems?.wrappedValue.filter {
            $0.playlistDownloadBatchID == batchID && ($0.isQueuedForDownload || $0.isDownloading)
        } ?? []
        for row in rows {
            cancelDownload(itemID: row.id)
        }
    }

    /// Cancels the playlist batch the given row belongs to; falls back to
    /// cancelling just that row when it isn't part of a playlist.
    func cancelPlaylistBatch(containing itemID: UUID) {
        guard let batchID = findItem(itemID)?.playlistDownloadBatchID else {
            cancelDownload(itemID: itemID)
            return
        }
        cancelPlaylistBatch(batchID)
    }

    /// Runs playlist downloads sequentially to avoid competing for bandwidth. Each
    /// item still gets its own cancellation control, so cancelling one row skips
    /// only that row, and cannot affect an unrelated download running elsewhere.
    /// Rows that were removed or cancelled while waiting are skipped.
    private func runPlaylistBatch(batchID: UUID, itemIDs: [UUID], outputFolder: URL) async {
        defer { playlistBatchTasks.removeValue(forKey: batchID) }
        for itemID in itemIDs {
            guard let item = findItem(itemID), item.isQueuedForDownload,
                  let sourceURL = item.sourceURL else { continue }
            guard !Task.isCancelled else {
                cancelDownload(itemID: itemID)
                continue
            }

            updateItem(itemID) {
                $0.isQueuedForDownload = false
                $0.isDownloading = true
            }

            // performDownload kicks off its own thumbnail fetch — don't double-probe.
            let task = launchDownloadTask(
                itemID: itemID,
                urlString: sourceURL,
                outputFolder: outputFolder,
                liveFromStart: false,
                audioOnly: item.downloadAudioOnly
            )
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    /// Formats a duration in seconds for `VideoItem.duration` display ("h:mm:ss" or "m:ss").
    private static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Serialize attempts for one queue row, including retries after explicit cancel.
    @discardableResult
    private func launchDownloadTask(
        itemID: UUID,
        urlString: String,
        outputFolder: URL,
        liveFromStart: Bool,
        audioOnly: Bool,
        section: DownloadSection? = nil,
        forceOverwrite: Bool = false
    ) -> Task<Void, Never> {
        let previous = downloadTasks[itemID]?.task
        previous?.cancel()
        _ = downloadControls[itemID]?.cancel()
        let control = YTDLPDownloadControl()
        downloadControls[itemID] = control
        let task = Task {
            defer {
                if self.downloadTasks[itemID]?.control === control {
                    self.downloadTasks.removeValue(forKey: itemID)
                }
                if self.downloadControls[itemID] === control {
                    self.downloadControls.removeValue(forKey: itemID)
                }
            }
            await previous?.value
            guard self.downloadControls[itemID] === control else { return }
            guard !Task.isCancelled else {
                self.cancelDownload(itemID: itemID)
                return
            }
            // Keep App Nap from throttling output parsing and the stall watchdog, and
            // idle sleep from cutting off long downloads and live recordings.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Downloading a video"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            await self.performDownload(
                itemID: itemID, urlString: urlString, outputFolder: outputFolder,
                liveFromStart: liveFromStart, audioOnly: audioOnly, section: section,
                forceOverwrite: forceOverwrite, waitForStream: false, control: control
            )
        }
        downloadTasks[itemID] = (control, task)
        return task
    }

    /// Clears every live-stream state of a row whose download has ended.
    private static func clearLiveState(_ item: inout VideoItem) {
        item.isLiveStreamRecording = false
        item.downloadStopping = false
        item.liveRecordingFileSize = nil
        item.liveRecordingDuration = nil
        item.waitingForLiveStream = false
        item.liveStreamStartsAt = nil
    }

    /// Performs the actual download. `waitForStream` is set when a previous attempt
    /// found a scheduled stream that hasn't started; yt-dlp then waits for it.
    private func performDownload(
        itemID: UUID,
        urlString: String,
        outputFolder: URL,
        liveFromStart: Bool,
        audioOnly: Bool,
        section: DownloadSection?,
        forceOverwrite: Bool,
        waitForStream: Bool,
        control: YTDLPDownloadControl
    ) async {
        let downloadStartTime = Date()
        logger.info("[TIMING] performDownload started at \(downloadStartTime)")

        // Hold a security-scoped resource on the output folder for the duration of
        // the subprocess. Required when the folder was restored from a bookmark
        // (relaunch); harmless when the folder is already accessible (~/Downloads).
        let folderAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: outputFolder)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(folderAccess) }

        if !waitForStream {
            // Add to download history immediately (for easy retry of failed downloads)
            let initialTitle = URL(string: urlString)?.host ?? "Download"
            DownloadHistoryService.addEntry(url: urlString, title: initialTitle)
        }

        // Fetch thumbnail in parallel (doesn't block download). A forced re-download
        // keeps the row's thumbnail, and a stream wait fetches its own.
        if !forceOverwrite && !waitForStream {
            fetchThumbnailInBackground(itemID: itemID, urlString: urlString)
        }

        // Start the actual download immediately (don't wait for metadata)
        do {
            let actualDownloadStartTime = Date()
            logger.info("[TIMING] Starting download immediately for: \(urlString)")

            let result = try await ytdlpService.download(
                url: urlString,
                outputFolder: outputFolder,
                forceOverwrite: forceOverwrite,
                liveFromStart: liveFromStart,
                audioOnly: audioOnly,
                section: section,
                waitForStream: waitForStream,
                control: control,
                progress: { [weak self] progress, speed, isLiveStream in
                    Task { @MainActor in
                        guard let self = self,
                              self.downloadControls[itemID] === control else { return }
                        let wasLiveStreamRecording = self.findItem(itemID)?.isLiveStreamRecording ?? false
                        self.updateItem(itemID) { item in
                            item.downloadProgress = progress
                            item.downloadHasProgress = true
                            item.downloadSpeed = speed
                            // For live streams, mark as live recording
                            if isLiveStream {
                                item.isLiveStreamRecording = true
                                item.waitingForLiveStream = false
                            }
                            // Also update the main progress for the progress bar
                            item.progress = progress
                        }
                        // Start stat updates when we detect live stream recording
                        if isLiveStream && !wasLiveStreamRecording {
                            self.logger.info("[LiveStream] Detected live stream, starting stat updates")
                            self.startLiveRecordingStatUpdates(itemID: itemID, outputFolder: outputFolder, control: control)
                        }
                    }
                },
                titleUpdate: { [weak self] title in
                    Task { @MainActor in
                        guard let self,
                              self.downloadControls[itemID] === control else { return }
                        self.updateItem(itemID) { item in
                            // Update name with discovered title
                            item.name = title
                        }
                        self.logger.info("Updated item name to: \(title)")
                    }
                },
                engineUpdate: { [weak self] engine, fallbackReason in
                    Task { @MainActor in
                        guard let self,
                              self.downloadControls[itemID] === control else { return }
                        self.updateItem(itemID) { item in
                            item.downloadEngine = engine
                            item.downloadEngineFallbackReason = fallbackReason
                        }
                    }
                },
                liveUpdate: { [weak self] update in
                    Task { @MainActor in
                        guard let self,
                              self.downloadControls[itemID] === control else { return }
                        self.applyLiveUpdate(update, itemID: itemID)
                    }
                }
            )

            guard downloadControls[itemID] === control else {
                logger.info("Ignoring completion from a cancelled or superseded download: \(itemID)")
                return
            }
            guard !Task.isCancelled else {
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = "Cancelled"
                    item.status = .cancelled
                }
                return
            }

            // Download complete - update item. A live recording stopped by the user
            // ends here too: yt-dlp finalizes it like a stream that ended.
            let downloadElapsed = Date().timeIntervalSince(actualDownloadStartTime)
            let totalElapsed = Date().timeIntervalSince(downloadStartTime)
            logger.info("[TIMING] Download complete: \(result.outputURL.path)")
            if let reason = result.engineFallbackReason {
                logger.info("[Engine] Downloaded with yt-dlp after yt-dlp-rs failed: \(reason, privacy: .public)")
            }
            logger.info("[TIMING] Actual download took \(String(format: "%.2f", downloadElapsed))s, total elapsed: \(String(format: "%.2f", totalElapsed))s")

            let videoTitle = result.title.isEmpty
                ? result.outputURL.deletingPathExtension().lastPathComponent
                : result.title

            // Save to download history
            DownloadHistoryService.addEntry(
                url: urlString,
                title: videoTitle,
                outputFileName: result.outputURL.lastPathComponent
            )

            // Stop live recording stat updates
            stopLiveRecordingStatUpdates(itemID: itemID)

            updateItem(itemID) { item in
                item.url = result.outputURL
                item.downloadEngine = result.engine
                item.downloadEngineFallbackReason = result.engineFallbackReason
                item.name = result.outputURL.lastPathComponent
                item.isDownloading = false
                Self.clearLiveState(&item)
                item.downloadProgress = 1.0
                item.downloadSpeed = nil
                item.progress = 0  // Reset for encoding
                item.status = .waiting
                item.detailsLoaded = false  // Will be loaded by the queue

                // Get file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path),
                   let size = attrs[.size] as? Int64 {
                    item.size = size
                }
            }

            // Trigger details and metadata loading for the downloaded file
            if let item = findItem(itemID) {
                let shouldAutoEncode = item.autoEncodeAfterDownload
                loadDownloadedFileDetails(
                    itemID: itemID, fileURL: result.outputURL, autoEncode: shouldAutoEncode,
                    section: section, sourceDuration: result.sourceDuration
                )
            }

        } catch let error as YTDLPError {
            guard downloadControls[itemID] === control else { return }
            // Stop live recording stat updates for any error
            stopLiveRecordingStatUpdates(itemID: itemID)

            switch error {
            case .streamNotStarted(let message) where !waitForStream && !Task.isCancelled:
                logger.info("Stream has not started yet, waiting for it: \(message, privacy: .public)")
                updateItem(itemID) { item in
                    item.waitingForLiveStream = true
                    item.downloadHasProgress = false
                    item.downloadProgress = 0
                    item.downloadSpeed = nil
                }
                fetchUpcomingStreamInfo(itemID: itemID, urlString: urlString)
                await performDownload(
                    itemID: itemID, urlString: urlString, outputFolder: outputFolder,
                    liveFromStart: liveFromStart, audioOnly: audioOnly, section: section,
                    forceOverwrite: forceOverwrite, waitForStream: true, control: control
                )
            case .fileAlreadyExists(let path, let title):
                logger.warning("File already exists: \(path)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = "File already exists"
                    item.fileAlreadyExistsPath = path
                    item.status = .failed
                    item.name = title
                    Self.clearLiveState(&item)
                }
            case .liveRecordingStopped:
                // yt-dlp could not finalize the stopped recording (or was forced to
                // stop); keep whatever it wrote.
                logger.info("Download stopped for item: \(itemID), searching for partial file...")

                // Recover only a destination emitted by this download; another
                // recording in the same folder must never be adopted or renamed.
                if let partialFile = control.partialFile(in: outputFolder) {
                    logger.info("Found partial file: \(partialFile.path)")

                    // Rename the file to remove .part extension if present
                    var finalFile = partialFile
                    let filename = partialFile.lastPathComponent
                    if filename.hasSuffix(".part") {
                        var newURL = partialFile.deletingPathExtension() // Remove ".part"
                        // A live HLS recording cut off before yt-dlp's fixup is still
                        // MPEG-TS, whatever extension it was given.
                        if newURL.pathExtension.lowercased() != "ts", Self.isMPEGTransportStream(partialFile) {
                            newURL = newURL.deletingPathExtension().appendingPathExtension("ts")
                        }
                        let newFilename = newURL.lastPathComponent
                        do {
                            try FileManager.default.moveItem(at: partialFile, to: newURL)
                            finalFile = newURL
                            logger.info("Renamed partial file to: \(newFilename)")
                        } catch {
                            logger.warning("Could not rename partial file: \(error.localizedDescription)")
                            // Continue with original file
                        }
                    }

                    updateItem(itemID) { item in
                        item.url = finalFile
                        item.name = finalFile.lastPathComponent
                        item.isDownloading = false
                        Self.clearLiveState(&item)
                        item.downloadError = nil
                        item.downloadProgress = 1.0
                        item.downloadSpeed = nil
                        item.progress = 0
                        item.status = .waiting
                        item.detailsLoaded = false

                        // Get file size
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalFile.path),
                           let size = attrs[.size] as? Int64 {
                            item.size = size
                        }
                    }

                    // Update download history with the proper title
                    let videoTitle = (finalFile.deletingPathExtension().lastPathComponent)
                    DownloadHistoryService.addEntry(
                        url: urlString,
                        title: videoTitle,
                        outputFileName: finalFile.lastPathComponent
                    )

                    // Load details and metadata for the file
                    loadDownloadedFileDetails(itemID: itemID, fileURL: finalFile, autoEncode: false)
                } else {
                    logger.warning("Could not find partial file for stopped download")
                    updateItem(itemID) { item in
                        item.isDownloading = false
                        Self.clearLiveState(&item)
                        item.downloadError = "Stopped - partial file not found"
                        item.status = .failed
                    }
                }
            case .cancelled:
                logger.info("Download cancelled for item: \(itemID)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    Self.clearLiveState(&item)
                    item.downloadSpeed = nil
                    item.downloadError = "Cancelled"
                    item.status = .cancelled
                }
            default:
                logger.error("Download failed: \(error.localizedDescription)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = error.localizedDescription
                    item.status = .failed
                    Self.clearLiveState(&item)
                    item.downloadSpeed = nil
                }
            }
        } catch {
            guard downloadControls[itemID] === control else { return }
            // Stop live recording stat updates for any error
            stopLiveRecordingStatUpdates(itemID: itemID)

            logger.error("Download failed: \(error.localizedDescription)")

            updateItem(itemID) { item in
                item.isDownloading = false
                item.downloadError = error.localizedDescription
                item.status = .failed
                Self.clearLiveState(&item)
                item.downloadSpeed = nil
            }
        }

    }

    /// MPEG-TS packets are 188 bytes, each starting with the 0x47 sync byte.
    nonisolated static func isMPEGTransportStream(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 188 * 3), data.count == 188 * 3 else { return false }
        return [0, 188, 376].allSatisfy { data[data.startIndex + $0] == 0x47 }
    }

    private func applyLiveUpdate(_ update: YTDLPLiveUpdate, itemID: UUID) {
        switch update {
        case .streamAvailable:
            logger.info("[LiveStream] Awaited stream is available")
            updateItem(itemID) { $0.waitingForLiveStream = false }
        case .recording(let duration, let bytes):
            // ffmpeg reports what it has written, which also covers yt-dlp-rs's
            // private working directory; stop probing the growing file.
            stopLiveRecordingStatUpdates(itemID: itemID)
            updateItem(itemID) { item in
                if let duration { item.liveRecordingDuration = duration }
                if let bytes { item.liveRecordingFileSize = bytes }
            }
        }
    }

    /// Title, thumbnail and announced start time for a row waiting for its stream.
    private func fetchUpcomingStreamInfo(itemID: UUID, urlString: String) {
        let service = ytdlpService
        thumbnailTasks.start(itemID: itemID, timeout: .seconds(60)) {
            let info = try await service.fetchUpcomingStreamInfo(url: urlString)
            try Task.checkCancellation()
            var thumbnailData: Data?
            if let thumbnailURL = info.thumbnailURL,
               let (data, response) = try? await URLSession.shared.data(from: thumbnailURL),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                thumbnailData = data
            }
            return UpcomingStreamThumbnail(info: info, data: thumbnailData)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let upcoming):
                let info = upcoming.info
                let thumbnailData = upcoming.data
                self.updateItem(itemID) { item in
                    guard item.waitingForLiveStream else { return }
                    item.liveStreamStartsAt = info.startsAt
                    if let title = info.title, item.name == "Fetching info..." || item.name.isEmpty {
                        item.name = title
                    }
                    if let thumbnailData, item.thumbnailData == nil {
                        item.thumbnailData = thumbnailData
                    }
                }
            case .failure(let error):
                self.logger.info("Could not fetch upcoming stream info: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels a download
    func cancelDownload(itemID: UUID) {
        logger.info("Cancel download requested for item: \(itemID)")

        thumbnailTasks.cancel(itemID: itemID)
        detailsTasks.cancel(itemID: itemID)

        // Stop live recording stat updates immediately
        stopLiveRecordingStatUpdates(itemID: itemID)

        _ = downloadControls[itemID]?.cancel()

        // Retain the cancelled task until it drains. A later retry must wait for
        // its subprocess to stop touching the destination before starting again.
        downloadTasks[itemID]?.task.cancel()
        downloadControls.removeValue(forKey: itemID)

        // Update item state
        updateItem(itemID) { item in
            item.isDownloading = false
            item.isQueuedForDownload = false
            Self.clearLiveState(&item)
            item.downloadSpeed = nil
            item.downloadError = "Cancelled"
            item.status = .cancelled
        }
    }

    func stopLiveDownload(itemID: UUID) {
        logger.info("Stop live download requested for item: \(itemID)")

        // Nothing has been recorded while waiting for a stream to start, and SIGINT
        // would only make yt-dlp check again right away.
        if findItem(itemID)?.waitingForLiveStream == true {
            cancelDownload(itemID: itemID)
            return
        }

        // Immediately update UI to show stopping state (provides instant feedback)
        updateItem(itemID) { item in
            item.downloadStopping = true
        }

        // Stop live recording stat updates immediately to prevent further polling
        stopLiveRecordingStatUpdates(itemID: itemID)

        // The first stop asks yt-dlp to finish the recording (merge, metadata) and exit;
        // a second one forces it. The orchestration task stays alive either way and
        // finalizes the row: as a completed download, or by recovering the partial file.
        _ = downloadControls[itemID]?.stopLiveRecording()
    }

    /// Retries a failed download
    func retryDownload(itemID: UUID) async {
        guard let item = findItem(itemID),
              let sourceURL = item.sourceURL,
              let outputFolder = outputFolder else {
            return
        }

        cancelDownload(itemID: itemID)

        // Reset item state
        updateItem(itemID) { item in
            item.isDownloading = true
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
            item.downloadError = nil
            item.fileAlreadyExistsPath = nil
            item.status = .waiting
        }

        // Start new download
        launchDownloadTask(
            itemID: itemID,
            urlString: sourceURL,
            outputFolder: outputFolder,
            liveFromStart: item.downloadLiveFromStart,
            audioOnly: item.downloadAudioOnly,
            section: item.downloadSection
        )
    }

    /// Force re-downloads, overwriting existing file
    func forceRedownload(itemID: UUID) async {
        guard let item = findItem(itemID),
              let sourceURL = item.sourceURL,
              let outputFolder = outputFolder else {
            return
        }

        cancelDownload(itemID: itemID)

        // Reset item state
        updateItem(itemID) { item in
            item.isDownloading = true
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
            item.downloadError = nil
            item.fileAlreadyExistsPath = nil
            item.status = .waiting
        }

        // Start download with force overwrite
        launchDownloadTask(
            itemID: itemID,
            urlString: sourceURL,
            outputFolder: outputFolder,
            liveFromStart: item.downloadLiveFromStart,
            audioOnly: item.downloadAudioOnly,
            section: item.downloadSection,
            forceOverwrite: true
        )
    }

    /// Removes a download from the queue
    func removeDownload(itemID: UUID) {
        // Cancel if in progress
        cancelDownload(itemID: itemID)

        // Remove from queue
        videoItems?.wrappedValue.removeAll { $0.id == itemID }
    }

    /// Checks if a URL is likely supported by yt-dlp
    static func isYTDLPCompatibleURL(_ url: URL) -> Bool {
        let supportedHosts = [
            "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
            "vimeo.com", "www.vimeo.com",
            "twitch.tv", "www.twitch.tv",
            "twitter.com", "x.com",
            "facebook.com", "www.facebook.com", "fb.watch",
            "instagram.com", "www.instagram.com",
            "tiktok.com", "www.tiktok.com",
            "reddit.com", "www.reddit.com",
            "dailymotion.com", "www.dailymotion.com"
        ]

        guard let host = url.host?.lowercased() else { return false }
        return supportedHosts.contains { host.contains($0) }
    }

    /// Checks if a string is a valid URL for yt-dlp
    /// Extracts the first line and trims whitespace before validation
    nonisolated static func isValidURL(_ string: String) -> Bool {
        let sanitized = sanitizeURLInput(string)
        guard !sanitized.isEmpty, let url = URL(string: sanitized) else { return false }
        // Require http/https AND a non-empty host — `https://` alone parses into a
        // URL but yt-dlp would error out seconds later with a confusing message.
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }

        // Reject private/loopback/link-local destinations unless the user has
        // explicitly opted in. Catches naive `http://192.168.x.y/...` and
        // `localhost` cases — does not chase DNS or HTTP redirects.
        let allowsPrivate = UserDefaults.standard.bool(forKey: AppConstants.allowPrivateNetworkDownloadsKey)
        if !allowsPrivate && isPrivateOrLocalHost(host) { return false }
        return true
    }

    /// Returns true if `host` is a literal private/loopback/link-local IP or a
    /// hostname conventionally used for the local machine / LAN (`localhost`,
    /// `*.local`, `*.localhost`).
    nonisolated static func isPrivateOrLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" { return true }
        if lower == "local" || lower.hasSuffix(".local") { return true }
        if lower.hasSuffix(".localhost") { return true }

        if let v4 = IPv4Address(lower) {
            return isPrivateIPv4(v4.rawValue)
        }

        // URL.host strips the brackets around literal IPv6, but accept either form.
        let v6String: String = {
            if lower.hasPrefix("["), lower.hasSuffix("]") {
                return String(lower.dropFirst().dropLast())
            }
            return lower
        }()
        if let v6 = IPv6Address(v6String) {
            let bytes = v6.rawValue
            // ::1 — loopback
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            // fc00::/7 — unique local addresses
            if (bytes[0] & 0xFE) == 0xFC { return true }
            // fe80::/10 — link-local
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
            // ::ffff:a.b.c.d — IPv4-mapped, classify by the embedded IPv4
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return isPrivateIPv4(bytes.suffix(4))
            }
            return false
        }
        return false
    }

    private nonisolated static func isPrivateIPv4(_ bytes: Data) -> Bool {
        guard bytes.count == 4 else { return false }
        let b = Array(bytes)
        // 10.0.0.0/8, 127.0.0.0/8, 0.0.0.0/8
        if b[0] == 10 || b[0] == 127 || b[0] == 0 { return true }
        // 172.16.0.0/12
        if b[0] == 172 && (b[1] & 0xF0) == 16 { return true }
        // 192.168.0.0/16
        if b[0] == 192 && b[1] == 168 { return true }
        // 169.254.0.0/16 — link-local
        if b[0] == 169 && b[1] == 254 { return true }
        return false
    }

    /// Sanitizes URL input by extracting the first line and trimming whitespace
    nonisolated static func sanitizeURLInput(_ string: String) -> String {
        // Extract first line only (handles multi-line pastes)
        let firstLine = string.components(separatedBy: .newlines).first ?? string
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private Helpers

    private func updateItem(_ itemID: UUID, update: (inout VideoItem) -> Void) {
        guard let items = videoItems else { return }
        if let index = items.wrappedValue.firstIndex(where: { $0.id == itemID }) {
            update(&items.wrappedValue[index])
        }
    }

    private func findItem(_ itemID: UUID) -> VideoItem? {
        videoItems?.wrappedValue.first { $0.id == itemID }
    }

    // MARK: - Scheduled Download Persistence

    /// Called only after explicit confirmation: replaces unreadable saved data with
    /// the schedules still present in this session's queue.
    func resetScheduledDownloadStorage() {
        let entries = (videoItems?.wrappedValue ?? []).compactMap { item -> PersistedScheduledDownload? in
            guard let time = item.scheduledDownloadTime, let url = item.sourceURL else { return nil }
            return PersistedScheduledDownload(
                itemID: item.id, url: url, scheduledTime: time,
                liveFromStart: item.downloadLiveFromStart,
                autoEncode: item.autoEncodeAfterDownload,
                uploadEnabled: item.uploadEnabled, audioOnly: item.downloadAudioOnly
            )
        }
        do {
            try scheduleStore.reset(with: entries)
            hasScheduledDownloadStorageError = false
        } catch {
            hasScheduledDownloadStorageError = true
            logger.error("Cannot reset scheduled downloads; saved data retained: \(error.localizedDescription)")
        }
    }

    private func appendPersistedSchedule(_ entry: PersistedScheduledDownload) {
        do {
            try scheduleStore.append(entry)
        } catch {
            hasScheduledDownloadStorageError = true
            logger.error("Cannot persist scheduled download; saved data retained: \(error.localizedDescription)")
        }
    }

    private func removePersistedSchedule(itemID: UUID) {
        do {
            try scheduleStore.remove(itemID: itemID)
        } catch {
            hasScheduledDownloadStorageError = true
            logger.error("Cannot remove persisted schedule; saved data retained: \(error.localizedDescription)")
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

private struct DownloadThumbnailResult: Sendable {
    let title: String
    let data: Data?
}

private struct UpcomingStreamThumbnail: Sendable {
    let info: YTDLPUpcomingStreamInfo
    let data: Data?
}

/// Owns optional per-download work independently of the transfer. A replaced or
/// cancelled operation cannot publish results or remove its replacement's task.
@MainActor
final class DownloadAuxiliaryTaskStore {
    private var tasks: [UUID: (generation: UUID, task: Task<Void, Never>)] = [:]

    @discardableResult
    func start<Output: Sendable>(
        itemID: UUID,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Output,
        completion: @escaping @MainActor (Result<Output, Error>) -> Void
    ) -> Task<Void, Never> {
        cancel(itemID: itemID)
        let generation = UUID()
        let task = Task { [weak self] in
            let result: Result<Output, Error>
            do {
                result = .success(try await NonJoiningTaskDeadline.run(
                    timeout: timeout, operation: operation
                ))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled,
                  self.tasks[itemID]?.generation == generation else { return }
            self.tasks.removeValue(forKey: itemID)
            completion(result)
        }
        tasks[itemID] = (generation, task)
        return task
    }

    func cancel(itemID: UUID) {
        tasks.removeValue(forKey: itemID)?.task.cancel()
    }
}

struct PersistedScheduledDownload: Codable, Equatable {
    var itemID: UUID
    let url: String
    let scheduledTime: Date
    let liveFromStart: Bool
    let autoEncode: Bool
    let uploadEnabled: Bool
    let audioOnly: Bool
    let section: DownloadSection?

    init(itemID: UUID, url: String, scheduledTime: Date, liveFromStart: Bool, autoEncode: Bool, uploadEnabled: Bool, audioOnly: Bool, section: DownloadSection? = nil) {
        self.itemID = itemID
        self.url = url
        self.scheduledTime = scheduledTime
        self.liveFromStart = liveFromStart
        self.autoEncode = autoEncode
        self.uploadEnabled = uploadEnabled
        self.audioOnly = audioOnly
        self.section = section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(UUID.self, forKey: .itemID)
        url = try container.decode(String.self, forKey: .url)
        scheduledTime = try container.decode(Date.self, forKey: .scheduledTime)
        liveFromStart = try container.decode(Bool.self, forKey: .liveFromStart)
        autoEncode = try container.decode(Bool.self, forKey: .autoEncode)
        uploadEnabled = try container.decode(Bool.self, forKey: .uploadEnabled)
        // Back-compat: schedules persisted before audio-only existed have no key.
        audioOnly = container.contains(.audioOnly)
            ? try container.decode(Bool.self, forKey: .audioOnly)
            : false
        // Back-compat: schedules persisted before section downloads have no key.
        section = try container.decodeIfPresent(DownloadSection.self, forKey: .section)
    }
}

/// A failed decode must never turn into an empty queue that overwrites recoverable schedules.
struct ScheduledDownloadStore {
    static let key = "persistedScheduledDownloads.v1"
    let defaults: UserDefaults

    func load() throws -> [PersistedScheduledDownload] {
        guard let stored = defaults.object(forKey: Self.key) else { return [] }
        guard let data = stored as? Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode([PersistedScheduledDownload].self, from: data)
    }

    func save(_ entries: [PersistedScheduledDownload]) throws {
        // Refuse to replace an unsupported or damaged existing schema.
        _ = try load()
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Explicit recovery only. Encode first so a failure preserves the original value.
    func reset(with entries: [PersistedScheduledDownload]) throws {
        let data = try JSONEncoder().encode(entries)
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(data, forKey: Self.key)
        }
    }

    func append(_ entry: PersistedScheduledDownload) throws {
        var entries = try load()
        entries.removeAll { $0.itemID == entry.itemID }
        entries.append(entry)
        try save(entries)
    }

    func remove(itemID: UUID) throws {
        var entries = try load()
        let count = entries.count
        entries.removeAll { $0.itemID == itemID }
        guard entries.count != count else { return }
        try save(entries)
    }
}
