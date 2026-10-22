//
//  LastSessionStore.swift
//  Aagedal Media Converter
//
//  Keeps a rolling snapshot of unfinished queue rows on disk while the app
//  runs. On the next launch that snapshot becomes a one-shot "restore last
//  session" offer; the queue itself is never restored automatically.
//

import Foundation
import Observation

@MainActor
@Observable
final class LastSessionStore {
    static let shared = LastSessionStore()

    /// Snapshot from a previous run that the user hasn't restored or discarded.
    private(set) var pending: LastSessionSnapshot?

    /// Builds a snapshot from the live queue. Registered by the main window.
    @ObservationIgnored var snapshotProvider: (@MainActor () -> LastSessionSnapshot)?
    @ObservationIgnored private var lastWritten: LastSessionSnapshot?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    /// Set at quit so window teardown doesn't rewrite the snapshot just flushed.
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults

    /// Ignored offers expire so an old queue doesn't linger forever.
    nonisolated static let pendingLifetime: TimeInterval = 14 * 86_400

    init(directory: URL = AppConstants.encodeHistoryDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    private var liveURL: URL { directory.appendingPathComponent("last-session.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending-session.json") }

    var isEnabled: Bool {
        defaults.object(forKey: AppConstants.lastSessionRestoreEnabledKey) as? Bool ?? AppConstants.defaultLastSessionRestoreEnabled
    }

    /// Promotes the previous run's snapshot to the pending offer.
    func bootstrap(now: Date = Date()) {
        guard !didBootstrap else { return }
        didBootstrap = true

        let previous = read(liveURL)
        remove(liveURL)

        guard isEnabled else {
            remove(pendingURL)
            return
        }
        if let previous, !previous.isEmpty {
            pending = previous
            write(previous, to: pendingURL)
        } else if let older = read(pendingURL), !older.isEmpty,
                  now.timeIntervalSince(older.savedAt) < Self.pendingLifetime {
            // Not acted on last time; keep offering it.
            pending = older
        } else {
            remove(pendingURL)
        }
    }

    /// Throttled: queue changes (including progress ticks) trigger at most one
    /// snapshot every couple of seconds, built from the latest state.
    func scheduleUpdate() {
        guard isEnabled, !isTerminating, updateTask == nil else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            if let snapshot = self.snapshotProvider?() { self.update(snapshot) }
        }
    }

    /// Records the current unfinished rows. No-op when nothing changed.
    func update(_ snapshot: LastSessionSnapshot) {
        guard isEnabled else { return }
        var comparable = snapshot
        comparable.savedAt = lastWritten?.savedAt ?? snapshot.savedAt
        guard comparable != lastWritten else { return }
        lastWritten = snapshot
        let url = liveURL
        if snapshot.isEmpty {
            remove(url)
        } else {
            guard let data = try? EncodeHistoryStore.encoder.encode(snapshot) else { return }
            EncodeHistoryStore.writeQueue.async { Self.writeData(data, to: url) }
        }
    }

    /// Writes the latest snapshot synchronously (called at quit).
    func flush() {
        isTerminating = true
        updateTask?.cancel()
        updateTask = nil
        if let snapshot = snapshotProvider?() { update(snapshot) }
        EncodeHistoryStore.writeQueue.sync {}
    }

    /// The main window closed while the app keeps running, which drops the
    /// queue. Offer its unfinished rows right away in the next window.
    func windowClosed() {
        guard !isTerminating else { return }
        updateTask?.cancel()
        updateTask = nil
        let snapshot = snapshotProvider?()
        snapshotProvider = nil
        lastWritten = nil
        remove(liveURL)
        guard isEnabled, let snapshot, !snapshot.isEmpty else { return }
        pending = snapshot
        write(snapshot, to: pendingURL)
    }

