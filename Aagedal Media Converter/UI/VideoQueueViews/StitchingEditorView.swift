// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Source ranges mapped onto one gapless output sequence.
enum StitchingTimeline {
    static func zoomOffset(time: Double, scale: Double, anchorX: Double,
                           contentWidth: Double, viewportWidth: Double) -> Double {
        min(max(0, contentWidth - viewportWidth), max(0, time * scale + 10 - anchorX))
    }

    /// Destination is a boundary in the original sequence, before removing the selection.
    static func move(_ items: inout [VideoItem], selection: Set<UUID>, to destination: Int) {
        let boundary = min(items.count, max(0, destination))
        let moving = items.filter { selection.contains($0.id) }
        let insertion = items.prefix(boundary).filter { !selection.contains($0.id) }.count
        items.removeAll { selection.contains($0.id) }
        items.insert(contentsOf: moving, at: insertion)
    }

    static func selectionRange(from anchor: UUID, through target: UUID, in ids: [UUID]) -> Set<UUID> {
        guard let first = ids.firstIndex(of: anchor), let last = ids.firstIndex(of: target) else { return [target] }
        return Set(ids[min(first, last)...max(first, last)])
    }

    static func insertionBoundary(at x: Double, widths: [Double]) -> Int {
        var edge = 0.0
        for (index, width) in widths.enumerated() {
            if x < edge + width / 2 { return index }
            edge += width
        }
        return widths.count
    }

    static func duration(_ item: VideoItem) -> Double {
        let value = item.trimmedDuration
        return value.isFinite ? max(0, value) : 0
    }

    static func location(at time: Double, in items: [VideoItem]) -> (id: UUID, sourceTime: Double)? {
        guard time.isFinite else { return nil }
        var remaining = max(0, time)
        let playable = items.filter { duration($0) > 0 }
        for (index, item) in playable.enumerated() {
            let length = duration(item)
            if remaining < length || index == playable.count - 1 {
                return (item.id, item.effectiveTrimStart + min(remaining, length))
            }
            remaining -= length
        }
        return nil
    }

    /// Resolve play through the sequence so empty clips and a clip's out point
    /// advance to the next playable source. Only the sequence end wraps to zero.
    static func playbackLocation(at time: Double, in items: [VideoItem]) -> (id: UUID, sourceTime: Double)? {
        guard time.isFinite else { return nil }
        let total = items.reduce(0) { $0 + duration($1) }
        return location(at: time >= total ? 0 : time, in: items)
    }

    /// A gapless sequence ripples automatically when a retained source range shrinks.
    static func rippleTrim(_ items: inout [VideoItem], at time: Double, start: Bool) -> UUID? {
        guard let location = location(at: time, in: items),
              let index = items.firstIndex(where: { $0.id == location.id }) else { return nil }
        trim(&items[index], start: start, to: location.sourceTime)
        return location.id
    }

    static func resetTrims(_ items: inout [VideoItem], selection: Set<UUID>) {
        for index in items.indices where selection.contains(items[index].id) {
            items[index].trimStart = nil
            items[index].trimEnd = nil
        }
    }

    static func frameRate(for item: VideoItem) -> Double? {
        guard let rate = item.imageSequenceConfig?.frameRate ?? item.metadata?.primaryVideoStream?.frameRate?.value,
              rate.isFinite, rate >= 1, rate <= 1000 else { return nil }
        return rate
    }

    static func timeDisplay(_ seconds: Double, frameRate: Double?, compact: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else { return "—" }
        if let frameRate {
            let timecode = TimecodeFormatter.timecode(from: seconds, frameRate: frameRate)
            return compact && seconds < 3600 ? String(timecode.dropFirst(3)) : timecode
        }
        let whole = Int(seconds)
        return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    static func frameCount(_ seconds: Double, rate: Double) -> Int {
        guard seconds.isFinite, seconds >= 0, rate.isFinite, rate > 0,
              seconds * rate < Double(Int.max) else { return 0 }
        return Int((seconds * rate).rounded())
    }

    static func trim(_ item: inout VideoItem, start: Bool, to value: Double) {
        guard value.isFinite, item.durationSeconds.isFinite, item.durationSeconds > 0 else { return }
        let rate = frameRate(for: item)
        let gap = min(rate.map { 1 / $0 } ?? 0.1, item.durationSeconds)
        let snapped = rate.map { (value * $0).rounded() / $0 } ?? value
        if start {
            let latest = rate.map { floor((item.effectiveTrimEnd - gap) * $0 + 0.000001) / $0 }
                ?? (item.effectiveTrimEnd - gap)
            let value = max(0, min(snapped, latest))
            item.trimStart = value == 0 ? nil : value
        } else {
            let earliest = rate.map { ceil((item.effectiveTrimStart + gap) * $0 - 0.000001) / $0 }
                ?? (item.effectiveTrimStart + gap)
            let value = value >= item.durationSeconds ? item.durationSeconds
                : min(item.durationSeconds, max(snapped, earliest))
            item.trimEnd = value == item.durationSeconds ? nil : value
        }
    }
}

struct StitchingEditorView<FileList: View>: View {
    @Binding var group: EncodingGroup
    let isStreamCopy: Bool
    @State private var editingMarkerID: UUID?
    @State private var markerText = ""
    @State private var showsMarkerEditor = false
    @State private var selectedID: UUID?
    @Binding var selectedClipIDs: Set<UUID>
    @ViewBuilder var fileList: () -> FileList
    @State private var selectionAnchor: UUID?
    @State private var draggedClipIDs: Set<UUID> = []
    @State private var insertionBoundary: Int?
    @GestureState private var isDraggingClips = false
    @State private var clipDragCancelled = false
    @State private var sourceTime: Double = 0
    @State private var seekRequest = StitchingSeek(time: 0)
    @State private var isPlaying = false
    // Display preference only: never stored in the encoding group or audio settings.
    @AppStorage("stitchingWaveformVisualScale") private var waveformVisualScale: Double = 4
    @State private var shuttleRate: Float = 1
    @State private var keyboardZoomSteps = 0
    @State private var pinchStartZoom: Double?
    @State private var zoomAnchorTime: Double = 0
    @State private var zoomAnchorX: Double = 0
    @State private var cursorX: Double?
    @State private var scrollOffset: Double = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrubTask: Task<Void, Never>?
    @State private var pendingScrubTime: Double?
    @State private var zoom: Double = 1
    @State private var fittedDuration: Double?
    @State private var fitRequest = UUID()
    @State private var previewAssets: [UUID: PreviewAssets] = [:]
    @State private var filmstrips: [UUID: [URL]] = [:]

