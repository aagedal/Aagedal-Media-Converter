// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

// MARK: - Custom Table View
//
// File-drag-out from a queue row is handled by `DraggableFileImageView` itself
// (it starts its own NSDraggingSession on mouseDown). This subclass only needs
// to surface a drag-exit hook for the row-reorder / group-drop highlight.

private final class VideoQueueNSTableView: NSTableView {

    /// Fires when a drag leaves the table without dropping, so the coordinator can
    /// clear its "hovering over group" highlight. `validateDrop` isn't called at
    /// exit, so we need this AppKit-level hook.
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExit?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExit?()
        // Do NOT call super here. `draggingEnded(_:)` is an *optional*
        // NSDraggingDestination method that NSTableView does not implement, so
        // `super.draggingEnded(_:)` raises "unrecognized selector". That
        // exception fires inside AppKit's drag-completion proc, leaving the drag
        // session unfinished — after which AppKit rejects every later drag with
        // "Cannot start a new drag. A previous drag has not finished", so only
        // the first drag of a session worked.
    }
}

// MARK: - Custom Row View (suppresses default selection highlight)

private final class TransparentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // No-op: VideoFileCellView draws its own selection border
    }
}

// MARK: - Pasteboard type for internal reorder

extension NSPasteboard.PasteboardType {
    static let videoQueueItem = NSPasteboard.PasteboardType("com.aagedal.mediaconverter.videoqueueitem")
}

/// Returns true when `info` represents an internal reorder/group-move gesture —
/// a drag that originated inside `tableView` AND carries the reorder marker.
///
/// The marker check matters because a drag-to-share handle (`DraggableFileImageView`)
/// is also a descendant of the table, but it puts only a `.fileURL` on the
/// pasteboard. Without the marker requirement, dragging an exported file back onto
/// our own queue would be mistaken for a reorder. Genuine reorders always write
/// `.videoQueueItem` (see `pasteboardWriterForRow`), so requiring it lets a
/// re-dropped export fall through to the external-file path and be re-added.
@MainActor
func draggingSourceIsInternal(_ info: any NSDraggingInfo, tableView: NSTableView) -> Bool {
    guard info.draggingPasteboard.types?.contains(.videoQueueItem) == true else { return false }
    if let src = info.draggingSource as? NSTableView, src === tableView { return true }
    if let view = info.draggingSource as? NSView, view.isDescendant(of: tableView) { return true }
    return false
}

struct QueueSubtitleCancellationTarget: Equatable {
    let method: SubtitleConversionMethod
    let operationID: UUID?
}

/// Resolves and invalidates a subtitle attempt in either queue storage location.
/// Returning the target before clearing its token lets the caller route cancellation
/// to the correct service while stale callbacks are fenced immediately.
enum QueueSubtitleCancellationState {
    static func takeTarget(
        itemID: UUID,
        droppedFiles: inout [VideoItem],
        encodingGroups: inout [EncodingGroup]
    ) -> QueueSubtitleCancellationTarget? {
        if let index = droppedFiles.firstIndex(where: { $0.id == itemID }) {
            return takeTarget(from: &droppedFiles[index])
        }

        for groupIndex in encodingGroups.indices {
            if let itemIndex = encodingGroups[groupIndex].items.firstIndex(where: { $0.id == itemID }) {
                return takeTarget(from: &encodingGroups[groupIndex].items[itemIndex])
            }
        }
        return nil
    }

    private static func takeTarget(from item: inout VideoItem) -> QueueSubtitleCancellationTarget {
        let target = QueueSubtitleCancellationTarget(
            method: item.subtitleMethod,
            operationID: item.subtitleOperationID
        )
        item.subtitleStatus = .notQueued
        item.subtitleOperationID = nil
        return target
    }
}

// MARK: - Queue Table Handle
//
// Lightweight bridge letting a SwiftUI parent ask the NSTableView questions
// about its current state without owning a reference. Currently only answers
// "is row X fully visible?" — used by VideoFileListView to decide whether the
// "new group" toast should offer a scroll button.

@MainActor final class QueueTableHandle: ObservableObject {
    fileprivate var isRowVisibleImpl: (UUID) -> Bool = { _ in false }
    func isRowVisible(for id: UUID) -> Bool { isRowVisibleImpl(id) }
}

// MARK: - VideoQueueTableView (NSViewRepresentable)

struct VideoQueueTableView: NSViewRepresentable {
    @Binding var droppedFiles: [VideoItem]
    @Binding var encodingGroups: [EncodingGroup]
    @Binding var selection: Set<UUID>
    @Binding var focusedCommentID: UUID?
    @Binding var shouldScrollToSelection: Bool
    let isCompactMode: Bool
    let preset: ExportPreset
    let mergeClipsEnabled: Bool
    let mergeClipsAvailable: Bool
    let showCommentField: Bool
    let showDateTagButton: Bool
    let isTranscriptionAvailable: Bool

    /// Invoked when a cell raises `.tabCommentField` from its comment popover.
    /// VideoFileListView owns the focus-navigation logic (`handleTabPress`), so
    /// this just forwards the direction.
    var onTabCommentField: ((Bool) -> Void)?

    // Callbacks
    var onDelete: (IndexSet) -> Void
    var onReset: (Int, Bool) -> Void
    var onOpenTrim: ((UUID) -> Void)?
    var onOpenTrimWithCrop: ((UUID) -> Void)?
    var onOpenTimecode: ((UUID) -> Void)?
    var onOpenAudioConfig: ((UUID) -> Void)?
    var onOpenMetadata: (([UUID]) -> Void)?
    var onOpenDCPMetadata: ((UUID) -> Void)?
    var onOpenIMFMetadata: ((UUID) -> Void)?
    var onOpenAnalyticsResults: ((UUID) -> Void)?
    var onToggleDateTag: ((Int) -> Void)?
    var onPlayFullscreen: ((UUID) -> Void)?
    var onRenameOutputFileName: ((UUID, String?) -> Void)?
    var encodeOnly: ((UUID) async -> Void)?
    /// Option-click on a group's encode button → encode that group's items
    /// immediately. Mirrors `encodeOnly` for single items.
    var encodeOnlyGroup: ((UUID) async -> Void)?
    var transcribeOnly: ((UUID, SubtitleConversionMethod) async -> Void)?
    var analyzeOnly: ((UUID) async -> Void)?
    var analyzeMetrics: ((UUID, [QualityMetric]) async -> Void)?
    var onDeleteGroup: ((UUID) -> Void)?
    /// Called when the user clicks the cancel-upload button on a group card.
    /// Cancels any in-flight uploads for the group's items without deleting the group.
    var onCancelGroupUpload: ((UUID) -> Void)?
    var onAddFilesToGroup: ((UUID) -> Void)?
    var onResetGroup: ((UUID) -> Void)?
    var queueOrder: [UUID]
    var onReorder: ((_ movedIDs: [UUID], _ destinationQueueIndex: Int) -> Void)?
    var onQueueSync: (() -> Void)?
    /// Called when the user clicks the sort button on a group card. Cycling the
    /// sort mode is handled in VideoFileListView so main-queue and group sorts
    /// share the same comparator logic.
    var onCycleGroupSort: ((UUID) -> Void)?
    /// Called when the user clicks the "Edit" button on a group card. The caller
    /// (ContentView) owns the window lifecycle.
    var onOpenGroupEditor: ((UUID) -> Void)?
    /// Handle exposed back to the SwiftUI parent so it can ask the table view
    /// questions (e.g. row visibility). Optional — tests/previews can omit it.
    var handle: QueueTableHandle?
    /// Called when the user drops files from Finder directly onto a group header.
    var onFileDropToGroup: ((UUID, [URL]) -> Void)?
    /// Called when the user drops files from Finder onto the table but not on a group.
    /// The NSTableView claims file drags over its bounds, so routing non-group drops
    /// through this callback preserves the "drop anywhere to add to main queue" UX.
    var onFileDropToMainQueue: (([URL]) -> Void)?
    /// Fires while an external file drag hovers over the table but NOT over a group
    /// header. Lets the SwiftUI parent paint the queue-area highlight border —
    /// without this, the only visible affordance during a populated-queue drop is
    /// the per-group blue border, leaving "drop on the queue" feeling invisible.
    var onQueueAreaDropHover: ((Bool) -> Void)?
    /// Opens the Settings window on a specific tab (e.g. "upload", "whisper", "analytics").
    /// Triggered by Shift+Cmd-clicking a queue item's action icon.
    var onOpenSettingsTab: ((String) -> Void)?

