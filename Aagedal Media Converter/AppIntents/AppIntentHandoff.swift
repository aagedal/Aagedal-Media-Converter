// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decodes the notification boundary without depending on a view or mutating the queue.
enum AppIntentHandoff {
    case enqueue([URL])
    case convert(files: [URL], outputFolder: URL, preset: ExportPreset)
    case pickFiles(preset: ExportPreset, startConversion: Bool)

    init?(notification: Notification, selectedPreset: ExportPreset) {
        let info = notification.userInfo ?? [:]
        let preset = (info["presetRawValue"] as? String).flatMap(ExportPreset.init(rawValue:)) ?? selectedPreset
        switch notification.name {
        case .enqueueFileURL:
            if let url = notification.object as? URL {
                self = .enqueue([url])
            } else if let urls = notification.object as? [URL] {
                self = .enqueue(urls)
            } else {
                return nil
            }
        case .convertImmediately:
            guard let folder = info["outputFolderURL"] as? URL else { return nil }
            let urls: [URL]
            if let url = info["fileURL"] as? URL {
                urls = [url]
            } else if let values = info["fileURLs"] as? [URL] {
                urls = values
            } else {
                return nil
            }
            self = .convert(files: urls, outputFolder: folder, preset: preset)
        case .convertPickFiles:
            self = .pickFiles(preset: preset, startConversion: (info["startConversion"] as? Bool) ?? true)
        default:
            return nil
        }
    }
}

/// Builds the first-party App Intent request for presets supported by the 4.5
/// shared boundary. Unsupported presets continue through the existing queue so
/// no established Shortcut silently loses settings the v1 contract cannot hold.
enum AppIntentApplicationJobBridge {
    static let requesterID = "app-intents"

    static func makeRequest(
        sourceURLs: [URL],
        destinationFolderURL: URL,
        preset: ExportPreset,
        requestID: UUID?,
        capturedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> ApplicationConversionRequest? {
        guard let presetID = ApplicationPresetID(exportPreset: preset),
              presetID.usesExistingManualSharedBridge else { return nil }

        var seen = Set<URL>()
        let uniqueSources = sourceURLs.filter {
            seen.insert($0.standardizedFileURL).inserted
        }
        guard !uniqueSources.isEmpty else { return nil }

        let presetSettings = ApplicationPresetSettings(presetID: presetID, defaults: defaults)
        let executionSettings = ApplicationRequestExecutionSettings(appIntentDefaults: defaults)
        let destinationSettings = OutputDestinationSettings(defaults: defaults)
        let sourceSettings: [ApplicationSourceExecutionSettings]?
        if destinationSettings.saveNextToOriginal {
            sourceSettings = uniqueSources.map { sourceURL in
                let path = destinationSettings.resolveFolder(
                    for: sourceURL,
                    defaultOutputFolder: destinationFolderURL.path,
                    presetSuffix: presetSettings.fileName.presetSuffix
                )
                return ApplicationSourceExecutionSettings(
                    sourceURL: sourceURL,
                    destinationFolderURL: path.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    },
                    includeDateTag: executionSettings.includeDateTag,
                    timecodeConfig: executionSettings.timecodeConfig
                )
            }
        } else {
            sourceSettings = nil
        }

        let request = ApplicationConversionRequest(
            requestID: requestID ?? UUID(),
            origin: .appIntent,
            requesterID: requesterID,
            sourceURLs: uniqueSources,
            destinationFolderURL: destinationFolderURL,
            presetID: presetID,
            presetSettings: presetSettings,
            executionSettings: executionSettings,
            sourceSettings: sourceSettings,
            idempotencyKey: requestID?.uuidString.lowercased(),
            capturedAt: capturedAt,
            defaults: defaults
        )
        guard (try? ApplicationJobRegistry.validate(request)) != nil else { return nil }
        return request
    }

    /// IntentFile URLs represent an explicit user selection. Persist those
    /// grants before the asynchronous shared service reopens them for planning,
    /// execution, or a later reconnect.
    @MainActor
    static func persistFileAccess(
        sourceURLs: [URL],
        destinationFolderURL: URL,
        bookmarks: SecurityScopedBookmarkManager = .shared
    ) {
        for sourceURL in Set(sourceURLs.map(\.standardizedFileURL)) {
            _ = bookmarks.saveBookmark(for: sourceURL)
        }
        _ = bookmarks.saveWritableBookmark(for: destinationFolderURL.standardizedFileURL)
    }

    /// Persists only destinations that the accepted request will actually use.
    /// This matters for Save Next to Original batches, where the App Intent's
    /// fallback folder is not part of the planned output set.
    @MainActor
    static func persistFileAccess(
        for request: ApplicationConversionRequest,
        bookmarks: SecurityScopedBookmarkManager = .shared
    ) {
        for sourceURL in Set(request.sourceURLs.map(\.standardizedFileURL)) {
            _ = bookmarks.saveBookmark(for: sourceURL)
        }
        var destinations = Set<URL>()
        for index in request.sourceURLs.indices {
            let sourceDestination = request.sourceSettings?.indices.contains(index) == true
                ? request.sourceSettings?[index].destinationFolderURL
                : nil
            destinations.insert(
                (sourceDestination ?? request.destinationFolderURL).standardizedFileURL
            )
        }
        for destinationURL in destinations {
            try? FileManager.default.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true
            )
            _ = bookmarks.saveWritableBookmark(for: destinationURL)
        }
    }
}

