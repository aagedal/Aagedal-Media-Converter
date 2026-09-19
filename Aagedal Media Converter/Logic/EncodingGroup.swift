// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

// MARK: - Encoding Group

/// A group of video items that share conversion settings.
/// Groups can have their own preset, concat, upload, and transcription settings.
struct EncodingGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var items: [VideoItem]
    var isExpanded: Bool
    var preset: ExportPreset?
    var concatEnabled: Bool
    var uploadEnabled: Bool
    var transcriptionEnabled: Bool
    var analyticsEnabled: Bool
    var sequentialNamingEnabled: Bool

    // Conformance merge (two-pass force merge for incompatible clips)
    var conformanceMergeEnabled: Bool
    var conformanceReferenceItemID: UUID?

    /// Last sort applied to `items`. Tracked so the per-group sort button can
    /// cycle through modes without passing state through the UI layer.
    var lastSortMode: QueueSortMode?

    init(
        id: UUID = UUID(),
        name: String,
        items: [VideoItem] = [],
        isExpanded: Bool = false,
        preset: ExportPreset? = nil,
        concatEnabled: Bool = true,
        uploadEnabled: Bool = false,
        transcriptionEnabled: Bool = false,
        analyticsEnabled: Bool = false,
        sequentialNamingEnabled: Bool = false,
        conformanceMergeEnabled: Bool = false,
        conformanceReferenceItemID: UUID? = nil,
        lastSortMode: QueueSortMode? = nil
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.isExpanded = isExpanded
        self.preset = preset
        self.concatEnabled = concatEnabled
        self.uploadEnabled = uploadEnabled
        self.transcriptionEnabled = transcriptionEnabled
        self.analyticsEnabled = analyticsEnabled
        self.sequentialNamingEnabled = sequentialNamingEnabled
        self.conformanceMergeEnabled = conformanceMergeEnabled
        self.conformanceReferenceItemID = conformanceReferenceItemID
        self.lastSortMode = lastSortMode
    }

    var clipCount: Int { items.count }

    var status: ConversionManager.ConversionStatus {
        if items.isEmpty { return .waiting }
        if items.contains(where: { $0.status == .converting }) { return .converting }
        if items.allSatisfy({ $0.status == .done }) { return .done }
        if items.contains(where: { $0.status == .failed }) { return .failed }
        if items.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .waiting
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0.0) { $0 + $1.progress } / Double(items.count)
    }

    var totalDurationSeconds: Double {
        items.reduce(0.0) { $0 + $1.durationSeconds }
    }

    var formattedTotalDuration: String {
        let total = totalDurationSeconds
        if total <= 0 { return "" }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    /// Re-applies (or clears) sequential output-filename overrides on `items`
    /// in place, matching the current `sequentialNamingEnabled` flag and `name`.
    /// Call from: toggle, name change, and any time items are added/removed.
    mutating func normalizeSequentialNaming() {
        if sequentialNamingEnabled {
            let processed = FileNameProcessor.processFileName(name)
            for i in items.indices {
                items[i].outputFileNameOverride = String(format: "%@_%03d", processed, i + 1)
            }
        } else {
            for i in items.indices {
                items[i].outputFileNameOverride = nil
            }
        }
    }
}

// MARK: - Queue Entry

/// A single entry in the conversion queue: either a standalone file or a group.
enum QueueEntry: Identifiable, Equatable, Sendable {
    case single(VideoItem)
    case group(EncodingGroup)

    var id: UUID {
        switch self {
        case .single(let item): return item.id
        case .group(let group): return group.id
        }
    }