    // MARK: - Display Rows

    /// Computes a flat list of display rows ordered by queueOrder.
    /// Group children are rendered inline inside the group-header cell when expanded,
    /// so we never emit `.groupItem` rows here.
    func computeDisplayRows() -> [FlatQueueRow] {
        let filesByID = Dictionary(uniqueKeysWithValues: droppedFiles.map { ($0.id, $0) })
        let groupsByID = Dictionary(uniqueKeysWithValues: encodingGroups.map { ($0.id, $0) })

        var rows: [FlatQueueRow] = []
        rows.reserveCapacity(queueOrder.count)
        for id in queueOrder {
            if let item = filesByID[id] {
                rows.append(.single(item))
            } else if let group = groupsByID[id] {
                rows.append(.groupHeader(group))
            }
        }
        return rows
    }

    /// Maps a flat display row index to the corresponding queueOrder index.
    /// Singles and group headers map directly; group items map to their parent group.
    func queueOrderIndex(forDisplayRow row: Int, in displayRows: [FlatQueueRow], queueOrderLookup: [UUID: Int]? = nil) -> Int {
        guard row < displayRows.count else { return queueOrder.count }
        let targetID: UUID
        switch displayRows[row] {
        case .single(let item): targetID = item.id
        case .groupHeader(let group): targetID = group.id
        case .groupItem(_, let groupID): targetID = groupID
        }
        if let lookup = queueOrderLookup {
            return lookup[targetID] ?? queueOrder.count
        }
        return queueOrder.firstIndex(of: targetID) ?? queueOrder.count
    }

    // MARK: - makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let tableView = VideoQueueNSTableView()
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none
        tableView.rowSizeStyle = .custom

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        // Register internal reorder + external Finder file drops. File drops are only
        // accepted when they land ON a group header; drops elsewhere fall through to
        // the outer SwiftUI .onDrop which adds them to the main queue.
        tableView.registerForDraggedTypes([.videoQueueItem, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        // Clear the "hovering over group" highlight when the drag leaves or ends
        // without a drop — `validateDrop` isn't called in that case.
        tableView.onDragExit = { [weak coordinator = context.coordinator] in
            coordinator?.setDragHoverGroup(nil)
            coordinator?.setQueueAreaHover(false)
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        // Let the parent query "is row X visible?" via the handle — used to
        // decide whether the "new group created" toast should offer a scroll
        // button (skipped when the group already fits on screen).
        handle?.isRowVisibleImpl = { [weak coordinator = context.coordinator] id in
            coordinator?.isRowVisible(for: id) ?? false
        }

        // Store initial snapshot and populate cache
        let initialRows = computeDisplayRows()
        context.coordinator.cachedDisplayRows = initialRows
        context.coordinator.rebuildLookupCaches()
        context.coordinator.previousIDs = initialRows.map(\.id)
        context.coordinator.previousCompactMode = isCompactMode

        // Ensure the table loads its initial data — without this, the first
        // updateNSView sees newIDs == oldIDs and only calls updateVisibleCells,
        // which is a no-op on an empty table, leaving the view blank.
        tableView.reloadData()

        return scrollView
    }

    // MARK: - updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        // Always update the parent reference so closures are current
        coordinator.parent = self

        let displayRows = computeDisplayRows()
        coordinator.cachedDisplayRows = displayRows
        coordinator.rebuildLookupCaches()
        let newIDs = displayRows.map(\.id)
        let oldIDs = coordinator.previousIDs

        // Handle compact mode changes - notify table about row height changes.
        // `previousCompactMode` is updated at the end of `updateVisibleCells` so the
        // globalChanged check there sees the difference and reconfigures every visible cell.
        if isCompactMode != coordinator.previousCompactMode,
           tableView.numberOfRows > 0 {
            let allRows = IndexSet(integersIn: 0..<tableView.numberOfRows)
            tableView.noteHeightOfRows(withIndexesChanged: allRows)
        }

        if newIDs == oldIDs {
            coordinator.updateVisibleCells()
        } else if Set(newIDs) == Set(oldIDs) && newIDs.count == oldIDs.count {
            coordinator.applyRowMoves(from: oldIDs, to: newIDs)
            coordinator.updateVisibleCells()
        } else {
            tableView.reloadData()
        }

        coordinator.previousIDs = newIDs

        // Sync selection: SwiftUI -> NSTableView
        syncSelectionToTableView(coordinator: coordinator, tableView: tableView)

        // Handle scroll-to-selection
        if shouldScrollToSelection {
            if let firstSelectedID = selection.first,
               let row = coordinator.displayRowIndex[firstSelectedID] {
                tableView.scrollRowToVisible(row)
            }
            DispatchQueue.main.async {
                self.shouldScrollToSelection = false
            }
        }
    }

    private func syncSelectionToTableView(coordinator: Coordinator, tableView: NSTableView) {
        guard !coordinator.isUpdatingSelection else { return }
        coordinator.isUpdatingSelection = true
        defer { coordinator.isUpdatingSelection = false }

        let desiredRows = IndexSet(selection.compactMap { id in
            coordinator.displayRowIndex[id]
        })

        let currentRows = tableView.selectedRowIndexes
        if desiredRows != currentRows {
            tableView.selectRowIndexes(desiredRows, byExtendingSelection: false)
        }
    }

    // MARK: - makeCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: VideoQueueTableView
        weak var tableView: NSTableView?
        var previousIDs: [UUID] = []
        var previousCompactMode = false
        var isUpdatingSelection = false
        /// Cached display rows to avoid redundant recomputation in delegate callbacks.
        /// Refreshed in updateNSView when SwiftUI pushes new data.
        var cachedDisplayRows: [FlatQueueRow] = []

        // O(1) lookup caches — rebuilt each updateNSView cycle
        var droppedFilesIndex: [UUID: Int] = [:]
        var encodingGroupsIndex: [UUID: Int] = [:]
        var displayRowIndex: [UUID: Int] = [:]
        var queueOrderLookup: [UUID: Int] = [:]
        var itemToGroupID: [UUID: UUID] = [:]

        /// Item IDs with an in-flight background thumbnail decode.
        /// Prevents duplicate enqueues when the same cell scrolls in/out quickly.
        var inFlightThumbnailDecodes: Set<UUID> = []

        /// Memoized fileExists lookups for concat output paths. `buildGroupCellConfiguration`
        /// runs on every SwiftUI update (including per-item progress ticks), so an uncached
        /// check hit the disk many times per second per visible waiting group — the main
        /// scroll-lag culprit. TTL lets externally-deleted files be picked up reasonably soon.
        private var concatExistsCache: [String: (exists: Bool, checkedAt: Date)] = [:]
        private let concatExistsCacheTTL: TimeInterval = 5

        /// Previous item count per group, used to auto-reapply sequential naming
        /// when items are added to or removed from a group.
        var previousGroupItemCount: [UUID: Int] = [:]

        /// Group currently receiving a drag-hover highlight. Updated from validateDrop
        /// (whenever the proposed drop lands `.on` a group header) and cleared on
        /// acceptDrop or when the drag exits the table without dropping.
        var dragHoverGroupID: UUID?
        /// True while an external file drag is over the table but NOT over a group.
        /// Drives the queue-area highlight border via `onQueueAreaDropHover`.
        var isQueueAreaHovered: Bool = false

        /// Previous snapshot for selective cell updates
        var previousDisplayRows: [FlatQueueRow] = []
        var previousSelection: Set<UUID> = []
        var previousPreset: ExportPreset?
        var previousMergeEnabled = false
        var previousMergeAvailable = false
        var previousShowComment = true
        var previousShowDateTag = true
        var previousTranscriptionAvailable = false

        private static let cellID = NSUserInterfaceItemIdentifier("VideoQueueCell")
        private static let appkitCellID = NSUserInterfaceItemIdentifier("VideoFileCellView")
        private static let groupHeaderCellID = NSUserInterfaceItemIdentifier("EncodingGroupHeaderCellView")
        // FFprobe-style names ("hdmv_pgs_subtitle", …) plus Matroska-container codec
        // IDs ("S_HDMV/PGS", "S_VOBSUB"), since SwiftExif's MKV reader surfaces the
        // raw Matroska codecID rather than translating it to FFprobe's vocabulary.
        private static let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "s_hdmv/pgs", "s_vobsub"]

