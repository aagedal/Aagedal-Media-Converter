// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct WatchFolderSettingsView: View {
    @State private var folderErrorMessage: String?
    @State private var isConfirmingForget = false
    @AppStorage(AppConstants.watchFolderIncludeSubfoldersKey) private var includeSubfolders = false
    @AppStorage(AppConstants.watchFolderImportMemoryDaysKey) private var importMemoryDays = AppConstants.defaultWatchFolderImportMemoryDays
    @AppStorage(WatchFolderSelectionService.writableGrantPathKey) private var writableGrantPath = ""
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @AppStorage(AppConstants.watchFolderAutoActivateOnLaunchKey) private var watchFolderAutoActivateOnLaunch = false
    @AppStorage(AppConstants.watchFolderIgnoreOlderThan24hKey) private var watchFolderIgnoreOlderThan24h = false
    @AppStorage(AppConstants.watchFolderAutoDeleteOlderThanWeekKey) private var watchFolderAutoDeleteOlderThanWeek = false
    @AppStorage(AppConstants.watchFolderIgnoreDurationValueKey) private var watchFolderIgnoreDurationValue = AppConstants.defaultWatchFolderIgnoreDurationValue
    @AppStorage(AppConstants.watchFolderIgnoreDurationUnitKey) private var watchFolderIgnoreDurationUnitRaw = AppConstants.defaultWatchFolderIgnoreDurationUnitRaw
    @AppStorage(AppConstants.watchFolderDeleteDurationValueKey) private var watchFolderDeleteDurationValue = AppConstants.defaultWatchFolderDeleteDurationValue
    @AppStorage(AppConstants.watchFolderDeleteDurationUnitKey) private var watchFolderDeleteDurationUnitRaw = AppConstants.defaultWatchFolderDeleteDurationUnitRaw
    @AppStorage(AppConstants.watchFolderKeepAwakeKey) private var watchFolderKeepAwake = AppConstants.defaultWatchFolderKeepAwake

    @AppStorage(AppConstants.watchFolderSettlingSecondsKey) private var settlingSeconds = AppConstants.defaultWatchFolderSettlingSeconds

    var body: some View {
        Form {
            watchFolderSection
        }
        .formStyle(.grouped)
        .alert("Watch Folder", isPresented: Binding(
            get: { folderErrorMessage != nil },
            set: { if !$0 { folderErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { folderErrorMessage = nil }
        } message: {
            Text(folderErrorMessage ?? "")
        }
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
                            do {
                                try WatchFolderSelectionService().reveal(url)
                            } catch {
                                folderErrorMessage = error.localizedDescription
                            }
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                        .accessibilityIdentifier("settings.watchFolder.reveal")
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

            Text("When Watch Mode is on in the toolbar, new video files in this folder are added to the conversion queue as soon as they have finished copying. Folders on network drives are also checked every 5 seconds, because they don't report changes made from other computers.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Include subfolders", isOn: $includeSubfolders)
                .toggleStyle(SwitchToggleStyle())
                .accessibilityIdentifier("settings.watchFolder.includeSubfolders")
                .help("Also import files placed in folders inside the watch folder, such as copied camera cards. The output folder is skipped.")

            Picker("File settling time", selection: Binding(
                get: { WatchFolderObservation.settlingInterval(defaults: .standard) },
                set: { settlingSeconds = $0 }
            )) {
                ForEach(AppConstants.watchFolderSettlingSecondsValues, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(Double(seconds))
                }
            }
            .accessibilityIdentifier("settings.watchFolder.settlingTime")
            Text("Wait until file size and modification time remain unchanged before importing or cleaning up. Files in the queue are never cleaned up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Remember imported files for", selection: Binding(
                get: {
                    AppConstants.watchFolderImportMemoryDaysValues.contains(importMemoryDays)
                        ? importMemoryDays : AppConstants.defaultWatchFolderImportMemoryDays
                },
                set: { importMemoryDays = $0 }
            )) {
                ForEach(AppConstants.watchFolderImportMemoryDaysValues, id: \.self) { days in
                    Text(Self.memoryDescription(days: days)).tag(days)
                }
            }
            .accessibilityIdentifier("settings.watchFolder.importMemory")
            HStack(alignment: .firstTextBaseline) {
                Text("Imported files are not added again after you remove them from the queue or relaunch the app, as long as they stay in the folder, and for this long after they leave it. A file that is replaced or changed is imported again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget Imported Files…") { isConfirmingForget = true }
                    .confirmationDialog(
                        "Forget imported files?",
                        isPresented: $isConfirmingForget
                    ) {
                        Button("Forget", role: .destructive) {
                            WatchFolderImportHistoryStore.forgetAll()
                        }
                    } message: {
                        Text("Files still in the watch folder will be added to the queue again while Watch Mode is on.")
                    }
            }

            Toggle("Activate Watch Folder on app launch", isOn: $watchFolderAutoActivateOnLaunch)
                .toggleStyle(SwitchToggleStyle())
                .disabled(watchFolderPath.isEmpty)
                .help(watchFolderPath.isEmpty
                    ? "Select a watch folder above to enable this option."
                    : "When enabled, Watch Folder Mode starts automatically every time the app launches.")

            Toggle("Keep Mac awake while watching", isOn: $watchFolderKeepAwake)
                .toggleStyle(SwitchToggleStyle())
                .disabled(watchFolderPath.isEmpty)
                .help("Prevent the system from going to sleep while Watch Folder Mode is active so dropped files are picked up without delay.")

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
                .help("Move files that have stayed in the watch folder longer than the selected duration to Trash")
                .onChange(of: watchFolderAutoDeleteOlderThanWeek) { _, isOn in
                    if !isOn {
                        watchFolderDeleteDurationValue = AppConstants.defaultWatchFolderDeleteDurationValue
                        watchFolderDeleteDurationUnitRaw = AppConstants.defaultWatchFolderDeleteDurationUnitRaw
                    }
                }
            if watchFolderAutoDeleteOlderThanWeek {
                if !watchFolderPath.isEmpty && writableGrantPath != watchFolderPath {
                    Text("Select the watch folder again to allow automatic cleanup. Monitoring remains available until access is renewed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Renew Access", action: selectWatchFolder)
                        .accessibilityIdentifier("settings.watchFolder.renewAccess")
                }
                durationPickerRow(
                    title: "Deletion threshold",
                    valueBinding: deleteDurationValueBinding,
                    unitBinding: deleteDurationUnitBinding
                )
            }
        }
    }

    // MARK: - Helpers

    private static func memoryDescription(days: Int) -> String {
        switch days {
        case 1: return "1 day"
        case 7: return "1 week"
        case 14: return "2 weeks"
        default: return "\(days) days"
        }
    }

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
            do {
                try WatchFolderSelectionService().select(url)
            } catch {
                folderErrorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    WatchFolderSettingsView()
}