    var isSingle: Bool {
        if case .single = self { return true }
        return false
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

// MARK: - Flat Queue Row

/// Flattened representation for the NSTableView data source.
/// Groups are expanded into a header row followed by their item rows.
enum FlatQueueRow: Identifiable, Equatable {
    case single(VideoItem)
    case groupHeader(EncodingGroup)
    case groupItem(VideoItem, groupID: UUID)

    var id: UUID {
        switch self {
        case .single(let item): return item.id
        case .groupHeader(let group): return group.id
        case .groupItem(let item, _): return item.id
        }
    }
}

// MARK: - Helpers

extension Array where Element == QueueEntry {
    /// Flattens queue entries into rows for the table view.
    /// Expanded groups produce a header row followed by their item rows.
    var flattenedRows: [FlatQueueRow] {
        var rows: [FlatQueueRow] = []
        for entry in self {
            switch entry {
            case .single(let item):
                rows.append(.single(item))
            case .group(let group):
                rows.append(.groupHeader(group))
                if group.isExpanded {
                    for item in group.items {
                        rows.append(.groupItem(item, groupID: group.id))
                    }
                }
            }
        }
        return rows
    }

    /// All video items across all entries (singles + group items), in queue order.
    var allVideoItems: [VideoItem] {
        flatMap { entry in
            switch entry {
            case .single(let item): return [item]
            case .group(let group): return group.items
            }
        }
    }

    /// All video item URLs for deduplication checks.
    var allVideoURLs: Set<URL> {
        Set(allVideoItems.map { $0.url })
    }

    /// Finds the queue entry index and (for groups) the item index for a given item ID.
    func locate(itemID: UUID) -> (entryIndex: Int, itemIndex: Int?)? {
        for (i, entry) in enumerated() {
            switch entry {
            case .single(let item):
                if item.id == itemID { return (i, nil) }
            case .group(let group):
                if let j = group.items.firstIndex(where: { $0.id == itemID }) {
                    return (i, j)
                }
            }
        }
        return nil
    }

    /// Finds the queue entry index for a given group ID.
    func locateGroup(groupID: UUID) -> Int? {
        firstIndex(where: { $0.id == groupID })
    }
}

/// Moves complete clip values, preserving trims and queue order. Revalidates at
/// invocation time because background work can start while a menu is open.
enum QueueGrouping {
    static func canMove(_ ids: Set<UUID>, files: [VideoItem], groups: [EncodingGroup]) -> Bool {
        guard !ids.isEmpty else { return false }
        let items = (files + groups.flatMap(\.items)).filter { ids.contains($0.id) }
        guard items.count == ids.count else { return false }
        guard !groups.contains(where: { group in
            group.status == .converting && group.items.contains { ids.contains($0.id) }
        }) else { return false }
        return items.allSatisfy {
            $0.applicationJobID == nil && $0.status != .converting && !$0.isDownloading
                && $0.scheduledDownloadTime == nil && !$0.subtitleStatus.isInProgress
                && !$0.analyticsStatus.isInProgress && $0.uploadStatus != .uploading
        }
    }

    @discardableResult
    static func move(_ ids: Set<UUID>, into group: inout EncodingGroup,
                     files: inout [VideoItem], groups: inout [EncodingGroup], order: inout [UUID]) -> Bool {
        guard canMove(ids, files: files, groups: groups) else { return false }
        let entries = order.compactMap { id -> QueueEntry? in
            if let file = files.first(where: { $0.id == id }) { return .single(file) }
            if let existing = groups.first(where: { $0.id == id }) { return .group(existing) }
            return nil
        }
        let selected = entries.allVideoItems.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { return false }
        let firstEntry = entries.first { entry in
            switch entry {
            case .single(let item): return ids.contains(item.id)
            case .group(let existing): return existing.items.contains { ids.contains($0.id) }
            }
        }?.id
        let insertionIndex = firstEntry.flatMap { order.firstIndex(of: $0) } ?? order.count
        files.removeAll { ids.contains($0.id) }
        for index in groups.indices {
            groups[index].items.removeAll { ids.contains($0.id) }
            if groups[index].sequentialNamingEnabled { groups[index].normalizeSequentialNaming() }
        }
        group.items = selected
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
        order.insert(group.id, at: insertionIndex)
        order.removeAll { ids.contains($0) }
        groups.append(group)
        return true
    }
}
