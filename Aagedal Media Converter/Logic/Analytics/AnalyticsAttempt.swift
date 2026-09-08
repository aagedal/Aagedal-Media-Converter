// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Owns manual analytics publication, including exports, across cancellation and retry.
struct AnalyticsAttempt: Sendable {
    let operationID: UUID
    let itemID: UUID
    let sourceURL: URL
    let encodedURL: URL
    let durationSeconds: Double

    init(item: inout VideoItem, encodedURL: URL) {
        operationID = UUID()
        itemID = item.id
        sourceURL = item.url
        self.encodedURL = encodedURL
        durationSeconds = item.durationSeconds
        item.analyticsOperationID = operationID
        item.analyticsStatus = .pending
        item.analyticsProgress = 0
    }

    /// Run publication and its associated side effects together under the caller's
    /// main-actor isolation. A terminal result relinquishes its token in the update.
    @discardableResult
    func apply(to items: inout [VideoItem], update: (inout VideoItem) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].analyticsOperationID == operationID,
              items[index].url == sourceURL,
              items[index].outputURL == encodedURL,
              items[index].analyticsStatus.isInProgress else { return false }
        update(&items[index])
        return true
    }
}