    private var selectedIndex: Int? {
        group.items.firstIndex { $0.id == selectedID } ?? group.items.indices.first
    }
    private var total: Double { group.items.reduce(0) { $0 + StitchingTimeline.duration($1) } }
    private var sequenceFrameRate: Double? {
        guard let first = group.items.first, let rate = StitchingTimeline.frameRate(for: first),
              group.items.allSatisfy({ item in
                  guard let candidate = StitchingTimeline.frameRate(for: item) else { return false }
                  return abs(candidate - rate) < 0.0001
              }) else { return nil }
        return rate
    }
    private var sourceTotal: Double {
        max(1, group.items.reduce(0) { $0 + ($1.durationSeconds.isFinite ? max(0, $1.durationSeconds) : 0) })
    }
    private func offset(_ index: Int) -> Double {
        group.items.prefix(index).reduce(0) { $0 + StitchingTimeline.duration($1) }
    }
    private var sequenceTime: Double {
        guard let index = selectedIndex else { return 0 }
        let item = group.items[index]
        return offset(index) + min(StitchingTimeline.duration(item), max(0, sourceTime - item.effectiveTrimStart))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let index = selectedIndex {
                let item = group.items[index]
                HSplitView {
                    fileList()
                        .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    // Keep the split pane's identity stable while replacing only the source player.
                    ZStack {
                        StitchingSequencePreview(
                            item: itemBinding(item), initialTime: item.id == selectedID ? sourceTime : item.effectiveTrimStart,
                            seekRequest: seekRequest, isPlaying: $isPlaying, shuttleRate: shuttleRate,
                            onTime: { time in if selectedIndex.map({ group.items[$0].id }) == item.id { sourceTime = time } },
                            onTogglePlayback: togglePlayback,
                            onShuttle: shuttle,
                            onFit: fitTimeline,
                            onZoom: { keyboardZoomSteps += $0 },
                            onAddMarker: addMarker,
                            onRippleTrim: rippleTrim,
                            onFinished: { advance(after: item.id) },
                            onAssets: { filmstrips[item.id] = $0 }
                        )
                        .id(item.id)
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomLeading) {
                        Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                            .accessibilityIdentifier("stitching.selectedClip")
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 230, maxHeight: .infinity)

                HStack {
                    Button(action: togglePlayback) {
                        Label(isPlaying ? "Pause" : "Play sequence", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityIdentifier("stitching.play")
                    Text("\(StitchingTimeline.timeDisplay(sequenceTime, frameRate: sequenceFrameRate)) / \(StitchingTimeline.timeDisplay(total, frameRate: sequenceFrameRate))")
                        .monospacedDigit()
                        .accessibilityIdentifier("stitching.timecode")
                        .help(sequenceFrameRate.map { "HH:MM:SS:FF · \($0.formatted()) fps · non-drop-frame" }
                              ?? "HH:MM:SS · mixed or unknown frame rates")
                    Text(isPlaying ? "\(shuttleRate.formatted())×" : "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stitching.rate")
                    Spacer()
                    Button(action: addMarker) {
                        Label("Marker", systemImage: "bookmark.fill")
                    }
                    .help("Add a marker at the playhead (M). Click a timeline marker to edit its note.")
                    .accessibilityIdentifier("stitching.addMarker")
                    Text("Zoom").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...32).frame(width: 110)
                        .help("Zoom the timeline (⌘+ / ⌘−)")
                    Button("Fit", action: fitTimeline)
                        .keyboardShortcut("z", modifiers: [.shift])
                        .help("Fit the timeline (⇧Z)")
                        .accessibilityIdentifier("stitching.fit")
                }
                timeline
                if isStreamCopy {
                    Label {
                        Text("Stream Copy cuts are approximate. Export may include extra video frames and audio, even at keyframes. Preview and timeline duration show the requested selection; exported boundaries and duration may differ.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("stitching.streamCopyBoundaryGuidance")
                }
                HStack(spacing: 12) {
                    Text("J/K/L: reverse • pause • play · M: marker · Q/W: trim start/end")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Pinch to zoom. Drag clips to reorder. Shift-click selects a range; ⌘-click toggles individual clips. Drag an edge to trim, or drag the time ruler to scrub. Repeat J or L to increase playback speed. Q trims the start to the playhead; W trims the end. Later clips close the gap.")
                    Picker("Waveform height", selection: $waveformVisualScale) {
                        ForEach([1.0, 2, 4, 8, 16], id: \.self) { scale in
                            Text("\(Int(scale))×").tag(scale)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("stitching.waveformScale")
                    .help("Enlarge the waveform visually. Playback and export volume are unchanged. Choose 1× to reset.")
                    Spacer()
                    if selectedClipIDs.count > 1 {
                        Text("\(selectedClipIDs.count) clips selected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Reset trim", action: resetSelectedTrims)
                        .accessibilityIdentifier("stitching.resetTrim")
                        .help("Reset the start and end trims of all selected clips.")
                }
            } else {
                ContentUnavailableView("No clips", systemImage: "film", description: Text("Add files to start stitching."))
            }

        }
        .padding(12)
        .disabled(group.status == .converting)
        .task(id: group.items.map(\.id)) {
            // Generate sequentially so a large group does not launch a decoder per clip.
            let items = group.items
            for item in items {
                guard !Task.isCancelled else { return }
                guard previewAssets[item.id] == nil else { continue }
                if let assets = try? await PreviewAssetGenerator.shared.generateAssets(for: item.url) {
                    guard !Task.isCancelled else { return }
                    previewAssets[item.id] = assets
                    filmstrips[item.id] = assets.thumbnails
                }
            }
        }
        .onChange(of: selectedClipIDs) { _, ids in
            guard let item = group.items.first(where: { ids.contains($0.id) }),
                  selectedID.map({ !ids.contains($0) }) ?? true else { return }
            isPlaying = false
            selectionAnchor = item.id
            seek(item.id, to: item.effectiveTrimStart)
        }
        .onChange(of: group.items.map(\.id)) { _, ids in
            isPlaying = false
            selectedClipIDs.formIntersection(ids)
            previewAssets = previewAssets.filter { ids.contains($0.key) }
            filmstrips = filmstrips.filter { ids.contains($0.key) }
            if let selectionAnchor, !ids.contains(selectionAnchor) { self.selectionAnchor = nil }
            cancelClipDrag()
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                sourceTime = group.items.first?.effectiveTrimStart ?? 0
            }
        }
        .onChange(of: group.status) { _, status in
            if status == .converting { isPlaying = false; cancelClipDrag() }
        }
        .onChange(of: isDraggingClips) { _, dragging in
            if !dragging { cancelClipDrag(); clipDragCancelled = false }
        }
        .onExitCommand {
            if isDraggingClips { clipDragCancelled = true; cancelClipDrag() }
        }
        .sheet(isPresented: $showsMarkerEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Marked note").font(.headline)
                TextField("Note", text: $markerText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("stitching.markerText")
                HStack {
                    Button("Delete", role: .destructive) { finishMarkerEdit(delete: true) }
                        .accessibilityIdentifier("stitching.deleteMarker")
                    Spacer()
                    Button("Cancel") { showsMarkerEditor = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { finishMarkerEdit(delete: false) }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("stitching.saveMarker")
                }
            }.padding(20).frame(width: 380)
        }
        .onDisappear {
            isPlaying = false
            scrubTask?.cancel()
            scrubTask = nil
            pendingScrubTime = nil
            cancelClipDrag()
        }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let scale = max(0.01, (geometry.size.width - 20) / (fittedDuration ?? sourceTotal) * zoom)
            let clipWidths = group.items.map { max(1, StitchingTimeline.duration($0) * scale) }
            let width = max(geometry.size.width - 20, clipWidths.reduce(0, +))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        Canvas { context, size in
                            let step = pow(10, floor(log10(max(1, 90 / scale))))
                            let interval = step * (90 / scale / step > 5 ? 10 : 90 / scale / step > 2 ? 5 : 2)
                            for tick in stride(from: 0.0, through: max(total, width / scale), by: interval) {
                                let x = tick * scale
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: 19))
                                path.addLine(to: CGPoint(x: x, y: 27))
                                context.stroke(path, with: .color(.secondary), lineWidth: 1)
                                context.draw(Text(StitchingTimeline.timeDisplay(tick, frameRate: sequenceFrameRate, compact: true)).font(.caption2).foregroundStyle(.secondary),
                                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                            }
                        }
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in scheduleScrub(value.location.x / scale) }
                            .onEnded { value in
                                scrubTask?.cancel()
                                scrubTask = nil
                                pendingScrubTime = nil
                                scrub(value.location.x / scale)
                            })
                        HStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                StitchingTimelineClip(
                                    item: item, selected: selectedClipIDs.contains(item.id), scale: scale,
                                    thumbnailURLs: filmstrips[item.id] ?? [],
                                    assets: previewAssets[item.id],
                                    waveformVisualScale: waveformVisualScale,
                                    visibleRange: max(0, min(clipWidths[index], scrollOffset - 10 - clipWidths.prefix(index).reduce(0, +)))...max(0, min(clipWidths[index], scrollOffset + geometry.size.width - 10 - clipWidths.prefix(index).reduce(0, +))),
                                    onSelect: { selectClip(item.id) },
                                    reorderGesture: clipDrag(item.id, widths: clipWidths),
                                    onTrim: { start, value in setTrim(item.id, start: start, value: value) }
                                )
                                .frame(width: clipWidths[index], height: 164)
                                .opacity(draggedClipIDs.contains(item.id) ? 0.45 : 1)
                                .id(item.id)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 164)
                    }
                    .frame(width: width, alignment: .leading)
                    .coordinateSpace(name: "stitching.clips")
                    .overlay(alignment: .topLeading) {
                        if let boundary = insertionBoundary {
                            let x = clipWidths.prefix(boundary).reduce(0, +)
                            // Both elements must share the timeline's leading origin. An
                            // implicit overlay stack centers the narrow line in the label's width.
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(Color.accentColor)
                                    .frame(width: 4, height: 168)
                                    .overlay(alignment: .top) {
                                        Image(systemName: "arrowtriangle.down.fill")
                                            .font(.system(size: 14)).foregroundStyle(Color.accentColor)
                                            .offset(y: -10)
                                    }
                                    .offset(x: x - 2, y: 26)
                                Text("Move \(draggedClipIDs.count) clips here")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                                    .offset(x: max(0, min(x - 60, width - 150)), y: 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                        }
                    }
                    .allowsHitTesting(group.status != .converting)
                    .id("stitching.timeline.origin")
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(.red).frame(width: 2, height: 192)
                            .offset(x: min(width - 2, sequenceTime * scale))
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            ForEach(item.timelineMarkers.filter {
                                $0.sourceTime >= item.effectiveTrimStart &&
                                $0.sourceTime < item.effectiveTrimStart + StitchingTimeline.duration(item)
                            }) { marker in
                                Button {
                                    isPlaying = false
                                    seek(item.id, to: marker.sourceTime)
                                    editingMarkerID = marker.id
                                    markerText = marker.text
                                    showsMarkerEditor = true
                                } label: {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(.yellow)
                                        .frame(width: 18, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Marked: " + marker.text)
                                .accessibilityLabel("Marked: " + marker.text)
                                .accessibilityIdentifier("stitching.marker")
                                .offset(x: max(0, (offset(index) + marker.sourceTime - item.effectiveTrimStart) * scale - 9), y: 7)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    geometry.contentOffset.x
                } action: { _, value in
                    scrollOffset = max(0, value)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): cursorX = point.x
                    case .ended: cursorX = nil
                    }
                }
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        if pinchStartZoom == nil {
                            pinchStartZoom = zoom
                            // Prefer the pointer; otherwise keep the visible playhead fixed.
                            zoomAnchorX = cursorX ?? min(geometry.size.width, max(0, sequenceTime * scale + 10 - scrollOffset))
                            zoomAnchorTime = max(0, (scrollOffset + zoomAnchorX - 10) / scale)
                        }
                        zoom = min(32, max(1, (pinchStartZoom ?? zoom) * value.magnification))
                        let newScale = max(0.01, (geometry.size.width - 20) / (fittedDuration ?? sourceTotal) * zoom)
                        let newWidth = max(geometry.size.width, total * newScale + 20)
                        scrollPosition.scrollTo(x: StitchingTimeline.zoomOffset(
                            time: zoomAnchorTime, scale: newScale, anchorX: zoomAnchorX,
                            contentWidth: newWidth, viewportWidth: geometry.size.width))
                    }
                    .onEnded { _ in pinchStartZoom = nil })
                .onChange(of: keyboardZoomSteps) { previous, current in
                    let oldScale = max(0.01, (geometry.size.width - 20) / (fittedDuration ?? sourceTotal) * zoom)
                    let anchorX = cursorX ?? min(geometry.size.width, max(0, sequenceTime * oldScale + 10 - scrollOffset))
                    let anchorTime = max(0, (scrollOffset + anchorX - 10) / oldScale)
                    zoom = min(32, max(1, zoom * pow(1.25, Double(current - previous))))
                    let newScale = max(0.01, (geometry.size.width - 20) / (fittedDuration ?? sourceTotal) * zoom)
                    scrollPosition.scrollTo(x: StitchingTimeline.zoomOffset(
                        time: anchorTime, scale: newScale, anchorX: anchorX,
                        contentWidth: max(geometry.size.width, total * newScale + 20),
                        viewportWidth: geometry.size.width))
                }
                .onChange(of: fitRequest) { _, _ in
                    proxy.scrollTo("stitching.timeline.origin", anchor: .leading)
                }
                .onChange(of: selectedID) { _, id in
                    if let id, isPlaying { proxy.scrollTo(id, anchor: .leading) }
                }
            }
        }
        .frame(height: 214)
        .accessibilityIdentifier("group.timeline")
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addMarker() {
        guard group.status != .converting, !showsMarkerEditor,
              let index = selectedIndex else { return }
        let item = group.items[index]
        let duration = StitchingTimeline.duration(item)
        guard duration > 0 else { return }
        let frame = 1 / (StitchingTimeline.frameRate(for: item) ?? 25)
        let time = min(item.effectiveTrimStart + max(0, duration - frame),
                       max(item.effectiveTrimStart, sourceTime))
        // Repeated M on the same frame edits the existing note.
        if let marker = item.timelineMarkers.first(where: { abs($0.sourceTime - time) < frame / 2 }) {
            isPlaying = false
            editingMarkerID = marker.id
            markerText = marker.text
            showsMarkerEditor = true
            return
        }
        let number = group.items.reduce(0) { $0 + $1.timelineMarkers.count } + 1
        group.items[index].timelineMarkers.append(StitchTimelineMarker(sourceTime: time, text: "Note \(number)"))
    }

