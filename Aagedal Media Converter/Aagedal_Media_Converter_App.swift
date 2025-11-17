// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import SwiftData
import AppKit

@main
struct Aagedal_Media_Converter_App: App {
    init() {
        UserDefaults.standard.register(defaults: [
            AppConstants.watchFolderIgnoreOlderThan24hKey: false,
            AppConstants.watchFolderAutoDeleteOlderThanWeekKey: false,
            AppConstants.watchFolderIgnoreDurationValueKey: AppConstants.defaultWatchFolderIgnoreDurationValue,
            AppConstants.watchFolderIgnoreDurationUnitKey: AppConstants.defaultWatchFolderIgnoreDurationUnitRaw,
            AppConstants.watchFolderDeleteDurationValueKey: AppConstants.defaultWatchFolderDeleteDurationValue,
            AppConstants.watchFolderDeleteDurationUnitKey: AppConstants.defaultWatchFolderDeleteDurationUnitRaw,
            AppConstants.previewCacheCleanupPolicyKey: AppConstants.defaultPreviewCacheCleanupPolicyRaw,
            AppConstants.audioWaveformVideoDefaultEnabledKey: true,
            AppConstants.audioWaveformResolutionKey: "1280x720",
            AppConstants.audioWaveformBackgroundColorKey: "#000000",
            AppConstants.audioWaveformForegroundColorKey: "#FFFFFF",
            AppConstants.audioWaveformNormalizeKey: false,
            AppConstants.audioWaveformStyleKey: AppConstants.defaultAudioWaveformStyleRaw,
            AppConstants.audioWaveformLineThicknessKey: AppConstants.defaultAudioWaveformLineThickness,
            AppConstants.audioWaveformDetailLevelKey: AppConstants.defaultAudioWaveformDetailLevel
        ])

        applyPreviewCacheCleanupPolicy()
    }

    var body: some Scene {
        WindowGroup {
            VStack {
                ContentView()
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            MainAppCommands()
        }
        Settings {
            SettingsView().keyboardShortcut(",",modifiers: .command)
        }
        Window("About Aagedal Media Converter", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct MainAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import…") {
                NotificationCenter.default.post(name: .showFileImporter, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aagedal Media Converter") {
                openWindow(id: "about")
            }
        }
    }
}

private extension Aagedal_Media_Converter_App {
    func applyPreviewCacheCleanupPolicy() {
        let defaults = UserDefaults.standard
        let storedPolicyRaw = defaults.string(forKey: AppConstants.previewCacheCleanupPolicyKey) ?? AppConstants.defaultPreviewCacheCleanupPolicyRaw
        let policy = PreviewCacheCleanupPolicy(rawValue: storedPolicyRaw) ?? .purgeOnLaunch

        Task {
            await PreviewAssetGenerator.shared.applyCleanupPolicy(policy)
        }
    }
}
