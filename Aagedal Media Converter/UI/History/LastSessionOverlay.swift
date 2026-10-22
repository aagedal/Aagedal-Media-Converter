//
//  LastSessionOverlay.swift
//  Aagedal Media Converter
//
//  One-shot offer to put the previous run's unfinished queue back.
//

import SwiftUI

struct LastSessionOverlay: View {
    @Binding var isPresented: Bool
    let snapshot: LastSessionSnapshot
    let onRestore: (_ selectedIDs: Set<UUID>, _ resolved: [UUID: URL]) -> Void
    let onDiscard: () -> Void

    @State private var selection: Set<UUID> = []
    @State private var resolved: [UUID: URL] = [:]
    @State private var didResolve = false

    private var allItems: [SnapshotItem] { snapshot.items + snapshot.groups.flatMap(\.items) }
    private var restorableSelection: Set<UUID> { selection.filter { resolved[$0] != nil } }

    var body: some View {
        HistoryOverlayPanel(isPresented: $isPresented, title: "Restore Last Session", systemImage: "arrow.uturn.backward.circle") {
            Text("These items were still in the queue when the app last closed (saved \(snapshot.savedAt.historySessionLabel)). Trim, crop, audio routing and other per-item settings are restored.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !snapshot.items.isEmpty {
                        section(
                            title: String(localized: "Queue", comment: "Last session section for ungrouped items."),
                            subtitle: ExportPreset(rawValue: snapshot.presetRawValue).map { PresetManager.shared.displayName(for: $0) },
                            items: snapshot.items
                        )
                    }
                    ForEach(snapshot.groups) { group in
                        section(
                            title: group.name,
                            subtitle: group.presetRawValue.flatMap(ExportPreset.init(rawValue:)).map { PresetManager.shared.displayName(for: $0) },
                            items: group.items
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 420)
        } footer: {
            HStack {
                Button("Discard", role: .destructive) {
                    onDiscard()
                    isPresented = false
                }
                .help("Forget these items")
                Spacer()
                Button("Not Now") { isPresented = false }
                Button(restoreTitle) {
                    onRestore(restorableSelection, resolved)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(restorableSelection.isEmpty)
            }
        }
        .task {
            guard !didResolve else { return }
            didResolve = true
            resolveAll()
            selection = Set(allItems.map(\.id))
        }
    }

    private var restoreTitle: String {
        let count = restorableSelection.count
        return count == allItems.count
            ? String(localized: "Restore All")
            : String(localized: "Restore \(count)", comment: "Button that restores the selected number of last-session items.")
    }

    private func section(title: String, subtitle: String?, items: [SnapshotItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private func row(_ item: SnapshotItem) -> some View {
        let isMissing = didResolve && resolved[item.id] == nil
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selection.contains(item.id) },
                set: { isOn in
                    if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isMissing)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.source.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isMissing ? .secondary : .primary)
                let details = ([item.statusLabel] + item.recipe.summaryLines).joined(separator: " · ")
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isMissing {
                Label("Missing", systemImage: "questionmark.folder")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Locate…") { relink(item) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func resolveAll() {
        var result: [UUID: URL] = [:]
        for item in allItems {
            if let url = item.source.resolve() { result[item.id] = url }
        }
        resolved = result
    }

    private func relink(_ item: SnapshotItem) {
        guard let newURL = HistoryRelinker.chooseReplacement(for: item.source.path) else { return }
        LastSessionStore.shared.relink(itemID: item.id, to: newURL)
        resolved[item.id] = newURL
        selection.insert(item.id)
        // Files usually move as a folder: relink siblings found next to the new location.
        let missing = allItems.filter { resolved[$0.id] == nil }
        let matches = HistoryRelinker.siblingMatches(
            missingPaths: missing.map(\.source.path), relinkedFrom: item.source.path, to: newURL
        )
        for other in missing {
            guard let match = matches[other.source.path] else { continue }
            LastSessionStore.shared.relink(itemID: other.id, to: match)
            resolved[other.id] = match
            selection.insert(other.id)
        }
    }
}
