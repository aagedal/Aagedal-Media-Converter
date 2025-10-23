// Aagedal VideoLoop Converter 2.0
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
struct Aagedal_VideoLoop_Converter_2_0App: App {
    init() {
        UserDefaults.standard.register(defaults: [
            AppConstants.watchFolderIgnoreOlderThan24hKey: false,
            AppConstants.watchFolderAutoDeleteOlderThanWeekKey: false,
            AppConstants.watchFolderIgnoreDurationValueKey: AppConstants.defaultWatchFolderIgnoreDurationValue,
            AppConstants.watchFolderIgnoreDurationUnitKey: AppConstants.defaultWatchFolderIgnoreDurationUnitRaw,
            AppConstants.watchFolderDeleteDurationValueKey: AppConstants.defaultWatchFolderDeleteDurationValue,
            AppConstants.watchFolderDeleteDurationUnitKey: AppConstants.defaultWatchFolderDeleteDurationUnitRaw
        ])
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
        Window("About Aagedal VideoLoop Converter", id: "about") {
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
            Button("About Aagedal VideoLoop Converter") {
                openWindow(id: "about")
            }
        }
    }
}
