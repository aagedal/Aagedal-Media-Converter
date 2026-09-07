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
    static let shared = DownloadManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "DownloadManager")
    private let ytdlpService = YTDLPService()

    /// Active download tasks keyed by VideoItem ID
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]

    /// Per-item subprocess cancellation, kept separate so concurrent downloads cannot
    /// stop whichever yt-dlp process happened to register most recently.
    private var downloadControls: [UUID: YTDLPDownloadControl] = [:]

    /// Live recording stat update tasks keyed by VideoItem ID
    private var liveRecordingStatTasks: [UUID: Task<Void, Never>] = [:]

    /// Queue of video items (bound from ContentView)
    var videoItems: Binding<[VideoItem]>?

    /// Output folder for downloads
    var outputFolder: URL?

    /// Callback to trigger encoding for a specific item (set by ContentView)
    var onAutoEncode: ((UUID) -> Void)?

    private init() {}

    // MARK: - Live Recording Stats

    /// Starts periodic updates of file size and duration for live stream recording
    private func startLiveRecordingStatUpdates(itemID: UUID, outputFolder: URL) {
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

                // Get the item's name to use as a hint for finding the right partial file
                let nameHint = self.findItem(itemID)?.name

                // Find the partial file being written (using name hint to find the right one)
                if let partialFile = findPartialFile(in: outputFolder, nameHint: nameHint) {
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
                    if let duration = duration {
                        if updateCount % 10 == 1 {
                            logger.info("[LiveStats] Update #\(updateCount): duration = \(String(format: "%.1f", duration))s")
                        }
                        await MainActor.run {
                            self.updateItem(itemID) { item in
                                item.liveRecordingDuration = duration
                            }
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
        Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                // Fetch metadata to get thumbnail URL
                let metadata = try await self.ytdlpService.fetchMetadata(url: urlString)

                // Update title if we got one
                if !metadata.title.isEmpty {
                    await MainActor.run {
                        self.updateItem(itemID) { item in
                            if item.name == "Fetching info..." || item.name.isEmpty {
                                item.name = metadata.title
                            }
                        }
                    }
                }

                // Download thumbnail if URL is available
                if let thumbnailURL = metadata.thumbnailURL {
                    let (data, response) = try await URLSession.shared.data(from: thumbnailURL)

                    // Verify it's an image
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       !data.isEmpty {
                        await MainActor.run {
                            self.updateItem(itemID) { item in
                                item.thumbnailData = data
                            }
                            self.logger.info("Fetched thumbnail for download: \(metadata.title)")
                        }
                    }
                }
            } catch {
                // Silently fail - thumbnail is not critical
                await MainActor.run {
                    self.logger.info("Could not fetch thumbnail: \(error.localizedDescription)")
                }
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
        let persisted = Self.loadPersistedScheduledDownloads()
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
        Self.savePersistedScheduledDownloads(rewritten)
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
        let control = YTDLPDownloadControl()
        downloadControls[itemID] = control
        let task = Task {
            await self.performDownload(
                itemID: itemID,
                urlString: sourceURL,
                outputFolder: folder,
                liveFromStart: item.downloadLiveFromStart,
                audioOnly: item.downloadAudioOnly,
                control: control
            )
        }
        downloadTasks[itemID] = task
    }

    /// Checks if yt-dlp is available and configured
    func isYTDLPConfigured() async -> Bool {
        await YTDLPUpdateService.shared.isYTDLPAvailable()
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
        let control = YTDLPDownloadControl()
        downloadControls[itemID] = control
        let task = Task {
            await self.performDownload(
                itemID: itemID,
                urlString: urlString,
                outputFolder: outputFolder,
                liveFromStart: liveFromStart,
                audioOnly: audioOnly,
                control: control
            )
        }
        downloadTasks[itemID] = task

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
            guard let item = self.findItem(itemID), let sourceURL = item.sourceURL else { continue }

            self.updateItem(itemID) { $0.isDownloading = true }

            // performDownload kicks off its own thumbnail fetch — don't double-probe.
            let control = YTDLPDownloadControl()
            downloadControls[itemID] = control
            await self.performDownload(
                itemID: itemID,
                urlString: sourceURL,
                outputFolder: outputFolder,
                liveFromStart: false,
                audioOnly: item.downloadAudioOnly,
                control: control
            )
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
        defer {
            if downloadControls[itemID] === control {
                downloadTasks.removeValue(forKey: itemID)
                downloadControls.removeValue(forKey: itemID)
            }
        }

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

            updateItem(itemID) { item in
                if liveFromStart {
                    item.isLiveStreamRecording = true
                }
            }

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
                            self.startLiveRecordingStatUpdates(itemID: itemID, outputFolder: outputFolder)
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
                Task.detached {
                    let details = await VideoFileUtils.loadDetails(for: item.url)
                    await MainActor.run {
                        guard self.findItem(itemID)?.url == result.outputURL else { return }
                        self.updateItem(itemID) { item in
                            item.apply(details: details)
                            item.detailsLoaded = true
                        }

                        // Trigger auto-encode if enabled
                        if shouldAutoEncode {
                            self.logger.info("Auto-encoding enabled for downloaded item: \(itemID)")
                            self.onAutoEncode?(itemID)
                        }
                    }
                }
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

                // Get the item's name to help find the right partial file
                let nameHint = findItem(itemID)?.name

                // Try to find the partial file in the output folder
                if let partialFile = findPartialFile(in: outputFolder, nameHint: nameHint) {
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
                    Task.detached { [finalFile] in
                        let details = await VideoFileUtils.loadDetails(for: finalFile)
                        await MainActor.run {
                            guard self.findItem(itemID)?.url == finalFile else { return }
                            self.updateItem(itemID) { item in
                                item.apply(details: details)
                                item.detailsLoaded = true
                            }
                        }
                    }
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

        // Stop live recording stat updates immediately
        stopLiveRecordingStatUpdates(itemID: itemID)

        _ = downloadControls[itemID]?.cancel()

        if let task = downloadTasks[itemID] {
            task.cancel()
            downloadTasks.removeValue(forKey: itemID)
        }
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
        let control = YTDLPDownloadControl()
        downloadControls[itemID] = control
        let task = Task {
            await self.performDownload(
                itemID: itemID,
                urlString: sourceURL,
                outputFolder: outputFolder,
                liveFromStart: item.downloadLiveFromStart,
                audioOnly: item.downloadAudioOnly,
                control: control
            )
        }
        downloadTasks[itemID] = task
    }

    /// Force re-downloads, overwriting existing file
    func forceRedownload(itemID: UUID) async {
        guard let item = findItem(itemID),
              let sourceURL = item.sourceURL,
              let outputFolder = outputFolder else {
            return
        }

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
        let control = YTDLPDownloadControl()
        downloadControls[itemID] = control
        let task = Task {
            await self.performForceDownload(
                itemID: itemID,
                urlString: sourceURL,
                outputFolder: outputFolder,
                liveFromStart: item.downloadLiveFromStart,
                audioOnly: item.downloadAudioOnly,
                control: control
            )
        }
        downloadTasks[itemID] = task
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
        defer {
            if downloadControls[itemID] === control {
                downloadTasks.removeValue(forKey: itemID)
                downloadControls.removeValue(forKey: itemID)
            }
        }
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
                Task.detached {
                    let details = await VideoFileUtils.loadDetails(for: item.url)
                    await MainActor.run {
                        guard self.findItem(itemID)?.url == result.outputURL else { return }
                        self.updateItem(itemID) { item in
                            item.apply(details: details)
                            item.detailsLoaded = true
                        }

                        // Trigger auto-encode if enabled
                        if shouldAutoEncode {
                            self.logger.info("Auto-encoding enabled for re-downloaded item: \(itemID)")
                            self.onAutoEncode?(itemID)
                        }
                    }
                }
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

    /// Finds the most recently modified video file in the output folder (including .part files)
    /// - Parameters:
    ///   - folder: The folder to search in
    ///   - nameHint: Optional filename hint to prioritize matching files (e.g., item name without extension)
    private func findPartialFile(in folder: URL, nameHint: String? = nil) -> URL? {
        let fileManager = FileManager.default
        let videoExtensions = ["mp4", "mkv", "webm", "mov", "avi", "flv", "ts", "m4v", "part"]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Find video files modified recently. 5 minutes covers downloads that stalled
        // briefly (e.g. flaky upstream, sleep/wake) before the user hit stop — a 60s
        // window missed those cases and reported "partial file not found".
        let recentCutoff = Date().addingTimeInterval(-300)

        let recentVideoFiles = contents.compactMap { url -> (URL, Date)? in
            // Check if it's a video file or .part file
            let ext = url.pathExtension.lowercased()
            guard videoExtensions.contains(ext) || url.lastPathComponent.contains(".part") else {
                return nil
            }

            // Get modification date
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate,
                  modDate > recentCutoff else {
                return nil
            }

            return (url, modDate)
        }

        // If we have a name hint, try to find a file matching it first
        if let hint = nameHint, !hint.isEmpty {
            // Look for files containing the hint (handles both with and without .part extension)
            let matchingFiles = recentVideoFiles.filter { url, _ in
                url.lastPathComponent.contains(hint)
            }
            if let match = matchingFiles.sorted(by: { $0.1 > $1.1 }).first {
                logger.info("Found matching partial file: \(match.0.lastPathComponent)")
                return match.0
            }
        }

        // Fall back to most recently modified file
        let sorted = recentVideoFiles.sorted { $0.1 > $1.1 }
        if let mostRecent = sorted.first {
            logger.info("Found partial file: \(mostRecent.0.lastPathComponent), modified: \(mostRecent.1)")
            return mostRecent.0
        }

        return nil
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

    private static let persistedScheduledDownloadsKey = "persistedScheduledDownloads.v1"

    private struct PersistedScheduledDownload: Codable {
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
            audioOnly = try container.decodeIfPresent(Bool.self, forKey: .audioOnly) ?? false
        }
    }

    private static func loadPersistedScheduledDownloads() -> [PersistedScheduledDownload] {
        guard let data = UserDefaults.standard.data(forKey: persistedScheduledDownloadsKey),
              let entries = try? JSONDecoder().decode([PersistedScheduledDownload].self, from: data) else {
            return []
        }
        return entries
    }

    private static func savePersistedScheduledDownloads(_ entries: [PersistedScheduledDownload]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: persistedScheduledDownloadsKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: persistedScheduledDownloadsKey)
        }
    }

    private func appendPersistedSchedule(_ entry: PersistedScheduledDownload) {
        var list = Self.loadPersistedScheduledDownloads()
        list.removeAll { $0.itemID == entry.itemID }
        list.append(entry)
        Self.savePersistedScheduledDownloads(list)
    }

    private func removePersistedSchedule(itemID: UUID) {
        var list = Self.loadPersistedScheduledDownloads()
        let before = list.count
        list.removeAll { $0.itemID == itemID }
        guard list.count != before else { return }
        Self.savePersistedScheduledDownloads(list)
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
