// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A completed output remains eligible across unrelated batches, but never across
/// another conversion of the same queue item. Resolve it again after every hop.
struct ConversionFollowUp: Sendable {
    let itemID: UUID
    let sourceURL: URL
    let outputURL: URL?
    let ownership: ConversionCallbackOwnership
    // The retained conversion token also identifies its subtitle service run,
    // even after a row reset/cancel clears the UI's operation identifier.
    var subtitleOperationID: UUID { ownership.id }
    let analyticsOperationID = UUID()

    init(item: VideoItem, ownership: ConversionCallbackOwnership) {
        itemID = item.id
        sourceURL = item.url
        outputURL = item.outputURL
        self.ownership = ownership
    }

    func index(in items: [VideoItem]) -> Int? {
        guard ownership.isActive, outputURL != nil else { return nil }
        return items.firstIndex {
            $0.id == itemID && $0.url == sourceURL && $0.outputURL == outputURL && $0.status == .done
        }
    }

    /// Reserve synchronously with conversion completion so an immediate UI cancel
    /// can invalidate the operation before its deferred service task starts.
    func reserveSubtitles(in items: inout [VideoItem]) {
        guard let index = index(in: items), items[index].subtitleEnabled else { return }
        items[index].subtitleOperationID = subtitleOperationID
        items[index].subtitleStatus = .pending
    }

    func canBeginSubtitles(in items: [VideoItem]) -> Bool {
        guard let index = index(in: items), items[index].subtitleEnabled else { return false }
        return items[index].subtitleOperationID == subtitleOperationID
    }

    func reserveAnalytics(in items: inout [VideoItem]) {
        guard let index = index(in: items), items[index].analyticsEnabled,
              !items[index].analyticsStatus.isInProgress else { return }
        items[index].analyticsOperationID = analyticsOperationID
        items[index].analyticsStatus = .pending
    }

    func analyticsIndex(in items: [VideoItem]) -> Int? {
        guard let index = index(in: items), items[index].analyticsStatus.isInProgress,
              items[index].analyticsOperationID == analyticsOperationID else { return nil }
        return index
    }
}