/// Routes the ordinary manual conversions representable by the v1 application
/// contract through the same serialized executor as Shortcut and agent work.
/// Items with per-file behavior that the contract cannot preserve stay on the
/// established ConversionManager path. First-party snapshots may select a
/// destination per source while agent requests retain one batch destination.
enum ManualApplicationJobBridge {
    static let requesterID = "manual-ui"

    static func makeRequest(
        items: [VideoItem],
        destinationFolderURL: URL,
        preset: ExportPreset,
        mergeClipsEnabled: Bool,
        capturedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> ApplicationConversionRequest? {
        let destinationSettings = OutputDestinationSettings(defaults: defaults)
        guard !mergeClipsEnabled,
              let presetID = ApplicationPresetID(exportPreset: preset),
              presetID.usesExistingManualSharedBridge,
              !items.isEmpty,
              items.allSatisfy({ isRepresentable($0, preset: preset) }) else {
            return nil
        }

        var sources = Set<URL>()
        guard items.allSatisfy({ sources.insert($0.url.standardizedFileURL).inserted }) else {
            return nil
        }

        guard let first = items.first else { return nil }

        let settings = ApplicationPresetSettings(presetID: presetID, defaults: defaults)
        if settings.fileName.fileNamePreferences.customTemplateUsesCounter {
            for (index, item) in items.enumerated() {
                let expected = settings.fileName.counterStart.addingReportingOverflow(index)
                guard !expected.overflow, item.customCounterValue == expected.partialValue else {
                    return nil
                }
            }
        }

        let sourceSettings = items.map { item -> ApplicationSourceExecutionSettings? in
            let destinationFolder: URL?
            if destinationSettings.saveNextToOriginal {
                guard let path = destinationSettings.resolveFolder(
                    for: item.url,
                    defaultOutputFolder: destinationFolderURL.path,
                    presetSuffix: settings.fileName.presetSuffix
                ) else { return nil }
                destinationFolder = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                destinationFolder = nil
            }
            return ApplicationSourceExecutionSettings(
                sourceURL: item.url,
                destinationFolderURL: destinationFolder,
                comment: item.comment,
                includeDateTag: item.includeDateTag,
                timecodeConfig: item.timecodeConfig,
                trimStart: item.trimStart,
                trimEnd: item.trimEnd,
                cropConfig: item.cropConfig,
                isMuted: item.isMuted,
                audioRoutingConfig: item.audioRoutingConfig,
                outputBaseNameOverride: item.outputFileNameOverride
            )
        }
        guard sourceSettings.allSatisfy({ $0 != nil }) else { return nil }

        let request = ApplicationConversionRequest(
            origin: .manual,
            requesterID: requesterID,
            sourceURLs: items.map(\.url),
            destinationFolderURL: destinationFolderURL,
            presetID: presetID,
            presetSettings: settings,
            executionSettings: ApplicationRequestExecutionSettings(
                includeDateTag: first.includeDateTag,
                timecodeConfig: first.timecodeConfig,
                defaults: defaults
            ),
            sourceSettings: sourceSettings.compactMap { $0 },
            capturedAt: capturedAt,
            defaults: defaults
        )
        guard (try? ApplicationJobRegistry.validate(request)) != nil else { return nil }
        return request
    }

    private static func isRepresentable(_ item: VideoItem, preset: ExportPreset) -> Bool {
        let hasActiveCrop = item.cropConfig?.isActive == true
        return item.status == .waiting
            && item.applicationJobID == nil
            && item.isEncodable
            && !item.isImageSequence
            && (item.audioRoutingConfig == nil
                || (preset.outputsAudioTrack && preset.appliesAudioRouting))
            && (!hasActiveCrop || preset.outputsVisualFrames)
            && (!item.isMuted || (preset.outputsVideoTrack && preset != .streamCopy))
            && (preset != .streamCopy || !hasActiveCrop)
            // The waveform preference is captured on every imported row, but
            // it only changes execution for audio-only sources. Do not force
            // ordinary video back onto the legacy path because the dormant
            // preference happens to be enabled.
            && !item.requiresWaveformVideo
            && !item.uploadEnabled
            && !item.subtitleEnabled
            && !item.analyticsEnabled
    }

    @MainActor
    static func persistFileAccess(
        sourceURLs: [URL],
        destinationFolderURL: URL,
        bookmarks: SecurityScopedBookmarkManager = .shared
    ) {
        AppIntentApplicationJobBridge.persistFileAccess(
            sourceURLs: sourceURLs,
            destinationFolderURL: destinationFolderURL,
            bookmarks: bookmarks
        )
    }

    @MainActor
    static func persistFileAccess(
        for request: ApplicationConversionRequest,
        bookmarks: SecurityScopedBookmarkManager = .shared
    ) {
        AppIntentApplicationJobBridge.persistFileAccess(
            for: request,
            bookmarks: bookmarks
        )
    }
}
