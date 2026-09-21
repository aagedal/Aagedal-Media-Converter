// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// A unified entry representing an upload server from any backend type.
struct UploadServerEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
    let backendType: UploadBackendType

    var displayLabel: String {
        "\(name) (\(backendType.displayName))"
    }
}

struct CameraCardImportView: View {
    @Environment(\.openSettings) private var openSettings
    let clipCount: Int
    let folderName: String
    let hasRemovableSources: Bool
    @Binding var masterName: String
    @Binding var selectedPreset: ExportPreset
    @Binding var concatEnabled: Bool
    @Binding var uploadEnabled: Bool
    @Binding var autoEncodeEnabled: Bool
    let mergeCompatibilityResult: ConversionManager.MergeCompatibilityResult?
    let isCheckingCompatibility: Bool
    let onImport: () -> Void
    let onCancel: () -> Void
    let onAutoSplit: (() -> Void)?
    let onForceMerge: (() -> Void)?

    private let presetManager = PresetManager.shared
    @State private var servers: [UploadServerEntry] = []
    @State private var selectedServerID: UUID?

    private var isVideoLoopPreset: Bool {
        selectedPreset == .videoLoop || selectedPreset == .videoLoopWithSound
    }

    /// Characters that are unsafe in macOS file names. `/` is the path separator
    /// and `:` is reserved (Finder converts it to `/` for display but the BSD
    /// layer rejects it). NUL is always invalid.
    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "/:\0")

    private var trimmedMasterName: String {
        masterName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var invalidCharactersFound: String {
        let chars = trimmedMasterName.unicodeScalars.filter {
            Self.invalidFilenameCharacters.contains($0)
        }
        // De-duplicate while preserving order.
        var seen = Set<Unicode.Scalar>()
        return chars.filter { seen.insert($0).inserted }.map { String($0) }.joined(separator: " ")
    }

    private var isNameValid: Bool {
        !trimmedMasterName.isEmpty && invalidCharactersFound.isEmpty
    }

    /// True when the user has concat on for 2+ clips, the compatibility check has
    /// run, and the clips are not mergeable. In that state, plain "Import" would
    /// silently fall back to individual encoding (and N uploads instead of 1), so
    /// we promote Auto-split to the primary action instead.
    private var shouldOfferAutoSplit: Bool {
        guard concatEnabled,
              clipCount >= 2,
              !isCheckingCompatibility,
              onAutoSplit != nil,
              let result = mergeCompatibilityResult else {
            return false
        }
        if case .compatible = result { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Camera Card")
                .font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folderName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(clipCount) clips found",
                     comment: "Label showing how many clips were detected on the imported camera card.")
                    .foregroundStyle(.secondary)
            }

            if hasRemovableSources {
                Label {
                    Text("Editing directly from removable media can be slow, especially for long recordings. For smoother editing, copy the card to local storage first. You can also continue importing from the card.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("cameraCardRemovableMediaAdvisory")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Card name")
                    .font(.body)
                TextField("e.g. Interview_Day1", text: $masterName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity)

                if !trimmedMasterName.isEmpty && !invalidCharactersFound.isEmpty {
                    Label {
                        Text("Invalid characters in name: \(invalidCharactersFound)",
                             comment: "Inline validation error listing characters that cannot be used in the card name.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !trimmedMasterName.isEmpty {
                    Text(namingPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("Preset") {
                Picker("", selection: $selectedPreset) {
                    ForEach(presetManager.visiblePresets) { preset in
                        Text(presetManager.displayName(for: preset)).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }

            if isVideoLoopPreset {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("VideoLoop is not recommended for card ingest.")
                        .font(.callout)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Use TV AVC-Intra") { selectedPreset = .tvAVCIntra }
                        .controlSize(.small)
                    Button("Use ProRes") { selectedPreset = .prores }
                        .controlSize(.small)
                }
            }

            Divider()

            if clipCount >= 2 {
                Toggle("Concatenate clips into single file", isOn: $concatEnabled)
            }

            if concatEnabled && clipCount >= 2 {
                if isCheckingCompatibility {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking clip compatibility\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = mergeCompatibilityResult {
                    if case .compatible = result {
                        // Compatible — no warning needed
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(result.tooltip)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let onAutoSplit, !shouldOfferAutoSplit {
                                Button("Auto-split into groups") {
                                    onAutoSplit()
                                }
                                .controlSize(.small)
                                .help("Create separate encoding groups for compatible clips")
                            }
                            if let onForceMerge {
                                Button("Force Merge\u{2026}") {
                                    onForceMerge()
                                }
                                .controlSize(.small)
                                .help("Re-encode incompatible clips to match a reference, then merge all")
                            }
                        }
                    }
                }
            }

            Toggle("Upload after conversion", isOn: $uploadEnabled)

            if uploadEnabled {
                serverPickerSection
            }

            Toggle("Start encoding after import", isOn: $autoEncodeEnabled)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                if shouldOfferAutoSplit, let onAutoSplit {
                    Button("Auto-split") {
                        applySelectedServer()
                        onAutoSplit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isNameValid)
                    .help("Clips have different formats and cannot be concatenated into one file. Auto-split creates one encoding group per format. Toggle \u{201C}Concatenate clips\u{201D} off to import them as separate files instead.")
                } else {
                    Button("Import") {
                        applySelectedServer()
                        onImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isNameValid)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 720)
        .onAppear { loadServers() }
    }

    @ViewBuilder
    private var serverPickerSection: some View {
        if servers.isEmpty {
            HStack {
                Text("No upload servers configured")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                addServerButton
            }
        } else if servers.count == 1 {
            HStack {
                Label(servers[0].displayLabel, systemImage: servers[0].backendType.iconName)
                    .font(.callout)
                Spacer()
                addServerButton
            }
        } else {
            HStack {
                Picker("Server", selection: $selectedServerID) {
                    ForEach(servers) { server in
                        Text(server.displayLabel).tag(Optional(server.id))
                    }
                }
                addServerButton
            }
        }
    }

    private var addServerButton: some View {
        Button {
            UserDefaults.standard.set("upload", forKey: AppConstants.settingsTabToOpenKey)
            openSettings()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add server in Upload settings")
    }

    private var namingPreview: String {
        let name = trimmedMasterName
        let ext = selectedPreset.fileExtension
        if concatEnabled {
            return String(
                localized: "Output: \(name).\(ext)",
                comment: "Shows the filename that will be produced for a concatenated camera-card import."
            )
        } else if clipCount > 1 {
            return String(
                localized: "Output: \(name)_001.\(ext), \(name)_002.\(ext), \u{2026}",
                comment: "Shows the filename pattern that will be produced for a multi-clip camera-card import."
            )
        } else {
            return String(
                localized: "Output: \(name)_001.\(ext)",
                comment: "Shows the filename that will be produced for a single-clip camera-card import."
            )
        }
    }

    private func loadServers() {
        let entries: [UploadServerEntry] = UploadProfileStore.loadProfiles().compactMap { profile in
            let hasDestination: Bool = {
                switch profile.backend {
                case .s3: return !profile.bucket.isEmpty
                case .gdrive: return false
                default: return !profile.server.isEmpty
                }
            }()
            guard hasDestination else { return nil }
            return UploadServerEntry(id: profile.id, name: profile.name, backendType: profile.backend)
        }

        servers = entries

        if let activeProfileID = UploadProfileStore.loadSelectedProfileID(),
           entries.contains(where: { $0.id == activeProfileID }) {
            selectedServerID = activeProfileID
        } else {
            selectedServerID = entries.first?.id
        }
    }

    private func applySelectedServer() {
        guard uploadEnabled,
              let selectedID = selectedServerID ?? servers.first?.id else { return }
        UploadProfileStore.saveSelectedProfileID(selectedID)
    }
}