        init(parent: VideoQueueTableView) {
            self.parent = parent
            super.init()
        }

        /// Rebuilds all UUID → index lookup dictionaries from current state.
        func rebuildLookupCaches() {
            droppedFilesIndex.removeAll(keepingCapacity: true)
            for (i, item) in parent.droppedFiles.enumerated() {
                droppedFilesIndex[item.id] = i
            }

            encodingGroupsIndex.removeAll(keepingCapacity: true)
            for (i, group) in parent.encodingGroups.enumerated() {
                encodingGroupsIndex[group.id] = i
            }

            displayRowIndex.removeAll(keepingCapacity: true)
            for (i, row) in cachedDisplayRows.enumerated() {
                displayRowIndex[row.id] = i
            }

            queueOrderLookup.removeAll(keepingCapacity: true)
            for (i, id) in parent.queueOrder.enumerated() {
                queueOrderLookup[id] = i
            }

            itemToGroupID.removeAll(keepingCapacity: true)
            for group in parent.encodingGroups {
                for item in group.items {
                    itemToGroupID[item.id] = group.id
                }
            }

            // Re-apply sequential naming when a group's item count has changed
            // (drag-in, drag-out, programmatic add/remove). Mirrors the old
            // SwiftUI .onChange(of: group.items.count) watcher.
            for (idx, group) in parent.encodingGroups.enumerated() {
                let prev = previousGroupItemCount[group.id]
                let current = group.items.count
                if let prev, prev != current, group.sequentialNamingEnabled {
                    parent.encodingGroups[idx].normalizeSequentialNaming()
                }
                previousGroupItemCount[group.id] = current
            }

            // Drop tracked counts for groups that no longer exist
            if !previousGroupItemCount.isEmpty {
                let validGroupIDs = Set(parent.encodingGroups.map(\.id))
                previousGroupItemCount = previousGroupItemCount.filter { validGroupIDs.contains($0.key) }
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            cachedDisplayRows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return nil }

            switch displayRows[row] {
            case .single(let item), .groupItem(let item, _):
                let cell = tableView.makeView(withIdentifier: Self.appkitCellID, owner: nil) as? VideoFileCellView
                    ?? VideoFileCellView()
                cell.identifier = Self.appkitCellID
                let isGroupItem: Bool
                if case .groupItem = displayRows[row] { isGroupItem = true } else { isGroupItem = false }
                let config = buildCellConfiguration(item: item, isGroupItem: isGroupItem)
                let capturedID = item.id
                cell.configure(with: config) { [weak self] (action: CellAction) in
                    guard let self else { return }
                    self.handleCellAction(action, itemID: capturedID, displayRows: self.cachedDisplayRows, row: row)
                }
                return cell
            case .groupHeader(let group):
                let cell = tableView.makeView(withIdentifier: Self.groupHeaderCellID, owner: nil) as? EncodingGroupHeaderCellView
                    ?? EncodingGroupHeaderCellView()
                cell.identifier = Self.groupHeaderCellID
                let config = buildGroupCellConfiguration(group: group)
                let capturedID = group.id
                cell.configure(with: config) { [weak self] (action: CellAction) in
                    self?.handleGroupAction(action, groupID: capturedID)
                }
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            TransparentRowView()
        }

        // MARK: Row Height (fixed, avoids Auto Layout solving)

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return 200 }
            switch displayRows[row] {
            case .single, .groupItem:
                return parent.isCompactMode ? 120 : 170
            case .groupHeader:
                // Group cards are now single-height summary rows; the detail
                // editor lives in its own window.
                return parent.isCompactMode
                    ? EncodingGroupHeaderCellView.baseCompactRowHeight
                    : EncodingGroupHeaderCellView.baseRowHeight
            }
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            guard let tableView = tableView else { return }
            let displayRows = cachedDisplayRows
            let selectedRows = tableView.selectedRowIndexes
            let newSelection = Set(selectedRows.compactMap { row -> UUID? in
                guard row < displayRows.count else { return nil }
                return displayRows[row].id
            })
            parent.selection = newSelection
        }

        // MARK: Drag-to-Reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            // Encode the row's stable ID (item UUID or group UUID) on the pasteboard so
            // drags can be matched across sources — including mini-rows inside a group
            // card that don't have their own table row.
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(displayRows[row].id.uuidString, forType: .videoQueueItem)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let displayRows = cachedDisplayRows
            // Helper: if the proposed drop lands `.on` a group header, return its ID.
            // Used below to highlight that group as the active drop target.
            let hoverGroupID: UUID? = {
                guard dropOperation == .on, row < displayRows.count,
                      case .groupHeader(let g) = displayRows[row] else { return nil }
                return g.id
            }()

            // External drag (e.g. Finder file drop). The table claims file drags over
            // its bounds, so we have to answer for BOTH cases here — dropping ON a
            // group routes into that group, dropping anywhere else in the table
            // routes to the main queue (preserving the "drop anywhere" UX).
            if !draggingSourceIsInternal(info, tableView: tableView) {
                guard info.draggingPasteboard.types?.contains(.fileURL) == true else {
                    setDragHoverGroup(nil)
                    setQueueAreaHover(false)
                    return []
                }
                if hoverGroupID != nil {
                    setDragHoverGroup(hoverGroupID)
                    setQueueAreaHover(false)
                    return .copy
                }
                setDragHoverGroup(nil)
                setQueueAreaHover(true)
                // Force `.above` as the visual affordance for main-queue drops so
                // AppKit doesn't draw the "drop on row" highlight on single items.
                tableView.setDropRow(row, dropOperation: .above)
                return .copy
            }

            // Dropping ON a group header → move items into that group
            if hoverGroupID != nil {
                setDragHoverGroup(hoverGroupID)
                setQueueAreaHover(false)
                return .move
            }

            setDragHoverGroup(nil)
            setQueueAreaHover(false)

            // Drop ON a non-group row is not accepted
            if dropOperation == .on { return [] }

            // Dropping ABOVE at any position → reorder in queue
            if dropOperation == .above {
                return .move
            }

            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            // Clear any drop-target highlight as soon as we commit to a drop.
            defer {
                setDragHoverGroup(nil)
                setQueueAreaHover(false)
            }

            // External file drop → route URLs to either a group or the main queue
            // depending on where the drop landed.
            if !draggingSourceIsInternal(info, tableView: tableView) {
                let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
                guard !urls.isEmpty else { return false }
                let displayRows = cachedDisplayRows
                if dropOperation == .on,
                   row < displayRows.count,
                   case .groupHeader(let targetGroup) = displayRows[row] {
                    parent.onFileDropToGroup?(targetGroup.id, urls)
                } else {
                    parent.onFileDropToMainQueue?(urls)
                }
                return true
            }

            let displayRows = cachedDisplayRows

            // Collect source IDs from the pasteboard — stable across moves within the drag.
            var sourceIDs: [UUID] = []
            info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                if let pbItem = item.item as? NSPasteboardItem,
                   let str = pbItem.string(forType: .videoQueueItem),
                   let uuid = UUID(uuidString: str) {
                    sourceIDs.append(uuid)
                }
            }
            guard !sourceIDs.isEmpty else { return false }

            // Classify each source ID once so both branches share the same logic.
            enum SourceKind { case single(VideoItem), groupItem(VideoItem, UUID), groupHeader(UUID) }
            let sources: [SourceKind] = sourceIDs.compactMap { id in
                if let idx = droppedFilesIndex[id], idx < parent.droppedFiles.count {
                    return .single(parent.droppedFiles[idx])
                }
                if let groupID = itemToGroupID[id],
                   let gIdx = encodingGroupsIndex[groupID],
                   let item = parent.encodingGroups[gIdx].items.first(where: { $0.id == id }) {
                    return .groupItem(item, groupID)
                }
                if let gIdx = encodingGroupsIndex[id], gIdx < parent.encodingGroups.count {
                    return .groupHeader(id)
                }
                return nil
            }
            guard !sources.isEmpty else { return false }

            // Dropping ON a group header → move items into that group
            if dropOperation == .on, row < displayRows.count,
               case .groupHeader(let targetGroup) = displayRows[row] {
                guard parent.encodingGroups.contains(where: { $0.id == targetGroup.id }) else { return false }

                var itemsToMove: [VideoItem] = []
                for source in sources {
                    switch source {
                    case .single(let item):
                        if let idx = parent.droppedFiles.firstIndex(where: { $0.id == item.id }) {
                            itemsToMove.append(parent.droppedFiles.remove(at: idx))
                        }
                    case .groupItem(let item, let srcGroupID):
                        // Skip drops onto the same group (no-op)
                        guard srcGroupID != targetGroup.id else { continue }
                        if let srcGIdx = parent.encodingGroups.firstIndex(where: { $0.id == srcGroupID }),
                           let iIdx = parent.encodingGroups[srcGIdx].items.firstIndex(where: { $0.id == item.id }) {
                            itemsToMove.append(parent.encodingGroups[srcGIdx].items.remove(at: iIdx))
                        }
                    case .groupHeader:
                        continue
                    }
                }

                if let gIdx2 = parent.encodingGroups.firstIndex(where: { $0.id == targetGroup.id }) {
                    parent.encodingGroups[gIdx2].items.append(contentsOf: itemsToMove)
                }

                parent.selection = Set(itemsToMove.map(\.id))
                parent.onQueueSync?()
                return true
            }

            // Dropping ABOVE → reorder in the unified queue. Items pulled out of a
            // group become ungrouped singles.
            let destQueueIndex = parent.queueOrderIndex(forDisplayRow: row, in: displayRows, queueOrderLookup: queueOrderLookup)

            var movedTopLevelIDs: [UUID] = []
            var itemsToMoveToUngrouped: [VideoItem] = []

            for source in sources {
                switch source {
                case .single(let item):
                    movedTopLevelIDs.append(item.id)
                case .groupHeader(let groupID):
                    movedTopLevelIDs.append(groupID)
                case .groupItem(let item, let srcGroupID):
                    if let gIdx = parent.encodingGroups.firstIndex(where: { $0.id == srcGroupID }),
                       let iIdx = parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == item.id }) {
                        let removed = parent.encodingGroups[gIdx].items.remove(at: iIdx)
                        itemsToMoveToUngrouped.append(removed)
                        movedTopLevelIDs.append(removed.id)
                    }
                }
            }

            if !itemsToMoveToUngrouped.isEmpty {
                parent.droppedFiles.append(contentsOf: itemsToMoveToUngrouped)
            }

            guard !movedTopLevelIDs.isEmpty else { return false }

            parent.onReorder?(movedTopLevelIDs, destQueueIndex)
            parent.selection = Set(movedTopLevelIDs)
            return true
        }

        // MARK: Visibility

        /// Returns true when the row for `id` is FULLY visible in the scroll view.
        /// Used by the "new group created" toast to decide whether offering a
        /// scroll button makes sense — if the group is already on screen, a
        /// scroll button would feel redundant.
        func isRowVisible(for id: UUID) -> Bool {
            guard let tableView,
                  let row = displayRowIndex[id] else { return false }
            let rowRect = tableView.rect(ofRow: row)
            guard !rowRect.isEmpty else { return false }
            return NSContainsRect(tableView.visibleRect, rowRect)
        }

        // MARK: Drag-Hover Highlight

        /// Updates `dragHoverGroupID` and re-renders the two affected group cells so
        /// the border highlight transitions immediately. Called from validateDrop on
        /// every mouse-move, so the guard on equality keeps this cheap.
        func setDragHoverGroup(_ groupID: UUID?) {
            guard dragHoverGroupID != groupID else { return }
            let previous = dragHoverGroupID
            dragHoverGroupID = groupID
            refreshGroupCell(groupID: previous)
            refreshGroupCell(groupID: groupID)
        }

        /// Toggles the queue-area drop highlight and notifies the SwiftUI parent so
        /// it can paint the same blue dashed border the empty-state backstop uses.
        func setQueueAreaHover(_ hovered: Bool) {
            guard isQueueAreaHovered != hovered else { return }
            isQueueAreaHovered = hovered
            parent.onQueueAreaDropHover?(hovered)
        }

        private func refreshGroupCell(groupID: UUID?) {
            guard let groupID,
                  let row = displayRowIndex[groupID],
                  let tableView = tableView,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EncodingGroupHeaderCellView,
                  let gIdx = encodingGroupsIndex[groupID],
                  gIdx < parent.encodingGroups.count else { return }
            let group = parent.encodingGroups[gIdx]
            let config = buildGroupCellConfiguration(group: group)
            let capturedID = group.id
            cell.configure(with: config) { [weak self] (action: CellAction) in
                self?.handleGroupAction(action, groupID: capturedID)
            }
        }

        // MARK: Row Moves

        /// Applies row moves to the NSTableView using moveRow(at:to:) instead
        /// of reloadData(). This physically moves existing cells without
        /// recreating them, avoiding the expensive full-table layout pass.
        func applyRowMoves(from oldIDs: [UUID], to newIDs: [UUID]) {
            guard let tableView = tableView else { return }
            var workingIDs = oldIDs
            var positionOf: [UUID: Int] = Dictionary(minimumCapacity: oldIDs.count)
            for (i, id) in oldIDs.enumerated() { positionOf[id] = i }
            tableView.beginUpdates()
            for newIndex in 0..<newIDs.count {
                let targetID = newIDs[newIndex]
                guard let currentIndex = positionOf[targetID], currentIndex != newIndex else { continue }
                workingIDs.remove(at: currentIndex)
                workingIDs.insert(targetID, at: newIndex)
                let lo = min(currentIndex, newIndex)
                let hi = max(currentIndex, newIndex)
                for i in lo...hi { positionOf[workingIDs[i]] = i }
                tableView.moveRow(at: currentIndex, to: newIndex)
            }
            tableView.endUpdates()
        }

        // MARK: Update Visible Cells

        /// Updates visible cells in-place by setting hostingView.rootView.
        /// This preserves SwiftUI internal state (focus, hover, text editing)
        /// unlike reloadData(forRowIndexes:) which destroys and recreates cells.
        /// Only updates cells whose data or selection actually changed.
        func updateVisibleCells() {
            guard let tableView = tableView else { return }
            let displayRows = cachedDisplayRows

            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }
            let start = visibleRange.location
            let end = min(start + visibleRange.length, displayRows.count)

            let newSelection = parent.selection

            // If global view state changed, update all visible cells
            let globalChanged = parent.preset != previousPreset
                || parent.mergeClipsEnabled != previousMergeEnabled
                || parent.mergeClipsAvailable != previousMergeAvailable
                || parent.showCommentField != previousShowComment
                || parent.showDateTagButton != previousShowDateTag
                || parent.isTranscriptionAvailable != previousTranscriptionAvailable
                || parent.isCompactMode != previousCompactMode

            for row in start..<end {
                // Skip cells where row data and selection are unchanged
                if !globalChanged,
                   row < previousDisplayRows.count,
                   displayRows[row] == previousDisplayRows[row],
                   newSelection.contains(displayRows[row].id) == previousSelection.contains(displayRows[row].id) {
                    continue
                }
                guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                if let appkitCell = cellView as? VideoFileCellView {
                    switch displayRows[row] {
                    case .single(let item), .groupItem(let item, _):
                        let isGroupItem: Bool
                        if case .groupItem = displayRows[row] { isGroupItem = true } else { isGroupItem = false }
                        let config = buildCellConfiguration(item: item, isGroupItem: isGroupItem)
                        let capturedID = item.id
                        appkitCell.configure(with: config) { [weak self] (action: CellAction) in
                            guard let self else { return }
                            self.handleCellAction(action, itemID: capturedID, displayRows: self.cachedDisplayRows, row: row)
                        }
                    default: break
                    }
                } else if let groupCell = cellView as? EncodingGroupHeaderCellView {
                    if case .groupHeader(let group) = displayRows[row] {
                        let config = buildGroupCellConfiguration(group: group)
                        let capturedID = group.id
                        groupCell.configure(with: config) { [weak self] (action: CellAction) in
                            self?.handleGroupAction(action, groupID: capturedID)
                        }
                    }
                }
            }

            previousDisplayRows = displayRows
            previousSelection = newSelection
            previousPreset = parent.preset
            previousMergeEnabled = parent.mergeClipsEnabled
            previousMergeAvailable = parent.mergeClipsAvailable
            previousShowComment = parent.showCommentField
            previousShowDateTag = parent.showDateTagButton
            previousTranscriptionAvailable = parent.isTranscriptionAvailable
            previousCompactMode = parent.isCompactMode
        }

        // MARK: - Thumbnail Resolution

        /// Returns a cached thumbnail if available, otherwise kicks off an async
        /// background decode and returns nil. When the decode completes the
        /// matching visible cell is updated directly via `applyDecodedThumbnail`.
        func resolvedThumbnail(for item: VideoItem) -> NSImage? {
            if let cached = ThumbnailCache.shared[item.id] {
                return cached
            }
            if let data = item.thumbnailData {
                enqueueThumbnailDecode(itemID: item.id, data: data)
            }
            return nil
        }

        /// Dispatches a thumbnail decode to a background queue. Hops back to
        /// MainActor to populate the cache and refresh the live cell.
        private func enqueueThumbnailDecode(itemID: UUID, data: Data) {
            guard !inFlightThumbnailDecodes.contains(itemID) else { return }
            inFlightThumbnailDecodes.insert(itemID)
            ThumbnailDecoder.queue.async { [weak self] in
                let image = ThumbnailDecoder.decodeSync(data: data)
                DispatchQueue.main.async {
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.completeThumbnailDecode(itemID: itemID, image: image)
                    }
                }
            }
        }

        private func completeThumbnailDecode(itemID: UUID, image: NSImage?) {
            inFlightThumbnailDecodes.remove(itemID)
            if let image {
                ThumbnailCache.shared[itemID] = image
            }
            guard let tableView = self.tableView else { return }

            // Case 1: the item has its own row (ungrouped single or flattened group item).
            if let row = displayRowIndex[itemID],
               let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? VideoFileCellView {
                cell.applyDecodedThumbnail(image, forItemID: itemID)
                return
            }

            // Case 2: the item lives inside an expanded group — refresh that group's header cell
            // so the stacked thumbnail preview and the inline mini-row can pick up the new image.
            if let groupID = itemToGroupID[itemID],
               let groupRow = displayRowIndex[groupID],
               let cell = tableView.view(atColumn: 0, row: groupRow, makeIfNecessary: false) as? EncodingGroupHeaderCellView {
                cell.applyDecodedChildThumbnail(image, forItemID: itemID)
            }
        }

        // MARK: - AppKit Cell Configuration Builder

        func buildCellConfiguration(item: VideoItem, isGroupItem: Bool) -> VideoFileCellConfiguration {
            let metadata = item.metadata
            let audioStreams = metadata?.audioStreams ?? []
            let hasBitmapSubs = metadata?.subtitleStreams.contains { Self.bitmapCodecs.contains($0.codec?.lowercased() ?? "") } ?? false
            let hasSurround = audioStreams.contains { ($0.channels ?? 0) > 2 }
            let audioRouting = item.audioRoutingConfig
            let hasCustomRouting = audioRouting?.isCustomized ?? false
            let hasDownmix = audioRouting?.outputTracks.contains { $0.downmixToStereo } ?? false
            let hasOutputSurroundNoDownmix = audioRouting?.hasOutputSurroundWithoutDownmix ?? false
            let trackCount = audioRouting?.outputTracks.count ?? 0

            // Timecode mode string drives the thumbnail badge. We always emit a
            // value (never nil) so the badge stays clickable — users need to be
            // able to reopen the timecode popover after choosing "disabled"
            // inside it (which nils out item.timecodeConfig).
            let timecodeMode: String
            if let tc = item.timecodeConfig {
                switch tc.mode {
                case .manual: timecodeMode = "MAN"
                case .preserveSource:
                    timecodeMode = (metadata?.timecode != nil) ? "SRC" : "No TC"
                }
            } else {
                timecodeMode = "No TC"
            }

            let cropPct: Int
            let hasCrop: Bool
            if let crop = item.cropConfig, crop.isActive {
                hasCrop = true
                cropPct = Int(crop.normalizedRect.width * 100)
            } else {
                hasCrop = false
                cropPct = 0
            }

            // Source video format summary (resolution / frame rate / scan type)
            // for the metadata row. Each field is optional — the cell hides them
            // independently so files with partial probes still render cleanly.
            let videoResolution: String? = {
                guard let v = metadata?.primaryVideoStream,
                      let w = v.width, let h = v.height else { return nil }
                return "\(w)×\(h)"
            }()
            let videoFrameRate: String? = {
                guard let fps = metadata?.primaryVideoStream?.frameRate?.value,
                      fps > 0, fps.isFinite else { return nil }
                let rounded = (fps * 100).rounded() / 100
                if rounded == rounded.rounded() {
                    return "\(Int(rounded)) fps"
                }
                return String(format: "%.2f fps", rounded)
            }()
            let videoIsInterlaced = metadata?.primaryVideoStream?.isInterlaced == true

            return VideoFileCellConfiguration(
                itemID: item.id,
                name: item.name,
                duration: item.duration,
                durationSeconds: item.durationSeconds,
                formattedSize: item.formattedSize,
                videoResolution: videoResolution,
                videoFrameRate: videoFrameRate,
                videoIsInterlaced: videoIsInterlaced,
                status: item.status,
                progress: item.progress,
                eta: item.eta,
                statusMessage: item.statusMessage,
                conversionError: item.conversionError,
                comment: item.comment,
                includeDateTag: item.includeDateTag,
                outputURL: item.outputURL,
                url: item.url,
                thumbnailImage: resolvedThumbnail(for: item),
                hasVideoStream: item.hasVideoStream,
                isSelected: parent.selection.contains(item.id),
                isCompactMode: isGroupItem ? true : parent.isCompactMode,
                showCommentField: isGroupItem ? false : parent.showCommentField,
                showDateTagButton: isGroupItem ? false : parent.showDateTagButton,
                isFocusedComment: parent.focusedCommentID == item.id,
                preset: parent.preset,
                mergeClipsEnabled: isGroupItem ? false : parent.mergeClipsEnabled,
                mergeClipsAvailable: isGroupItem ? false : parent.mergeClipsAvailable,
                outputFileExists: item.outputFileExists,
                outputFileNameOverride: item.outputFileNameOverride,
                isDownloading: item.isDownloading,
                downloadProgress: item.downloadProgress,
                downloadHasProgress: item.downloadHasProgress,
                downloadSpeed: item.downloadSpeed,
                downloadError: item.downloadError,
                fileAlreadyExistsPath: item.fileAlreadyExistsPath,
                sourceURL: item.sourceURL,
                scheduledDownloadTime: item.scheduledDownloadTime,
                autoEncodeAfterDownload: item.autoEncodeAfterDownload,
                isLiveStreamRecording: item.isLiveStreamRecording,
                downloadStopping: item.downloadStopping,
                uploadEnabled: item.uploadEnabled,
                uploadSourceFile: item.uploadSourceFile,
                uploadStatus: item.uploadStatus,
                uploadProgress: item.uploadProgress,
                subtitleEnabled: item.subtitleEnabled,
                subtitleStatus: item.subtitleStatus,
                subtitleProgress: item.subtitleProgress,
                subtitleFilePath: item.subtitleFilePath,
                subtitleMethod: item.subtitleMethod,
                hasBitmapSubtitles: hasBitmapSubs,
                audioStreamCount: audioStreams.count,
                analyticsEnabled: item.analyticsEnabled,
                analyticsStatus: item.analyticsStatus,
                analyticsProgress: item.analyticsProgress,
                hasAnalyticsResults: item.analyticsResults != nil,
                isReadyForAnalytics: item.isReadyForAnalytics,
                canRunAnalyticsWithFilePicker: item.canRunAnalyticsWithFilePicker,
                isMuted: item.isMuted,
                hasCustomAudioRouting: hasCustomRouting,
                hasSurroundAudio: hasSurround,
                hasDownmix: hasDownmix,
                audioTrackCount: trackCount,
                hasOutputSurroundWithoutDownmix: hasOutputSurroundNoDownmix,
                hasTrim: item.trimStart != nil || item.trimEnd != nil,
                trimmedDuration: item.trimmedDuration,
                hasCrop: hasCrop,
                cropPercentage: cropPct,
                hasTimecodeConfig: item.timecodeConfig != nil,
                timecodeMode: timecodeMode,
                loopPlayback: item.loopPlayback,
                waveformVideoEnabled: item.waveformVideoEnabled,
                isImageSequence: item.isImageSequence,
                isGroupChild: isGroupItem,
                isDCPPreset: parent.preset == .dcp,
                dcpMetadataTitle: item.dcpMetadata?.contentTitleText,
                showDCPAudioWarning: parent.preset == .dcp && !(audioRouting?.isCustomized ?? false) && audioStreams.count > 1 && !audioStreams.allSatisfy { ($0.channels ?? 0) == 1 },
                isIMFPreset: parent.preset == .imfJ2K || parent.preset == .imfProRes,
                imfMetadataTitle: item.imfMetadata?.contentTitleText,
                formattedOutputSize: item.formattedOutputSize,
                isTranscriptionAvailable: parent.isTranscriptionAvailable,
                isUploadConfigured: UploadManager.shared.isConfigured
            )
        }

        // MARK: - Group Cell Configuration Builder

        func buildGroupCellConfiguration(group: EncodingGroup) -> EncodingGroupCellConfiguration {
            let concatOutputURL: URL? = {
                guard group.concatEnabled, group.status == .done,
                      let first = group.items.first else { return nil }
                return first.outputURL
            }()

            let (concatExists, existingURL): (Bool, URL?) = {
                guard group.concatEnabled, group.status == .waiting,
                      let first = group.items.first,
                      let output = first.outputURL else { return (false, nil) }
                let exists = cachedConcatFileExists(at: output)
                return (exists, exists ? output : nil)
            }()

            let childSummaries: [EncodingGroupChildSummary] = group.items.map { item in
                EncodingGroupChildSummary(
                    itemID: item.id,
                    name: item.name,
                    status: item.status,
                    progress: item.progress,
                    hasVideoStream: item.hasVideoStream,
                    durationSeconds: item.durationSeconds,
                    isDownloading: item.isDownloading
                )
            }

            let stacked = Array(childSummaries.prefix(3))
            // Kick off thumbnail decodes for stacked previews so the cache populates
            // for children that aren't rendered as their own rows.
            for child in stacked {
                if ThumbnailCache.shared[child.itemID] == nil,
                   let rawData = thumbnailData(forItemID: child.itemID) {
                    enqueueThumbnailDecode(itemID: child.itemID, data: rawData)
                }
            }

            return EncodingGroupCellConfiguration(
                groupID: group.id,
                name: group.name,
                itemCount: group.items.count,
                isSelected: parent.selection.contains(group.id),
                isDropTargetHover: dragHoverGroupID == group.id,
                isCompactMode: parent.isCompactMode,
                globalPreset: parent.preset,
                stackedChildren: stacked,
                groupPreset: group.preset,
                concatEnabled: group.concatEnabled,
                uploadEnabled: group.uploadEnabled,
                transcriptionEnabled: group.transcriptionEnabled,
                analyticsEnabled: group.analyticsEnabled,
                sequentialNamingEnabled: group.sequentialNamingEnabled,
                isUploadConfigured: UploadManager.shared.isConfigured,
                status: group.status,
                progress: group.progress,
                totalDuration: group.formattedTotalDuration,
                totalSize: "",
                concatOutputURL: concatOutputURL,
                concatOutputAlreadyExists: concatExists,
                concatOutputExistingURL: existingURL,
                uploadSummary: buildGroupUploadSummary(items: group.items, concatEnabled: group.concatEnabled)
            )
        }

        private func cachedConcatFileExists(at url: URL) -> Bool {
            let path = url.path
            let now = Date()
            if let entry = concatExistsCache[path],
               now.timeIntervalSince(entry.checkedAt) < concatExistsCacheTTL {
                return entry.exists
            }
            let exists = FileManager.default.fileExists(atPath: path)
            concatExistsCache[path] = (exists, now)
            return exists
        }

        /// Looks up the raw thumbnail data for an item in either `droppedFiles` or any encoding group.
        private func thumbnailData(forItemID itemID: UUID) -> Data? {
            if let idx = droppedFilesIndex[itemID], idx < parent.droppedFiles.count {
                return parent.droppedFiles[idx].thumbnailData
            }
            if let groupID = itemToGroupID[itemID],
               let gIdx = encodingGroupsIndex[groupID], gIdx < parent.encodingGroups.count {
                return parent.encodingGroups[gIdx].items.first(where: { $0.id == itemID })?.thumbnailData
            }
            return nil
        }

        private func buildGroupUploadSummary(items: [VideoItem], concatEnabled: Bool) -> EncodingGroupCellConfiguration.UploadSummaryState {
            let enabledItems = items.filter { $0.uploadEnabled }
            guard !enabledItems.isEmpty else { return .hidden }

            // Merged groups produce a single output file, and ConversionManager triggers
            // exactly one upload (anchored on the first uploadEnabled item — see
            // ConversionManager.completeMerge). The other source items keep status .pending
            // forever, so counting them would surface "1/7" instead of "1/1".
            let uploadItems = concatEnabled ? Array(enabledItems.prefix(1)) : enabledItems

            let uploaded = uploadItems.filter { $0.uploadStatus.isComplete }.count
            let failed = uploadItems.filter { $0.uploadStatus.hasFailed }.count
            let uploading = uploadItems.filter { $0.uploadStatus == .uploading }
            let pending = uploadItems.filter { $0.uploadStatus == .pending }.count
            let total = uploadItems.count

            if uploaded == total {
                return .uploaded(count: uploaded, total: total)
            }
            if failed > 0 && uploading.isEmpty && pending == 0 {
                return .failed(count: failed, total: total)
            }
            if let current = uploading.first {
                let completed = Double(uploaded)
                let overall = (completed + current.uploadProgress) / Double(total)
                return .uploading(completed: uploaded, total: total, progress: overall, speed: current.uploadSpeed)
            }
            if pending > 0 {
                return .pending(uploaded: uploaded, total: total)
            }
            return .hidden
        }

        // MARK: - Group Action Handler

        func handleGroupAction(_ action: CellAction, groupID: UUID) {
            guard let idx = encodingGroupsIndex[groupID],
                  idx < parent.encodingGroups.count,
                  parent.encodingGroups[idx].id == groupID else { return }

            switch action {
            case .groupNameChanged(let name):
                parent.encodingGroups[idx].name = name
                if parent.encodingGroups[idx].sequentialNamingEnabled {
                    parent.encodingGroups[idx].normalizeSequentialNaming()
                }
            case .toggleConcat:
                parent.encodingGroups[idx].concatEnabled.toggle()
                // Merge and sequential naming are mutually exclusive — turning
                // merge on must clear sequential naming (and its filename overrides).
                if parent.encodingGroups[idx].concatEnabled,
                   parent.encodingGroups[idx].sequentialNamingEnabled {
                    parent.encodingGroups[idx].sequentialNamingEnabled = false
                    parent.encodingGroups[idx].normalizeSequentialNaming()
                }
            case .toggleGroupUpload(let optionPressed):
                if optionPressed {
                    let failedItemIDs = parent.encodingGroups[idx].items
                        .filter { $0.uploadStatus.hasFailed }
                        .map { $0.id }
                    for failedID in failedItemIDs {
                        Task { await UploadManager.shared.retryUpload(itemID: failedID) }
                    }
                } else {
                    parent.encodingGroups[idx].uploadEnabled.toggle()
                }
            case .toggleGroupTranscription:
                parent.encodingGroups[idx].transcriptionEnabled.toggle()
            case .toggleGroupAnalytics:
                parent.encodingGroups[idx].analyticsEnabled.toggle()
            case .toggleSequentialNaming:
                parent.encodingGroups[idx].sequentialNamingEnabled.toggle()
                // Mutual exclusion with merge — see .toggleConcat above.
                if parent.encodingGroups[idx].sequentialNamingEnabled,
                   parent.encodingGroups[idx].concatEnabled {
                    parent.encodingGroups[idx].concatEnabled = false
                }
                parent.encodingGroups[idx].normalizeSequentialNaming()
            case .setGroupPreset(let preset):
                parent.encodingGroups[idx].preset = preset
            case .deleteGroup:
                parent.onDeleteGroup?(groupID)
            case .addFilesToGroup:
                parent.onAddFilesToGroup?(groupID)
            case .resetGroup:
                parent.onResetGroup?(groupID)
            case .cancelGroupUpload:
                parent.onCancelGroupUpload?(groupID)
            case .cycleGroupSort:
                parent.onCycleGroupSort?(groupID)
            case .openGroupEditor:
                parent.onOpenGroupEditor?(groupID)
            case .encodeNow(let optionPressed):
                if optionPressed {
                    let callback = parent.encodeOnlyGroup
                    Task { @MainActor in
                        await callback?(groupID)
                    }
                }
            default:
                break
            }
        }

        // MARK: - Cell Action Handler

        /// Finds a VideoItem by ID, searching both ungrouped droppedFiles and encoding groups.
        private func findItem(by itemID: UUID) -> VideoItem? {
            // Fast path: use O(1) caches
            if let idx = droppedFilesIndex[itemID], idx < parent.droppedFiles.count,
               parent.droppedFiles[idx].id == itemID {
                return parent.droppedFiles[idx]
            }
            if let gID = itemToGroupID[itemID],
               let gIdx = encodingGroupsIndex[gID], gIdx < parent.encodingGroups.count {
                return parent.encodingGroups[gIdx].items.first(where: { $0.id == itemID })
            }
            return nil
        }

        /// Finds the group ID that contains the given item, if any.
        private func groupID(for itemID: UUID) -> UUID? {
            return itemToGroupID[itemID]
        }

        func handleCellAction(_ action: CellAction, itemID: UUID, displayRows: [FlatQueueRow], row: Int) {
            switch action {
            case .delete:
                Task { @MainActor in
                    await ConversionManager.shared.cancelSubtitleEmbedding(
                        itemID: itemID,
                        operationID: nil
                    )
                    if let idx = parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        parent.onDelete(IndexSet(integer: idx))
                    } else if let gIdx = parent.encodingGroups.firstIndex(where: {
                        $0.items.contains(where: { $0.id == itemID })
                    }), let iIdx = parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                        parent.encodingGroups[gIdx].items.remove(at: iIdx)
                    }
                }
            case .reset(let optionKeyPressed):
                Task { @MainActor in
                    await ConversionManager.shared.cancelSubtitleEmbedding(
                        itemID: itemID,
                        operationID: nil
                    )
                    if let idx = parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        parent.onReset(idx, optionKeyPressed)
                    }
                }
            case .cancel:
                Task { await ConversionManager.shared.cancelItem(with: itemID) }
            case .cancelDownload:
                DownloadManager.shared.cancelDownload(itemID: itemID)
            case .stopLiveRecording:
                DownloadManager.shared.stopLiveDownload(itemID: itemID)
            case .retryDownload:
                Task { await DownloadManager.shared.retryDownload(itemID: itemID) }
            case .forceRedownload:
                Task { await DownloadManager.shared.forceRedownload(itemID: itemID) }
            case .cancelScheduledDownload:
                ScheduledDownloadService.shared.cancelScheduledItem(itemID: itemID)
                if let idx = droppedFilesIndex[itemID] {
                    parent.onDelete(IndexSet(integer: idx))
                }
            case .cancelSubtitleGeneration:
                if let target = QueueSubtitleCancellationState.takeTarget(
                    itemID: itemID,
                    droppedFiles: &parent.droppedFiles,
                    encodingGroups: &parent.encodingGroups
                ) {
                    Task {
                        await ConversionManager.shared.cancelSubtitleEmbedding(
                            itemID: itemID,
                            operationID: target.operationID
                        )
                    }
                    switch target.method {
                    case .ocr:
                        if let operationID = target.operationID {
                            Task {
                                await TesseractService.shared.cancelGeneration(
                                    operationID: operationID
                                )
                            }
                        }
                    case .whisper:
                        if let operationID = target.operationID {
                            Task {
                                await WhisperService.shared.cancelGeneration(
                                    operationID: operationID
                                )
                            }
                        }
                    case .parakeet:
                        if let operationID = target.operationID {
                            Task {
                                await ParakeetService.shared.cancelGeneration(
                                    operationID: operationID
                                )
                            }
                        }
                    }
                }
            case .cancelAnalytics:
                Task { await AnalyticsService.shared.cancelAnalysis() }
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].analyticsStatus = .notQueued
                    parent.droppedFiles[idx].analyticsProgress = 0
                }
            case .encodeNow(let optionPressed):
                if optionPressed {
                    // Option+click: encode this single item immediately
                    let callback = parent.encodeOnly
                    Task { @MainActor in
                        await callback?(itemID)
                    }
                }
            case .toggleUpload(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        parent.droppedFiles[idx].uploadSourceFile.toggle()
                        if parent.droppedFiles[idx].uploadSourceFile {
                            parent.droppedFiles[idx].uploadEnabled = true
                            Task { UploadManager.shared.startUpload(itemID: itemID) }
                        }
                    } else {
                        parent.droppedFiles[idx].uploadEnabled.toggle()
                        if !parent.droppedFiles[idx].uploadEnabled {
                            parent.droppedFiles[idx].uploadSourceFile = false
                        }
                    }
                }
            case .toggleTranscription(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        let method: SubtitleConversionMethod = UserDefaults.standard.string(forKey: AppConstants.defaultTranscriptionEngineKey) == "parakeet" ? .parakeet : .whisper
                        Task { @MainActor in
                            await parent.transcribeOnly?(itemID, method)
                        }
                    } else {
                        parent.droppedFiles[idx].subtitleEnabled.toggle()
                        if parent.droppedFiles[idx].subtitleEnabled {
                            let method: SubtitleConversionMethod = UserDefaults.standard.string(forKey: AppConstants.defaultTranscriptionEngineKey) == "parakeet" ? .parakeet : .whisper
                            parent.droppedFiles[idx].subtitleMethod = method
                        }
                    }
                }
            case .toggleOCR(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        Task { @MainActor in
                            await parent.transcribeOnly?(itemID, .ocr)
                        }
                    } else if parent.droppedFiles[idx].subtitleEnabled && parent.droppedFiles[idx].subtitleMethod == .ocr {
                        parent.droppedFiles[idx].subtitleEnabled = false
                    } else {
                        parent.droppedFiles[idx].subtitleMethod = .ocr
                        parent.droppedFiles[idx].subtitleEnabled = true
                    }
                }
            case .toggleAnalytics(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if parent.droppedFiles[idx].analyticsResults != nil {
                        if optionPressed && parent.droppedFiles[idx].isReadyForAnalytics {
                            parent.droppedFiles[idx].analyticsResults = nil
                            parent.droppedFiles[idx].analyticsStatus = .notQueued
                            Task { @MainActor in
                                await parent.analyzeOnly?(itemID)
                            }
                        } else {
                            parent.onOpenAnalyticsResults?(itemID)
                        }
                    } else if parent.droppedFiles[idx].isReadyForAnalytics {
                        Task { @MainActor in
                            await parent.analyzeOnly?(itemID)
                        }
                    } else {
                        parent.droppedFiles[idx].analyticsEnabled.toggle()
                    }
                }
            case .toggleAutoEncode:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].autoEncodeAfterDownload.toggle()
                }
            case .toggleWaveform:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].waveformVideoEnabled.toggle()
                }
            case .toggleDateTag:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].includeDateTag.toggle()
                }
            case .toggleMute:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].isMuted.toggle()
                }
            case .commentChanged(let text):
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].comment = text
                }
            case .commentFocusChanged(let focused):
                if focused {
                    if !parent.selection.contains(itemID) {
                        parent.selection = [itemID]
                    }
                    parent.focusedCommentID = itemID
                } else if parent.focusedCommentID == itemID {
                    parent.focusedCommentID = nil
                }
            case .tabCommentField(let forward):
                parent.onTabCommentField?(forward)
            case .beginRename:
                parent.onRenameOutputFileName?(itemID, nil)
            case .commitRename(let name):
                parent.onRenameOutputFileName?(itemID, name)
            case .showPreview:
                parent.onOpenTrim?(itemID)
            case .showMetadata:
                parent.onOpenMetadata?([itemID])
            case .showDCPMetadata:
                parent.onOpenDCPMetadata?(itemID)
            case .showIMFMetadata:
                parent.onOpenIMFMetadata?(itemID)
            case .showAudioRouting:
                parent.onOpenAudioConfig?(itemID)
            case .showTimecode:
                parent.onOpenTimecode?(itemID)
            case .playFullscreen:
                parent.onPlayFullscreen?(itemID)
            case .openSettingsTab(let tab):
                parent.onOpenSettingsTab?(tab)
            case .showInFinder:
                if let item = findItem(by: itemID) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            case .showOutputInFinder:
                if let item = findItem(by: itemID), let url = item.outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .showSubtitleInFinder:
                if let item = findItem(by: itemID), let url = item.subtitleFilePath {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .showDownloadedInFinder:
                if let item = findItem(by: itemID) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            case .attachSubtitleFile:
                promptAttachSubtitleFile(itemID: itemID, source: .ungrouped)
            default:
                // Group actions and sheet presentations not yet handled for AppKit cells
                break
            }
        }

        private enum ItemSource {
            case ungrouped
            case group(UUID)
        }

        // MARK: - Attach Subtitle File

        /// Opens a file picker for SRT/ASS/SSA subtitle files and attaches the selected
        /// file to the given queue item. If the embed-subtitles setting is on and the
        /// item already has an output file, the subtitle is also muxed in.
        private func promptAttachSubtitleFile(itemID: UUID, source: ItemSource) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Select Subtitle File"
            panel.message = "Choose an SRT, ASS, or SSA subtitle file to attach."
            panel.allowedContentTypes = [
                .init(filenameExtension: "srt")!,
                .init(filenameExtension: "ass")!,
                .init(filenameExtension: "ssa")!,
            ]

            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { return }

                // Update the item's subtitleFilePath
                switch source {
                case .ungrouped:
                    if let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.droppedFiles[idx].subtitleFilePath = url
                        self.parent.droppedFiles[idx].subtitleStatus = .completed

                        // If embed is enabled and the item already has an output, mux it in
                        let shouldEmbed = UserDefaults.standard.bool(forKey: AppConstants.embedSubtitlesKey)
                        if shouldEmbed, let outputURL = self.parent.droppedFiles[idx].outputURL,
                           self.parent.droppedFiles[idx].status == .done {
                            Task {
                                await ConversionManager.shared.embedSubtitlesForAttachedFile(
                                    srtURL: url,
                                    videoURL: outputURL,
                                    itemID: itemID
                                )
                            }
                        }
                    }
                case .group(let groupID):
                    if let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                       let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                        self.parent.encodingGroups[gIdx].items[iIdx].subtitleFilePath = url
                        self.parent.encodingGroups[gIdx].items[iIdx].subtitleStatus = .completed

                        let shouldEmbed = UserDefaults.standard.bool(forKey: AppConstants.embedSubtitlesKey)
                        if shouldEmbed, let outputURL = self.parent.encodingGroups[gIdx].items[iIdx].outputURL,
                           self.parent.encodingGroups[gIdx].items[iIdx].status == .done {
                            Task {
                                await ConversionManager.shared.embedSubtitlesForAttachedFile(
                                    srtURL: url,
                                    videoURL: outputURL,
                                    itemID: itemID
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
