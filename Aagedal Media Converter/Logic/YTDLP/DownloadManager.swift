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
    func loadDownloadedFileDetails(itemID: UUID, fileURL: URL, autoEncode: Bool) -> Task<Void, Never> {
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
                    // Update file size
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: partialFile.path),
                       let fileSize = attrs[.size] as? Int64 {
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
        audioOnly: Bool = false
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
            audioOnly: audioOnly
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
                audioOnly: entry.audioOnly
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
            audioOnly: item.downloadAudioOnly
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
        audioOnly: Bool = false
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
            audioOnly: audioOnly
        )

        return itemID
    }

    /// Probes a playlist/channel URL and adds one queue item per entry, then
    /// downloads each sequentially. Single-video URLs work too — the probe
    /// returns one entry and you get the same result as `startDownload`.
    /// - Returns: IDs of every queue item that was created (in playlist order).
    @discardableResult
    func startPlaylistDownload(
        url urlString: String,
        items: Binding<[VideoItem]>,
        outputFolder: URL,
        audioOnly: Bool = false
    ) async -> [UUID] {
        guard await isYTDLPConfigured() else {
            logger.error("yt-dlp not configured. Please configure in Settings > General > Video Downloads.")
            return []
        }

        self.videoItems = items
        self.outputFolder = outputFolder

        // Probe the playlist before touching the queue. If this fails we don't
        // want to leave a stray placeholder behind.
        let entries: [YTDLPPlaylistEntry]
        do {
            entries = try await ytdlpService.fetchPlaylistEntries(url: urlString)
        } catch {
            logger.error("Failed to fetch playlist entries: \(error.localizedDescription)")
            return []
        }

        guard !entries.isEmpty else {
            logger.warning("Playlist probe returned no entries for: \(urlString)")
            return []
        }

        logger.info("Spawning \(entries.count) queue item(s) from playlist")

        // Snap the automation defaults once so every spawned item shares the same
        // value — toggling "Encode" mid-playlist shouldn't affect already-queued items.
        let autoEncode = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        let uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)

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
            item.downloadProgress = 0
            item.downloadHasProgress = false

            items.wrappedValue.append(item)
            itemIDs.append(item.id)
        }

        // Run playlist downloads sequentially to avoid competing for bandwidth. Each item
        // still gets its own cancellation control so cancelling it cannot affect a separate
        // download that may already be running outside this playlist.
        for itemID in itemIDs {
            guard !Task.isCancelled else {
                cancelDownload(itemID: itemID)
                continue
            }
            guard let item = self.findItem(itemID), let sourceURL = item.sourceURL else { continue }

            self.updateItem(itemID) { $0.isDownloading = true }

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

        return itemIDs
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
            if forceOverwrite {
                await self.performForceDownload(
                    itemID: itemID, urlString: urlString, outputFolder: outputFolder,
                    liveFromStart: liveFromStart, audioOnly: audioOnly, control: control
                )
            } else {
                await self.performDownload(
                    itemID: itemID, urlString: urlString, outputFolder: outputFolder,
                    liveFromStart: liveFromStart, audioOnly: audioOnly, control: control
                )
            }
        }
        downloadTasks[itemID] = (control, task)
        return task
    }

    /// Performs the actual download
    private func performDownload(
        itemID: UUID,
        urlString: String,
        outputFolder: URL,
        liveFromStart: Bool,
        audioOnly: Bool,
        control: YTDLPDownloadControl
    ) async {
        let downloadStartTime = Date()
        logger.info("[TIMING] performDownload started at \(downloadStartTime)")

        // Hold a security-scoped resource on the output folder for the duration of
        // the subprocess. Required when the folder was restored from a bookmark
        // (relaunch); harmless when the folder is already accessible (~/Downloads).
        let folderAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: outputFolder)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(folderAccess) }

        // Add to download history immediately (for easy retry of failed downloads)
        let initialTitle = URL(string: urlString)?.host ?? "Download"
        DownloadHistoryService.addEntry(url: urlString, title: initialTitle)

        // Fetch thumbnail in parallel (doesn't block download)
        fetchThumbnailInBackground(itemID: itemID, urlString: urlString)

        // Start the actual download immediately (don't wait for metadata)
        do {
            let actualDownloadStartTime = Date()
            logger.info("[TIMING] Starting download immediately for: \(urlString)")

            let result = try await ytdlpService.download(
                url: urlString,
                outputFolder: outputFolder,
                forceOverwrite: false,
                liveFromStart: liveFromStart,
                audioOnly: audioOnly,
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

            // Download complete - update item
            let downloadElapsed = Date().timeIntervalSince(actualDownloadStartTime)
            let totalElapsed = Date().timeIntervalSince(downloadStartTime)
            logger.info("[TIMING] Download complete: \(result.outputURL.path)")
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
                item.name = result.outputURL.lastPathComponent
                item.isDownloading = false
                item.isLiveStreamRecording = false
                item.liveRecordingFileSize = nil
                item.liveRecordingDuration = nil
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
                    itemID: itemID, fileURL: result.outputURL, autoEncode: shouldAutoEncode
                )
            }

        } catch let error as YTDLPError {
            guard downloadControls[itemID] === control else { return }
            // Stop live recording stat updates for any error
            stopLiveRecordingStatUpdates(itemID: itemID)

            switch error {
            case .fileAlreadyExists(let path, let title):
                logger.warning("File already exists: \(path)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = "File already exists"
                    item.fileAlreadyExistsPath = path
                    item.status = .failed
                    item.name = title
                    item.liveRecordingFileSize = nil
                    item.liveRecordingDuration = nil
                }
            case .liveRecordingStopped:
                logger.info("Download stopped for item: \(itemID), searching for partial file...")

                // Recover only a destination emitted by this download; another
                // recording in the same folder must never be adopted or renamed.
                if let partialFile = control.partialFile(in: outputFolder) {
                    logger.info("Found partial file: \(partialFile.path)")

                    // Rename the file to remove .part extension if present
                    var finalFile = partialFile
                    let filename = partialFile.lastPathComponent
                    if filename.hasSuffix(".part") {
                        let newFilename = String(filename.dropLast(5)) // Remove ".part"
                        let newURL = partialFile.deletingLastPathComponent().appendingPathComponent(newFilename)
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
                        item.isLiveStreamRecording = false
                        item.downloadStopping = false
                        item.liveRecordingFileSize = nil
                        item.liveRecordingDuration = nil
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
                        item.isLiveStreamRecording = false
                        item.downloadStopping = false
                        item.liveRecordingFileSize = nil
                        item.liveRecordingDuration = nil
                        item.downloadError = "Stopped - partial file not found"
                        item.status = .failed
                    }
                }
            case .cancelled:
                logger.info("Download cancelled for item: \(itemID)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.isLiveStreamRecording = false
                    item.downloadStopping = false
                    item.liveRecordingFileSize = nil
                    item.liveRecordingDuration = nil
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
                    item.isLiveStreamRecording = false
                    item.liveRecordingFileSize = nil
                    item.liveRecordingDuration = nil
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
                item.isLiveStreamRecording = false
                item.liveRecordingFileSize = nil
                item.liveRecordingDuration = nil
                item.downloadSpeed = nil
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
            item.isLiveStreamRecording = false
            item.downloadStopping = false
            item.liveRecordingFileSize = nil
            item.liveRecordingDuration = nil
            item.downloadSpeed = nil
            item.downloadError = "Cancelled"
            item.status = .cancelled
        }
    }

    func stopLiveDownload(itemID: UUID) {
        logger.info("Stop live download requested for item: \(itemID)")

        // Immediately update UI to show stopping state (provides instant feedback)
        updateItem(itemID) { item in
            item.downloadStopping = true
        }

        // Stop live recording stat updates immediately to prevent further polling
        stopLiveRecordingStatUpdates(itemID: itemID)

        // Stop this item's process immediately while leaving its orchestration task alive
        // so it can recover and finalize the partial recording.
        _ = downloadControls[itemID]?.stopLiveRecording()

        // Note: The item state will be updated by performDownload when it catches liveRecordingStopped
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
            audioOnly: item.downloadAudioOnly
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
            forceOverwrite: true
        )
    }

    /// Performs a forced download (overwrites existing files)
    private func performForceDownload(
        itemID: UUID,
        urlString: String,
        outputFolder: URL,
        liveFromStart: Bool,
        audioOnly: Bool,
        control: YTDLPDownloadControl
    ) async {
        let folderAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: outputFolder)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(folderAccess) }

        // Record a history entry upfront so the URL stays retry-able even if this
        // forced run is cancelled or fails before completion. Mirrors performDownload.
        let initialTitle = URL(string: urlString)?.host ?? "Download"
        DownloadHistoryService.addEntry(url: urlString, title: initialTitle)

        do {
            // Start the actual download with force overwrite
            logger.info("Starting forced download for: \(urlString)")

            let result = try await ytdlpService.download(
                url: urlString,
                outputFolder: outputFolder,
                forceOverwrite: true,
                liveFromStart: liveFromStart,
                audioOnly: audioOnly,
                control: control,
                progress: { [weak self] progress, speed, isLiveStream in
                    Task { @MainActor in
                        guard let self,
                              self.downloadControls[itemID] === control else { return }
                        self.updateItem(itemID) { item in
                            item.downloadProgress = progress
                            item.downloadHasProgress = true
                            item.downloadSpeed = speed
                            if isLiveStream {
                                item.isLiveStreamRecording = true
                            }
                            item.progress = progress
                        }
                    }
                },
                titleUpdate: { [weak self] title in
                    Task { @MainActor in
                        guard let self,
                              self.downloadControls[itemID] === control else { return }
                        self.updateItem(itemID) { item in
                            item.name = title
                        }
                    }
                }
            )

            guard downloadControls[itemID] === control else {
                logger.info("Ignoring completion from a cancelled or superseded forced download: \(itemID)")
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

            // Download complete - update item
            logger.info("Force download complete: \(result.outputURL.path)")

            // Save to download history
            DownloadHistoryService.addEntry(
                url: urlString,
                title: result.title.isEmpty
                    ? result.outputURL.deletingPathExtension().lastPathComponent
                    : result.title,
                outputFileName: result.outputURL.lastPathComponent
            )

            updateItem(itemID) { item in
                item.url = result.outputURL
                item.name = result.outputURL.lastPathComponent
                item.isDownloading = false
                item.downloadProgress = 1.0
                item.downloadSpeed = nil
                item.progress = 0  // Reset for encoding
                item.status = .waiting
                item.detailsLoaded = false

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
                    itemID: itemID, fileURL: result.outputURL, autoEncode: shouldAutoEncode
                )
            }

        } catch YTDLPError.cancelled {
            guard downloadControls[itemID] === control else { return }
            logger.info("Force download cancelled for item: \(itemID)")
            updateItem(itemID) { item in
                item.isDownloading = false
                item.isLiveStreamRecording = false
                item.downloadStopping = false
                item.liveRecordingFileSize = nil
                item.liveRecordingDuration = nil
                item.downloadSpeed = nil
                item.downloadError = "Cancelled"
                item.status = .cancelled
            }
        } catch {
            guard downloadControls[itemID] === control else { return }
            logger.error("Force download failed: \(error.localizedDescription)")

            updateItem(itemID) { item in
                item.isDownloading = false
                item.downloadError = error.localizedDescription
                item.status = .failed
                item.downloadSpeed = nil
            }
        }

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

    init(itemID: UUID, url: String, scheduledTime: Date, liveFromStart: Bool, autoEncode: Bool, uploadEnabled: Bool, audioOnly: Bool) {
        self.itemID = itemID
        self.url = url
        self.scheduledTime = scheduledTime
        self.liveFromStart = liveFromStart
        self.autoEncode = autoEncode
        self.uploadEnabled = uploadEnabled
        self.audioOnly = audioOnly
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
