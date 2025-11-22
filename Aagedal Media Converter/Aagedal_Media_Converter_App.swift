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
import OSLog

@main
struct Aagedal_Media_Converter_App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
        .handlesExternalEvents(matching: []) // Prevent automatic window creation for opened files
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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var isFirstActivation = true

    func applicationDidBecomeActive(_ notification: Notification) {
        // Ignore the first activation (app launch) to avoid conflict with default SwiftUI window creation
        if isFirstActivation {
            isFirstActivation = false
            return
        }

        let visibleWindows = NSApp.windows.filter { $0.isVisible }

        // If there are no visible windows, open a new one
        if visibleWindows.isEmpty {
            var foundItem: NSMenuItem?
            
            if let mainMenu = NSApp.mainMenu {
                for item in mainMenu.items {
                    if let submenu = item.submenu {
                        for subitem in submenu.items {
                            if subitem.keyEquivalent == "n" && subitem.keyEquivalentModifierMask.contains(.command) {
                                foundItem = subitem
                                break
                            }
                        }
                    }
                    if foundItem != nil { break }
                }
            }
            
            if let item = foundItem, let action = item.action {
                 DispatchQueue.main.async {
                    // IMPORTANT: Pass 'item' as sender so SwiftUI knows which command to trigger
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
    }
    
    // MARK: - Handle files dropped on dock icon
    func application(_ application: NSApplication, open urls: [URL]) {
        // Filter for supported video files only
        let videoURLs = urls.filter { VideoFileUtils.isVideoFile(url: $0) }
        
        guard !videoURLs.isEmpty else { return }
        
        // Check if there are any visible windows
        let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        
        if visibleWindows.isEmpty {
            // No windows open - let SwiftUI create a new window and add files there
            // We need to delay posting notifications until the new window is created
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for url in videoURLs {
                    NotificationCenter.default.post(name: .enqueueFileURL, object: url)
                }
            }
        } else {
            // Windows exist - bring the frontmost one forward and add files there
            if let frontWindow = visibleWindows.first {
                frontWindow.makeKeyAndOrderFront(nil)
            }
            
            // Post notifications for the existing window(s)
            for url in videoURLs {
                NotificationCenter.default.post(name: .enqueueFileURL, object: url)
            }
        }
    }
}
