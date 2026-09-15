// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// ViewModifier for notification handlers (enqueue and convert immediately)
struct ContentViewNotificationHandlers: ViewModifier {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ContentViewNotificationHandlers")

    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    @Binding var currentOutputFolder: URL
    @Binding var outputFolder: String
    @Binding var isFileImporterPresented: Bool
    @Binding var pendingConvertAfterImport: Bool
    let selectedPreset: ExportPreset
    let videoLoopDefaultMuted: Bool
    let startConversion: () async -> Void
    /// Switches the app to a given preset (with the usual side effects) before a
    /// per-preset "Convert Immediately" App Intent starts conversion.
    let applyPreset: (ExportPreset) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .enqueueFileURL)) { notification in
                handleEnqueueNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertImmediately)) { notification in
                handleConvertImmediatelyNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertPickFiles)) { notification in
                handleConvertPickFilesNotification(notification)
            }
            .task { @MainActor in
                // Let this modifier's subscriptions attach before replaying a
                // cold-launch request. An earlier onAppear drain is harmless:
                // unclaimed requests remain buffered until a receiver is ready.
                await Task.yield()
                guard !Task.isCancelled else { return }
                PendingAppIntentRequests.shared.drain()
            }
    }

    /// Handles a convert/enqueue App Intent that ran without any file input
    /// (e.g. a Spotlight/Siri phrase, which can't attach files): switch to the
    /// carried preset, bring the window forward, and present the file importer.
    /// For convert intents (`startConversion` flag absent or true), conversion
    /// starts once the user picks files; the enqueue intent only queues them.
    private func handleConvertPickFilesNotification(_ notification: Notification) {
        guard case let .pickFiles(preset, shouldConvert) = AppIntentHandoff(
            notification: notification, selectedPreset: selectedPreset
        ) else { return }
        guard PendingAppIntentRequests.shared.claim(notification) else { return }
        AppIntentOperationQueue.shared.enqueue {
            applyPreset(preset)
            pendingConvertAfterImport = shouldConvert
            NSApp.activate(ignoringOtherApps: true)
            isFileImporterPresented = true
        }
    }

    private func handleEnqueueNotification(_ notification: Notification) {
        guard case let .enqueue(urls) = AppIntentHandoff(
            notification: notification, selectedPreset: selectedPreset
        ) else { return }

        guard PendingAppIntentRequests.shared.claim(notification) else { return }
        AppIntentOperationQueue.shared.enqueue {
            enqueueFiles(urls)
        }
    }

    private func enqueueFiles(_ urls: [URL]) {
        let importPreset = selectedPreset
        let importFolder = outputFolder
        let importSettings = VideoImportSettings()
        let naming = VideoImportNamingSettings(preset: importPreset)

        for url in urls {
            guard !droppedFiles.contains(where: { $0.url == url }) else { continue }

            guard let placeholder = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: importFolder,
                preset: importPreset, settings: importSettings, namingSettings: naming
            ) else {
                Self.logger.info("Skipping unsupported file from AppIntent: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            droppedFiles.append(placeholder)
            queueOrder.append(placeholder.id)
            if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                droppedFiles[droppedFiles.count - 1].isMuted = true
            }
            let placeholderID = placeholder.id

            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(
                    for: url,
                    outputFolder: importFolder,
                    preset: importPreset,
                    generateRowThumbnailIfMissing: false,
                    counter: placeholder.customCounterValue, namingSettings: naming
                )

                await MainActor.run {
                    if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        droppedFiles[index].apply(details: details)
                        droppedFiles[index].detailsLoaded = true
                    }
                }

                if details.thumbnailData == nil {
                    Task.detached(priority: .background) {
                        let thumbnailData = await VideoFileUtils.getCachedThumbnail(url: url, generateRowThumbnailIfMissing: true)
                        guard let thumbnailData else { return }
                        await MainActor.run {
                            if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }),
                               droppedFiles[index].thumbnailData == nil {
                                droppedFiles[index].thumbnailData = thumbnailData
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleConvertImmediatelyNotification(_ notification: Notification) {
        guard case let .convert(fileURLs, folderURL, preset) = AppIntentHandoff(
            notification: notification, selectedPreset: selectedPreset
        ) else { return }

        guard PendingAppIntentRequests.shared.claim(notification) else { return }

        let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID

        AppIntentOperationQueue.shared.enqueue {
            // The six presets exposed by the 4.5 application contract go through
            // the same persisted planner and serialized executor as agent jobs.
            // Wider presets retain the established queue path until the contract
            // can represent their additional settings faithfully.
            if let request = AppIntentApplicationJobBridge.makeRequest(
                sourceURLs: fileURLs,
                destinationFolderURL: folderURL,
                preset: preset,
                requestID: requestID
            ) {
                currentOutputFolder = folderURL
                outputFolder = folderURL.path
                applyPreset(preset)
                AppIntentApplicationJobBridge.persistFileAccess(for: request)
                do {
                    _ = try await ApplicationJobService.shared.planAndSubmit(request)
                } catch {
                    addFailedSharedSubmissionRows(
                        request: request,
                        preset: preset,
                        message: ApplicationAgentToolFailure(error: error).message
                    )
                    Self.logger.error(
                        "Shared App Intent submission failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                return
            }

            for fileURL in fileURLs {
                if var videoItem = await VideoFileUtils.createVideoItem(
                    from: fileURL,
                    outputFolder: folderURL.path,
                    preset: preset
                ) {
                    await MainActor.run {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            if preset == .videoLoop && videoLoopDefaultMuted {
                                videoItem.isMuted = true
                            }
                            droppedFiles.append(videoItem)
                            queueOrder.append(videoItem.id)
                        }
                    }
                }
            }
            // Metadata loading suspends. Apply the request's settings only after
            // import, immediately before conversion snapshots them. The modifier's
            // captured selectedPreset may be stale, so apply unconditionally.
            currentOutputFolder = folderURL
            outputFolder = folderURL.path
            applyPreset(preset)
            await startConversion()
        }
    }

    private func addFailedSharedSubmissionRows(
        request: ApplicationConversionRequest,
        preset: ExportPreset,
        message: String
    ) {
        for (index, sourceURL) in request.sourceURLs.enumerated() {
            guard !droppedFiles.contains(where: { $0.url == sourceURL }) else { continue }
            let sourceDestination = request.sourceSettings?.indices.contains(index) == true
                ? request.sourceSettings?[index].destinationFolderURL
                : nil
            let outputFolder = sourceDestination ?? request.destinationFolderURL
            var item = VideoFileUtils.makePlaceholderItem(
                from: sourceURL,
                outputFolder: outputFolder.path,
                preset: preset
            ) ?? VideoItem(
                url: sourceURL,
                name: sourceURL.lastPathComponent,
                size: 0,
                duration: "--:--",
                status: .failed,
                progress: 0,
                eta: nil
            )
            item.status = .failed
            item.progress = 0
            item.conversionError = message
            item.applicationJobOrigin = .appIntent
            item.applicationPresetID = ApplicationPresetID(exportPreset: preset)
            droppedFiles.append(item)
            queueOrder.append(item.id)
        }
    }
}