    private func finishMarkerEdit(delete: Bool) {
        defer { showsMarkerEditor = false }
        guard group.status != .converting, let id = editingMarkerID else { return }
        for index in group.items.indices {
            guard let markerIndex = group.items[index].timelineMarkers.firstIndex(where: { $0.id == id }) else { continue }
            if delete { group.items[index].timelineMarkers.remove(at: markerIndex) }
            else { group.items[index].timelineMarkers[markerIndex].text = markerText }
            break
        }
    }

    private func itemBinding(_ fallback: VideoItem) -> Binding<VideoItem> {
        Binding(get: { group.items.first { $0.id == fallback.id } ?? fallback }, set: { value in
            guard group.status != .converting, let index = group.items.firstIndex(where: { $0.id == fallback.id }) else { return }
            group.items[index] = value
        })
    }
    private func seek(_ id: UUID, to time: Double) {
        selectedID = id
        sourceTime = time
        seekRequest = StitchingSeek(time: time)
    }
    private func scheduleScrub(_ time: Double) {
        isPlaying = false
        pendingScrubTime = time
        guard scrubTask == nil else { return }
        scrubTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let latest = pendingScrubTime else { break }
                pendingScrubTime = nil
                scrub(latest)
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            scrubTask = nil
        }
    }

    private func scrub(_ time: Double) {
        isPlaying = false
        guard let location = StitchingTimeline.location(at: time, in: group.items) else { return }
        seek(location.id, to: location.sourceTime)
    }
    private func togglePlayback() {
        guard group.status != .converting else { return }
        if isPlaying { isPlaying = false; return }
        shuttleRate = 1
        startForwardPlayback()
    }
    private func startForwardPlayback() {
        guard let location = StitchingTimeline.playbackLocation(at: sequenceTime, in: group.items) else { return }
        if selectedIndex.map({ group.items[$0].id }) != location.id || abs(sourceTime - location.sourceTime) > 0.000001 {
            seek(location.id, to: location.sourceTime)
        }
        isPlaying = true
    }
    private func shuttle(_ direction: Int) {
        guard group.status != .converting else { return }
        if direction == 0 { isPlaying = false; return }
        if direction > 0 {
            shuttleRate = isPlaying && shuttleRate > 0 ? min(8, shuttleRate + 0.5) : 1
            startForwardPlayback()
        } else {
            shuttleRate = isPlaying && shuttleRate < 0 ? max(-8, shuttleRate - 1) : -1
            guard sequenceTime > 0 else { isPlaying = false; return }
            isPlaying = true
        }
    }
    private func advance(after id: UUID) {
        guard isPlaying, let index = selectedIndex, group.items[index].id == id else { return }
        if shuttleRate < 0 {
            if let previous = group.items.prefix(index).last(where: { StitchingTimeline.duration($0) > 0 }) {
                seek(previous.id, to: previous.effectiveTrimEnd)
            } else {
                isPlaying = false
                sourceTime = group.items[index].effectiveTrimStart
            }
        } else if let next = group.items.dropFirst(index + 1).first(where: { StitchingTimeline.duration($0) > 0 }) {
            seek(next.id, to: next.effectiveTrimStart)
        } else {
            isPlaying = false
            sourceTime = group.items[index].effectiveTrimEnd
        }
    }
    private func fitTimeline() {
        fittedDuration = max(total, 0.1)
        zoom = 1
        fitRequest = UUID()
    }
    private func rippleTrim(start: Bool) {
        guard group.status != .converting, !showsMarkerEditor else { return }
        let time = sequenceTime
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        guard let id = StitchingTimeline.rippleTrim(&group.items, at: time, start: start),
              let item = group.items.first(where: { $0.id == id }) else { return }
        seek(id, to: start ? item.effectiveTrimStart : item.effectiveTrimEnd)
    }

    private func resetSelectedTrims() {
        guard group.status != .converting, let index = selectedIndex else { return }
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        let id = group.items[index].id
        let selection = selectedClipIDs.isEmpty ? Set([id]) : selectedClipIDs
        StitchingTimeline.resetTrims(&group.items, selection: selection)
        // Keep the current source frame visible, including when it is outside the selection.
        seek(id, to: min(group.items[index].effectiveTrimEnd,
                         max(group.items[index].effectiveTrimStart, sourceTime)))
    }

    private func setTrim(_ id: UUID, start: Bool, value: Double) {
        guard group.status != .converting, let index = group.items.firstIndex(where: { $0.id == id }) else { return }
        isPlaying = false
        StitchingTimeline.trim(&group.items[index], start: start, to: value)
        seek(id, to: start ? group.items[index].effectiveTrimStart : group.items[index].effectiveTrimEnd)
    }
    private func selectClip(_ id: UUID) {
        guard group.status != .converting else { return }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            selectedClipIDs = StitchingTimeline.selectionRange(
                from: selectionAnchor ?? selectedID ?? id, through: id, in: group.items.map(\.id))
        } else if modifiers.contains(.command) {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
            selectionAnchor = id
        } else {
            selectedClipIDs = [id]
            selectionAnchor = id
        }
        isPlaying = false
        if let item = group.items.first(where: { $0.id == id }) { seek(id, to: item.effectiveTrimStart) }
    }

    private func clipDrag(_ id: UUID, widths: [Double]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("stitching.clips"))
            .updating($isDraggingClips) { _, active, _ in active = true }
            .onChanged { value in
                guard group.status != .converting, !clipDragCancelled else { return }
                if draggedClipIDs.isEmpty {
                    if !selectedClipIDs.contains(id) { selectClip(id) }
                    draggedClipIDs = selectedClipIDs
                    isPlaying = false
                }
                insertionBoundary = (0...192).contains(value.location.y)
                    ? StitchingTimeline.insertionBoundary(at: value.location.x, widths: widths) : nil
            }
            .onEnded { value in
                defer { cancelClipDrag() }
                guard group.status != .converting, !clipDragCancelled, !draggedClipIDs.isEmpty,
                      value.location.y >= 0, value.location.y <= 192 else { return }
                let destination = StitchingTimeline.insertionBoundary(at: value.location.x, widths: widths)
                let previous = group.items.map(\.id)
                StitchingTimeline.move(&group.items, selection: draggedClipIDs, to: destination)
                if group.items.map(\.id) != previous {
                    group.lastSortMode = nil
                    if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
                }
            }
    }

    private func cancelClipDrag() {
        draggedClipIDs = []
        insertionBoundary = nil
    }

}

