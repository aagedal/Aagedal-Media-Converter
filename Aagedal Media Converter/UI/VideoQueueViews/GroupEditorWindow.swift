// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Group Editor Window Controller
//
// Detail editor for an encoding group, shown in a standalone panel. The main
// queue keeps the group card as a compact summary; actions that mutate the
// group's contents (reorder, remove, extract, rename, add files) live here so
// the main queue stays focused on high-level queue manipulation.
//
// Follows the same singleton / NSHostingView pattern as MetadataWindowController.

@MainActor
final class GroupEditorWindowController: NSObject, NSWindowDelegate {

    static let shared = GroupEditorWindowController()

    private var currentWindow: NSWindow?
    private var hostingView: NSHostingView<GroupEditorWindowContent>?

    private override init() { super.init() }

    /// Opens (or re-focuses) the editor on `groupID`. Bindings are passed by the
    /// caller so the editor mutates the same underlying @State that ContentView
    /// owns — no snapshot syncing required.
    func open(
        groupID: UUID,
        groups: Binding<[EncodingGroup]>,
        droppedFiles: Binding<[VideoItem]>,
        queueOrder: Binding<[UUID]>,
        globalPreset: ExportPreset,
        onAddFiles: @escaping (UUID) -> Void,
        onOpenTrim: @escaping (UUID) -> Void,
        onPlayFullscreen: @escaping (UUID) -> Void,
        onOpenMetadata: @escaping ([UUID]) -> Void
    ) {
        let titleUpdater: (String) -> Void = { [weak self] name in
            self?.applyTitle(groupName: name)
        }
        let content = GroupEditorWindowContent(
            groupID: groupID,
            groups: groups,
            droppedFiles: droppedFiles,
            queueOrder: queueOrder,
            globalPreset: globalPreset,
            onAddFiles: onAddFiles,
            onOpenTrim: onOpenTrim,
            onPlayFullscreen: onPlayFullscreen,
            onOpenMetadata: onOpenMetadata,
            onClose: { [weak self] in self?.close() },
            onTitleChange: titleUpdater
        )

        if let existing = currentWindow {
            hostingView?.rootView = content
            fitWindowToScreen(existing)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Edit Group")
        window.minSize = NSSize(width: 960, height: 700)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Persist window size/position across opens. AppKit stores the frame in
        // UserDefaults under this autosave name automatically.
        window.setFrameAutosaveName("GroupEditorWindow")

        let hosting = NSHostingView(rootView: content)
        // The resizable window owns the layout size. In particular, the preview's
        // intrinsic/ideal size must not expand the window when media loads.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = window.contentView?.bounds ?? .zero
        window.contentView = hosting

        // If no autosaved frame existed, position next to the main window.
        if !window.setFrameUsingName("GroupEditorWindow") {
            positionNextToMainWindow(window)
        }

        // Repair oversized saved frames, including those from a larger display.
        fitWindowToScreen(window)
        currentWindow = window
        hostingView = hosting
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        currentWindow?.close()
        currentWindow = nil
        hostingView = nil
    }

    var isOpen: Bool { currentWindow != nil }

    private func applyTitle(groupName: String) {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentWindow?.title = String(localized: "Edit Group")
        } else {
            currentWindow?.title = String(
                localized: "Edit Group: \(trimmed)",
                comment: "Title of the Group Editor window. Placeholder is the group's name."
            )
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        currentWindow = nil
        hostingView = nil
    }

    private func fitWindowToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.minSize = NSSize(width: min(960, visible.width), height: min(700, visible.height))
        window.setFrame(GroupEditorWindowLayout.fittedFrame(window.frame, within: visible), display: true)
    }