    /// Removes restored items from the offer; discards it when empty.
    func consume(itemIDs: Set<UUID>) {
        guard var snapshot = pending else { return }
        snapshot.items.removeAll { itemIDs.contains($0.id) }
        for index in snapshot.groups.indices {
            snapshot.groups[index].items.removeAll { itemIDs.contains($0.id) }
        }
        snapshot.groups.removeAll { $0.items.isEmpty }
        if snapshot.isEmpty {
            discardPending()
        } else {
            pending = snapshot
            write(snapshot, to: pendingURL)
        }
    }

    func discardPending() {
        pending = nil
        remove(pendingURL)
    }

    /// Updates a pending item's source after the user relinked a moved file.
    func relink(itemID: UUID, to url: URL) {
        guard var snapshot = pending else { return }
        let reference = HistoryFileReference(url: url)
        if let index = snapshot.items.firstIndex(where: { $0.id == itemID }) {
            snapshot.items[index].source = reference
        }
        for groupIndex in snapshot.groups.indices {
            if let index = snapshot.groups[groupIndex].items.firstIndex(where: { $0.id == itemID }) {
                snapshot.groups[groupIndex].items[index].source = reference
            }
        }
        pending = snapshot
        write(snapshot, to: pendingURL)
    }

    // MARK: - Snapshot building

    /// Whether a row is worth offering again. Finished, downloading and
    /// scheduled rows are skipped; image sequences aren't restorable yet.
    static func isRestorable(_ item: VideoItem) -> Bool {
        item.status != .done && item.isEncodable && !item.isImageSequence
    }

    static func makeSnapshot(
        files: [VideoItem],
        groups: [EncodingGroup],
        order: [UUID],
        preset: ExportPreset,
        now: Date = Date()
    ) -> LastSessionSnapshot {
        func snapshotItem(_ item: VideoItem) -> SnapshotItem {
            SnapshotItem(id: item.id, source: HistoryFileReference(path: item.url.path), recipe: EncodeRecipe(item: item),
                         statusLabel: statusLabel(item.status))
        }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedFiles = files.sorted { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }
        let orderedGroups = groups.sorted { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }

        let items = orderedFiles.filter(isRestorable).map(snapshotItem)
        let snapshotGroups: [SnapshotGroup] = orderedGroups.compactMap { group in
            let groupItems = group.items.filter(isRestorable).map(snapshotItem)
            guard !groupItems.isEmpty else { return nil }
            return SnapshotGroup(
                id: group.id,
                name: group.name,
                presetRawValue: group.preset?.rawValue,
                concatEnabled: group.concatEnabled,
                uploadEnabled: group.uploadEnabled,
                transcriptionEnabled: group.transcriptionEnabled,
                analyticsEnabled: group.analyticsEnabled,
                sequentialNamingEnabled: group.sequentialNamingEnabled,
                items: groupItems
            )
        }
        return LastSessionSnapshot(savedAt: now, presetRawValue: preset.rawValue, items: items, groups: snapshotGroups)
    }

    static func statusLabel(_ status: ConversionManager.ConversionStatus) -> String {
        switch status {
        case .waiting: return String(localized: "Waiting", comment: "Last session item status.")
        case .converting: return String(localized: "Interrupted", comment: "Encode history outcome: the app quit or crashed during the encode.")
        case .done: return String(localized: "Done", comment: "Last session item status.")
        case .failed: return String(localized: "Failed", comment: "Encode history outcome.")
        case .cancelled: return String(localized: "Cancelled", comment: "Encode history outcome.")
        }
    }

    // MARK: - Files

    private func read(_ url: URL) -> LastSessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? EncodeHistoryStore.decoder.decode(LastSessionSnapshot.self, from: data)
    }

    private func write(_ snapshot: LastSessionSnapshot, to url: URL) {
        guard let data = try? EncodeHistoryStore.encoder.encode(snapshot) else { return }
        EncodeHistoryStore.writeQueue.async { Self.writeData(data, to: url) }
    }

    /// Queued behind pending writes so a delete can't be undone by an earlier write.
    private func remove(_ url: URL) {
        EncodeHistoryStore.writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated private static func writeData(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
