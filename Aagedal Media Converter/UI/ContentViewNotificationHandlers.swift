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
    }

    /// Handles a convert/enqueue App Intent that ran without any file input
    /// (e.g. a Spotlight/Siri phrase, which can't attach files): switch to the
    /// carried preset, bring the window forward, and present the file importer.
    /// For convert intents (`startConversion` flag absent or true), conversion
    /// starts once the user picks files; the enqueue intent only queues them.
    private func handleConvertPickFilesNotification(_ notification: Notification) {
        // Mark the buffered request handled so a later drain() won't replay it.
        if let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        guard case let .pickFiles(preset, shouldConvert) = AppIntentHandoff(
            notification: notification, selectedPreset: selectedPreset
        ) else { return }
        if preset != selectedPreset {
            applyPreset(preset)
        }

        pendingConvertAfterImport = shouldConvert
        NSApp.activate(ignoringOtherApps: true)
        isFileImporterPresented = true
    }

    private func handleEnqueueNotification(_ notification: Notification) {
        // Mark the buffered request handled so a later drain() won't replay it.
        if let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        guard case let .enqueue(urls) = AppIntentHandoff(
            notification: notification, selectedPreset: selectedPreset
        ) else { return }

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

        if let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        Task {
            await MainActor.run {
                currentOutputFolder = folderURL
                outputFolder = folderURL.path
                // Switch the app to the requested preset before converting so
                // startConversion() (which reads selectedPreset) uses it too.
                if preset != selectedPreset {
                    applyPreset(preset)
                }
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
            await startConversion()
        }
    }
}