    private func positionNextToMainWindow(_ window: NSWindow) {
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            window.center()
            return
        }
        let mainFrame = main.frame
        let size = window.frame.size
        var origin = NSPoint(x: mainFrame.maxX + 20, y: mainFrame.maxY - size.height)
        if let screen = main.screen {
            let sf = screen.visibleFrame
            if origin.x + size.width > sf.maxX { origin.x = mainFrame.minX - size.width - 20 }
            if origin.x < sf.minX { origin.x = sf.midX - size.width / 2 }
            origin.y = max(sf.minY, min(origin.y, sf.maxY - size.height))
        }
        window.setFrameOrigin(origin)
    }
}

/// Keep both new and restored windows inside the usable screen area, excluding
/// the menu bar and Dock. Preserve a valid user-selected size and position.
enum GroupEditorWindowLayout {
    static func fittedFrame(_ frame: NSRect, within visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }
}

// MARK: - Sort Mode

/// Sort mode for the group editor. Mirrors `QueueSortMode` cases plus a
/// `manual` option (no implicit sort — user reorders by drag).
enum GroupEditorSortMode: String, CaseIterable, Identifiable {
    case manual
    case nameAscending
    case nameDescending
    case dateOldest
    case dateNewest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:           return String(localized: "Manual")
        case .nameAscending:    return String(localized: "File Name (A–Z)")
        case .nameDescending:   return String(localized: "File Name (Z–A)")
        case .dateOldest:       return String(localized: "Date Created (Old → New)")
        case .dateNewest:       return String(localized: "Date Created (New → Old)")
        }
    }

    /// Maps to the existing queue sort mode used elsewhere. Returns nil for
    /// `.manual` since manual order isn't expressible as a comparator.
    var queueSortMode: QueueSortMode? {
        switch self {
        case .manual:           return nil
        case .nameAscending:    return .filenameAscending
        case .nameDescending:   return .filenameDescending
        case .dateOldest:       return .dateOldest
        case .dateNewest:       return .dateNewest
        }
    }

    init(_ queueMode: QueueSortMode?) {
        switch queueMode {
        case .none:                      self = .manual
        case .filenameAscending:         self = .nameAscending
        case .filenameDescending:        self = .nameDescending
        case .dateOldest:                self = .dateOldest
        case .dateNewest:                self = .dateNewest
        }
    }
}

// MARK: - Window Content (root)

struct GroupEditorWindowContent: View {
    let groupID: UUID
    @Binding var groups: [EncodingGroup]
    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    let globalPreset: ExportPreset
    var onAddFiles: (UUID) -> Void
    var onOpenTrim: (UUID) -> Void
    var onPlayFullscreen: (UUID) -> Void
    var onOpenMetadata: ([UUID]) -> Void
    var onClose: () -> Void
    var onTitleChange: (String) -> Void

    var body: some View {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            GroupEditorView(
                group: $groups[index],
                droppedFiles: $droppedFiles,
                queueOrder: $queueOrder,
                globalPreset: globalPreset,
                onAddFiles: { onAddFiles(groupID) },
                onOpenTrim: onOpenTrim,
                onPlayFullscreen: onPlayFullscreen,
                onOpenMetadata: onOpenMetadata,
                onClose: onClose,
                onTitleChange: onTitleChange
            )
        } else {
            // The group was deleted while the editor was open — dismiss so the
            // user isn't stuck staring at a stale panel.
            Color.clear.onAppear { onClose() }
        }
    }
}

// MARK: - Editor View

struct GroupEditorView: View {
    @Binding var group: EncodingGroup
    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    let globalPreset: ExportPreset
    var onAddFiles: () -> Void
    var onOpenTrim: (UUID) -> Void
    var onPlayFullscreen: (UUID) -> Void
    var onOpenMetadata: ([UUID]) -> Void
    var onClose: () -> Void
    var onTitleChange: (String) -> Void

    @State private var selectedClipIDs: Set<UUID> = []

    private var effectivePreset: ExportPreset { group.preset ?? globalPreset }

