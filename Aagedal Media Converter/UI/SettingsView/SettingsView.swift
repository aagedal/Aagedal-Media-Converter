// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var sidebarCollapsed = false

    private enum SettingsTab: String, CaseIterable, Hashable {
        case general
        case tools
        case encoding
        case fileNames
        case metadata
        case presets
        case screenshots
        case screenCapture
        case waveform
        case watchFolder
        case ytdlp
        case upload
        case whisper
        case ocr
        case analytics
        case sync
        case updates
        case shortcuts

        var label: String {
            switch self {
            case .general: return String(localized: "General", comment: "Settings sidebar tab.")
            case .encoding: return String(localized: "Encoding Groups", comment: "Settings sidebar tab.")
            case .fileNames: return String(localized: "File Names", comment: "Settings sidebar tab.")
            case .metadata: return String(localized: "Metadata", comment: "Settings sidebar tab.")
            case .presets: return String(localized: "Presets", comment: "Settings sidebar tab.")
            case .screenshots: return String(localized: "Screenshots", comment: "Settings sidebar tab.")
            case .screenCapture: return String(localized: "Screen Capture", comment: "Settings sidebar tab.")
            case .waveform: return String(localized: "Audio Waveform", comment: "Settings sidebar tab.")
            case .watchFolder: return String(localized: "Watch Folder", comment: "Settings sidebar tab.")
            case .ytdlp: return String(localized: "Downloads", comment: "Settings sidebar tab.")
            case .upload: return String(localized: "Upload", comment: "Settings sidebar tab.")
            case .whisper: return String(localized: "Transcription", comment: "Settings sidebar tab.")
            case .ocr: return String(localized: "OCR", comment: "Settings sidebar tab.")
            case .analytics: return String(localized: "Analytics", comment: "Settings sidebar tab.")
            case .sync: return String(localized: "Sync", comment: "Settings sidebar tab.")
            case .updates: return String(localized: "Updates", comment: "Settings sidebar tab.")
            case .tools: return String(localized: "Tool Diagnostics", comment: "Settings sidebar tab.")
            case .shortcuts: return String(localized: "Shortcuts", comment: "Settings sidebar tab.")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .encoding: return "rectangle.stack"
            case .fileNames: return "textformat"
            case .metadata: return "info.circle"
            case .presets: return "slider.horizontal.3"
            case .screenshots: return "camera.on.rectangle"
            case .screenCapture: return "record.circle"
            case .waveform: return "waveform"
            case .watchFolder: return "eye.fill"
            case .ytdlp: return "arrow.down.circle"
            case .upload: return "icloud.and.arrow.up"
            case .whisper: return "captions.bubble"
            case .ocr: return "character.magnify"
            case .analytics: return "chart.bar.xaxis"
            case .sync: return "arrow.clockwise.icloud"
            case .updates: return "arrow.triangle.2.circlepath"
            case .tools: return "stethoscope"
            case .shortcuts: return "command"
            }
        }
    }

    // Prevents deselection when clicking the already-selected row
    private var tabSelection: Binding<SettingsTab?> {
        Binding(get: { selectedTab }, set: { if let t = $0 { selectedTab = t } })
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .general: GeneralSettingsView()
        case .encoding: EncodingSettingsView()
        case .fileNames: FileNameSettingsView()
        case .metadata: MetadataSettingsView()
        case .presets: PresetsSettingsView()
        case .screenshots: ScreenshotSettingsView()
        case .screenCapture: ScreenCaptureSettingsView()
        case .waveform: WaveformSettingsView()
        case .watchFolder: WatchFolderSettingsView()
        case .ytdlp: YTDLPSettingsView()
        case .upload: UploadSettingsView()
        case .whisper: TranscriptionSettingsView()
        case .ocr: TesseractSettingsView()
        case .analytics: AnalyticsSettingsView()
        case .sync: SyncSettingsView()
        case .updates: UpdateSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .tools: ToolDiagnosticsSettingsView()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, id: \.self, selection: tabSelection) { tab in
                if sidebarCollapsed {
                    Label(tab.label, systemImage: tab.icon)
                        .labelStyle(.iconOnly)
                        .help(tab.label)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                        .accessibilityLabel(tab.label)
                } else {
                    Label(tab.label, systemImage: tab.icon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                        .accessibilityLabel(tab.label)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sidebarCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
                            .padding(.leading, sidebarCollapsed ? 0 : 10)
                            .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
                    .accessibilityIdentifier("settings.toggleSidebar")
                    .accessibilityLabel(sidebarCollapsed ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar"))
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(width: sidebarCollapsed ? 46 : 195)
            .clipped()

            Divider()

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 600)
        .accessibilityIdentifier("settings.root")
        .accessibilityValue(selectedTab.rawValue)
        .navigationTitle("Settings – Aagedal Media Converter")
        .background {
            // Keyboard shortcuts for tab switching (Control+1-9, 0 to avoid conflict with main window's CMD+1-9, 0 preset selection)
            VStack(spacing: 0) {
                Button("") { selectedTab = .general }
                    .keyboardShortcut("1", modifiers: .control)
                Button("") { selectedTab = .metadata }
                    .keyboardShortcut("2", modifiers: .control)
                Button("") { selectedTab = .presets }
                    .keyboardShortcut("3", modifiers: .control)
                Button("") { selectedTab = .screenCapture }
                    .keyboardShortcut("4", modifiers: .control)
                Button("") { selectedTab = .waveform }
                    .keyboardShortcut("5", modifiers: .control)
                Button("") { selectedTab = .watchFolder }
                    .keyboardShortcut("6", modifiers: .control)
                Button("") { selectedTab = .ytdlp }
                    .keyboardShortcut("7", modifiers: .control)
                Button("") { selectedTab = .upload }
                    .keyboardShortcut("8", modifiers: .control)
                Button("") { selectedTab = .whisper }
                    .keyboardShortcut("9", modifiers: .control)
                Button("") { selectedTab = .analytics }
                    .keyboardShortcut("0", modifiers: .control)
                Button("") { selectedTab = .updates }
                    .keyboardShortcut("a", modifiers: .control)
                Button("") { selectedTab = .shortcuts }
                    .keyboardShortcut("k", modifiers: .control)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .onAppear {
            // Check if we should open to a specific tab (e.g., from Control+K in main window)
            if let tabToOpen = UserDefaults.standard.string(forKey: AppConstants.settingsTabToOpenKey) {
                if let tab = SettingsTab(rawValue: tabToOpen) {
                    selectedTab = tab
                }
                // Clear the key so subsequent opens go to the default tab
                UserDefaults.standard.removeObject(forKey: AppConstants.settingsTabToOpenKey)
            }
        }
    }
}

#Preview {
    SettingsView()
}
