// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct WatchFolderSettingsView: View {
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @AppStorage(AppConstants.watchFolderIgnoreOlderThan24hKey) private var watchFolderIgnoreOlderThan24h = false
    @AppStorage(AppConstants.watchFolderAutoDeleteOlderThanWeekKey) private var watchFolderAutoDeleteOlderThanWeek = false
    @AppStorage(AppConstants.watchFolderIgnoreDurationValueKey) private var watchFolderIgnoreDurationValue = AppConstants.defaultWatchFolderIgnoreDurationValue
    @AppStorage(AppConstants.watchFolderIgnoreDurationUnitKey) private var watchFolderIgnoreDurationUnitRaw = AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
    @AppStorage(AppConstants.watchFolderDeleteDurationValueKey) private var watchFolderDeleteDurationValue = AppConstants.defaultWatchFolderDeleteDurationValue
    @AppStorage(AppConstants.watchFolderDeleteDurationUnitKey) private var watchFolderDeleteDurationUnitRaw = AppConstants.defaultWatchFolderDeleteDurationUnitRaw

    var body: some View {
        Form {
            watchFolderSection
        }
        .formStyle(.grouped)
    }

    private var watchFolderSection: some View {
        Section(header: Text("Watch Folder")) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch Folder:")
                    .font(.headline)

                if watchFolderPath.isEmpty {
                    Text("No folder selected")
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.bottom, 8)
                } else {
                    HStack {
                        Text(watchFolderPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(watchFolderPath)

                        Button(action: {
                            let url = URL(fileURLWithPath: watchFolderPath)
                            guard FileManager.default.fileExists(atPath: url.path) else {
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
                    }.padding(.bottom, 8)
                }

                HStack {
                    Button(action: { selectWatchFolder() }) {
                        Label(watchFolderPath.isEmpty ? "Select Folder" : "Change Folder", systemImage: "folder.badge.plus")
                    }

                    if !watchFolderPath.isEmpty {
                        Button(action: { watchFolderPath = "" }) {
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
}

#Preview {
    WatchFolderSettingsView()
}