private struct StitchingSeek: Equatable {
    let id = UUID()
    let time: Double
}

/// Render amplitude data at the visible pixel density, without enlarging a bitmap.
private struct StitchingClipWaveform: View {
    let item: VideoItem
    let assets: PreviewAssets?
    let visualScale: Double
    let visibleRange: ClosedRange<Double>
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard let envelope = assets?.waveformEnvelope, size.width > 0 else { return }
            let duration = max(0.001, StitchingTimeline.duration(item))
            let secondsPerPoint = duration / size.width
            let pixel = 1 / max(1, displayScale)
            let level = envelope.level(secondsPerPixel: secondsPerPoint * pixel)
            let gain = visualScale.isFinite ? min(16, max(1, visualScale)) : 4
            let midY = size.height / 2
            let halfHeight = max(0, midY - 2)
            let start = max(0, floor(visibleRange.lowerBound / pixel) * pixel)
            let end = min(size.width, visibleRange.upperBound)
            guard end > start else { return }
            var path = Path()
            for x in stride(from: start, to: end, by: pixel) {
                let time = item.effectiveTrimStart + x * secondsPerPoint
                let peak = envelope.peak(from: time, to: time + pixel * secondsPerPoint, level: level)
                let top = midY - min(1, Double(peak.maximum) * gain) * halfHeight
                let bottom = midY - max(-1, Double(peak.minimum) * gain) * halfHeight
                path.addRect(CGRect(x: x, y: top, width: pixel, height: max(pixel, bottom - top)))
            }
            context.fill(path, with: .color(Color(red: 1, green: 0.18, blue: 0.47)))
        }
        .background(Color.black.opacity(0.8))
        .overlay {
            if assets?.waveformEnvelope == nil {
                Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
                    .help(assets == nil ? "Generating waveform…" : "Waveform unavailable")
            }
        }
        .accessibilityLabel("Audio waveform for \(item.name)")
    }
}

