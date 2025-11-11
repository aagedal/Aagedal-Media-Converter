// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Defines user-configurable strategies for trimming the preview cache.

import Foundation

enum PreviewCacheCleanupPolicy: String, CaseIterable, Identifiable {
    case purgeOnLaunch
    case keepOneDay
    case keepThreeDays
    case keepSevenDays
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .purgeOnLaunch:
            return "Delete on launch"
        case .keepOneDay:
            return "Keep 1 day"
        case .keepThreeDays:
            return "Keep 3 days"
        case .keepSevenDays:
            return "Keep 7 days"
        case .manual:
            return "Manual"
        }
    }

    var description: String {
        switch self {
        case .purgeOnLaunch:
            return "Removes all cached previews every time the app launches. Best for freeing disk space."
        case .keepOneDay:
            return "Automatically removes preview cache items that have not been accessed in the last day."
        case .keepThreeDays:
            return "Removes cached previews older than three days to strike a balance between speed and space."
        case .keepSevenDays:
            return "Keeps cached previews for up to a week before cleaning them up automatically."
        case .manual:
            return "Leaves the cache alone until you clear it manually from the settings screen."
        }
    }

    /// Number of days of cache to retain. `nil` means use a non time-based strategy.
    var retentionDays: Int? {
        switch self {
        case .purgeOnLaunch, .manual:
            return nil
        case .keepOneDay:
            return 1
        case .keepThreeDays:
            return 3
        case .keepSevenDays:
            return 7
        }
    }
}
