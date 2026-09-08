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