private struct StitchingTimelineClip<ReorderGesture: Gesture>: View {
    let item: VideoItem
    let selected: Bool
    let scale: Double
    let thumbnailURLs: [URL]
    let assets: PreviewAssets?
    let waveformVisualScale: Double
    let visibleRange: ClosedRange<Double>
    let onSelect: () -> Void
    let reorderGesture: ReorderGesture
    let onTrim: (Bool, Double) -> Void
    @State private var images: [NSImage] = []
    @State private var fallbackThumbnail: NSImage?
    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.accentColor.opacity(selected ? 0.4 : 0.2)
                HStack(spacing: 0) {
                    let count = max(1, min(100, Int(ceil(geometry.size.width / 90))))
                    ForEach(0..<count, id: \.self) { index in
                        if let image = image(at: index, count: count) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width / Double(count), height: 68).clipped()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.2))
                                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                        }
                    }
                }
                .frame(height: 68).offset(y: 24)
                Text(item.name).font(.caption).lineLimit(1).padding(.horizontal, 12).padding(.top, 4)
                StitchingClipWaveform(item: item, assets: assets, visualScale: waveformVisualScale,
                                      visibleRange: visibleRange)
                    .frame(height: 48)
                    .offset(y: 92)
                clipReadouts(width: geometry.size.width)
                    .frame(height: 24)
                    .background(Color.black)
                    .offset(y: 140)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(reorderGesture)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { handle(start: true) }
            .overlay(alignment: .trailing) { handle(start: false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction { onSelect() }
        .help("Drag to move. Shift-click to select a range; ⌘-click to toggle selection.")
        .task(id: thumbnailURLs) {
            fallbackThumbnail = ThumbnailCache.shared[item.id] ?? item.thumbnailData.flatMap { NSImage(data: $0) }
            let urls: [URL]
            if thumbnailURLs.isEmpty {
                urls = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: item.url)?.thumbnails ?? []
            } else { urls = thumbnailURLs }
            let decoded = await Task.detached(priority: .utility) { urls.compactMap { NSImage(contentsOf: $0) } }.value
            guard !Task.isCancelled else { return }
            images = decoded
        }
    }

    private var removedStart: Double { max(0, item.effectiveTrimStart) }
    private var removedEnd: Double { max(0, item.durationSeconds - item.effectiveTrimEnd) }

    private var clipFrameRate: Double? { StitchingTimeline.frameRate(for: item) }

    private func removedDisplay(_ seconds: Double) -> String {
        if let rate = clipFrameRate { return "−\(StitchingTimeline.frameCount(seconds, rate: rate))f" }
        return "−" + StitchingTimeline.timeDisplay(seconds, frameRate: nil)
    }

    private var trimSummary: String {
        if let rate = clipFrameRate {
            return String(localized: "Start removed: \(StitchingTimeline.frameCount(removedStart, rate: rate)) frames; kept: \(StitchingTimeline.frameCount(StitchingTimeline.duration(item), rate: rate)) frames; end removed: \(StitchingTimeline.frameCount(removedEnd, rate: rate)) frames")
        }
        return String(localized: "Frame rate unavailable. Start removed: \(StitchingTimeline.timeDisplay(removedStart, frameRate: nil)); kept: \(StitchingTimeline.timeDisplay(StitchingTimeline.duration(item), frameRate: nil)); end removed: \(StitchingTimeline.timeDisplay(removedEnd, frameRate: nil))")
    }

    private func clipReadouts(width: Double) -> some View {
        HStack(spacing: 4) {
            if width >= 180 {
                Text(removedDisplay(removedStart))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(StitchingTimeline.timeDisplay(StitchingTimeline.duration(item), frameRate: clipFrameRate, compact: true))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
            if width >= 180 {
                Text(removedDisplay(removedEnd))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(width: width)
        .clipped()
        .help(trimSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trimSummary)
    }

    private func image(at index: Int, count: Int) -> NSImage? {
        guard !images.isEmpty else {
            return fallbackThumbnail
        }
        let fraction = (item.effectiveTrimStart + (Double(index) + 0.5) / Double(count) * StitchingTimeline.duration(item)) / max(0.1, item.durationSeconds)
        return images[min(images.count - 1, max(0, Int(fraction * Double(images.count))))]
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.white)
            .frame(width: 3, height: 40)
            .padding(2)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 3))
            .frame(width: 14, height: 68)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = start ? item.effectiveTrimStart : item.effectiveTrimEnd }
                    onTrim(start, (dragOrigin ?? 0) + value.translation.width / scale)
                }
                .onEnded { _ in dragOrigin = nil })
            .accessibilityLabel(start ? "Trim in for \(item.name)" : "Trim out for \(item.name)")
            .accessibilityAdjustableAction { direction in
                let step = clipFrameRate.map { 1 / $0 } ?? 0.1
                let delta = direction == .increment ? step : -step
                onTrim(start, (start ? item.effectiveTrimStart : item.effectiveTrimEnd) + delta)
            }
            .help(start ? "Drag to trim the start" : "Drag to trim the end")
    }
}

