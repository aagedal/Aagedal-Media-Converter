// Aagedal Media Converter
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
    static let showFileImporter = Notification.Name("showFileImporter")
    static let showCameraCardImporter = Notification.Name("showCameraCardImporter")
    static let createEncodingGroup = Notification.Name("createEncodingGroup")
    /// Posted after the queue has appended a new group. `userInfo["groupID"]` holds
    /// the new group's UUID so the list view can highlight and scroll to it.
    static let encodingGroupCreated = Notification.Name("encodingGroupCreated")
    /// Posted by `SettingsSyncService` after a newer remote snapshot replaced the
    /// local settings. `userInfo["deviceName"]` holds the source Mac's name so the
    /// UI can show an "updated from X" notice.
    static let settingsSyncedFromRemote = Notification.Name("settingsSyncedFromRemote")
    /// The settings-sync location (iCloud Drive or custom folder) changed.
    static let syncLocationDidChange = Notification.Name("syncLocationDidChange")
    /// Posted by the File menu "Export Settings…" command.
    static let exportSettingsRequested = Notification.Name("exportSettingsRequested")
    /// Posted by the File menu "Import Settings…" command.
    static let importSettingsRequested = Notification.Name("importSettingsRequested")
}

// MARK: - Add To Encode Queue Intent
struct AddToEncodeQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Encode Queue"
    static let description = IntentDescription("Add the selected video files to the Aagedal VideoLoop Converter queue.")

    /// Launch the app if it isn't already running so the files actually land in the queue.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$videos) to the encode queue")
    }

    func perform() async throws -> some IntentResult {
        let urls = videos.compactMap { $0.fileURL }
        let requestID = UUID()

        // No file input (e.g. invoked from a Spotlight/Siri phrase, which can't
        // attach files): open the app and present the file importer so the user
        // can pick files. Unlike the convert intents, this only queues them.
        guard !urls.isEmpty else {
            await MainActor.run {
                PendingAppIntentRequests.shared.submit(
                    name: .convertPickFiles,
                    object: nil,
                    userInfo: [
                        "startConversion": false,
                        PendingAppIntentRequests.requestIDKey: requestID
                    ]
                )
            }
            return .result()
        }
        // Broadcast to the running app instance, buffering so the request also
        // survives a cold launch (window receivers may not be ready yet).
        await MainActor.run {
            PendingAppIntentRequests.shared.submit(
                name: .enqueueFileURL,
                object: urls,
                userInfo: [PendingAppIntentRequests.requestIDKey: requestID]
            )
        }
        return .result()
    }
}
