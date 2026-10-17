// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Captured by callbacks so invalidating a batch also invalidates work already
/// dispatched to the main actor, without another suspension before UI mutation.
final class ConversionCallbackOwnership: Sendable {
    let id = UUID()
    private let active = OSAllocatedUnfairLock(initialState: true)

    var isActive: Bool { active.withLock { $0 } }

    func invalidate() { active.withLock { $0 = false } }
}

/// Queue decisions and item mutations without process, binding, or actor dependencies.
enum ConversionQueueState {
    enum CancellationScope {
        case converting
        case waitingAndConverting
    }

    static func nextItem(in items: [VideoItem], allowedItemIDs: Set<UUID>?) -> VideoItem? {
        items.first {
            $0.applicationJobID == nil
                && $0.status == .waiting
                && (allowedItemIDs?.contains($0.id) ?? true)
        }
    }

    /// Resolve callback targets by source identity and current state, never by
    /// positions retained across asynchronous encoding or probing.
    static func callbackIndices(
        for selectedItems: [VideoItem],
        in items: [VideoItem],
        status: ConversionManager.ConversionStatus = .converting
    ) -> [Int] {
        selectedItems.compactMap { selected in
            items.firstIndex {
                $0.id == selected.id && $0.url == selected.url && $0.status == status
            }
        }
    }

    static func applyProgress(
        _ progress: Double,
        message: String?,
        isDuration: Bool,
        for selectedItems: [VideoItem],
        ownership: ConversionCallbackOwnership,
        in items: inout [VideoItem]
    ) {
        guard ownership.isActive else { return }
        for index in callbackIndices(for: selectedItems, in: items) {
            items[index].progress = progress
            if isDuration {
                items[index].eta = message
                items[index].statusMessage = nil
            } else {
                items[index].statusMessage = message
            }
        }
    }

    static func applyETA(
        _ eta: String?,
        for selectedItems: [VideoItem],
        ownership: ConversionCallbackOwnership,
        in items: inout [VideoItem]
    ) {
        guard ownership.isActive else { return }
        for index in callbackIndices(for: selectedItems, in: items) {
            items[index].eta = eta
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
        let activeItems = items.filter {
            $0.applicationJobID == nil && $0.status != .cancelled && $0.status != .failed
        }
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
            guard items[index].applicationJobID == nil else { continue }
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

struct ApplicationJobSourceID: Hashable, Sendable {
    let jobID: ApplicationJobID
    let sourceIndex: Int
}

/// Projects authoritative jobs without reformatting immutable settings or
/// re-reading completed outputs on every unrelated progress snapshot.
enum ApplicationJobRowProjection {
    /// A retry gets fresh ownership while the old durable record stays intact.
    /// Active batch rows cannot be detached while their executor still owns them.
    static func releaseTerminalOwnership(of item: inout VideoItem) -> ApplicationJobSourceID? {
        guard item.status != .waiting, item.status != .converting,
              let jobID = item.applicationJobID, let index = item.applicationJobSourceIndex else { return nil }
        item.applicationJobID = nil
        item.applicationJobSourceIndex = nil
        item.applicationJobOrigin = nil
        item.applicationPresetID = nil
        item.applicationJobSettingsSummary = nil
        return ApplicationJobSourceID(jobID: jobID, sourceIndex: index)
    }

    static func apply(_ record: ApplicationJobRecord, sourceIndex: Int, outputURL: URL?, to item: inout VideoItem) {
        let needsSettings = item.applicationJobID != record.id || item.applicationJobSourceIndex != sourceIndex
        let previousStatus = item.status
        let previousOutputURL = item.outputURL
        item.applicationJobID = record.id
        item.applicationJobSourceIndex = sourceIndex
        item.applicationJobOrigin = record.request.origin
        item.applicationPresetID = record.request.presetID
        if needsSettings {
            item.applicationJobSettingsSummary = record.request.acceptedSettingsSummary(sourceIndex: sourceIndex)
        }
        item.outputURL = outputURL
        if let sourceSettings = record.request.sourceSettings, sourceSettings.indices.contains(sourceIndex) {
            let settings = sourceSettings[sourceIndex]
            item.analyticsSourceRange = AnalyticsSourceRange(start: settings.trimStart, end: settings.trimEnd)
        } else {
            item.analyticsSourceRange = AnalyticsSourceRange()
        }
        item.progress = record.progress ?? 0
        item.eta = nil
        item.statusMessage = switch record.state {
        case .queued: "Queued"
        case .running: record.stage ?? "Encoding"
        case .cancelling: "Cancelling"
        case .succeeded: nil
        case .failed: "Shared job failed"
        case .cancelled: nil
        case .interrupted: "Interrupted after app restart"
        }
        item.conversionError = switch record.state {
        case .failed, .interrupted: record.diagnostic
        default: nil
        }
        item.status = switch record.state {
        // Treat queued shared jobs as active in the legacy row model. This keeps
        // manual encode actions from claiming work already owned by the service.
        case .queued, .running, .cancelling: .converting
        case .succeeded: .done
        case .failed, .interrupted: .failed
        case .cancelled: .cancelled
        }
        // A later failure or cancellation does not undo earlier batch outputs.
        if record.outputURLs.indices.contains(sourceIndex) {
            item.status = .done
            item.statusMessage = nil
            item.conversionError = nil
        }
        if item.status == .done {
            item.progress = 1
            if previousStatus != .done || previousOutputURL != outputURL {
                item.refreshOutputFileCache()
            }
        }
    }
}
