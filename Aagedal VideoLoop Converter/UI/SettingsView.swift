// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct SettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.includeDateTagPreferenceKey) private var includeDateTagByDefault = false
    @AppStorage(AppConstants.preserveMetadataPreferenceKey) private var preserveMetadataByDefault = false
    @AppStorage(AppConstants.customPresetCommandKey) private var customPresetCommand = "-c copy"
    @AppStorage(AppConstants.customPresetSuffixKey) private var customPresetSuffix = "_custom"
    @AppStorage(AppConstants.customPresetExtensionKey) private var customPresetExtension = "mp4"
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @AppStorage(AppConstants.watchFolderIgnoreOlderThan24hKey) private var watchFolderIgnoreOlderThan24h = false
    @AppStorage(AppConstants.watchFolderAutoDeleteOlderThanWeekKey) private var watchFolderAutoDeleteOlderThanWeek = false
    @State private var selectedPreset: ExportPreset = .videoLoop
    
    var body: some View {
        Form {
            Section(header: Text("Output Folder")) {
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
                                // If the saved folder doesn't exist, reset to default
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
                        
                        // Choose new folder
                        Button(action: {
                            selectNewOutputFolder()
                        }) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Change default output folder")
                    }
                }
                .padding(8)
            }
            
            Section(header: Text("Watch Folder")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watch Folder:")
                        .font(.headline)
                    
                    if watchFolderPath.isEmpty {
                        Text("No folder selected")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        HStack {
                            Text(watchFolderPath)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .help(watchFolderPath)
                            
                            Button(action: {
                                let url = URL(fileURLWithPath: watchFolderPath)
                                guard FileManager.default.fileExists(atPath: url.path) else {
                                    // If the saved folder doesn't exist, clear it
                                    watchFolderPath = ""
                                    return
                                }
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Show in Finder")
                        }
                    }
                    
                    HStack {
                        Button(action: {
                            selectWatchFolder()
                        }) {
                            Label(watchFolderPath.isEmpty ? "Select Folder" : "Change Folder", systemImage: "folder.badge.plus")
                        }
                        
                        if !watchFolderPath.isEmpty {
                            Button(action: {
                                watchFolderPath = ""
                            }) {
                                Label("Clear", systemImage: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                .padding(8)
                
                Text("When Watch Folder Mode is enabled in the toolbar, the app will automatically scan this folder every 5 seconds for new video files and add them to the conversion queue.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Toggle("Ignore files added more than 24 hours ago", isOn: $watchFolderIgnoreOlderThan24h)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Skip files that were added to the watch folder more than 24 hours ago")
                    .padding(.top, 6)
                Toggle("Automatically delete files added to the watch folder more than 7 days ago", isOn: $watchFolderAutoDeleteOlderThanWeek)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Permanently remove files that have been in the watch folder for more than a week")
            }
            
            Section(header: Text("Metadata")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Preserve all original metadata", isOn: $preserveMetadataByDefault)
                        .toggleStyle(SwitchToggleStyle())
                        .help("When enabled, the original file's metadata is kept intact during conversion")
                    Text("By default, metadata such as title, timecode, and encoder tags are stripped to keep output files clean. Enable this to keep all metadata untouched. However, color related metadata (including HDR) will always be preserved, to assure an accurate viewing experience.")
                        .font(Font.caption.italic())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Date tag").font(.headline)
                Toggle("Include date tag on new files", isOn: $includeDateTagByDefault)
                    .toggleStyle(SwitchToggleStyle())
                    .disabled(preserveMetadataByDefault)
                    .help("Controls whether newly added files include the \"Date generated\" metadata tag by default")
                Text("Date tag is an autogenerated text that is added to the start of metadata field 'Comment'. E.g.: 'Date generated: 20250925'. If turned on, the date tag comes before the text written in the comment field on the video card.").font(Font.caption.italic())
                    .foregroundColor(preserveMetadataByDefault ? .secondary : .primary)
            }
            
            // Preset Information Section
            Section(header: Text("Preset Information")) {
                VStack(alignment: .leading) {
                    // Segmented Control for Preset Selection
                    HStack(alignment: .center, spacing: 12) {
                        Picker("Preset", selection: $selectedPreset) {
                            ForEach(ExportPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.automatic)
                        .labelsHidden()
                        
                        Spacer()
                        Button(action: setSelectedPresetAsDefault) {
                            if isSelectedPresetDefault {
                                Text("Default")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.green)
                            } else {
                                Text("Set as Default")
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSelectedPresetDefault)
                        .help(isSelectedPresetDefault ? "Current default preset" : "Set this preset as the default for new files")
                    }
                    
                    // Preset Description
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(selectedPreset.displayName)
                                .font(.headline)
                            Spacer()
                            HStack {
                                Text(selectedPreset.fileSuffix)
                                Text(".\(selectedPreset.fileExtension)")
                            }
                            .font(.subheadline)
                            .monospaced()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                        }
                        
                        Text(selectedPreset.description)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }
            }
            if selectedPreset == .custom {
                Section(header: Text("Custom Preset")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself).")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $customPresetCommand)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .onChange(of: customPresetCommand) { _, newValue in
                                customPresetCommand = sanitizeCustomCommand(newValue)
                            }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output file suffix")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                TextField("_custom", text: $customPresetSuffix)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: customPresetSuffix) { _, newValue in
                                        customPresetSuffix = sanitizeCustomSuffix(newValue)
                                    }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output extension")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                TextField("mp4", text: $customPresetExtension)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: customPresetExtension) { _, newValue in
                                        customPresetExtension = sanitizeCustomExtension(newValue)
                                    }
                            }
                        }
                        Text("Example: `-c:v libx264 -crf 18 -preset slow -c:a copy` produces `filename\(customPresetSuffix).\(customPresetExtension)`.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Links Section
            Section {
                HStack(spacing: 20) {
                    // Left-aligned Close button (only shown in sheet)
                    Spacer()
                    // Right-aligned links
                    HStack(spacing: 20) {
                        Link("GitHub Project", destination: URL(string: "https://github.com/yourusername/Aagedal-VideoLoop-Converter-2.0")!)
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                        
                        Link("Developer Website", destination: URL(string: "https://aagedal.me")!)
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 560)
        .navigationTitle("Settings – Aagedal VideoLoop Converter")
        .padding(.horizontal, 20)
    }
    
    // MARK: - Helpers
    
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
        }
    }
    
    private func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Watch Folder"
        panel.message = "Choose a folder to watch for new video files"
        
        if !watchFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: watchFolderPath)
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            watchFolderPath = url.path
            // Save security-scoped bookmark for the watch folder
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }
    }

    private func sanitizeCustomSuffix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "_custom" : (trimmed.hasPrefix("_") ? trimmed : "_" + trimmed)
    }
    
    private func sanitizeCustomExtension(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? "mp4" : trimmed.lowercased()
    }
    
    private func sanitizeCustomCommand(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? "-c copy" : trimmed
    }

    private var defaultPreset: ExportPreset {
        ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
    }
    
    private var isSelectedPresetDefault: Bool {
        selectedPreset == defaultPreset
    }
    
    private func setSelectedPresetAsDefault() {
        storedDefaultPresetRawValue = selectedPreset.rawValue
    }
}

#Preview {
    SettingsView()
}
