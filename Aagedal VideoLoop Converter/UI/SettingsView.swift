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
    @AppStorage(AppConstants.customPreset1CommandKey) private var customPreset1Command = AppConstants.defaultCustomPresetCommands[0]
    @AppStorage(AppConstants.customPreset1SuffixKey) private var customPreset1Suffix = AppConstants.defaultCustomPresetSuffixes[0]
    @AppStorage(AppConstants.customPreset1ExtensionKey) private var customPreset1Extension = AppConstants.defaultCustomPresetExtensions[0]
    @AppStorage(AppConstants.customPreset1NameKey) private var customPreset1Name = AppConstants.defaultCustomPresetNameSuffixes[0]
    @AppStorage(AppConstants.customPreset2CommandKey) private var customPreset2Command = AppConstants.defaultCustomPresetCommands[1]
    @AppStorage(AppConstants.customPreset2SuffixKey) private var customPreset2Suffix = AppConstants.defaultCustomPresetSuffixes[1]
    @AppStorage(AppConstants.customPreset2ExtensionKey) private var customPreset2Extension = AppConstants.defaultCustomPresetExtensions[1]
    @AppStorage(AppConstants.customPreset2NameKey) private var customPreset2Name = AppConstants.defaultCustomPresetNameSuffixes[1]
    @AppStorage(AppConstants.customPreset3CommandKey) private var customPreset3Command = AppConstants.defaultCustomPresetCommands[2]
    @AppStorage(AppConstants.customPreset3SuffixKey) private var customPreset3Suffix = AppConstants.defaultCustomPresetSuffixes[2]
    @AppStorage(AppConstants.customPreset3ExtensionKey) private var customPreset3Extension = AppConstants.defaultCustomPresetExtensions[2]
    @AppStorage(AppConstants.customPreset3NameKey) private var customPreset3Name = AppConstants.defaultCustomPresetNameSuffixes[2]
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @AppStorage(AppConstants.watchFolderIgnoreOlderThan24hKey) private var watchFolderIgnoreOlderThan24h = false
    @AppStorage(AppConstants.watchFolderAutoDeleteOlderThanWeekKey) private var watchFolderAutoDeleteOlderThanWeek = false
    @AppStorage(AppConstants.watchFolderIgnoreDurationValueKey) private var watchFolderIgnoreDurationValue = AppConstants.defaultWatchFolderIgnoreDurationValue
    @AppStorage(AppConstants.watchFolderIgnoreDurationUnitKey) private var watchFolderIgnoreDurationUnitRaw = AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
    @AppStorage(AppConstants.watchFolderDeleteDurationValueKey) private var watchFolderDeleteDurationValue = AppConstants.defaultWatchFolderDeleteDurationValue
    @AppStorage(AppConstants.watchFolderDeleteDurationUnitKey) private var watchFolderDeleteDurationUnitRaw = AppConstants.defaultWatchFolderDeleteDurationUnitRaw
    @State private var selectedPreset: ExportPreset = .videoLoop
    @FocusState private var focusedCustomCommandSlot: Int?
    @State private var previousFocusedCustomCommandSlot: Int?
    
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
                Toggle("Ignore files older than", isOn: $watchFolderIgnoreOlderThan24h)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Skip files that have been in the watch folder longer than the selected duration")
                    .onChange(of: watchFolderIgnoreOlderThan24h) { _, isOn in
                        if !isOn {
                            watchFolderIgnoreDurationValue = AppConstants.defaultWatchFolderIgnoreDurationValue
                            watchFolderIgnoreDurationUnitRaw = AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
                        }
                    }
                if watchFolderIgnoreOlderThan24h {
                    durationPickerRow(
                        title: "Ignore threshold",
                        valueBinding: ignoreDurationValueBinding,
                        unitBinding: ignoreDurationUnitBinding
                    )
                }
                Toggle("Automatically delete files older than", isOn: $watchFolderAutoDeleteOlderThanWeek)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Permanently remove files that have stayed in the watch folder longer than the selected duration")
                    .onChange(of: watchFolderAutoDeleteOlderThanWeek) { _, isOn in
                        if !isOn {
                            watchFolderDeleteDurationValue = AppConstants.defaultWatchFolderDeleteDurationValue
                            watchFolderDeleteDurationUnitRaw = AppConstants.defaultWatchFolderDeleteDurationUnitRaw
                        }
                    }
                if watchFolderAutoDeleteOlderThanWeek {
                    durationPickerRow(
                        title: "Deletion threshold",
                        valueBinding: deleteDurationValueBinding,
                        unitBinding: deleteDurationUnitBinding
                    )
                }
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
                Toggle(isOn: $includeDateTagByDefault) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Include date tag on new files", systemImage: "calendar.badge.clock")
                            .font(.subheadline.weight(.semibold))
                        Text("Date tag is an autogenerated text added to the beginning of the comment field, e.g. 'Date generated: 20250925'. The tag precedes any custom comment you enter on the video card.")
                            .font(Font.caption.italic())
                            .foregroundColor(preserveMetadataByDefault ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(preserveMetadataByDefault)
                .help("Controls whether newly added files include the \"Date generated\" metadata tag by default")
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
            if selectedPreset.isCustom {
                Section(header: Text("Custom Preset")) {
                    let slot = selectedPreset.customSlotIndex ?? 0
                    VStack(alignment: .leading, spacing: 16) {
                        presetNameField(for: slot)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself).")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: Binding(
                                get: { customCommand(for: slot) },
                                set: { updateCustomCommand($0, slot: slot) }
                            ))
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .focused($focusedCustomCommandSlot, equals: slot)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output file suffix")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                TextField("_c\(slot + 1)", text: Binding(
                                    get: { customSuffix(for: slot) },
                                    set: { updateCustomSuffix($0, slot: slot) }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output extension")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                TextField("mp4", text: Binding(
                                    get: { customExtension(for: slot) },
                                    set: { updateCustomExtension($0, slot: slot) }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                        Text("Example: `-c:v libx264 -crf 18 -preset slow -c:a copy` produces `filename\(customSuffix(for: slot)).\(customExtension(for: slot))`.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Links Section
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Source code and author website", systemImage: "questionmark.circle")
                        .font(.headline)
                    HStack {
                        Link("GitHub Repository", destination: URL(string: "https://github.com/aagedal/Aagedal-VideoLoop-Converter/tree/main")!)
                        Spacer()
                        Link("Developer Website", destination: URL(string: "https://aagedal.me/about")!)
                    }.padding(8)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("For additional assistance, please visit our support page or contact us via email.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 560)
        .navigationTitle("Settings – Aagedal VideoLoop Converter")
        .padding(.horizontal, 20)
        .onChange(of: focusedCustomCommandSlot) { _, newValue in
            if let previous = previousFocusedCustomCommandSlot, previous != newValue {
                finalizeCustomCommand(for: previous)
            }
            previousFocusedCustomCommandSlot = newValue
        }
        .onDisappear {
            if let previous = previousFocusedCustomCommandSlot {
                finalizeCustomCommand(for: previous)
                previousFocusedCustomCommandSlot = nil
            }
        }
    }
    
    // MARK: - Helpers

    private var ignoreDurationUnitBinding: Binding<WatchFolderDurationUnit> {
        Binding(
            get: { WatchFolderDurationUnit(rawValue: watchFolderIgnoreDurationUnitRaw) ?? .hours },
            set: { watchFolderIgnoreDurationUnitRaw = $0.rawValue }
        )
    }
    
    private var deleteDurationUnitBinding: Binding<WatchFolderDurationUnit> {
        Binding(
            get: { WatchFolderDurationUnit(rawValue: watchFolderDeleteDurationUnitRaw) ?? .days },
            set: { watchFolderDeleteDurationUnitRaw = $0.rawValue }
        )
    }
    
    private var ignoreDurationValueBinding: Binding<Int> {
        Binding(
            get: {
                let defaultValue = AppConstants.defaultWatchFolderIgnoreDurationValue
                return AppConstants.watchFolderDurationValues.contains(watchFolderIgnoreDurationValue) ? watchFolderIgnoreDurationValue : defaultValue
            },
            set: { watchFolderIgnoreDurationValue = $0 }
        )
    }
    
    private var deleteDurationValueBinding: Binding<Int> {
        Binding(
            get: {
                let defaultValue = AppConstants.defaultWatchFolderDeleteDurationValue
                return AppConstants.watchFolderDurationValues.contains(watchFolderDeleteDurationValue) ? watchFolderDeleteDurationValue : defaultValue
            },
            set: { watchFolderDeleteDurationValue = $0 }
        )
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
        }
    }

    @ViewBuilder
    private func durationPickerRow(
        title: String,
        valueBinding: Binding<Int>,
        unitBinding: Binding<WatchFolderDurationUnit>
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: valueBinding) {
                ForEach(AppConstants.watchFolderDurationValues, id: \.self) { value in
                    Text("\(value)")
                        .tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            Picker("", selection: unitBinding) {
                ForEach(WatchFolderDurationUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
        .padding(.vertical, 4)
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

    private func customCommand(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Command
        case 1: return customPreset2Command
        case 2: return customPreset3Command
        default: return AppConstants.defaultCustomPresetCommands.indices.contains(slot)
            ? AppConstants.defaultCustomPresetCommands[slot]
            : "-c copy"
        }
    }
    
    private func customSuffix(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Suffix
        case 1: return customPreset2Suffix
        case 2: return customPreset3Suffix
        default: return AppConstants.defaultCustomPresetSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetSuffixes[slot]
            : "_c\(slot + 1)"
        }
    }
    
    private func customExtension(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Extension
        case 1: return customPreset2Extension
        case 2: return customPreset3Extension
        default: return AppConstants.defaultCustomPresetExtensions.indices.contains(slot)
            ? AppConstants.defaultCustomPresetExtensions[slot]
            : "mp4"
        }
    }
    
    private func customNamePrefix(for slot: Int) -> String {
        let prefixes = AppConstants.customPresetPrefixes
        return prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
    }
    
    private func customNameSuffix(for slot: Int) -> String {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let stored: String
        switch slot {
        case 0: stored = customPreset1Name
        case 1: stored = customPreset2Name
        case 2: stored = customPreset3Name
        default: stored = fallback
        }
        let sanitized = sanitizeCustomNameSuffix(stored, prefix: prefix, fallback: fallback)
        if sanitized != stored {
            updateStoredNameSuffix(sanitized, slot: slot)
        }
        return sanitized
    }
    
    private func customDisplayName(for slot: Int) -> String {
        "\(customNamePrefix(for: slot)) \(customNameSuffix(for: slot))"
    }
    
    private func updateCustomCommand(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetCommands
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "-c copy"
        let sanitized = sanitizeCustomCommand(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Command = sanitized
        case 1: customPreset2Command = sanitized
        case 2: customPreset3Command = sanitized
        default: break
        }
    }
    
    private func updateCustomSuffix(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetSuffixes
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "_c\(slot + 1)"
        let sanitized = sanitizeCustomSuffix(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Suffix = sanitized
        case 1: customPreset2Suffix = sanitized
        case 2: customPreset3Suffix = sanitized
        default: break
        }
    }
    
    private func updateCustomExtension(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetExtensions
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "mp4"
        let sanitized = sanitizeCustomExtension(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Extension = sanitized
        case 1: customPreset2Extension = sanitized
        case 2: customPreset3Extension = sanitized
        default: break
        }
    }
    
    private func updateCustomNameSuffix(_ value: String, slot: Int) {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let sanitized = sanitizeCustomNameSuffix(value, prefix: prefix, fallback: fallback)
        updateStoredNameSuffix(sanitized, slot: slot)
    }
    
    private func updateStoredNameSuffix(_ value: String, slot: Int) {
        switch slot {
        case 0: customPreset1Name = value
        case 1: customPreset2Name = value
        case 2: customPreset3Name = value
        default: break
        }
    }
    
    @ViewBuilder
    private func presetNameField(for slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display name")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text(customNamePrefix(for: slot))
                    .font(.body.monospaced())
                TextField("Custom Preset", text: Binding(
                    get: { customNameSuffix(for: slot) },
                    set: { updateCustomNameSuffix($0, slot: slot) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }
    
    private func sanitizeCustomSuffix(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("_") ? trimmed : "_" + trimmed
    }
    
    private func sanitizeCustomExtension(_ value: String, fallback: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? fallback : trimmed.lowercased()
    }
    
    private func sanitizeCustomCommand(_ value: String, fallback: String) -> String {
        let withoutControlCharacters = value.trimmingCharacters(in: .controlCharacters)
        let trimmedWhitespace = withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhitespace.isEmpty {
            return fallback
        }
        return withoutControlCharacters
    }
    
    private func finalizeCustomCommand(for slot: Int) {
        let current = customCommand(for: slot)
        let trimmedTrailing = trimTrailingWhitespace(from: current)
        updateCustomCommand(trimmedTrailing, slot: slot)
    }
    
    private func trimTrailingWhitespace(from value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }
    
    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lowercasedPrefix = prefix.lowercased()
        var remainder = trimmed
        if trimmed.lowercased().hasPrefix(lowercasedPrefix) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            remainder = String(trimmed[cutoff...])
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.first == ":" {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
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
