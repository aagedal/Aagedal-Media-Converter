// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct EncodingSettingsView: View {
    @AppStorage(AppConstants.defaultGroupMergeEnabledKey)
    private var defaultMergeEnabled = AppConstants.defaultGroupMergeEnabled

    @AppStorage(AppConstants.defaultGroupSequentialNamingEnabledKey)
    private var defaultSequentialNamingEnabled = AppConstants.defaultGroupSequentialNamingEnabled

    @AppStorage(AppConstants.defaultGroupPresetKey)
    private var defaultGroupPresetRaw = AppConstants.defaultGroupPreset

    @AppStorage(AppConstants.exportStitchMarkersKey)
    private var exportStitchMarkers = AppConstants.exportStitchMarkersDefault

    private let presetManager = PresetManager.shared

    private var defaultGroupPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { ExportPreset(rawValue: defaultGroupPresetRaw) ?? .streamCopy },
            set: { defaultGroupPresetRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Stitched Exports") {
                Toggle("Export timeline markers", isOn: $exportStitchMarkers)
                Text("Save cuts and marked notes in a Resolve marker EDL beside stitched files and embed chapters in MOV, MP4, M4V, and MKV. If source chapters exist, ask before replacing them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(header: Text("New Group Defaults")) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Default format for new groups") {
                        Picker("", selection: defaultGroupPresetBinding) {
                            ForEach(presetManager.visiblePresets) { preset in
                                Text(presetManager.displayName(for: preset)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    }
                    .help("New groups created with ⌘N will use this format. Camera-card imports have their own remembered preset.")

                    Toggle("Merge clips by default", isOn: $defaultMergeEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .help("New groups will have merge enabled — clips concatenate into a single output file.")
                        .onChange(of: defaultMergeEnabled) { _, newValue in
                            if newValue { defaultSequentialNamingEnabled = false }
                        }

                    Toggle("Sequential filename numbering by default", isOn: $defaultSequentialNamingEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .help("New groups will name outputs <group>_001, <group>_002, … using the group name.")
                        .onChange(of: defaultSequentialNamingEnabled) { _, newValue in
                            if newValue { defaultMergeEnabled = false }
                        }

                    Text("Merge and sequential naming are mutually exclusive — turning one on switches the other off, both on the card and in these defaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(8)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    EncodingSettingsView()
}
