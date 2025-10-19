// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AppIntents
import UniformTypeIdentifiers
import Foundation

// MARK: - Notification used to hand off URL from App Intent to running app instance
extension Notification.Name {
    static let enqueueFileURL = Notification.Name("enqueueFileURL")
}

// MARK: - Add To Encode Queue Intent
struct AddToEncodeQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Encode Queue"
    static let description = IntentDescription("Add the selected video file to the Aagedal VideoLoop Converter queue.")

    @Parameter(title: "Video File", supportedContentTypes: [.movie])
    var video: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$video) to the encode queue")
    }

    func perform() async throws -> some IntentResult {
        guard let url = video.fileURL else {
            throw NSError(domain: "AddToEncodeQueueIntent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])
        }
        // Broadcast to running app instance (if any) on the main thread
        await MainActor.run {
            NotificationCenter.default.post(name: .enqueueFileURL, object: url)
        }
        return .result()
    }
}
