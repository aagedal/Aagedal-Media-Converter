//
//  QueueRestoreRequest.swift
//  Aagedal Media Converter
//
//  Describes rows to put back into the queue from the last-session snapshot
//  or the encode history. Sources are already resolved to existing files.
//

import Foundation

struct QueueRestoreRequest: Equatable {
    struct Item: Equatable {
        var url: URL
        var recipe: EncodeRecipe
        /// Preset the item was encoded (or queued) with. Ungrouped rows get it
        /// as a per-item override when it differs from the queue preset.
        var preset: ExportPreset?
    }

    struct Group: Equatable {
        var name: String
        var preset: ExportPreset?
        var concatEnabled = false
        var uploadEnabled = false
        var transcriptionEnabled = false
        var analyticsEnabled = false
        var sequentialNamingEnabled = false
        var items: [Item]
    }

    /// Queue preset to adopt when restoring into an empty queue.
    var preset: ExportPreset?
    var items: [Item] = []
    var groups: [Group] = []

    var isEmpty: Bool { items.isEmpty && groups.allSatisfy(\.items.isEmpty) }

    /// Restores a last-session snapshot, keeping its groups. `resolved` maps
    /// snapshot item IDs to their current file location.
    static func fromSnapshot(
        _ snapshot: LastSessionSnapshot,
        selectedIDs: Set<UUID>,
        resolved: [UUID: URL]
    ) -> QueueRestoreRequest {
        let snapshotPreset = ExportPreset(rawValue: snapshot.presetRawValue)
        func items(_ source: [SnapshotItem], preset: ExportPreset?) -> [Item] {
            source.compactMap { item in
                guard selectedIDs.contains(item.id), let url = resolved[item.id] else { return nil }
                let override = item.recipe.presetOverrideRawValue.flatMap(ExportPreset.init(rawValue:))
                return Item(url: url, recipe: item.recipe, preset: override ?? preset)
            }
        }
        var request = QueueRestoreRequest(preset: snapshotPreset)
        request.items = items(snapshot.items, preset: snapshotPreset)
        for group in snapshot.groups {
            let groupPreset = group.presetRawValue.flatMap(ExportPreset.init(rawValue:))
            let groupItems = items(group.items, preset: groupPreset)
            guard !groupItems.isEmpty else { continue }
            request.groups.append(Group(
                name: group.name,
                preset: groupPreset,
                concatEnabled: group.concatEnabled,
                uploadEnabled: group.uploadEnabled,
                transcriptionEnabled: group.transcriptionEnabled,
                analyticsEnabled: group.analyticsEnabled,
                sequentialNamingEnabled: group.sequentialNamingEnabled,
                items: groupItems
            ))
        }
        return request
    }

    /// Re-queues history records as ungrouped rows that each keep the preset
    /// they were encoded with. An empty queue adopts the most common preset so
    /// fewer rows need an override.
    static func fromRecords(_ records: [EncodeRecord], resolved: [UUID: URL]) -> QueueRestoreRequest {
        var request = QueueRestoreRequest()
        var counts: [ExportPreset: Int] = [:]
        for record in records {
            guard let url = resolved[record.id] else { continue }
            request.items.append(Item(url: url, recipe: record.recipe, preset: record.preset))
            if let preset = record.preset { counts[preset, default: 0] += 1 }
        }
        // Ties go to the preset seen first, keeping the choice stable.
        request.preset = request.items.compactMap(\.preset).max { counts[$0, default: 0] < counts[$1, default: 0] }
        return request
    }
}
