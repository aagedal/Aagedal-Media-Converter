// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Displays metadata for one or more queue items side by side in the standalone metadata window.
/// A single finished item gains a second column for its exported output. Rows come from
/// `MetadataTableBuilder`, so search, the differences filter and copying share one definition.
struct ComparisonMetadataView: View {
    let items: [VideoItem]
    /// Owned by the window so the query survives selection changes (this view is recreated).
    @Binding var searchText: String
    @Binding var differencesOnly: Bool

    @State private var c2paByID: [UUID: C2PAMetadata] = [:]
    @State private var c2paCheckedIDs: Set<UUID> = []
    @State private var c2paLoadingIDs: Set<UUID> = []
    /// Signed thumbnails decoded once per item, so redraws (e.g. typing a search) don't decode again.
    @State private var c2paThumbnailsByID: [UUID: C2PAThumbnailImages] = [:]

    @State private var cameraByID: [UUID: CameraMetadata] = [:]
    @State private var cameraCheckedIDs: Set<UUID> = []
    @State private var cameraLoadingIDs: Set<UUID> = []

    /// The exported output file loaded for a single selected source item whose
    /// conversion has finished. Rendered as a second column alongside the source.
    @State private var exportedItem: VideoItem?
    @State private var isLoadingExportedItem: Bool = false

    @State private var exportErrorMessage: String?
    @FocusState private var isSearchFocused: Bool
    /// Comma-separated section IDs the user collapsed; persisted across launches.
    @AppStorage("metadataWindowCollapsedSections") private var collapsedSectionsRaw = ""

    private let labelColumnWidth: CGFloat = 170
    private let minValueColumnWidth: CGFloat = 220
    private let maxValueColumnWidth: CGFloat = 520
    private let columnSpacing: CGFloat = 16
    private let contentPadding: CGFloat = 20
    private let rowPadding: CGFloat = 10

    /// The items actually rendered in columns — source items plus an optional
    /// exported output file when a single source item has a completed export.
    private var displayItems: [VideoItem] {
        if items.count == 1, let exportedItem {
            return [items[0], exportedItem]
        }
        return items
    }

