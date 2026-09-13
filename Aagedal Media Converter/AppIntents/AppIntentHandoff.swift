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
        guard let presetID = ApplicationPresetID(exportPreset: preset) else { return nil }
        // The v1 request has one destination for the whole batch. Preserve the
        // established per-source output behavior until that is representable.
        guard !OutputDestinationSettings(defaults: defaults).saveNextToOriginal else { return nil }

        var seen = Set<URL>()
        let uniqueSources = sourceURLs.filter {
            seen.insert($0.standardizedFileURL).inserted
        }
        guard !uniqueSources.isEmpty else { return nil }

        return ApplicationConversionRequest(
            requestID: requestID ?? UUID(),
            origin: .appIntent,
            requesterID: requesterID,
            sourceURLs: uniqueSources,
            destinationFolderURL: destinationFolderURL,
            presetID: presetID,
            executionSettings: ApplicationRequestExecutionSettings(appIntentDefaults: defaults),
            idempotencyKey: requestID?.uuidString.lowercased(),
            capturedAt: capturedAt,
            defaults: defaults
        )
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
}

/// Routes the ordinary manual conversions representable by the v1 application
/// contract through the same serialized executor as Shortcut and agent work.
/// Items with per-file behavior that the contract cannot preserve stay on the
/// established ConversionManager path.
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
        guard !mergeClipsEnabled,
              let presetID = ApplicationPresetID(exportPreset: preset),
              !OutputDestinationSettings(defaults: defaults).saveNextToOriginal,
              !items.isEmpty,
              items.allSatisfy(isRepresentable) else {
            return nil
        }

        var sources = Set<URL>()
        guard items.allSatisfy({ sources.insert($0.url.standardizedFileURL).inserted }) else {
            return nil
        }

        guard let first = items.first,
              items.allSatisfy({
                  $0.includeDateTag == first.includeDateTag
                      && $0.timecodeConfig == first.timecodeConfig
              }) else {
            return nil
        }

        let settings = ApplicationPresetSettings(presetID: presetID, defaults: defaults)
        if settings.fileName.fileNamePreferences.customTemplateUsesCounter {
            for (index, item) in items.enumerated() {
                let expected = settings.fileName.counterStart.addingReportingOverflow(index)
                guard !expected.overflow, item.customCounterValue == expected.partialValue else {
                    return nil
                }
            }
        }

        return ApplicationConversionRequest(
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
            capturedAt: capturedAt,
            defaults: defaults
        )
    }

    private static func isRepresentable(_ item: VideoItem) -> Bool {
        item.status == .waiting
            && item.applicationJobID == nil
            && item.isEncodable
            && !item.isImageSequence
            && item.trimStart == nil
            && item.trimEnd == nil
            && item.audioRoutingConfig == nil
            && item.cropConfig == nil
            && !item.isMuted
            && !item.waveformVideoEnabled
            && item.waveformBackgroundImageURL == nil
            && item.comment.isEmpty
            && item.outputFileNameOverride == nil
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
}
