// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.saveNextToOriginalKey) private var saveNextToOriginal = AppConstants.defaultSaveNextToOriginal
    @AppStorage(AppConstants.saveNextToOriginalSubfolderKey) private var saveNextToOriginalSubfolder = AppConstants.defaultSaveNextToOriginalSubfolder
    @AppStorage(AppConstants.saveNextToOriginalSubfolderModeKey) private var saveNextToOriginalSubfolderMode = AppConstants.defaultSaveNextToOriginalSubfolderMode
    @AppStorage(AppConstants.saveNextToOriginalSubfolderNameKey) private var saveNextToOriginalSubfolderName = AppConstants.defaultSaveNextToOriginalSubfolderName
    @AppStorage(AppConstants.previewCacheCleanupPolicyKey) private var previewCacheCleanupPolicyRaw = AppConstants.defaultPreviewCacheCleanupPolicyRaw
    @AppStorage(AppConstants.autoDeleteOldEncodesKey) private var autoDeleteOldEncodes = AppConstants.defaultAutoDeleteOldEncodes
    @AppStorage(AppConstants.autoDeleteOldEncodesDaysKey) private var autoDeleteOldEncodesDays = AppConstants.defaultAutoDeleteOldEncodesDays
    @AppStorage(AppConstants.resetClearsSettingsKey) private var resetClearsSettings = AppConstants.defaultResetClearsSettings
    @AppStorage(AppConstants.queueViewModeKey) private var queueViewMode = AppConstants.defaultQueueViewMode
    @AppStorage(AppConstants.playSoundOnSuccessKey) private var playSoundOnSuccess = AppConstants.defaultPlaySoundOnSuccess
    @AppStorage(AppConstants.playSoundOnErrorKey) private var playSoundOnError = AppConstants.defaultPlaySoundOnError
    @AppStorage(AppConstants.preferredTimecodeDisplayModeKey) private var preferredTimecodeDisplayMode = AppConstants.defaultPreferredTimecodeDisplayMode

    @State private var isClearingPreviewCache = false
    @State private var previewCacheSizeBytes: Int64 = 0

    var body: some View {
        Form {
            outputFolderSection
            queueDisplaySection
            timecodeDisplaySection
            soundSection
            resetBehaviorSection
            previewCacheSection
        }
        .formStyle(.grouped)
        .onChange(of: previewCacheCleanupPolicyRaw) { _, newValue in
            let policy = PreviewCacheCleanupPolicy(rawValue: newValue) ?? .purgeOnLaunch
            Task {
                await PreviewAssetGenerator.shared.applyCleanupPolicy(policy)
                await refreshPreviewCacheSize()
            }
        }
        .task { await refreshPreviewCacheSize() }
        .onChange(of: isClearingPreviewCache) { _, isClearing in
            guard !isClearing else { return }
            Task { await refreshPreviewCacheSize() }
        }
    }

    private var outputFolderSection: some View {
        Section(header: Text("Output Location")) {
            VStack(alignment: .leading, spacing: 12) {
                
                HStack {
                    Toggle("Save encoded files next to original", isOn: $saveNextToOriginal)
                        .toggleStyle(SwitchToggleStyle())
                }
                
                Divider()
                    .padding(.vertical, 4)

                if saveNextToOriginal {
                    // Subfolder options when saving next to original
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Place in subfolder", isOn: $saveNextToOriginalSubfolder)
                                .toggleStyle(SwitchToggleStyle())
                                //.padding(.leading, 16)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        if saveNextToOriginalSubfolder {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Picker("Subfolder name:", selection: $saveNextToOriginalSubfolderMode) {
                                        Text("Custom name").tag("custom")
                                        Text("Use preset suffix").tag("presetSuffix")
                                    }
                                    .pickerStyle(.menu)
                                    .padding(.top, 16)
                                    
                                }
                                
                                if saveNextToOriginalSubfolderMode == "custom" {
                                    HStack {
                                        Text("Folder name:")
                                        TextField("", text: $saveNextToOriginalSubfolderName)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    .padding(.top, 10)
                                } else {
                                    Text("Folder will be named using the preset suffix (e.g., \"loop\", \"tv\", \"prores\")")
                                        .font(.callout)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Text("Encoded files will be saved in the same folder as the source file.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Default output folder UI
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Output Folder:")
                            .font(.headline)

                        HStack {
                            Text(outputFolder)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .help(outputFolder)

                            Button(action: {
                                let url = URL(fileURLWithPath: outputFolder)
                                guard FileManager.default.fileExists(atPath: url.path) else {
                                    outputFolder = AppConstants.defaultOutputDirectory.path
                                    NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultOutputDirectory])
                                    return
                                }

                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Show in Finder")
                            .accessibilityLabel("Show in Finder")
                            .accessibilityIdentifier("settings.general.revealOutput")

                            Button(action: { selectNewOutputFolder() }) {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Change default output folder")
                            .accessibilityLabel("Change default output folder")
                            .accessibilityIdentifier("settings.general.chooseOutput")
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Automatically delete old encodes", isOn: $autoDeleteOldEncodes)
                            .toggleStyle(SwitchToggleStyle())

                        if autoDeleteOldEncodes {
                            HStack {
                                Text("Delete files older than:")
                                Picker("", selection: $autoDeleteOldEncodesDays) {
                                    ForEach(AppConstants.autoDeleteOldEncodesDaysOptions, id: \.self) { days in
                                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)
                            }
                            .padding(.leading, 16)
                        }

                        Text("Only applies to the default output folder. Files in other locations are never deleted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
        }
    }

    private var queueDisplaySection: some View {
        Section(header: Text("Queue Display")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use compact list view", isOn: Binding(
                    get: { queueViewMode == "compact" },
                    set: { queueViewMode = $0 ? "compact" : "standard" }
                ))
                    .toggleStyle(SwitchToggleStyle())
                    .help("Show a condensed view with smaller thumbnails and inline action buttons")
                Text("Compact mode hides comment fields, file sizes, and duration to show more items at once. Action buttons appear in a row under each filename.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var timecodeDisplaySection: some View {
        Section(header: Text("Timecode Display")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default timecode mode:")
                    Picker("", selection: $preferredTimecodeDisplayMode) {
                        ForEach(TimecodeDisplayMode.allCases, id: \.rawValue) { mode in
                            Text(LocalizedStringKey(mode.displayName)).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 250)
                }
                Text("Sets the initial timecode display mode when opening the trim view or fullscreen player. You can toggle modes during playback by pressing T.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var soundSection: some View {
        Section(header: Text("Sounds")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Play sound when encoding completes", isOn: $playSoundOnSuccess)
                    .toggleStyle(SwitchToggleStyle())
                
                Divider()
                    .padding(.vertical, 4)
                
                Toggle("Play sound when an error occurs", isOn: $playSoundOnError)
                    .toggleStyle(SwitchToggleStyle())
            }
            .padding(8)
        }
    }

    private var resetBehaviorSection: some View {
        Section(header: Text("Reset Behavior")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Reset also clears trim, crop, and audio routing", isOn: $resetClearsSettings)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Controls what the Reset button does by default")
                Text(resetClearsSettings
                    ? "When enabled, resetting an item will clear all settings (trim points, crop, audio routing, timecode). Hold Option to only reset the encoding status."
                    : "When disabled, resetting only changes the item back to waiting status, preserving trim, crop, and audio routing settings. Hold Option to also clear all settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var previewCacheSection: some View {
        Section(header: Text("Preview Cache")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Cleanup policy", selection: $previewCacheCleanupPolicyRaw) {
                    ForEach(PreviewCacheCleanupPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(previewCacheCleanupPolicy.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Spacer()
                    Text(previewCacheSizeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        NSWorkspace.shared.open(AppConstants.previewCacheDirectory)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button {
                        isClearingPreviewCache = true
                        Task {
                            await PreviewAssetGenerator.shared.cleanupAllCache()
                            await refreshPreviewCacheSize()
                            await MainActor.run { isClearingPreviewCache = false }
                        }
                    } label: {
                        Label("Clear cache now", systemImage: "trash")
                    }
                    .disabled(isClearingPreviewCache)

                    if isClearingPreviewCache {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }.padding(.top, 8)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private var previewCacheCleanupPolicy: PreviewCacheCleanupPolicy {
        PreviewCacheCleanupPolicy(rawValue: previewCacheCleanupPolicyRaw) ?? .purgeOnLaunch
    }
    
    private var previewCacheSizeDescription: String {
        guard previewCacheSizeBytes > 0 else { return "Cache is empty" }
        return Self.byteCountFormatter.string(fromByteCount: previewCacheSizeBytes)
    }
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        formatter.includesActualByteCount = false
        return formatter
    }()

    private func refreshPreviewCacheSize() async {
        let size = await PreviewAssetGenerator.shared.cacheDirectorySizeInBytes()
        await MainActor.run { previewCacheSizeBytes = size }
    }

    private func selectNewOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolder)

        if panel.runModal() == .OK, let url = panel.url {
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outputFolder = url.path
            // Persist a writable bookmark so the folder survives across launches.
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
        }
    }

}

#Preview {
    GeneralSettingsView()
}
