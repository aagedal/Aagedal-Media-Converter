// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings ▸ Sync — enable iCloud Drive / custom-folder sync of presets and
/// preferences, with manual export/import. Backed by `SettingsSyncService`.
struct SyncSettingsView: View {
    @State private var sync = SettingsSyncService.shared

    @State private var alertMessage: String?
    @State private var showingAlert = false

    var body: some View {
        Form {
            syncSection
            if sync.syncEnabled {
                locationSection
                statusSection
            }
            manualSection
            scopeNoteSection
        }
        .formStyle(.grouped)
        .alert("Settings Sync", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Enable

    private var syncSection: some View {
        Section {
            Toggle("Sync settings and custom presets", isOn: Binding(
                get: { sync.syncEnabled },
                set: { sync.setSyncEnabled($0) }
            ))
            .toggleStyle(.switch)
        } header: {
            Text("Sync")
        } footer: {
            Text("Keeps your presets and preferences in sync across Macs through a single settings file. The newest change wins; you'll be notified when settings arrive from another Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        Section(header: Text("Location")) {
            Picker("Store settings in:", selection: Binding(
                get: { sync.locationMode },
                set: { sync.setLocationMode($0) }
            )) {
                Text("iCloud Drive").tag(SettingsSyncLocationMode.iCloudDrive)
                Text("Custom folder").tag(SettingsSyncLocationMode.customFolder)
            }
            .pickerStyle(.menu)

            if sync.locationMode == .iCloudDrive, !sync.isICloudDriveAvailable {
                Label("iCloud Drive isn't enabled on this Mac. Turn it on in System Settings, or choose a custom folder.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if sync.locationMode == .customFolder {
                HStack {
                    Text(sync.customFolderPath ?? "No folder chosen")
                        .foregroundStyle(sync.customFolderPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseCustomFolder() }
                }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section(header: Text("Status")) {
            HStack {
                Text("Last synced")
                Spacer()
                if let date = sync.lastSyncDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            if let error = sync.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Sync Now") { sync.syncNow() }
                .disabled(sync.snapshotFileURL() == nil)
        }
    }

    // MARK: - Manual export / import

    private var manualSection: some View {
        Section {
            HStack {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
            }
            Button("Reveal Backups in Finder") {
                do {
                    try sync.revealBackupsInFinder()
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        } header: {
            Text("Manual Backup")
        } footer: {
            Text("Export a settings file you can keep as a backup or import on another Mac. The app also keeps automatic local backups before applying any incoming settings — open them in Finder and use “Import Settings…” to roll back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Scope note

    private var scopeNoteSection: some View {
        Section {
            Label("Folder locations, security bookmarks, installed-tool paths, and upload credentials are never synced — those stay specific to each Mac.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let existing = sync.customFolderPath {
            panel.directoryURL = URL(fileURLWithPath: existing)
        }
        if panel.runModal() == .OK, let url = panel.url {
            sync.setCustomFolder(url)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Aagedal Media Converter Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sync.exportSnapshot(to: url)
        } catch {
            present(error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try sync.importSnapshot(from: url, notify: false)
            present("Imported settings from \(snapshot.deviceName) (\(snapshot.modifiedAt.formatted(date: .abbreviated, time: .shortened))).")
        } catch {
            present(error.localizedDescription)
        }
    }

    private func present(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
}

#Preview {
    SyncSettingsView()
}
