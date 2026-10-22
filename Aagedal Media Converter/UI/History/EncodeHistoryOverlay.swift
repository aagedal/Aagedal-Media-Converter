//
//  EncodeHistoryOverlay.swift
//  Aagedal Media Converter
//
//  Browse past encodes grouped by app session, inspect their settings and
//  put them back into the queue.
//

import AppKit
import SwiftUI

struct EncodeHistoryOverlay: View {
    @Binding var isPresented: Bool
    /// Called with records and their resolved source locations.
    let onRequeue: (_ records: [EncodeRecord], _ resolved: [UUID: URL]) -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var store = EncodeHistoryStore.shared
    @State private var searchText = ""
    @State private var expandedID: UUID?
    @State private var missingPrompt: MissingPrompt?
    /// Records whose source can't be found; their row re-queue button is disabled.
    @State private var missingSourceIDs: Set<UUID> = []

    private struct MissingPrompt: Identifiable {
        let id = UUID()
        let records: [EncodeRecord]
        let resolved: [UUID: URL]
        let missing: [EncodeRecord]
    }

    private struct SessionSection: Identifiable {
        let id: UUID
        let session: HistorySession?
        let records: [EncodeRecord]
    }

    var body: some View {
        HistoryOverlayPanel(isPresented: $isPresented, title: "Encode History", systemImage: "clock.arrow.circlepath", width: 720) {
            if !store.records.isEmpty {
                TextField("Search file names, presets, codecs…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }

            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections) { section in
                            sessionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, maxHeight: 460)
            }
        } footer: {
            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("History Settings…") {
                    UserDefaults.standard.set("history", forKey: AppConstants.settingsTabToOpenKey)
                    openSettings()
                }
            }
        }
        .alert(item: $missingPrompt) { prompt in
            let names = prompt.missing.prefix(3).map(\.sourceName).joined(separator: ", ")
            let extra = prompt.missing.count - 3
            return Alert(
                title: Text("\(prompt.missing.count) source files not found",
                            comment: "Alert title when re-queueing history items whose files are missing."),
                message: extra > 0
                    ? Text("\(names) and \(extra) more may have been moved or deleted.",
                           comment: "Lists up to three missing file names, then how many more.")
                    : Text("\(names) may have been moved or deleted.",
                           comment: "Lists the missing file names."),
                primaryButton: .default(Text("Locate…")) { locate(prompt) },
                secondaryButton: prompt.resolved.isEmpty
                    ? .cancel()
                    : .default(Text("Skip Missing")) { finishRequeue(prompt.records, resolved: prompt.resolved) }
            )
        }
        .task(id: store.records) { await refreshMissingSources() }
    }

    // MARK: - Sections

    private var filteredRecords: [EncodeRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.records }
        return store.records.filter { record in
            [record.sourceName, record.presetDisplayName, record.sourceFacts.videoCodec ?? "",
             record.sourceFacts.container ?? "", record.groupName ?? "", record.outputURL?.lastPathComponent ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var sections: [SessionSection] {
        let sessionsByID = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [UUID] = []
        var grouped: [UUID: [EncodeRecord]] = [:]
        for record in filteredRecords {
            if grouped[record.sessionID] == nil { order.append(record.sessionID) }
            grouped[record.sessionID, default: []].append(record)
        }
        return order.map { SessionSection(id: $0, session: sessionsByID[$0], records: grouped[$0] ?? []) }
    }

    private var footerText: String {
        let count = store.records.count
        let days = store.retentionDays
        if !store.isEnabled { return String(localized: "History recording is off") }
        return days > 0
            ? String(localized: "\(count) encodes · kept for \(days) days", comment: "Encode history footer.")
            : String(localized: "\(count) encodes · kept indefinitely", comment: "Encode history footer.")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? String(localized: "No encodes yet") : String(localized: "No matches"))
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text(store.isEnabled
                     ? String(localized: "Encodes are listed here once they start.")
                     : String(localized: "Turn on history in Settings to keep a record of encodes."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func sessionView(_ section: SessionSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((section.session?.startedAt ?? section.records.last?.startedAt ?? Date()).historySessionLabel)
                    .font(.subheadline.weight(.semibold))
                Text("· \(section.records.count) encodes", comment: "Encode count after a history session date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let session = section.session {
                    if session.id == store.currentSessionID {
                        Text("Current session").font(.caption).foregroundStyle(.secondary)
                    } else if session.endedAt != nil && !session.endedCleanly {
                        Label("Unexpected exit", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("The app didn’t quit normally during this session")
                    }
                    if session.deviceName != EncodeHistoryFormat.deviceName {
                        Text(session.deviceName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Re-queue All") { requeue(section.records) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(section.records) { record in
                recordRow(record)
            }
        }
    }

    // MARK: - Rows

    private func recordRow(_ record: EncodeRecord) -> some View {
        let isExpanded = expandedID == record.id
        let toggle = {
            withAnimation(.easeInOut(duration: 0.15)) { expandedID = isExpanded ? nil : record.id }
        }
        return VStack(alignment: .leading, spacing: 0) {
            // A tap gesture rather than a Button so the re-queue button inside stays clickable.
            HStack(spacing: 8) {
                EncodeOutcomeIcon(outcome: record.outcome)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.sourceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(rowSubtitle(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                rowRequeueButton(record)
                Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", toggle)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)

            if isExpanded {
                recordDetails(record)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isExpanded ? 0.07 : 0.04)))
        .contextMenu {
            Button("Re-queue") { requeue([record]) }
            if let output = record.outputURL {
                Button("Show Output in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            Button("Show Source in Finder") { revealSource(record) }
            Divider()
            Button("Remove from History", role: .destructive) { store.removeRecords([record.id]) }
        }
    }

    @ViewBuilder
    private func rowRequeueButton(_ record: EncodeRecord) -> some View {
        let icon = Image(systemName: "arrow.uturn.backward.circle")
            .font(.body)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        if missingSourceIDs.contains(record.id) {
            // Drawn like a disabled button: a real disabled Button shows no tooltip.
            icon
                .foregroundStyle(.tertiary)
                .onTapGesture {}  // Don't expand the row.
                .help("The source file no longer exists at \(record.source.path). Right-click and choose Re-queue to locate it.")
                .accessibilityElement()
                .accessibilityLabel("Re-queue \(record.sourceName)")
                .accessibilityValue("Unavailable, source file not found")
                .accessibilityAddTraits(.isButton)
        } else {
            Button { requeue([record]) } label: { icon }
                .buttonStyle(.borderless)
                .help("Add this file back to the queue with the same settings")
                .accessibilityLabel("Re-queue \(record.sourceName)")
        }
    }

    private func rowSubtitle(_ record: EncodeRecord) -> String {
        var parts = [record.presetDisplayName]
        if let groupName = record.groupName { parts.append(groupName) }
        if let duration = record.sourceFacts.durationSeconds { parts.append(EncodeHistoryFormat.timecode(duration)) }
        if let size = record.outputSizeBytes { parts.append(EncodeHistoryFormat.bytes(size)) }
        if record.outcome == .failed, let error = record.errorMessage { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func recordDetails(_ record: EncodeRecord) -> some View {
        let facts = record.sourceFacts
        return VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                detailRow("Source", record.source.path)
                detailRow("Format", [facts.container, facts.videoCodec, facts.resolutionLabel,
                                     facts.frameRate.map { String(format: "%.3g fps", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                detailRow("Audio", [facts.audioCodec, facts.audioChannels.map { "\($0) ch" }]
                    .compactMap { $0 }.joined(separator: " · "))
                detailRow("Source size", facts.sizeBytes.map(EncodeHistoryFormat.bytes))
                detailRow("Preset", record.presetDisplayName)
                detailRow("Settings", record.recipe.summaryLines.isEmpty ? nil : record.recipe.summaryLines.joined(separator: " · "))
                detailRow("Output", record.outputPath)
                detailRow("Output size", record.outputSizeBytes.map(EncodeHistoryFormat.bytes))
                detailRow("Encode time", record.encodeDuration.map { EncodeHistoryFormat.timecode($0) })
                detailRow("Merged", record.merged ? String(localized: "Part of a merged output") : nil)
                detailRow("Result", EncodeOutcomeIcon(outcome: record.outcome).label)
                detailRow("Error", record.errorMessage)
            }
            .font(.caption)
            .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Re-queue") { requeue([record]) }
                    .help("Add this file back to the queue with the same settings")
                if let output = record.outputURL {
                    Button("Show Output") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        .disabled(!FileManager.default.fileExists(atPath: output.path))
                }
                Spacer()
                Button("Remove", role: .destructive) { store.removeRecords([record.id]) }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).lineLimit(3).truncationMode(.middle)
            }
        }
    }

    // MARK: - Actions

    private func revealSource(_ record: EncodeRecord) {
        if let url = record.source.resolve() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSSound.beep()
        }
    }

    private func requeue(_ records: [EncodeRecord]) {
        // Queue in the order they were originally encoded.
        let records = records.sorted { $0.startedAt < $1.startedAt }
        var resolved: [UUID: URL] = [:]
        var missing: [EncodeRecord] = []
        for record in records {
            if let url = record.source.resolve() { resolved[record.id] = url } else { missing.append(record) }
        }
        if missing.isEmpty {
            finishRequeue(records, resolved: resolved)
        } else {
            missingPrompt = MissingPrompt(records: records, resolved: resolved, missing: missing)
        }
    }

    private func locate(_ prompt: MissingPrompt) {
        guard let first = prompt.missing.first,
              let newURL = HistoryRelinker.chooseReplacement(for: first.source.path) else { return }
        let missingPaths = Array(Set(prompt.missing.map(\.source.path)))
        var relinks = HistoryRelinker.siblingMatches(missingPaths: missingPaths, relinkedFrom: first.source.path, to: newURL)
        relinks[first.source.path] = newURL
        // Update every record (not just these) that pointed at a relinked path.
        for (oldPath, url) in relinks {
            let ids = Set(store.records.filter { $0.source.path == oldPath }.map(\.id))
            store.relinkSource(of: ids, oldPath: oldPath, to: url)
        }
        // Records were updated in the store; retry with fresh copies after the alert closes.
        let ids = Set(prompt.records.map(\.id))
        DispatchQueue.main.async {
            requeue(store.records.filter { ids.contains($0.id) })
        }
    }

    private func refreshMissingSources() async {
        let sources = store.records.map { ($0.id, $0.source) }
        // Bookmark resolution touches the disk; keep it off the main actor.
        let missing = await Task.detached(priority: .utility) {
            Set(sources.compactMap { id, source in source.resolve() == nil ? id : nil })
        }.value
        guard !Task.isCancelled else { return }
        missingSourceIDs = missing
    }

    private func finishRequeue(_ records: [EncodeRecord], resolved: [UUID: URL]) {
        guard !resolved.isEmpty else { return }
        onRequeue(records, resolved)
        isPresented = false
    }
}
