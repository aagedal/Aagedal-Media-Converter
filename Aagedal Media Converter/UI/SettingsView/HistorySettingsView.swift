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
                        Button("Clear History…") { showClearConfirmation = true }
                            .disabled(!store.hasClearableData)
                    }
                }
            }

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
            Text("This removes all \(store.records.count) recorded encodes and resets the statistics. Encoded files are not affected.")
        }
    }
}
