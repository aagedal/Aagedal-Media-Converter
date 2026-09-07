// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Chooses an upload representative for one completed output. UploadManager owns
/// configuration validation, upload state, and the actual transfer.
enum ConversionUploadFollowUp {
    static func itemID(afterSuccess success: Bool, item: VideoItem) -> UUID? {
        success && item.uploadEnabled ? item.id : nil
    }

    /// Merged items share one output, so use the first opted-in item in merge order.
    /// Indices that disappeared from the queue cannot represent the output.
    static func itemID(afterSuccess success: Bool, mergedIndices: [Int], items: [VideoItem]) -> UUID? {
        guard success else { return nil }
        for index in mergedIndices where items.indices.contains(index) {
            if let itemID = itemID(afterSuccess: success, item: items[index]) {
                return itemID
            }
        }
        return nil
    }
}