    private var sortBinding: Binding<GroupEditorSortMode> {
        Binding(
            get: { GroupEditorSortMode(group.lastSortMode) },
            set: { newMode in applySort(newMode) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .disabled(group.status == .converting)
            Divider()
            if group.concatEnabled {
                StitchingEditorView(group: $group, isStreamCopy: effectivePreset == .streamCopy,
                                    selectedClipIDs: $selectedClipIDs) {
                    itemList
                }
            } else {
                itemList
                    .disabled(group.status == .converting)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { onTitleChange(group.name) }
        .onChange(of: group.name) { _, newValue in
            onTitleChange(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
            TextField("Group name", text: $group.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if group.sequentialNamingEnabled {
                        group.normalizeSequentialNaming()
                    }
                }
            Button {
                onAddFiles()
            } label: {
                Label("Add files", systemImage: "plus")
            }
            .controlSize(.regular)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Add files to group (⇧⌘A)")
        }
        .padding(12)
    }

    private var itemList: some View {
        List(selection: $selectedClipIDs) {
            ForEach(group.items) { item in
                GroupEditorRow(
                    item: item,
                    preset: effectivePreset,
                    groupName: group.name,
                    showGroupOutputName: group.concatEnabled,
                    isFirstItem: group.items.first?.id == item.id,
                    onExtract: { extractItem(id: item.id) },
                    onRemove: { removeItem(id: item.id) },
                    onShowInFinder: { showInFinder(item: item) },
                    onCopyPath: { copyPath(for: item) },
                    onOpenTrim: { onOpenTrim(item.id) },
                    onPlayFullscreen: { onPlayFullscreen(item.id) },
                    onOpenMetadata: { onOpenMetadata([item.id]) }
                )
                .tag(item.id)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .onMove(perform: moveItems)
        }
        .listStyle(.plain)
        .accessibilityIdentifier("group.files")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(summaryText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: sortBinding) {
                ForEach(GroupEditorSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("Sort items in the group")
            .disabled(group.status == .converting)
            Button("Done", action: onClose)
                .accessibilityIdentifier("group.done")
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var summaryText: String {
        let count = group.items.count
        let duration = group.formattedTotalDuration
        let clips = String(
            localized: "\(count) clips",
            comment: "Clip-count summary in the group editor footer. Supports pluralization."
        )
        return duration.isEmpty ? clips : "\(clips) · \(duration)"
    }

    // MARK: Mutations

    private func moveItems(from source: IndexSet, to destination: Int) {
        group.items.move(fromOffsets: source, toOffset: destination)
        // Manual reorder breaks the implicit sort, so reflect that in the
        // group's saved sort mode — otherwise the picker would still claim
        // "Sorted by name" while items are clearly out of order.
        group.lastSortMode = nil
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    /// Pops the item out of the group and back into `droppedFiles` as an ungrouped
    /// single, inserting its ID right after the group so it's easy to find. Mirrors
    /// the logic the old mini-row extract button used.
    private func extractItem(id: UUID) {
        guard let idx = group.items.firstIndex(where: { $0.id == id }) else { return }
        let item = group.items.remove(at: idx)
        droppedFiles.append(item)
        if let groupIdx = queueOrder.firstIndex(of: group.id) {
            queueOrder.insert(item.id, at: groupIdx + 1)
        } else {
            queueOrder.append(item.id)
        }
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    private func removeItem(id: UUID) {
        guard let idx = group.items.firstIndex(where: { $0.id == id }) else { return }
        group.items.remove(at: idx)
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    private func applySort(_ mode: GroupEditorSortMode) {
        group.lastSortMode = mode.queueSortMode
        guard let sortMode = mode.queueSortMode else { return }
        // Stat each file at most once instead of on every comparison.
        let needsDate = (sortMode == .dateOldest || sortMode == .dateNewest)
        var dateMap: [URL: Date] = [:]
        if needsDate {
            for item in group.items where dateMap[item.url] == nil {
                dateMap[item.url] = GroupEditorComparators.creationDate(for: item.url)
            }
        }
        let dateByURL = dateMap
        let provider: ((URL) -> Date)? = needsDate ? { dateByURL[$0] ?? .distantPast } : nil
        group.items.sort(by: GroupEditorComparators.comparator(for: sortMode, dateProvider: provider))
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    private func showInFinder(item: VideoItem) {
        let target: URL = item.outputURL ?? item.url
        // Prefer the actual on-disk file — for unfinished items this falls back
        // to revealing the source so the user always sees something useful.
        let toReveal = (item.status == .done || item.outputFileExists) ? target : item.url
        NSWorkspace.shared.activateFileViewerSelecting([toReveal])
    }

    private func copyPath(for item: VideoItem) {
        let target: URL = (item.status == .done ? item.outputURL : nil) ?? item.url
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(target.path, forType: .string)
    }
}

// MARK: - Comparators

/// Shared sort comparators. Kept in this file so the editor is self-contained;
/// the main-queue equivalent in `VideoFileListView` uses the same logic.
enum GroupEditorComparators {
    /// `dateProvider` lets callers inject a memoized creation-date lookup so a sort
    /// doesn't re-`stat` the same file on every comparison; it defaults to a direct
    /// (uncached) disk read for callers that don't care.
    static func comparator(
        for mode: QueueSortMode,
        dateProvider: ((URL) -> Date)? = nil
    ) -> (VideoItem, VideoItem) -> Bool {
        switch mode {
        case .filenameAscending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .filenameDescending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateOldest:
            let date = dateProvider ?? creationDate
            return { date($0.url) < date($1.url) }
        case .dateNewest:
            let date = dateProvider ?? creationDate
            return { date($0.url) > date($1.url) }
        }
    }

    static func creationDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate ?? Date.distantPast
    }
}

// MARK: - Row

private struct GroupEditorRow: View {
    let item: VideoItem
    let preset: ExportPreset
    let groupName: String
    let showGroupOutputName: Bool
    let isFirstItem: Bool
    let onExtract: () -> Void
    let onRemove: () -> Void
    let onShowInFinder: () -> Void
    let onCopyPath: () -> Void
    let onOpenTrim: () -> Void
    let onPlayFullscreen: () -> Void
    let onOpenMetadata: () -> Void

    @State private var thumb: NSImage?

    /// Items are "outputable" once converted; for concat groups the merged
    /// output lives on the first item, so only that row gets the share icons.
    private var canShareOutput: Bool {
        if showGroupOutputName {
            return isFirstItem && item.status == .done
        }
        return item.status == .done || item.outputFileExists
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.tertiaryLabelColor)
                .font(.system(size: 11))

            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                outputPreview
                metadataRow
            }

            Spacer(minLength: 6)

            shareButtons

            Button(action: onOpenMetadata) {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Show metadata (⌘I)")

            Button(action: onPlayFullscreen) {
                Image(systemName: "play.circle")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Preview fullscreen")

            Button(action: onOpenTrim) {
                Image(systemName: "scissors")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Trim clip")

            Button(action: onExtract) {
                Image(systemName: "folder.badge.minus")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Move out of group (keep in queue)")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.vertical, 4)
        .task(id: item.id) { await loadThumbnail() }
    }

    /// "source.mp4 → output.mov", with the destination styled blue when the
    /// group merges into a single file (the merged output uses the group name,
    /// so per-item destinations don't really apply — show the group name instead
    /// to make the merge intent obvious).
    private var outputPreview: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            if showGroupOutputName {
                Text(groupOutputName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(perItemOutputName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var metadataRow: some View {
        ViewThatFits(in: .horizontal) {
            fullMetadataRow.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                Text(item.duration)
                if item.trimStart != nil || item.trimEnd != nil {
                    Image(systemName: "scissors")
                        .foregroundColor(.accentColor)
                        .accessibilityLabel("Trimmed")
                        .help("Kept: \(item.trimmedDuration.formatted(.number.precision(.fractionLength(2)))) seconds")
                }
                if let res = videoResolution {
                    Text("•")
                    Text(res)
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
    }

    private var fullMetadataRow: some View {
        HStack(spacing: 6) {
            Text(item.duration)
            if item.trimStart != nil || item.trimEnd != nil {
                Label("Trimmed", systemImage: "scissors")
                    .foregroundColor(.accentColor)
                    .help("Kept: \(item.trimmedDuration.formatted(.number.precision(.fractionLength(2)))) seconds")
            }
            if let res = videoResolution {
                Text("•")
                Text(res)
            }
            if let fps = videoFrameRate {
                Text("•")
                Text(fps)
            }
            Text("•")
            Text(item.formattedSize)
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }

    private var perItemOutputName: String {
        if let override = item.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override + "." + preset.outputExtension(for: item.url)
        }
        if let outputURL = item.outputURL {
            return outputURL.lastPathComponent
        }
        let base = (item.name as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(base)
        let suffix = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        return "\(sanitized)\(suffix).\(preset.outputExtension(for: item.url))"
    }

    private var groupOutputName: String {
        let base = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = FileNameProcessor.processFileName(base.isEmpty ? "group" : base)
        let suffix = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        return "\(sanitized)\(suffix).\(preset.outputExtension(for: item.url))"
    }

    private var videoResolution: String? {
        guard let v = item.metadata?.primaryVideoStream,
              let w = v.width, let h = v.height else { return nil }
        return "\(w)×\(h)"
    }

    private var videoFrameRate: String? {
        guard let fps = item.metadata?.primaryVideoStream?.frameRate?.value,
              fps > 0, fps.isFinite else { return nil }
        let rounded = (fps * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) fps"
        }
        return String(format: "%.2f fps", rounded)
    }

    /// Show-in-Finder, copy-path, and drag-to-share — only when the item has a
    /// usable output (or, for non-concat groups, an existing output file). For
    /// concat groups only the first row offers these (since the merged output
    /// is associated with that row).
    @ViewBuilder
    private var shareButtons: some View {
        if canShareOutput {
            Button(action: onShowInFinder) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button(action: onCopyPath) {
                Image(systemName: "document.on.document")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .help("Copy file path")

            DragShareButton(fileURL: shareURL)
                .frame(width: 18, height: 18)
                .help("Drag to share file")
        }
    }

    private var shareURL: URL? {
        if showGroupOutputName, isFirstItem {
            return item.outputURL
        }
        if item.status == .done, let outputURL = item.outputURL {
            return outputURL
        }
        if item.outputFileExists, let outputURL = item.outputURL {
            return outputURL
        }
        return nil
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.12))
                .frame(width: 64, height: 36)
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "film")
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Load from cache first; if missing, decode the raw JPEG bytes off the main
    /// thread so newly-imported items don't stay stuck on the film placeholder.
    private func loadThumbnail() async {
        if let cached = ThumbnailCache.shared[item.id] {
            thumb = cached
            return
        }
        guard let data = item.thumbnailData else { return }
        let itemID = item.id
        let decoded = await Task.detached(priority: .userInitiated) {
            ThumbnailDecoder.decodeSync(data: data)
        }.value
        guard !Task.isCancelled, let decoded else { return }
        ThumbnailCache.shared[itemID] = decoded
        thumb = decoded
    }
}

// MARK: - DragShareButton

/// Drag-to-share icon for a row in the group editor. Uses SwiftUI's `.onDrag`
/// so the drag is registered at the SwiftUI layer — the surrounding `List`
/// with `.onMove` swallows mouseDown before it reaches an embedded NSView,
/// so the queue's `DraggableFileImageView` (which starts its own drag from
/// mouseDown) can't be reused here.
private struct DragShareButton: View {
    let fileURL: URL?

    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.blue)
            .onDrag {
                guard let url = fileURL else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
    }
}

private extension Color {
    static let tertiaryLabelColor = Color(nsColor: .tertiaryLabelColor)
}
