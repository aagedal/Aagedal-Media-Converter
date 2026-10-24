// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "Update automatically" toggle and version picker (rollback) for one
/// app-managed tool. Choosing a specific version pins it and pauses automatic
/// updates for that tool until "Newest" is chosen again.
struct ManagedToolVersionControls: View {
    let tool: ManagedTool
    /// Change to reload after installs or source changes made elsewhere.
    let refreshToken: Int
    var onActiveVersionChange: @MainActor () async -> Void = {}

    @AppStorage private var autoUpdate: Bool
    @State private var snapshot: ManagedToolSnapshot?

    init(
        tool: ManagedTool,
        refreshToken: Int,
        onActiveVersionChange: @escaping @MainActor () async -> Void = {}
    ) {
        self.tool = tool
        self.refreshToken = refreshToken
        self.onActiveVersionChange = onActiveVersionChange
        _autoUpdate = AppStorage(wrappedValue: true, tool.autoUpdateKey)
    }

    private var hasChoices: Bool {
        guard let snapshot else { return false }
        return snapshot.installedVersions.count + (snapshot.bundledVersion == nil ? 0 : 1) > 1
            || snapshot.pin.isPinned
    }

    private var isPinned: Bool { snapshot?.pin.isPinned ?? false }

    private var pinSelection: Binding<String> {
        Binding(
            get: { snapshot?.pin.storageValue ?? "" },
            set: { newValue in
                let pin = ManagedToolPin(storageValue: newValue)
                Task { @MainActor in
                    await YTDLPUpdateService.shared.setManagedToolPin(pin, for: tool)
                    await reload()
                    await onActiveVersionChange()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Update automatically", isOn: $autoUpdate)
                .toggleStyle(SwitchToggleStyle())

            if let snapshot, hasChoices {
                HStack {
                    Text("Version:")
                    Picker("Version", selection: pinSelection) {
                        Text(newestLabel(for: snapshot)).tag("")
                        ForEach(snapshot.installedVersions, id: \.self) { version in
                            Text(verbatim: version).tag(version)
                        }
                        if let bundled = snapshot.bundledVersion {
                            Text("\(bundled) (included with the app)").tag(ManagedToolPin.bundledStorageValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }

            if isPinned {
                Text("Automatic updates are paused because a specific version is chosen. Choose Newest to resume them.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Checks at most once a day and never switches versions while a download is running. The last 3 downloaded versions are kept, so you can roll back by choosing an older version.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: refreshToken) {
            await reload()
        }
    }

    private func newestLabel(for snapshot: ManagedToolSnapshot) -> String {
        let newest = ManagedToolPolicy.activeChoice(
            installed: snapshot.installedVersions,
            bundled: snapshot.bundledVersion,
            pin: .automatic
        )
        switch newest {
        case .installed(let version):
            return String(localized: "Newest (\(version))", comment: "Managed tool version picker: automatic newest version.")
        case .bundled:
            return String(localized: "Newest (\(snapshot.bundledVersion ?? ""))", comment: "Managed tool version picker: automatic newest version.")
        case .none:
            return String(localized: "Newest", comment: "Managed tool version picker: automatic newest version.")
        }
    }

    private func reload() async {
        snapshot = await YTDLPUpdateService.shared.managedToolSnapshot(for: tool)
    }
}
