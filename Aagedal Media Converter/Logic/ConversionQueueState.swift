// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Queue decisions and item mutations without process, binding, or actor dependencies.
enum ConversionQueueState {
    enum CancellationScope {
        case converting
        case waitingAndConverting
    }

    static func nextItem(in items: [VideoItem], allowedItemIDs: Set<UUID>?) -> VideoItem? {
        items.first {
            $0.status == .waiting && (allowedItemIDs?.contains($0.id) ?? true)
        }
    }

    /// Resolve the selected item again after asynchronous metadata preparation.
    /// Queue positions can change while probing; cancelled, removed, or replaced
    /// sources must never receive the delayed result or start encoding.
    static func beginPreparedItem(
        _ selectedItem: VideoItem,
        details: VideoFileUtils.VideoItemDetails?,
        in items: inout [VideoItem]
    ) -> Int? {
        guard let index = items.firstIndex(where: {
            $0.id == selectedItem.id && $0.url == selectedItem.url && $0.status == .waiting
        }) else { return nil }
        // A concurrent import can have completed a newer details load meanwhile.
        if !items[index].detailsLoaded, let details {
            items[index].apply(details: details)
            items[index].detailsLoaded = true
        }
        items[index].status = .converting
        return index
    }

    /// Failed and cancelled items contribute neither work nor duration. Waiting items
    /// still contribute duration, and completed items contribute their full trimmed range.
    static func overallProgress(for items: [VideoItem]) -> Double {
        let activeItems = items.filter { $0.status != .cancelled && $0.status != .failed }
        let totalDuration = activeItems.reduce(0.0) { $0 + $1.trimmedDuration }
        guard totalDuration > 0 else { return 0 }

        let completedDuration = activeItems.reduce(0.0) { sum, item in
            switch item.status {
            case .done:
                return sum + item.trimmedDuration
            case .converting:
                return sum + item.trimmedDuration * item.progress
            default:
                return sum
            }
        }
        return min(max(completedDuration / totalDuration, 0), 1)
    }

    static func cancel(_ items: inout [VideoItem], scope: CancellationScope) {
        for index in items.indices {
            let status = items[index].status
            guard status == .converting ||
                    (scope == .waitingAndConverting && status == .waiting) else { continue }
            items[index].status = .cancelled
            items[index].progress = 0
            items[index].eta = nil
            items[index].statusMessage = nil
        }
    }
}
