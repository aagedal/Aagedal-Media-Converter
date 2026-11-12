// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct HistorySettingsView: View {
    @AppStorage(AppConstants.encodeHistoryEnabledKey)
    private var historyEnabled = AppConstants.defaultEncodeHistoryEnabled

    @AppStorage(AppConstants.encodeHistoryRetentionDaysKey)
    private var retentionDays = AppConstants.defaultEncodeHistoryRetentionDays

    @AppStorage(AppConstants.lastSessionRestoreEnabledKey)
    private var lastSessionRestoreEnabled = AppConstants.defaultLastSessionRestoreEnabled

    @AppStorage(AppConstants.confirmQuitWhileEncodingKey)
    private var confirmQuitWhileEncoding = AppConstants.defaultConfirmQuitWhileEncoding

    @State private var store = EncodeHistoryStore.shared
    @State private var showClearConfirmation = false
    @State private var deviceToRemove: HistorySyncDevice?

    private static let retentionOptions: [(days: Int, label: LocalizedStringKey)] = [
        (7, "1 week"), (30, "30 days"), (90, "90 days"), (180, "6 months"), (365, "1 year"), (0, "Forever"),
    ]

    var body: some View {
        Form {
            Section("Encode History") {
                Toggle("Keep a history of encodes", isOn: $historyEnabled)
                Text("Each encode is recorded when it starts: the source path, probe details, preset, per-item settings and the result. No thumbnails or media are stored. Open the history from the clock button in the lower-left corner of the queue to inspect or re-queue past encodes.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Keep history for", selection: $retentionDays) {
                    ForEach(Self.retentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .disabled(!historyEnabled)
                .onChange(of: retentionDays) { _, _ in store.applyRetention() }

                LabeledContent("Stored encodes") {
                    HStack {
                        Text(verbatim: "\(store.records.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        let otherMacsCount = store.allRecords.count - store.records.count
                        if store.isSyncEnabled && otherMacsCount > 0 {
                            Text("+ \(otherMacsCount) from other Macs",
                                 comment: "History settings: number of synced encodes recorded on other Macs.")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("Clear History…") { showClearConfirmation = true }
                            .disabled(!store.hasClearableData)
                    }
                }
            }

            syncSection

            Section("Last Session") {
                Toggle("Offer to restore unfinished items", isOn: $lastSessionRestoreEnabled)
                    .onChange(of: lastSessionRestoreEnabled) { _, isOn in
                        if !isOn { LastSessionStore.shared.discardPending() }
                    }
                Text("The queue always starts empty. When the app closes with items still waiting or encoding — including after a crash or closing the window — they are offered once from the Last Session button the next time the queue opens.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Ask before quitting while encoding", isOn: $confirmQuitWhileEncoding)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear encode history?", isPresented: $showClearConfirmation) {
            Button("Clear History", role: .destructive) { store.clearAll() }
        } message: {
            if store.isSyncEnabled {
                Text("This removes the encodes recorded on this Mac and resets its statistics, also in its synced history file. History from other Macs isn’t affected. Encoded files are not affected.")
            } else {
                Text("This removes all \(store.records.count) recorded encodes and resets the statistics. Encoded files are not affected.")
            }
        }
        .confirmationDialog(
            "Remove this Mac’s history from the sync folder?",
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            presenting: deviceToRemove
        ) { device in
            Button("Remove", role: .destructive) {
                Task { await store.removeSyncedDevice(device.id) }
            }
        } message: { _ in
            Text("Use this for a Mac you no longer use. If that Mac still syncs its history, its file comes back the next time it records an encode. Encoded files are not affected.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section("Sync") {
            Toggle("Sync history with your other Macs", isOn: Binding(
                get: { store.isSyncEnabled },
                set: { store.setSyncEnabled($0) }
            ))
            Text("Each Mac writes its own history file to the sync folder set in Settings ▸ Sync (iCloud Drive unless you chose a custom folder) and shows the encodes of all your Macs. The file contains the paths and names of the source and output files of every recorded encode, so these are stored in iCloud Drive. Security bookmarks and the last-session queue stay on this Mac. Turning sync off removes this Mac’s file.")
                .font(.caption).foregroundStyle(.secondary)

            if store.isSyncEnabled {
                if let directory = store.syncDirectory {
                    LabeledContent("Location") {
                        Text(verbatim: (directory.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let error = store.syncErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if store.syncDevices.isEmpty {
                    Text("No other Mac has synced its history yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.syncDevices) { device in
                        deviceRow(device)
                    }
                }
                Button("Sync Now") { Task { await store.syncNow() } }
                    .disabled(store.syncDirectory == nil)
            }
        }
    }

    private func deviceRow(_ device: HistorySyncDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name ?? String(localized: "Another Mac", comment: "Synced history device whose name isn't known yet."))
                Text(deviceStatus(device))
                    .font(.caption)
                    .foregroundStyle(device.state == .unreadable ? .orange : .secondary)
            }
            Spacer()
            Button("Remove…") { deviceToRemove = device }
                .controlSize(.small)
        }
    }

    private func deviceStatus(_ device: HistorySyncDevice) -> String {
        switch device.state {
        case .downloading:
            return String(localized: "Waiting for iCloud Drive to download this Mac’s history.",
                          comment: "Synced history device status: the file is not downloaded yet.")
        case .unreadable:
            return String(localized: "This Mac’s history file can’t be read. It is left as it is and read again when it changes.",
                          comment: "Synced history device status: damaged or partially synced file.")
        case .synced, .newerVersion:
            var parts = [String(localized: "\(device.recordCount) encodes", comment: "Encode history footer: number of stored encodes.")]
            if let updatedAt = device.updatedAt {
                parts.append(String(localized: "updated \(updatedAt.formatted(.relative(presentation: .named)))",
                                    comment: "Synced history device status: when the Mac last wrote its history, e.g. “updated 5 minutes ago”."))
            }
            if device.state == .newerVersion {
                parts.append(String(localized: "written by a newer app version, some details may be missing",
                                    comment: "Synced history device status: the file has a newer format than this app understands."))
            }
            return parts.joined(separator: " · ")
        }
    }
}
