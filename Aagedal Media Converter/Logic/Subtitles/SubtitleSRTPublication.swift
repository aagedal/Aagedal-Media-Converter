// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// One generation run owns only its unique staging file until this commit succeeds.
/// The UI check and rename share the main actor with row removal/reset, while the
/// lock fences service cancellation arriving from another actor during publication.
final class SubtitleSRTPublication: @unchecked Sendable {
    private let active = OSAllocatedUnfairLock(initialState: true)

    func cancel() {
        active.withLock { $0 = false }
    }

    @MainActor
    func publish(
        stagedURL: URL,
        destinationURL: URL,
        isCurrent: @MainActor @Sendable () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        try active.withLock { isActive in
            guard isActive else { throw CancellationError() }
            try Task.checkCancellation()
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else {
                try fileManager.moveItem(at: stagedURL, to: destinationURL)
            }
        }
    }
}
