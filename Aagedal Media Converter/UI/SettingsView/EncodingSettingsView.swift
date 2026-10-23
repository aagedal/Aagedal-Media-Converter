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

    @AppStorage(AppConstants.nativeMXFTrimmedMergeKey)
    private var nativeMXFTrimmedMerge = AppConstants.nativeMXFTrimmedMergeDefault

    @State private var temporaryFreeSpace: Int64?

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
                Text("Save cuts and marked notes in a Resolve marker EDL beside stitched files and embed chapters in MOV, MP4, M4V, and MKV. Cut titles include the source timecode at each clip’s trimmed in-point when available. If source chapters exist, ask before replacing them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MXF Merges") {
                Toggle("Keep camera metadata in trimmed MXF merges", isOn: $nativeMXFTrimmedMerge)
                Text("Stream Copy merges of MXF clips keep camera metadata such as S-Log3 colour space, lens and per-frame exposure, so DaVinci Resolve can read it. When clips are trimmed, every clip is first copied to a temporary MXF, which takes a little longer and needs free space for about the size of the merged file, twice that when the output goes to the same disk. Long GOP clips are cut on whole GOPs, so they may start and end a few frames outside the trim. If there is not enough space, the merge falls back to FFmpeg without camera metadata.")
                    .font(.caption).foregroundStyle(.secondary)
                if let temporaryFreeSpace {
                    Text("Free space for temporary files: \(ByteCountFormatter.string(fromByteCount: temporaryFreeSpace, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .task {
            let values = try? FileManager.default.temporaryDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            temporaryFreeSpace = values?.volumeAvailableCapacityForImportantUsage
        }
    }
}

#Preview {
    EncodingSettingsView()
}
