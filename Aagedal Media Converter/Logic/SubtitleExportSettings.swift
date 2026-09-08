// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured before conversion suspends so later preference edits affect the next job.
struct SubtitleExportSettings: Sendable {
    let keepSubtitles: Bool

    init(defaults: UserDefaults = .standard) {
        keepSubtitles = defaults.bool(forKey: AppConstants.keepSubtitlesKey)
    }
}

/// Owns the optional source map together with its container-compatible encoder.
enum SubtitleMappingPlan: Equatable, Sendable {
    case omit
    case copy
    case quickTimeText

    init(keepSubtitles: Bool, outputExtension: String) {
        guard keepSubtitles else {
            self = .omit
            return
        }
        switch outputExtension.lowercased() {
        case "mkv": self = .copy
        case "mp4", "mov": self = .quickTimeText
        default: self = .omit
        }
    }

    var arguments: [String] {
        switch self {
        case .omit: return []
        case .copy: return ["-map", "0:s?", "-c:s", "copy"]
        case .quickTimeText: return ["-map", "0:s?", "-c:s", "mov_text"]
        }
    }
}