    /// True when the Source vs Output comparison mode is active.
    private var isSourceOutputComparison: Bool {
        items.count == 1 && exportedItem != nil
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The filter persists in the window but only applies while several columns are shown.
    private var isFilteringDifferences: Bool {
        differencesOnly && displayItems.count > 1
    }

    private var allSections: [MetadataTableSection] {
        MetadataTableBuilder(
            items: displayItems,
            c2pa: c2paMetadata(for:),
            c2paStatus: c2paStatusValue(for:),
            camera: cameraMetadata(for:),
            cameraStatus: cameraStatusValue(for:)
        ).build()
    }

    var body: some View {
        let sections = MetadataTableFilter.apply(
            allSections,
            query: searchText,
            differencesOnly: isFilteringDifferences
        )

        VStack(spacing: 0) {
            headerBar(sections: sections)
            Divider()
            GeometryReader { geometry in
                let valueWidth = valueColumnWidth(forAvailableWidth: geometry.size.width)
                ScrollView(.vertical) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            fileCardsRow(valueWidth: valueWidth)
                            if sections.isEmpty {
                                noResultsView
                                    .frame(width: max(0, geometry.size.width - contentPadding * 2))
                            }
                            ForEach(sections) { section in
                                sectionView(section, valueWidth: valueWidth)
                            }
                        }
                        .padding(contentPadding)
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // ⌘F focuses the search field, matching Finder and Mail.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .id(items.map(\.id)) // Force view recreation when items change
        .task(id: items.map(\.id)) {
            await loadExportedItemIfNeeded()
            await loadC2PAIfNeeded()
        }
        .onChange(of: exportedItem?.id) { _, _ in
            Task { await loadC2PAIfNeeded() }
        }
        .onChange(of: items.map(\.id)) { _, newIDs in
            // Clear C2PA and Camera state for items no longer in the selection.
            // Keep entries for exportedItem (its id isn't in items) — it's cleared
            // separately when the source selection changes.
            let keepIDs = Set(newIDs).union(exportedItem.map { [$0.id] } ?? [])
            c2paByID = c2paByID.filter { keepIDs.contains($0.key) }
            c2paCheckedIDs = c2paCheckedIDs.intersection(keepIDs)
            c2paLoadingIDs = c2paLoadingIDs.intersection(keepIDs)
            c2paThumbnailsByID = c2paThumbnailsByID.filter { keepIDs.contains($0.key) }
            cameraByID = cameraByID.filter { keepIDs.contains($0.key) }
            cameraCheckedIDs = cameraCheckedIDs.intersection(keepIDs)
            cameraLoadingIDs = cameraLoadingIDs.intersection(keepIDs)
            exportedItem = nil
        }
    }

    // MARK: - Header

    private func headerBar(sections: [MetadataTableSection]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                headerSubtitle(sections: sections)
            }

            Spacer(minLength: 12)

            if displayItems.count > 1 {
                Toggle(isOn: $differencesOnly) {
                    Label("Differences", systemImage: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .help("Show only fields whose values differ between the files")
            }

            searchField

            Menu {
                Button("Copy All as Text") { copyAsText(sections: sections) }
                Divider()
                Button("Export JSON…") { export(.json) }
                    .disabled(items.count != 1)
                Button("Export PDF…") { export(.pdf) }
                    .disabled(items.count != 1)
                Divider()
                Button("Expand All Sections") { collapsedSectionsRaw = "" }
                Button("Collapse All Sections") {
                    collapsedSectionsRaw = allSections.map(\.id).joined(separator: ",")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy or export metadata")
        }
        .padding(.horizontal, contentPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func headerSubtitle(sections: [MetadataTableSection]) -> some View {
        if isSearching || isFilteringDifferences {
            let count = sections.reduce(0) { $0 + $1.fieldCount }
            Text(count == 1 ? "1 matching field" : "\(count) matching fields")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if items.count > 1 {
            Text("\(items.count) files selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if isLoadingExportedItem {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading exported output…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerTitle: String {
        if isSourceOutputComparison { return String(localized: "Source vs Output") }
        if items.count > 1 { return String(localized: "Metadata Comparison") }
        return String(localized: "Metadata")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search fields and values", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand { searchText = "" }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSearchFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12))
        )
        .frame(width: 230)
    }

    // MARK: - File Cards

    private func fileCardsRow(valueWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            Color.clear
                .frame(width: labelColumnWidth, height: 1)

            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                fileCard(for: item, index: index)
                    .frame(width: valueWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, rowPadding)
    }

    private func fileCard(for item: VideoItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let role = roleLabel(for: index) {
                Text(role)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            } else if displayItems.count > 1 {
                Text("FILE \(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            thumbnail(for: item)

            Text(item.name)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                if let c2pa = c2paMetadata(for: item), c2pa.hasContentCredentials {
                    badge(String(localized: "Content Credentials"), systemImage: "checkmark.seal.fill", tint: .green)
                    if c2pa.declaresGenerativeAI {
                        badge(String(localized: "Generative AI"), systemImage: "sparkles", tint: .purple)
                    }
                }
                if let range = item.metadata?.primaryVideoStream?.dynamicRangeDescription, range != "SDR" {
                    badge(range, systemImage: "sun.max.fill", tint: .orange)
                }
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.subheadline)
            }
            .buttonStyle(.link)
            .help(item.url.path)
        }
    }

    @ViewBuilder
    private func thumbnail(for item: VideoItem) -> some View {
        // The queue keeps decoded row thumbnails; fall back to decoding for exported files.
        if let nsImage = ThumbnailCache.shared[item.id] ?? item.thumbnailData.flatMap(NSImage.init(data:)) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 140, height: 80)
                .overlay {
                    Image(systemName: item.hasVideoStream ? "film" : "waveform")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func badge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func roleLabel(for index: Int) -> String? {
        guard isSourceOutputComparison else { return nil }
        return index == 0 ? String(localized: "SOURCE") : String(localized: "OUTPUT")
    }

    // MARK: - Sections

    private var collapsedSections: Set<String> {
        Set(collapsedSectionsRaw.split(separator: ",").map(String.init))
    }

    private func isExpanded(_ section: MetadataTableSection) -> Bool {
        // Search results are never hidden behind a collapsed section.
        isSearching || isFilteringDifferences || !collapsedSections.contains(section.id)
    }

    private func toggleSection(_ section: MetadataTableSection) {
        var collapsed = collapsedSections
        if collapsed.remove(section.id) == nil { collapsed.insert(section.id) }
        collapsedSectionsRaw = collapsed.sorted().joined(separator: ",")
    }

    private func sectionView(_ section: MetadataTableSection, valueWidth: CGFloat) -> some View {
        let expanded = isExpanded(section)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggleSection(section) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: section.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(section.title)
                        .font(.headline)
                    if !expanded, section.fieldCount > 0 {
                        Text("\(section.fieldCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: gridWidth(valueWidth: valueWidth), alignment: .leading)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if section.rows.isEmpty, let message = section.emptyMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, rowPadding)
                            .padding(.vertical, 8)
                            .frame(width: gridWidth(valueWidth: valueWidth), alignment: .leading)
                    }
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, striped: index.isMultiple(of: 2), valueWidth: valueWidth)
                    }
                    if section.id == "c2pa", anyItemHasC2PA {
                        c2paDisclosureView
                            .padding(.horizontal, rowPadding)
                            .padding(.vertical, 8)
                            .frame(width: gridWidth(valueWidth: valueWidth), alignment: .leading)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MetadataTableRow, striped: Bool, valueWidth: CGFloat) -> some View {
        let isHeader = row.kind == .streamHeader
        HStack(alignment: .firstTextBaseline, spacing: columnSpacing) {
            Text(highlighted(row.label))
                .font(isHeader ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(isHeader ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                valueText(value, isHeader: isHeader)
                    .frame(width: valueWidth, alignment: .leading)
                    .background(conflictHighlight(for: value, in: row))
            }
        }
        .padding(.horizontal, rowPadding)
        .padding(.top, isHeader ? 10 : 5)
        .padding(.bottom, 5)
        .background(isHeader ? Color.primary.opacity(0.06) : (striped ? Color.primary.opacity(0.025) : Color.clear))
        .contextMenu {
            Button("Copy \"\(row.label.isEmpty ? "Value" : row.label)\"") {
                copyToPasteboard(row.values.map { $0 ?? "—" }.joined(separator: "\t"))
            }
            if row.values.count > 1 {
                ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                    if let value {
                        Button("Copy Value from \(displayItems[safe: index]?.name ?? "File \(index + 1)")") {
                            copyToPasteboard(value)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func valueText(_ value: String?, isHeader: Bool) -> some View {
        if let value {
            Text(highlighted(value))
                .font(isHeader ? .callout.weight(.medium) : .callout.monospacedDigit())
                .foregroundStyle(isHeader ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    /// Tints values that disagree with another file's value.
    @ViewBuilder
    private func conflictHighlight(for value: String?, in row: MetadataTableRow) -> some View {
        if row.kind == .field, row.hasConflictingValues, value != nil {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.12))
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in MetadataTableFilter.matchRanges(in: text, query: searchText) {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = Color.yellow.opacity(0.45)
        }
        return attributed
    }

    private var noResultsView: some View {
        Group {
            if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Differences",
                    systemImage: "equal.circle",
                    description: Text("Every field has the same value in all displayed files.")
                )
            }
        }
        .padding(.top, 24)
    }

    // MARK: - C2PA Disclosure

    /// True when any displayed item carries C2PA content credentials.
    private var anyItemHasC2PA: Bool {
        displayItems.contains { c2paMetadata(for: $0)?.hasContentCredentials == true }
    }

    /// Signed thumbnails, disclosure note and verification links, shown only when at
    /// least one displayed item has content credentials.
    private var c2paDisclosureView: some View {
        VStack(alignment: .leading, spacing: 6) {
            c2paThumbnails

            Text("Signer details are read from the signing certificate. This app does not verify C2PA signatures or check signers against a trust list; use one of the services below for that.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Verification Resources")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            ForEach(verificationLinks, id: \.title) { link in
                Link(link.title, destination: link.url)
                    .font(.subheadline)
            }
        }
    }

    /// The preview images embedded in each file's credentials (what the signer saw).
    @ViewBuilder
    private var c2paThumbnails: some View {
        let thumbnails: [(id: UUID, name: String, claim: NSImage?, ingredient: NSImage?)] = displayItems.compactMap { item in
            guard let images = c2paThumbnailsByID[item.id], images.claim != nil || images.ingredient != nil else { return nil }
            return (item.id, item.name, images.claim, images.ingredient)
        }
        if !thumbnails.isEmpty {
            Text("Signed Thumbnails")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                ForEach(thumbnails, id: \.id) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        if let claim = entry.claim { c2paThumbnail(claim, caption: displayItems.count > 1 ? entry.name : String(localized: "This file")) }
                        if let ingredient = entry.ingredient { c2paThumbnail(ingredient, caption: String(localized: "Ingredient")) }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func c2paThumbnail(_ image: NSImage, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 160, maxHeight: 100, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var verificationLinks: [(title: String, url: URL)] {
        [
            ("Content Credentials", URL(string: "https://verify.contentauthenticity.org/")!),
            ("Adobe Content Authenticity", URL(string: "https://contentauthenticity.adobe.com/inspect")!),
            ("Sony Self Checker", URL(string: "https://digitalsignatureself-checker.authenticity.sony.net")!)
        ]
    }

    // MARK: - Copy & Export

    private func copyAsText(sections: [MetadataTableSection]) {
        copyToPasteboard(MetadataTableTextExporter.text(for: sections, fileNames: displayItems.map(\.name)))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Exports the selected source file, including lazily loaded C2PA and camera metadata.
    private func export(_ format: MetadataExporter.Format) {
        guard items.count == 1, var item = items.first else { return }
        item.c2paMetadata = c2paMetadata(for: item)
        item.cameraMetadata = cameraMetadata(for: item)
        do {
            try MetadataExporter.exportWithSavePanel(item: item, format: format)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Layout

    /// Value columns share the window width, bounded so a single file's values don't
    /// stretch into hard-to-read lines and many files scroll horizontally instead of squeezing.
    private func valueColumnWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, displayItems.count))
        let available = width - contentPadding * 2 - rowPadding * 2 - labelColumnWidth - columnSpacing * count
        return min(maxValueColumnWidth, max(minValueColumnWidth, available / count))
    }

    /// Total width of a grid row (label column + all value columns + row padding).
    private func gridWidth(valueWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, displayItems.count))
        return labelColumnWidth + rowPadding * 2 + (valueWidth + columnSpacing) * count
    }

    // MARK: - C2PA Helpers

    private func c2paMetadata(for item: VideoItem) -> C2PAMetadata? {
        item.c2paMetadata ?? c2paByID[item.id]
    }

    private func c2paStatusValue(for item: VideoItem) -> String? {
        if let c2pa = c2paMetadata(for: item) {
            return c2pa.hasContentCredentials ? String(localized: "Present") : String(localized: "No")
        }
        if c2paLoadingIDs.contains(item.id) {
            return String(localized: "Checking...")
        }
        return String(localized: "Not available")
    }

    // MARK: - Camera Helpers

    private func cameraMetadata(for item: VideoItem) -> CameraMetadata? {
        item.cameraMetadata ?? cameraByID[item.id]
    }

    private func cameraStatusValue(for item: VideoItem) -> String? {
        if let camera = cameraMetadata(for: item), camera.hasAnyData {
            return String(localized: "Present")
        }
        if cameraLoadingIDs.contains(item.id) {
            return String(localized: "Checking...")
        }
        if cameraCheckedIDs.contains(item.id) {
            return String(localized: "Not available")
        }
        return nil
    }

    // MARK: - Loading

    private func loadC2PAIfNeeded() async {
        await loadC2PAMetadata()
        await decodeC2PAThumbnails()
        await loadCameraMetadata()
    }

    /// When a single source item with a finished export is selected, probe the
    /// exported file so it can be shown as a side-by-side comparison column.
    private func loadExportedItemIfNeeded() async {
        guard items.count == 1 else { return }
        let source = items[0]
        guard source.status == .done,
              let outputURL = source.outputURL,
              source.cachedOutputFileExists,
              exportedItem == nil,
              !isLoadingExportedItem
        else { return }

        await MainActor.run { isLoadingExportedItem = true }
        defer { Task { @MainActor in isLoadingExportedItem = false } }

        let loaded = await VideoFileUtils.createVideoItem(from: outputURL)
        await MainActor.run { exportedItem = loaded }
    }

    private func loadC2PAMetadata() async {
        let itemsToLoad = displayItems.filter { item in
            item.c2paMetadata == nil
                && c2paByID[item.id] == nil
                && !c2paCheckedIDs.contains(item.id)
                && !c2paLoadingIDs.contains(item.id)
        }

        guard !itemsToLoad.isEmpty else { return }

        let loadingIDs = Set(itemsToLoad.map(\.id))
        await MainActor.run {
            c2paLoadingIDs.formUnion(loadingIDs)
        }

        await withTaskGroup(of: (UUID, C2PAMetadata?).self) { group in
            for item in itemsToLoad {
                group.addTask {
                    let metadata = await VideoFileUtils.fetchC2PAMetadata(for: item.url)
                    return (item.id, metadata)
                }
            }

            for await (id, metadata) in group {
                await MainActor.run {
                    if let metadata {
                        c2paByID[id] = metadata
                    }
                    c2paCheckedIDs.insert(id)
                    c2paLoadingIDs.remove(id)
                }
            }
        }
    }

    /// Decodes each item's signed thumbnails once, off the main thread.
    private func decodeC2PAThumbnails() async {
        for item in displayItems where c2paThumbnailsByID[item.id] == nil {
            guard let c2pa = c2paMetadata(for: item) else { continue }
            let claimData = c2pa.claimThumbnail
            let ingredientData = c2pa.ingredientThumbnail
            let images = await Task.detached(priority: .userInitiated) {
                C2PAThumbnailImages(
                    claim: claimData.flatMap(ThumbnailDecoder.decodeSync(data:)),
                    ingredient: ingredientData.flatMap(ThumbnailDecoder.decodeSync(data:))
                )
            }.value
            c2paThumbnailsByID[item.id] = images
        }
    }

    private func loadCameraMetadata() async {
        let itemsToLoad = displayItems.filter { item in
            item.cameraMetadata == nil
                && cameraByID[item.id] == nil
                && !cameraCheckedIDs.contains(item.id)
                && !cameraLoadingIDs.contains(item.id)
        }

        guard !itemsToLoad.isEmpty else { return }

        let loadingIDs = Set(itemsToLoad.map(\.id))
        await MainActor.run {
            cameraLoadingIDs.formUnion(loadingIDs)
        }

        await withTaskGroup(of: (UUID, CameraMetadata?).self) { group in
            for item in itemsToLoad {
                group.addTask {
                    let metadata = await VideoFileUtils.fetchCameraMetadata(for: item.url)
                    return (item.id, metadata)
                }
            }

            for await (id, metadata) in group {
                await MainActor.run {
                    if let metadata {
                        cameraByID[id] = metadata
                    }
                    cameraCheckedIDs.insert(id)
                    cameraLoadingIDs.remove(id)
                }
            }
        }
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A file's decoded Content Credentials thumbnails.
private struct C2PAThumbnailImages: @unchecked Sendable {
    let claim: NSImage?
    let ingredient: NSImage?
}