/// Each source owns its preview lifecycle. The sequence retains playback intent
/// across source changes and starts the next player only after it is ready.
private struct StitchingSequencePreview: View {
    @Binding var item: VideoItem
    let initialTime: Double
    let seekRequest: StitchingSeek
    @Binding var isPlaying: Bool
    let shuttleRate: Float
    let onShuttle: (Int) -> Void
    let onTime: (Double) -> Void
    let onTogglePlayback: () -> Void
    let onFit: () -> Void
    let onZoom: (Int) -> Void
    let onAddMarker: () -> Void
    let onRippleTrim: (Bool) -> Void
    let onFinished: () -> Void
    let onAssets: ([URL]) -> Void
    @StateObject private var controller: PreviewPlayerController
    @State private var playbackTime: Double = 0
    @State private var finished = false
    @State private var active = false
    @State private var requestedTime: Double
    @State private var preparedID: UUID?

    init(item: Binding<VideoItem>, initialTime: Double, seekRequest: StitchingSeek, isPlaying: Binding<Bool>, shuttleRate: Float,
         onTime: @escaping (Double) -> Void, onTogglePlayback: @escaping () -> Void, onShuttle: @escaping (Int) -> Void, onFit: @escaping () -> Void, onZoom: @escaping (Int) -> Void, onAddMarker: @escaping () -> Void, onRippleTrim: @escaping (Bool) -> Void, onFinished: @escaping () -> Void, onAssets: @escaping ([URL]) -> Void) {
        _item = item
        self.initialTime = initialTime
        self.seekRequest = seekRequest
        _isPlaying = isPlaying
        self.shuttleRate = shuttleRate
        self.onShuttle = onShuttle
        self.onTime = onTime
        self.onTogglePlayback = onTogglePlayback
        self.onFit = onFit
        self.onZoom = onZoom
        self.onAddMarker = onAddMarker
        self.onRippleTrim = onRippleTrim
        _requestedTime = State(initialValue: initialTime)
        self.onFinished = onFinished
        self.onAssets = onAssets
        var previewItem = item.wrappedValue
        previewItem.loopPlayback = false
        _controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: previewItem))
    }

    var body: some View {
        PreviewPlayerContent(item: $item, controller: controller, showsPlaybackControls: false,
                             togglePlaybackControls: {}, keyHandler: { key, modifiers, _ in
            guard item.status != .converting,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
            let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
            if key.lowercased() == "z", shortcutModifiers == .shift {
                onFit()
                return true
            }
            // Accept both the + character and the unshifted = key used by many keyboards.
            if shortcutModifiers == .command || shortcutModifiers == [.command, .shift] {
                if key == "+" || key == "=" { onZoom(1); return true }
                if key == "-", shortcutModifiers == .command { onZoom(-1); return true }
            }
            guard shortcutModifiers.isEmpty else { return false }
            switch key.lowercased() {
            case " ": onTogglePlayback()
            case "j": onShuttle(-1)
            case "k": onShuttle(0)
            case "l": onShuttle(1)
            case "m": onAddMarker()
            case "q": onRippleTrim(true)
            case "w": onRippleTrim(false)
            default: return false
            }
            return true
        }, currentPlaybackTime: $playbackTime)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewAccessibilityLabel)
        .accessibilityIdentifier("stitching.preview")
        .onAppear {
            active = true
            preparedID = item.id
            controller.playbackDidFinish = finish
            controller.preparePreview(startTime: initialTime)
        }
        .onDisappear {
            active = false
            controller.playbackDidFinish = nil
            controller.teardown()
        }
        .onChange(of: item) { _, value in
            var previewItem = value
            previewItem.loopPlayback = false
            controller.updateVideoItem(previewItem)
        }
        .onChange(of: seekRequest) { _, request in
            finished = false
            requestedTime = request.time
            guard preparedID == item.id, controller.isReady else { return }
            controller.pause()
            controller.seekTo(request.time)
            // Replay can change seek and playback intent in the same SwiftUI
            // update. Restore intent regardless of which onChange runs first.
            playIfReady()
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { finished = false; playIfReady() } else { controller.pause() }
        }
        .onChange(of: shuttleRate) { _, _ in
            finished = false
            playIfReady()
        }
        .onChange(of: controller.isReady) { _, ready in
            if ready, active, preparedID == item.id {
                controller.seekTo(requestedTime)
                playIfReady()
            }
        }
        .onChange(of: controller.errorMessage) { _, message in if message != nil { isPlaying = false } }
        .onChange(of: controller.previewAssets?.thumbnails) { _, urls in if let urls { onAssets(urls) } }
        .onReceive(controller.playbackTimePublisher) { time in
            guard active, preparedID == item.id, controller.isReady, !finished, time.isFinite else { return }
            playbackTime = time
            // Paused backend startup/seek callbacks can still report zero or an
            // earlier frame. Keep the explicit seek target until playback resumes.
            if isPlaying {
                requestedTime = time
                onTime(time)
            }
            if isPlaying && (shuttleRate < 0 ? time <= item.effectiveTrimStart : time >= item.effectiveTrimEnd) {
                finish()
            }
        }
        .overlay(alignment: .topTrailing) {
#if DEBUG
            if ProcessInfo.processInfo.environment["AMC_UI_TEST_SESSION"] == "1" {
                Text(String(controller.currentPlaybackTime))
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("stitching.backendTime")
            }
#endif
        }
    }

    private var previewAccessibilityLabel: String {
#if DEBUG
        if ProcessInfo.processInfo.environment["AMC_UI_TEST_SESSION"] == "1" {
            return "\(controller.useImageSequence ? "images" : controller.useMPV ? "mpv" : "native") \(controller.isReady ? "ready" : "loading")"
        }
#endif
        return String(localized: "Preview")
    }

    private func playIfReady() {
        guard active, isPlaying, controller.isReady else { return }
        controller.playShuttle(at: shuttleRate)
    }
    private func finish() {
        guard active, isPlaying, !finished else { return }
        finished = true
        controller.pause()
        onFinished()
    }
}
