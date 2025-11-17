// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: Hashable {
        case general
        case presets
        case waveform
        case watchFolder
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            PresetsSettingsView()
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.presets)

            WaveformSettingsView()
                .tabItem { Label("Audio Waveform", systemImage: "waveform") }
                .tag(SettingsTab.waveform)

            WatchFolderSettingsView()
                .tabItem { Label("Watch Folder", systemImage: "eye.fill") }
                .tag(SettingsTab.watchFolder)
        }
        .frame(width: 600, height: 560)
        .navigationTitle("Settings – Aagedal Media Converter")
        .padding(.horizontal, 20)
    }
}

#Preview {
    SettingsView()
}
