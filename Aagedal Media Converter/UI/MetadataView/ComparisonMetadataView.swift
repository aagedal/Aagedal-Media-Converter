// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Displays metadata comparison for multiple video items in the standalone metadata window.
/// This is a read-only version without a dismiss button (window has its own close button).
struct ComparisonMetadataView: View {
    let items: [VideoItem]

    @State private var c2paByID: [UUID: C2PAMetadata] = [:]
    @State private var c2paCheckedIDs: Set<UUID> = []
    @State private var c2paLoadingIDs: Set<UUID> = []

    @State private var cameraByID: [UUID: CameraMetadata] = [:]
    @State private var cameraCheckedIDs: Set<UUID> = []
    @State private var cameraLoadingIDs: Set<UUID> = []

    /// The exported output file loaded for a single selected source item whose
    /// conversion has finished. Rendered as a second column alongside the source.
    @State private var exportedItem: VideoItem?
    @State private var isLoadingExportedItem: Bool = false

    private let labelColumnWidth: CGFloat = 140
    private let valueColumnWidth: CGFloat = 200
    private let columnSpacing: CGFloat = 16

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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerView

            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 24) {
                        fileNamesRow
                        Divider()
                        c2paSection
                        Divider()
                        cameraSection
                        Divider()
                        generalSection
                        Divider()
                        videoSection
                        Divider()
                        audioSection
                        Divider()
                        subtitleSection
                    }
                    .padding(.trailing, 24)
                }
            }
            .textSelection(.enabled)
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
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
            cameraByID = cameraByID.filter { keepIDs.contains($0.key) }
            cameraCheckedIDs = cameraCheckedIDs.intersection(keepIDs)
            cameraLoadingIDs = cameraLoadingIDs.intersection(keepIDs)
            exportedItem = nil
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.title)
                .fontWeight(.semibold)
            if items.count > 1 {
                Text("\(items.count) files selected")
                    .font(.headline)
                    .foregroundColor(.secondary)
            } else if isLoadingExportedItem {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading exported output…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var headerTitle: String {
        if isSourceOutputComparison { return "Source vs Output" }
        if items.count > 1 { return "Metadata Comparison" }
        return "Metadata"
    }

    private var fileNamesRow: some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 8) {
                    if let role = roleLabel(for: index) {
                        Text(role)
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                    }

                    // Thumbnail
                    if let thumbnailData = item.thumbnailData,
                       let nsImage = NSImage(data: thumbnailData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        // Placeholder for files without thumbnails
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 80)
                            .overlay {
                                Image(systemName: item.hasVideoStream ? "film" : "waveform")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                            }
                    }

                    // Filename
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.subheadline)
                    }
                    .buttonStyle(.link)
                    .help("Show file in Finder")
                }
                .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.bottom, 12)
    }

    private func roleLabel(for index: Int) -> String? {
        guard isSourceOutputComparison else { return nil }
        return index == 0 ? "SOURCE" : "OUTPUT"
    }

    // MARK: - General Section

    private var generalSection: some View {
        sectionView(title: "GENERAL") {
            comparisonRow("Container") { item in
                item.metadata?.containerLongName ?? item.metadata?.formatName
            }
            comparisonRow("Duration") { item in
                item.duration
            }
            comparisonRow("File Size") { item in
                formattedSize(for: item)
            }
            comparisonRow("Title") { item in
                item.metadata?.title
            }
            comparisonRow("Artist") { item in
                item.metadata?.artist
            }
            comparisonRow("Source URL") { item in
                item.metadata?.sourceURL
            }
            comparisonRow("Date Created") { item in
                formattedCreationDate(for: item)
            }
            comparisonRow("Date Modified") { item in
                formattedModificationDate(for: item)
            }
            comparisonRow("Bit Rate") { item in
                formatBitRate(item.metadata?.bitRate)
            }
            comparisonRow("GPS") { item in
                formattedGPS(for: item)
            }
            comparisonRow("GPS Altitude") { item in
                formattedGPSAltitude(for: item)
            }
            // Timecodes: when multiple sources carry distinct values, emit a
            // row per source so the reader can spot disagreements.
            let maxTimecodeSources = displayItems
                .map { $0.metadata?.timecodes.count ?? 0 }
                .max() ?? 0
            if maxTimecodeSources <= 1 {
                comparisonRow("Timecode") { item in
                    item.metadata?.timecodes.first?.value ?? item.metadata?.timecode
                }
            } else {
                let sources = uniqueTimecodeSources()
                ForEach(sources, id: \.self) { source in
                    comparisonRow("Timecode (\(source.label))") { item in
                        item.metadata?.timecodes.first { $0.source == source }?.value
                    }
                }
            }
            comparisonRow("Description") { item in
                item.metadata?.description
            }
            comparisonRow("Comment") { item in
                item.metadataComment
            }
            // Warnings: emit one row per unique warning text; items that don't
            // carry that warning show a dash.
            let allWarnings = uniqueWarnings()
            ForEach(allWarnings.indices, id: \.self) { idx in
                comparisonRow(idx == 0 ? "Warnings" : "") { item in
                    let warning = allWarnings[idx]
                    return item.metadata?.warnings.contains(warning) == true ? warning : nil
                }
            }
        }
    }

    private func uniqueTimecodeSources() -> [TimecodeSource] {
        var seen: Set<TimecodeSource> = []
        var ordered: [TimecodeSource] = []
        for item in displayItems {
            for entry in item.metadata?.timecodes ?? [] {
                if seen.insert(entry.source).inserted {
                    ordered.append(entry.source)
                }
            }
        }
        return ordered
    }

    private func uniqueWarnings() -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for item in displayItems {
            for warning in item.metadata?.warnings ?? [] {
                if seen.insert(warning).inserted {
                    ordered.append(warning)
                }
            }
        }
        return ordered
    }

    // MARK: - C2PA Section

    private var c2paSection: some View {
        sectionView(title: "CONTENT AUTHENTICITY (C2PA)") {
            comparisonRow("Content Credentials") { item in
                c2paStatusValue(for: item)
            }
            if anyItemHasC2PA {
                c2paDisclosureView
                comparisonRow("Signature") { item in
                    guard let c2pa = c2paMetadata(for: item) else { return nil }
                    return c2pa.hasSignature ? "Present" : "Not found"
                }
                comparisonRow("Claim Generator Info Name") { item in
                    c2paMetadata(for: item)?.claimGeneratorInfoName
                }
                comparisonRow("Claim Generator") { item in
                    c2paMetadata(for: item)?.claimGenerator
                }
                comparisonRow("Actions Action") { item in
                    c2paMetadata(for: item)?.actionsAction
                }
                comparisonRow("Actions Digital Source Type") { item in
                    c2paMetadata(for: item)?.actionsDigitalSourceType
                }
                comparisonRow("Manifest Store") { item in
                    c2paMetadata(for: item)?.manifestStore
                }
                comparisonRow("Assertions") { item in
                    guard let assertions = c2paMetadata(for: item)?.assertions else { return nil }
                    return assertions.joined(separator: ", ")
                }
            }
        }
    }

    /// True when any displayed item carries C2PA content credentials.
    private var anyItemHasC2PA: Bool {
        displayItems.contains { c2paMetadata(for: $0)?.hasContentCredentials == true }
    }

    /// Full-width disclosure note + verification links shown only when at least
    /// one displayed item has content credentials.
    private var c2paDisclosureView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presence only. This app does not verify C2PA signatures.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Verification Resources")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            ForEach(verificationLinks, id: \.title) { link in
                Link(link.title, destination: link.url)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }
        }
        .frame(width: totalRowWidth, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var verificationLinks: [(title: String, url: URL)] {
        [
            ("Content Credentials", URL(string: "https://verify.contentauthenticity.org/")!),
            ("Adobe Content Authenticity", URL(string: "https://contentauthenticity.adobe.com/inspect")!),
            ("Sony Self Checker", URL(string: "https://digitalsignatureself-checker.authenticity.sony.net")!)
        ]
    }

    // MARK: - Camera Section

    private var cameraSection: some View {
        sectionView(title: "CAMERA") {
            comparisonRow("Status") { item in
                cameraStatusValue(for: item)
            }
            comparisonRow("Manufacturer") { item in
                cameraMetadata(for: item)?.deviceManufacturer
            }
            comparisonRow("Model") { item in
                cameraMetadata(for: item)?.deviceModelName
            }
            comparisonRow("Serial Number") { item in
                cameraMetadata(for: item)?.deviceSerialNumber
            }
            comparisonRow("Lens") { item in
                cameraMetadata(for: item)?.lensModelName
            }
            comparisonRow("Time Zone") { item in
                cameraMetadata(for: item)?.timeZone
            }
            comparisonRow("Gamma/Color Profile") { item in
                cameraMetadata(for: item)?.captureGammaEquation
            }
            comparisonRow("Recording Mode") { item in
                cameraMetadata(for: item)?.recordingModeType
            }
            comparisonRow("Capture FPS") { item in
                cameraMetadata(for: item)?.captureFps
            }
            comparisonRow("Clip Creation") { item in
                guard let date = cameraMetadata(for: item)?.creationDate else { return nil }
                return Self.dateFormatter.string(from: date)
            }
            comparisonRow("User Metadata") { item in
                guard let entries = cameraMetadata(for: item)?.userDescriptiveMetadata,
                      !entries.isEmpty else { return nil }
                return entries.map { "\($0.name): \($0.content)" }.joined(separator: "\n")
            }
        }
    }

    // MARK: - Video Section

    private var videoSection: some View {
        sectionView(title: "VIDEO") {
            // Find max number of video streams across all items
            let maxStreams = displayItems.compactMap { $0.metadata?.videoStreams.count }.max() ?? 0

            if maxStreams == 0 {
                comparisonRow("") { _ in "No video stream detected." }
            } else {
                ForEach(0..<maxStreams, id: \.self) { streamIndex in
                    if maxStreams > 1 {
                        videoStreamHeader(streamIndex + 1)
                    }

                    videoStreamRows(streamIndex: streamIndex)
                }
            }
        }
    }

    private func videoStreamHeader(_ streamNumber: Int) -> some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(displayItems, id: \.id) { item in
                let hasStream = (item.metadata?.videoStreams.count ?? 0) >= streamNumber
                Text(hasStream ? "Stream \(streamNumber)" : "—")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.top, streamNumber > 1 ? 12 : 0)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func videoStreamRows(streamIndex: Int) -> some View {
        comparisonRow("Codec") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            let stream = streams[streamIndex]
            return stream.codecLongName ?? stream.codec
        }
        comparisonRow("Profile") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].profile
        }
        comparisonRow("Track Title") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].title
        }
        comparisonRow("Resolution") { item in
            if streamIndex == 0 {
                return item.videoResolutionDescription
            }
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count,
                  let width = streams[streamIndex].width,
                  let height = streams[streamIndex].height else { return nil }
            return "\(width) × \(height)"
        }
        comparisonRow("Display Aspect") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].displayAspectRatio?.stringValue
        }
        comparisonRow("Pixel Aspect") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].pixelAspectRatio?.stringValue
        }
        comparisonRow("Frame Rate") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return formattedFrameRate(streams[streamIndex].frameRate)
        }
        if streamIndex == 0 {
            comparisonRow("Frame Count") { item in
                item.metadata?.frameCount.map(String.init)
            }
        }
        comparisonRow("Bit Depth") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].bitDepth.map { "\($0)-bit" }
        }
        comparisonRow("Bit Rate") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return formatBitRate(streams[streamIndex].bitRate)
        }
        comparisonRow("Chroma Subsampling") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].chromaSubsampling
        }
        comparisonRow("Chroma Resolution") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].chromaResolutionDescription
        }
        comparisonRow("Pixel Format") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].pixelFormat
        }
        comparisonRow("Alpha Channel") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].hasAlpha ? "Yes" : "No"
        }
        comparisonRow("Color Primaries") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].colorPrimaries
        }
        comparisonRow("Color Transfer") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].colorTransfer
        }
        comparisonRow("Color Space") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].colorSpace
        }
        comparisonRow("Color Range") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].colorRange
        }
        comparisonRow("Chroma Location") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].chromaLocation
        }
        comparisonRow("Scan Type") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return formattedScanType(streams[streamIndex])
        }
        comparisonRow("Field Order") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return formattedFieldOrder(streams[streamIndex])
        }
        comparisonRow("Default") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].isDefault ? "Yes" : nil
        }
        comparisonRow("Forced") { item in
            guard let streams = item.metadata?.videoStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].isForced ? "Yes" : nil
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        sectionView(title: "AUDIO") {
            // Find max number of audio streams across all items
            let maxStreams = displayItems.compactMap { $0.metadata?.audioStreams.count }.max() ?? 0

            if maxStreams == 0 {
                comparisonRow("") { _ in "No audio stream detected." }
            } else {
                ForEach(0..<maxStreams, id: \.self) { streamIndex in
                    if maxStreams > 1 {
                        streamHeader(streamIndex + 1)
                    }

                    audioStreamRows(streamIndex: streamIndex)
                }
            }
        }
    }

    private func streamHeader(_ streamNumber: Int) -> some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(displayItems, id: \.id) { item in
                let hasStream = (item.metadata?.audioStreams.count ?? 0) >= streamNumber
                Text(hasStream ? "Stream \(streamNumber)" : "—")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.top, streamNumber > 1 ? 12 : 0)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func audioStreamRows(streamIndex: Int) -> some View {
        comparisonRow("Codec") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            let stream = streams[streamIndex]
            return stream.codecLongName ?? stream.codec
        }
        comparisonRow("Language") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].languageCode?.uppercased()
        }
        comparisonRow("Profile") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].profile
        }
        comparisonRow("Sample Rate") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return formatSampleRate(streams[streamIndex].sampleRate)
        }
        comparisonRow("Channels") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].channels.map(String.init)
        }
        comparisonRow("Channel Layout") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].channelLayout
        }
        comparisonRow("Bit Depth") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].bitDepth.map { "\($0)-bit" }
        }
        comparisonRow("Bit Rate") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return formatBitRate(streams[streamIndex].bitRate)
        }
    }

    // MARK: - Subtitle Section

    private var subtitleSection: some View {
        sectionView(title: "SUBTITLE") {
            let maxStreams = displayItems.compactMap { $0.metadata?.subtitleStreams.count }.max() ?? 0

            if maxStreams == 0 {
                comparisonRow("") { _ in "No subtitle stream detected." }
            } else {
                ForEach(0..<maxStreams, id: \.self) { streamIndex in
                    if maxStreams > 1 {
                        subtitleStreamHeader(streamIndex + 1)
                    }

                    subtitleStreamRows(streamIndex: streamIndex)
                }
            }
        }
    }

    private func subtitleStreamHeader(_ streamNumber: Int) -> some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(displayItems, id: \.id) { item in
                let hasStream = (item.metadata?.subtitleStreams.count ?? 0) >= streamNumber
                Text(hasStream ? "Stream \(streamNumber)" : "—")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.top, streamNumber > 1 ? 12 : 0)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func subtitleStreamRows(streamIndex: Int) -> some View {
        comparisonRow("Codec") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            let stream = streams[streamIndex]
            return stream.codecLongName ?? stream.codec
        }
        comparisonRow("Language") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].languageCode?.uppercased()
        }
        comparisonRow("Title") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].title
        }
        comparisonRow("Default") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].isDefault ? "Yes" : nil
        }
        comparisonRow("Forced") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].isForced ? "Yes" : nil
        }
        comparisonRow("Hearing Impaired (SDH)") { item in
            guard let streams = item.metadata?.subtitleStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].isHearingImpaired ? "Yes" : nil
        }
    }

    // MARK: - C2PA Helpers

    private func c2paMetadata(for item: VideoItem) -> C2PAMetadata? {
        item.c2paMetadata ?? c2paByID[item.id]
    }

    private func c2paStatusValue(for item: VideoItem) -> String? {
        if let c2pa = c2paMetadata(for: item) {
            return c2pa.hasContentCredentials ? "Present" : "No"
        }
        if c2paLoadingIDs.contains(item.id) {
            return "Checking..."
        }
        return "Not available"
    }

    // MARK: - Camera Helpers

    private func cameraMetadata(for item: VideoItem) -> CameraMetadata? {
        item.cameraMetadata ?? cameraByID[item.id]
    }

    private func cameraStatusValue(for item: VideoItem) -> String? {
        if let camera = cameraMetadata(for: item), camera.hasAnyData {
            return "Present"
        }
        if cameraLoadingIDs.contains(item.id) {
            return "Checking..."
        }
        if cameraCheckedIDs.contains(item.id) {
            return "Not available"
        }
        return nil
    }

    // MARK: - Loading

    private func loadC2PAIfNeeded() async {
        await loadC2PAMetadata()
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

    // MARK: - Layout Helpers

    @ViewBuilder
    private func sectionView<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Span the full grid width (label + all value columns) so long
            // titles like "CONTENT AUTHENTICITY (C2PA)" don't wrap into the
            // 140pt label column.
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: totalRowWidth, alignment: .leading)
                .padding(.bottom, 6)

            content()
        }
    }

    /// Total width of the aligned grid (label column + all value columns with their spacing).
    private var totalRowWidth: CGFloat {
        let valueCount = max(1, displayItems.count)
        return labelColumnWidth
            + columnSpacing
            + (valueColumnWidth * CGFloat(valueCount))
            + columnSpacing * CGFloat(max(0, valueCount - 1))
    }

    @ViewBuilder
    private func comparisonRow(_ label: String, value: (VideoItem) -> String?) -> some View {
        let values = displayItems.map { value($0) }
        let hasAnyValue = values.contains { $0?.isEmpty == false }

        if hasAnyValue {
            HStack(alignment: .top, spacing: columnSpacing) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: labelColumnWidth, alignment: .leading)

                ForEach(Array(zip(displayItems, values).enumerated()), id: \.element.0.id) { _, itemValuePair in
                    let (_, itemValue) = itemValuePair
                    let displayValue = itemValue ?? "—"

                    Text(displayValue)
                        .textSelection(.enabled)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(itemValue == nil ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: valueColumnWidth, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(highlightBackground(for: itemValue, in: values))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Highlights values that differ from others
    @ViewBuilder
    private func highlightBackground(for value: String?, in allValues: [String?]) -> some View {
        let uniqueValues = Set(allValues.compactMap { $0 })
        if uniqueValues.count > 1, let value, !value.isEmpty {
            // Multiple different values - highlight to show difference
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.1))
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        }
    }

    // MARK: - Formatters

    private func formattedSize(for item: VideoItem) -> String? {
        let bytes = item.metadata?.sizeBytes ?? item.size
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func formattedCreationDate(for item: VideoItem) -> String? {
        if let containerDate = item.metadata?.containerCreationDate {
            return Self.dateFormatter.string(from: containerDate)
        }
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.creationDateKey]),
              let creationDate = resourceValues.creationDate else {
            return nil
        }
        return Self.dateFormatter.string(from: creationDate)
    }

    private func formattedModificationDate(for item: VideoItem) -> String? {
        if let containerDate = item.metadata?.containerModificationDate {
            return Self.dateFormatter.string(from: containerDate)
        }
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = resourceValues.contentModificationDate else {
            return nil
        }
        return Self.dateFormatter.string(from: modificationDate)
    }

    private func formattedGPS(for item: VideoItem) -> String? {
        guard let lat = item.metadata?.gpsLatitude, let lon = item.metadata?.gpsLongitude else { return nil }
        return String(format: "%.6f, %.6f", lat, lon)
    }

    private func formattedGPSAltitude(for item: VideoItem) -> String? {
        guard let alt = item.metadata?.gpsAltitude else { return nil }
        return String(format: "%.1f m", alt)
    }

    private func formatBitRate(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 1_000_000 {
            return String(format: "%.2f Mbps", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1f kbps", Double(value) / 1_000)
        } else {
            return "\(value) bps"
        }
    }

    private func formattedFrameRate(_ frameRate: VideoMetadata.FrameRate?) -> String? {
        guard let frameRate else { return nil }
        if let value = frameRate.value {
            return String(format: "%.3f fps", value)
        }
        return frameRate.stringValue
    }

    private func formatSampleRate(_ sampleRate: Int?) -> String? {
        guard let sampleRate else { return nil }
        return Self.numberFormatter.string(from: NSNumber(value: sampleRate))?.appending(" Hz")
    }

    private func formattedScanType(_ stream: VideoMetadata.VideoStream?) -> String? {
        guard let stream else { return nil }
        guard let isInterlaced = stream.isInterlaced else { return stream.fieldOrder }
        return isInterlaced ? "Interlaced" : "Progressive"
    }

    /// Maps the ffprobe-style `fieldOrder` string ("progressive", "tt", "bb",
    /// "unknown") to a reader-friendly label. Returns nil for progressive
    /// sources so the row hides — the Scan Type row already says "Progressive"
    /// and a duplicate row adds no information.
    private func formattedFieldOrder(_ stream: VideoMetadata.VideoStream) -> String? {
        guard let order = stream.fieldOrder else { return nil }
        switch order {
        case "tt": return "Top Field First (TFF)"
        case "bb": return "Bottom Field First (BFF)"
        case "progressive": return nil
        case "unknown": return nil
        default: return order
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = Locale.current.groupingSeparator
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
