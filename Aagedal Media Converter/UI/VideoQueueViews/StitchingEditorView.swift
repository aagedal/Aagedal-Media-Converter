// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
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

    static func removeSelected(_ items: inout [VideoItem], ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
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

    static func splitPoint(at time: Double, in items: [VideoItem]) -> (index: Int, time: Double)? {
        guard let location = location(at: time, in: items),
              let index = items.firstIndex(where: { $0.id == location.id }) else { return nil }
        let item = items[index]
        guard QueueGrouping.canMove([item.id], files: items, groups: []), item.isPlayable else { return nil }
        let rate = frameRate(for: item)
        let point = rate.map { (location.sourceTime * $0).rounded() / $0 } ?? location.sourceTime
        let minimum = rate.map { 1 / $0 } ?? 0.01
        guard point - item.effectiveTrimStart >= minimum - 0.000001,
              item.effectiveTrimEnd - point >= minimum - 0.000001 else { return nil }
        return (index, point)
    }

    @discardableResult
    static func split(_ items: inout [VideoItem], at time: Double) -> UUID? {
        guard let point = splitPoint(at: time, in: items) else { return nil }
        var second = items[point.index].timelineCopy()
        second.trimStart = point.time
        items[point.index].trimEnd = point.time
        let analyticsEnabled = items[point.index].analyticsEnabled
        items[point.index].resetConversionState()
        items[point.index].analyticsEnabled = analyticsEnabled
        items.insert(second, at: point.index + 1)
        return second.id
    }

    /// Remove a source range from one clip, retaining independent copies on either side.
    static func deleteRange(_ items: inout [VideoItem], id: UUID, range: ClosedRange<Double>) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              QueueGrouping.canMove([id], files: items, groups: []), items[index].isPlayable,
              range.lowerBound.isFinite, range.upperBound.isFinite else { return }
        let original = items[index]
        let lower = max(original.effectiveTrimStart, range.lowerBound)
        let upper = min(original.effectiveTrimEnd, range.upperBound)
        guard upper > lower else { return }
        var retained: [VideoItem] = []
        if lower > original.effectiveTrimStart {
            var left = original
            left.trimEnd = lower
            left.resetConversionState()
            left.analyticsEnabled = original.analyticsEnabled
            retained.append(left)
        }
        if upper < original.effectiveTrimEnd {
            var right = retained.isEmpty ? original : original.timelineCopy()
            right.trimStart = upper
            right.resetConversionState()
            right.analyticsEnabled = original.analyticsEnabled
            retained.append(right)
        }
        items.replaceSubrange(index...index, with: retained)
    }

    static func nearestKeyframe(_ time: Double, in times: [Double], bounds: ClosedRange<Double>) -> Double? {
        times.filter { $0.isFinite && bounds.contains($0) }.min { abs($0 - time) < abs($1 - time) }
    }

    /// A preceding sync sample is a seek estimate, never a decoded export boundary.
    /// Require scanned coverage through the requested cut so a distant cached
    /// candidate cannot be presented as the nearest preceding point.
    static func precedingSeekCandidate(_ requested: Double, times: [Double],
                                       scannedRanges: [ClosedRange<Double>]) -> Double? {
        guard requested.isFinite, requested >= 0,
              let candidate = times.last(where: { $0.isFinite && $0 >= 0 && $0 <= requested }),
              scannedRanges.contains(where: { $0.contains(candidate) && $0.contains(requested) }) else { return nil }
        return candidate
    }

    /// A following sync sample is only a source reference for an out-point.
    /// Packet copy can retain reordered video and audio across it, so this is
    /// neither an exported-end prediction nor an upper bound on the export.
    static func followingKeyframeReference(_ requested: Double, times: [Double],
                                          scannedRanges: [ClosedRange<Double>]) -> Double? {
        guard requested.isFinite, requested >= 0,
              let candidate = times.first(where: { $0.isFinite && $0 >= requested }),
              scannedRanges.contains(where: { $0.contains(requested) && $0.contains(candidate) }) else { return nil }
        return candidate
    }

    /// Source timestamps must be sorted, as returned by keyframe discovery. Keep
    /// dense regions hidden instead of suggesting that a sampled subset is complete.
    static func keyframeTickOffsets(in times: [Double], sourceStart: Double, duration: Double,
                                    scale: Double, visibleRange: ClosedRange<Double>) -> [Double] {
        guard sourceStart.isFinite, duration.isFinite, duration > 0,
              scale.isFinite, scale > 0,
              visibleRange.lowerBound.isFinite, visibleRange.upperBound.isFinite,
              visibleRange.upperBound > visibleRange.lowerBound else { return [] }
        let lowerTime = sourceStart + max(0, visibleRange.lowerBound) / scale
        let upperTime = sourceStart + min(duration, visibleRange.upperBound / scale)
        guard lowerTime <= upperTime else { return [] }
        // Search only the visible interval, even for all-intra or long recordings.
        var lower = 0
        var upper = times.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if times[middle] < lowerTime { lower = middle + 1 }
            else { upper = middle }
        }
        var offsets: [Double] = []
        var index = lower
        let minimumSpacing = 8.0 / scale
        while index < times.count, times[index] <= upperTime {
            let time = times[index]
            let previousReadable = index == 0 || time - times[index - 1] >= minimumSpacing
            let nextReadable = index + 1 == times.count || times[index + 1] - time >= minimumSpacing
            if previousReadable && nextReadable {
                offsets.append((time - sourceStart) * scale)
            }
            index += 1
        }
        return offsets
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

    /// Matches the merge request: the current first clip is the master, with
    /// preserve-source as the default and the first clip’s trim-in offset.
    static func outputStartTimecode(for items: [VideoItem], ignoreTrimOffset: Bool = false) -> String? {
        guard let first = items.first else { return nil }
        return FFMPEGCommandBuilder.resolvedTimecode(
            timecodeConfig: first.timecodeConfig ?? TimecodeConfig(mode: .preserveSource),
            sourceMetadata: first.metadata,
            trimStart: ignoreTrimOffset ? 0 : first.effectiveTrimStart
        )
    }

    static func sequenceTimeDisplay(_ seconds: Double, frameRate: Double?, startTimecode: String?) -> String {
        guard let frameRate else { return timeDisplay(seconds, frameRate: nil) }
        let rate = StitchMarkerTimecodeRate(frameRate: frameRate, dropFrame: startTimecode?.contains(";") == true)
        guard seconds >= 0, let frames = rate.frameCount(forSeconds: seconds) else { return "—" }
        let start = startTimecode.flatMap { rate.frameCount(forTimecode: $0) } ?? 0
        let sum = start.addingReportingOverflow(frames)
        guard !sum.overflow else { return "—" }
        return rate.timecode(forFrameCount: sum.partialValue)
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

/// History contains timeline edits only. Applying it retains current metadata and job state.
struct StitchingEditHistory {
    private struct Edit: Equatable {
        let id: UUID
        let start: Double?
        let end: Double?
        let markers: [StitchTimelineMarker]
    }
    private var undoItems: [[VideoItem]] = []
    private var redoItems: [[VideoItem]] = []
    private var observed: [Edit]?
    var canUndo: Bool { !undoItems.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }

    private func edits(_ items: [VideoItem]) -> [Edit] {
        items.map { Edit(id: $0.id, start: $0.trimStart, end: $0.trimEnd, markers: $0.timelineMarkers) }
    }

    mutating func record(from old: [VideoItem], to new: [VideoItem]) {
        guard (old + new).allSatisfy({ item in
            QueueGrouping.canMove([item.id], files: [item], groups: []) && item.isPlayable
        }) else {
            self = StitchingEditHistory()
            return
        }
        let next = edits(new)
        guard next != observed, edits(old) != next else { return }
        undoItems.append(old)
        if undoItems.count > 100 { undoItems.removeFirst() }
        redoItems.removeAll()
        observed = next
    }

    mutating func restore(_ items: inout [VideoItem], redo: Bool = false) {
        let target: [VideoItem]?
        if redo {
            target = redoItems.popLast()
            if target != nil { undoItems.append(items) }
        } else {
            target = undoItems.popLast()
            if target != nil { redoItems.append(items) }
        }
        guard let target else { return }
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = target.map { saved in
            var item = current[saved.id] ?? saved
            item.trimStart = saved.trimStart
            item.trimEnd = saved.trimEnd
            item.timelineMarkers = saved.timelineMarkers
            return item
        }
        observed = edits(items)
    }
}

struct StitchingEditorView<FileList: View>: View {
    @Binding var group: EncodingGroup
    let isStreamCopy: Bool
    @State private var rangeMode = false
    @State private var selectedRange: ClipRange?
    @State private var snapToKeyframes = false
    @State private var keyframes: [URL: [Double]] = [:]
    @State private var keyframeSourceIdentities: [URL: TimelineKeyframeService.SourceIdentity] = [:]
    @State private var keyframeLoading = false
    @State private var keyframeScannedRanges: [URL: [ClosedRange<Double>]] = [:]
    @State private var showsTimelineInfo = false
    private struct ClipRange: Equatable {
        let id: UUID
        let bounds: ClosedRange<Double>
    }
    @State private var editHistory = StitchingEditHistory()
    @State private var trimGestureBefore: [VideoItem]?
    @State private var editingMarkerID: UUID?
    @State private var markerText = ""
    @State private var showsMarkerEditor = false
    @State private var selectedID: UUID?
    @Binding var selectedClipIDs: Set<UUID>
    @ViewBuilder var fileList: () -> FileList
    @State private var selectionAnchor: UUID?
    @State private var draggedClipIDs: Set<UUID> = []
    @State private var rangeDragID: UUID?
    @State private var insertionBoundary: Int?
    @GestureState private var isDraggingClips = false
    @State private var clipDragCancelled = false
    @State private var sourceTime: Double = 0
    @State private var seekRequest = StitchingSeek(time: 0)
    @State private var isPlaying = false
    @State private var previewAudioTrack = 0
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
    @State private var isScrubbingTimeline = false
    @State private var zoom: Double = 1
    @State private var fittedDuration: Double?
    @State private var fitRequest = UUID()
    @State private var previewAssets: [UUID: PreviewAssets] = [:]
    @State private var filmstrips: [UUID: [URL]] = [:]

    private var canEditHistory: Bool {
        group.status != .converting && group.items.allSatisfy { item in
            QueueGrouping.canMove([item.id], files: [item], groups: []) && item.isPlayable
        }
    }

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
    @AppStorage(AppConstants.ignoreStitchTimecodeTrimOffsetKey) private var ignoreStitchTimecodeTrimOffset = false
    private var sequenceStartTimecode: String? {
        StitchingTimeline.outputStartTimecode(for: group.items, ignoreTrimOffset: ignoreStitchTimecodeTrimOffset)
    }
    private func sequenceTimeDisplay(_ seconds: Double) -> String {
        StitchingTimeline.sequenceTimeDisplay(seconds, frameRate: sequenceFrameRate, startTimecode: sequenceStartTimecode)
    }
    private var sequenceTimecodeHelp: String {
        if sequenceFrameRate == nil { return "Relative time · mixed or unknown frame rates" }
        if sequenceStartTimecode == nil { return "Relative timecode · no starting timecode on the first clip" }
        return "Output timecode follows the first clip’s settings. Reordering the first clip changes the timeline timecode. The value after / is the sequence duration."
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
                            seekRequest: seekRequest, isPlaying: $isPlaying, audioTrack: $previewAudioTrack, shuttleRate: shuttleRate,
                            onTime: { time in if selectedIndex.map({ group.items[$0].id }) == item.id { sourceTime = time } },
                            onTogglePlayback: togglePlayback,
                            onShuttle: shuttle,
                            onFit: fitTimeline,
                            onZoom: { keyboardZoomSteps += $0 },
                            onAddMarker: addMarker,
                            onSplit: splitAtPlayhead,
                            onDeleteSelection: deleteSelection,
                            onClearRange: clearSelectedRange,
                            onToggleRange: toggleRangeMode,
                            onUndo: { restoreEdit() },
                            onRedo: { restoreEdit(redo: true) },
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
                    Text(sequenceFrameRate != nil && sequenceStartTimecode != nil ? "Output TC" : "Relative TC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(sequenceTimecodeHelp)
                    Text("\(sequenceTimeDisplay(sequenceTime)) / \(StitchingTimeline.timeDisplay(total, frameRate: sequenceFrameRate))")
                        .monospacedDigit()
                        .accessibilityIdentifier("stitching.timecode")
                        .help(sequenceTimecodeHelp)
                    Text(isPlaying ? "\(shuttleRate.formatted())×" : "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stitching.rate")
                    Spacer()
                    Button { restoreEdit() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Undo timeline edit (⌘Z)")
                    .accessibilityLabel("Undo timeline edit")
                    .accessibilityIdentifier("stitching.undo")
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canEditHistory || !editHistory.canUndo || trimGestureBefore != nil)
                    Button { restoreEdit(redo: true) } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .help("Redo timeline edit (⇧⌘Z)")
                    .accessibilityLabel("Redo timeline edit")
                    .accessibilityIdentifier("stitching.redo")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canEditHistory || !editHistory.canRedo || trimGestureBefore != nil)
                    Button(action: splitAtPlayhead) {
                        Label("Split", systemImage: "scissors")
                    }
                    .disabled(group.status == .converting || StitchingTimeline.splitPoint(at: sequenceTime, in: group.items) == nil)
                    .help("Split the clip at the playhead (⌘B). Trim either part independently.")
                    .accessibilityIdentifier("stitching.split")
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
                HStack {
                    Toggle("Range", isOn: $rangeMode)
                        .toggleStyle(.button)
                        .keyboardShortcut("r", modifiers: [])
                        .help("Toggle Range mode (R), or hold Command while dragging across a clip to select a range. Backspace deletes the selected range or clips; Option+X or Escape clears a range.")
                        .accessibilityIdentifier("stitching.rangeTool")
                    Button(selectedRange == nil ? "Delete selected clips" : "Delete range", action: deleteSelection)
                        .disabled((selectedRange == nil && selectedClipIDs.isEmpty) || !canEditHistory)
                        .keyboardShortcut(.delete, modifiers: [])
                        .accessibilityIdentifier("stitching.deleteRange")
                    Button("Clear range") { clearSelectedRange() }
                        .disabled(selectedRange == nil)
                        .keyboardShortcut("x", modifiers: .option)
                        .help("Clear the selected range (⌥X or Escape)")
                        .accessibilityIdentifier("stitching.clearRange")
                    if let selection = selectedRange,
                       let selected = group.items.first(where: { $0.id == selection.id }) {
                        Text("Selected: \(StitchingTimeline.timeDisplay(selection.bounds.upperBound - selection.bounds.lowerBound, frameRate: StitchingTimeline.frameRate(for: selected)))")
                            .font(.caption.monospacedDigit())
                    }
                    Spacer()
                    if rangeMode {
                        Text("Drag within a clip · Backspace: delete selection · ⌥X: clear range")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                timeline
                HStack(spacing: 12) {
                    if isStreamCopy {
                        Toggle("Snap trims and ranges to keyframes", isOn: $snapToKeyframes)
                            .fixedSize()
                            .accessibilityIdentifier("stitching.keyframeSnap")
                    }
                    Button { showsTimelineInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Timeline information")
                    .accessibilityIdentifier("stitching.timelineInfo")
                    .help(isStreamCopy ? "Show timeline shortcuts and Stream Copy cut details" : "Show timeline shortcuts and gestures")
                    .popover(isPresented: $showsTimelineInfo, arrowEdge: .bottom) {
                        timelineInfo(for: item)
                    }
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
                Button("Undo timeline edit") { restoreEdit() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canEditHistory || !editHistory.canUndo)
                    .accessibilityIdentifier("stitching.undo")
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
        .task(id: keyframeRequestID) {
            keyframeLoading = false
            guard isStreamCopy, !isScrubbingTimeline else { return }
            // Let rapid seeks settle before opening a reader. A canceled reader
            // finishes its current sample before teardown, so scans during a drag
            // compete with the preview for decoder and disk resources.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            keyframeLoading = true
            defer { if !Task.isCancelled { keyframeLoading = false } }
            let previewID = selectedID ?? group.items.first?.id
            let items = snapToKeyframes ? group.items : group.items.filter { $0.id == previewID }
            for item in items {
                let points = [item.effectiveTrimStart, item.effectiveTrimEnd]
                    + (item.id == previewID ? [sourceTime] : [])
                for point in points {
                    do {
                        let scan = try await TimelineKeyframeService.shared.scan(
                            url: item.url, around: point, duration: item.durationSeconds)
                        try Task.checkCancellation()
                        if keyframeSourceIdentities[item.url] != scan.sourceIdentity || scan.sourceIdentity == nil {
                            keyframes[item.url] = []
                            keyframeScannedRanges[item.url] = []
                        }
                        keyframeSourceIdentities[item.url] = scan.sourceIdentity
                        // Incomplete scans never establish coverage or snapping candidates.
                        guard scan.status == .complete, let region = scan.scannedRange else { continue }
                        keyframes[item.url] = Array(Set((keyframes[item.url] ?? []) + scan.times)).sorted()
                        var regions = (keyframeScannedRanges[item.url] ?? []) + [region]
                        regions.sort { $0.lowerBound < $1.lowerBound }
                        var merged: [ClosedRange<Double>] = []
                        for region in regions {
                            if let last = merged.last, region.lowerBound <= last.upperBound.nextUp {
                                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, region.upperBound)
                            } else { merged.append(region) }
                        }
                        keyframeScannedRanges[item.url] = merged
                    } catch { if Task.isCancelled { return } }
                }
            }
        }
        .onChange(of: rangeMode) { _, _ in selectedRange = nil }
        .onChange(of: snapToKeyframes) { _, _ in selectedRange = nil }
        .onChange(of: group.items) { old, new in
            if old.map(\.id) != new.map(\.id) || zip(old, new).contains(where: { $0.trimStart != $1.trimStart || $0.trimEnd != $1.trimEnd }) {
                selectedRange = nil
            }
            guard canEditHistory else {
                editHistory = StitchingEditHistory()
                trimGestureBefore = nil
                return
            }
            if trimGestureBefore == nil { editHistory.record(from: old, to: new) }
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
            clearSelectedRange()
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

    private func timelineInfo(for item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline information").font(.headline)
            if isStreamCopy {
                Divider()
                Text("Stream Copy cuts").font(.subheadline.weight(.semibold))
                Text(item.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                if snapToKeyframes {
                    Text(keyframeLoading ? "Finding keyframes…" : (keyframes[item.url]?.isEmpty == false ? "Trims and ranges snap to the nearest available keyframe." : "Keyframes unavailable for this clip. Using frame snapping."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let requested = item.effectiveTrimStart
                    let display = StitchingTimeline.timeDisplay(requested, frameRate: StitchingTimeline.frameRate(for: item))
                    Text("Requested start: \(display)")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("stitching.requestedCut")
                    if let candidate = StitchingTimeline.precedingSeekCandidate(
                        requested, times: keyframes[item.url] ?? [],
                        scannedRanges: keyframeScannedRanges[item.url] ?? []) {
                        let candidateDisplay = StitchingTimeline.timeDisplay(candidate, frameRate: StitchingTimeline.frameRate(for: item))
                        let difference = (requested - candidate).formatted(.number.precision(.fractionLength(3)))
                        Text("Estimated seek point: \(candidateDisplay) (\(difference) s earlier). Export can differ.")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("stitching.seekEstimate")
                    } else {
                        Text("Seek estimate unavailable near this cut.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let requestedEnd = item.effectiveTrimEnd
                    let endDisplay = StitchingTimeline.timeDisplay(requestedEnd, frameRate: StitchingTimeline.frameRate(for: item))
                    Text("Requested end: \(endDisplay)")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("stitching.requestedEnd")
                    if let reference = StitchingTimeline.followingKeyframeReference(
                        requestedEnd, times: keyframes[item.url] ?? [],
                        scannedRanges: keyframeScannedRanges[item.url] ?? []) {
                        let referenceDisplay = StitchingTimeline.timeDisplay(reference, frameRate: StitchingTimeline.frameRate(for: item))
                        let difference = (reference - requestedEnd).formatted(.number.precision(.fractionLength(3)))
                        Text("Keyframe at or after end: \(referenceDisplay) (\(difference) s later). This does not predict the exported end.")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stitching.endKeyframeReference")
                    } else {
                        Text("No following keyframe found in the scanned region. Exported end cannot be estimated from keyframes.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stitching.endKeyframeUnavailable")
                    }
                }
                Text("Stream Copy cuts are approximate. Export may include extra video frames and audio, even at keyframes. Preview and timeline duration show the requested selection; exported boundaries and duration may differ.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stitching.streamCopyBoundaryGuidance")
            }
            Divider()
            Text("Shortcuts and gestures").font(.subheadline.weight(.semibold))
            Text("J/K/L: reverse, pause, play (repeat J or L to speed up).")
                .font(.caption).foregroundStyle(.secondary)
            Text("R: range · Backspace: delete selected range or clips · ⌥X: clear range · ⌘B: split · ⌘Z: undo · M: marker · Q/W: trim start/end.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Drag the ruler to scrub, clip edges to trim, or clips to reorder. Command-drag selects a time range; Shift-click selects multiple clips; ⌘-click toggles a clip. Pinch to zoom. Later clips close the gap after trimming.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
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
                            let labelSpacing = 115.0
                            let step = pow(10, floor(log10(max(1, labelSpacing / scale))))
                            let interval = step * (labelSpacing / scale / step > 5 ? 10 : labelSpacing / scale / step > 2 ? 5 : 2)
                            for tick in stride(from: 0.0, through: max(total, width / scale), by: interval) {
                                let x = tick * scale
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: 19))
                                path.addLine(to: CGPoint(x: x, y: 27))
                                context.stroke(path, with: .color(.secondary), lineWidth: 1)
                                context.draw(Text(sequenceTimeDisplay(tick)).font(.caption2).foregroundStyle(.secondary),
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
                                isScrubbingTimeline = false
                            })
                        HStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                StitchingTimelineClip(
                                    item: item, selected: selectedClipIDs.contains(item.id), scale: scale,
                                    thumbnailURLs: filmstrips[item.id] ?? [],
                                    keyframeTimes: isStreamCopy ? keyframes[item.url] ?? [] : [],
                                    assets: previewAssets[item.id],
                                    waveformVisualScale: waveformVisualScale,
                                    visibleRange: max(0, min(clipWidths[index], scrollOffset - 10 - clipWidths.prefix(index).reduce(0, +)))...max(0, min(clipWidths[index], scrollOffset + geometry.size.width - 10 - clipWidths.prefix(index).reduce(0, +))),
                                    onSelect: { selectClip(item.id) },
                                    reorderGesture: clipDrag(item.id, widths: clipWidths, scale: scale),
                                    onTrim: { start, value in setTrim(item.id, start: start, value: value) },
                                    onTrimGesture: { active in
                                        if active { trimGestureBefore = group.items }
                                        else if let before = trimGestureBefore {
                                            editHistory.record(from: before, to: group.items)
                                            trimGestureBefore = nil
                                        }
                                    }
                                )
                                .overlay {
                                    if rangeMode {
                                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityIdentifier("stitching.rangeSurface")
                                            .gesture(DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    selectRange(in: item, from: value.startLocation.x / scale,
                                                                to: value.location.x / scale)
                                                })
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    if let selection = selectedRange, selection.id == item.id {
                                        Rectangle().fill(Color.yellow.opacity(0.3))
                                            .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 2))
                                            .frame(width: (selection.bounds.upperBound - selection.bounds.lowerBound) * scale)
                                            .offset(x: (selection.bounds.lowerBound - item.effectiveTrimStart) * scale)
                                            .allowsHitTesting(false)
                                    }
                                }
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
        isScrubbingTimeline = true
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
    private func preserveTimelineScale() {
        // Structural edits change the sum of full source durations, even when
        // the visible sequence changes little. Keep the current time-to-pixel scale.
        if fittedDuration == nil { fittedDuration = sourceTotal }
    }
    private func restoreEdit(redo: Bool = false) {
        guard canEditHistory, !showsMarkerEditor, trimGestureBefore == nil,
              redo ? editHistory.canRedo : editHistory.canUndo else { return }
        let time = sequenceTime
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        cancelClipDrag()
        editHistory.restore(&group.items, redo: redo)
        group.lastSortMode = nil
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
        if let location = StitchingTimeline.location(at: min(time, total), in: group.items) {
            selectedClipIDs = [location.id]
            selectionAnchor = location.id
            seek(location.id, to: location.sourceTime)
        }
    }

    private func rippleTrim(start: Bool) {
        guard group.status != .converting, !showsMarkerEditor else { return }
        let time = sequenceTime
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        guard let location = StitchingTimeline.location(at: time, in: group.items) else { return }
        setTrim(location.id, start: start, value: location.sourceTime)
    }

    private func splitAtPlayhead() {
        guard group.status != .converting, !showsMarkerEditor else { return }
        let time = sequenceTime
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        guard StitchingTimeline.splitPoint(at: time, in: group.items) != nil else { return }
        preserveTimelineScale()
        guard let id = StitchingTimeline.split(&group.items, at: time),
              let item = group.items.first(where: { $0.id == id }) else { return }
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
        selectedClipIDs = [id]
        selectionAnchor = id
        seek(id, to: item.effectiveTrimStart)
    }

    private var keyframeRequestID: String {
        if isScrubbingTimeline { return "scrubbing" }
        let items = group.items.map {
            "\($0.id)-\($0.url.absoluteString)-\(floor($0.effectiveTrimStart / 5))-\(floor($0.effectiveTrimEnd / 5))"
        }.joined(separator: "|")
        return "\(isStreamCopy)-\(snapToKeyframes)-\(selectedID?.uuidString ?? "")-\(floor(sourceTime / 15))-\(items)"
    }

    private func scannedKeyframe(_ time: Double, item: VideoItem, bounds: ClosedRange<Double>) -> Double? {
        guard let region = keyframeScannedRanges[item.url]?.first(where: { $0.contains(time) }) else { return nil }
        let lower = max(region.lowerBound, bounds.lowerBound)
        let upper = min(region.upperBound, bounds.upperBound)
        guard lower <= upper else { return nil }
        guard let candidate = StitchingTimeline.nearestKeyframe(time, in: keyframes[item.url] ?? [], bounds: lower...upper) else { return nil }
        // An uninspected adjacent region may contain a closer point. Fall back to
        // frame snapping until the local search can establish the nearest candidate.
        let distance = abs(candidate - time)
        if region.lowerBound > bounds.lowerBound, distance > time - region.lowerBound { return nil }
        if region.upperBound < bounds.upperBound, distance > region.upperBound - time { return nil }
        return candidate
    }

    private func rangeBoundary(_ item: VideoItem, value: Double) -> Double {
        let bounds = item.effectiveTrimStart...item.effectiveTrimEnd
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, value))
        if clamped == bounds.lowerBound || clamped == bounds.upperBound { return clamped }
        if isStreamCopy, snapToKeyframes,
           let point = scannedKeyframe(clamped, item: item, bounds: bounds) { return point }
        let rate = StitchingTimeline.frameRate(for: item)
        return min(bounds.upperBound, max(bounds.lowerBound, rate.map { (clamped * $0).rounded() / $0 } ?? clamped))
    }

    private func toggleRangeMode() {
        guard group.status != .converting, !showsMarkerEditor else { return }
        rangeMode.toggle()
    }

    @discardableResult
    private func clearSelectedRange() -> Bool {
        guard !showsMarkerEditor, selectedRange != nil else { return false }
        selectedRange = nil
        return true
    }

    private func deleteSelection() {
        if selectedRange != nil { deleteSelectedRange() }
        else { deleteSelectedClips() }
    }

    private func deleteSelectedClips() {
        let selected = selectedClipIDs.intersection(Set(group.items.map(\.id)))
        guard canEditHistory, !showsMarkerEditor, trimGestureBefore == nil,
              !selected.isEmpty else { return }
        let time = sequenceTime
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        preserveTimelineScale()
        StitchingTimeline.removeSelected(&group.items, ids: selected)
        selectedClipIDs.removeAll()
        selectionAnchor = nil
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
        if let location = StitchingTimeline.location(at: min(time, total), in: group.items) {
            selectedClipIDs = [location.id]
            selectionAnchor = location.id
            seek(location.id, to: location.sourceTime)
        } else {
            selectedID = nil
            sourceTime = 0
        }
    }

    private func deleteSelectedRange() {
        guard canEditHistory, !showsMarkerEditor, let selection = selectedRange else { return }
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        let time = sequenceTime
        preserveTimelineScale()
        StitchingTimeline.deleteRange(&group.items, id: selection.id, range: selection.bounds)
        selectedRange = nil
        group.lastSortMode = nil
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
        if let location = StitchingTimeline.location(at: min(time, total), in: group.items) {
            selectedClipIDs = [location.id]
            seek(location.id, to: location.sourceTime)
        }
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
        let item = group.items[index]
        let gap = 1 / (StitchingTimeline.frameRate(for: item) ?? 100)
        let bounds = start ? 0...max(0, item.effectiveTrimEnd - gap)
            : min(item.durationSeconds, item.effectiveTrimStart + gap)...item.durationSeconds
        if isStreamCopy, snapToKeyframes,
           let point = scannedKeyframe(value, item: item, bounds: bounds) {
            if start { group.items[index].trimStart = point }
            else { group.items[index].trimEnd = point }
        } else {
            StitchingTimeline.trim(&group.items[index], start: start, to: value)
        }
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

    private func selectRange(in item: VideoItem, from start: Double, to end: Double) {
        isPlaying = false
        scrubTask?.cancel()
        scrubTask = nil
        pendingScrubTime = nil
        let a = rangeBoundary(item, value: item.effectiveTrimStart + start)
        let b = rangeBoundary(item, value: item.effectiveTrimStart + end)
        selectedRange = a == b ? nil : ClipRange(id: item.id, bounds: min(a, b)...max(a, b))
        seek(item.id, to: b)
    }

    private func selectDraggedRange(_ id: UUID, value: DragGesture.Value, widths: [Double], scale: Double) {
        guard let index = group.items.firstIndex(where: { $0.id == id }) else { return }
        let origin = widths.prefix(index).reduce(0, +)
        selectRange(in: group.items[index], from: (value.startLocation.x - origin) / scale,
                    to: (value.location.x - origin) / scale)
    }

    private func clipDrag(_ id: UUID, widths: [Double], scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("stitching.clips"))
            .updating($isDraggingClips) { _, active, _ in active = true }
            .onChanged { value in
                guard group.status != .converting, !clipDragCancelled else { return }
                // Latch the gesture's intent so releasing Command before the mouse
                // cannot turn a range selection into a clip reorder. A click still
                // reaches selectClip and retains Command-click multiselection.
                if draggedClipIDs.isEmpty, rangeDragID == nil, NSEvent.modifierFlags.contains(.command) {
                    rangeDragID = id
                }
                if rangeDragID == id {
                    selectDraggedRange(id, value: value, widths: widths, scale: scale)
                    return
                }
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
                guard group.status != .converting, !clipDragCancelled else { return }
                if rangeDragID == id {
                    selectDraggedRange(id, value: value, widths: widths, scale: scale)
                    return
                }
                guard !draggedClipIDs.isEmpty,
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
        rangeDragID = nil
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
    var body: some View {
        WaveformEnvelopeView(envelope: assets?.waveformEnvelope,
                             sourceStart: item.effectiveTrimStart,
                             sourceDuration: StitchingTimeline.duration(item),
                             visualScale: visualScale, visibleRange: visibleRange)
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
    let keyframeTimes: [Double]
    let assets: PreviewAssets?
    let waveformVisualScale: Double
    let visibleRange: ClosedRange<Double>
    let onSelect: () -> Void
    let reorderGesture: ReorderGesture
    let onTrim: (Bool, Double) -> Void
    let onTrimGesture: (Bool) -> Void
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
                let offsets = StitchingTimeline.keyframeTickOffsets(
                    in: keyframeTimes, sourceStart: item.effectiveTrimStart,
                    duration: StitchingTimeline.duration(item), scale: scale,
                    visibleRange: visibleRange
                )
                Canvas { context, _ in
                    var ticks = Path()
                    for x in offsets {
                        ticks.move(to: CGPoint(x: x, y: 59))
                        ticks.addLine(to: CGPoint(x: x, y: 67))
                    }
                    context.stroke(ticks, with: .color(.black.opacity(0.8)), lineWidth: 3)
                    context.stroke(ticks, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
                .frame(height: 68).offset(y: 24)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Keyframe candidates: \(offsets.count)"))
                .accessibilityIdentifier("stitching.keyframeMarkers")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
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
                    if dragOrigin == nil {
                        onTrimGesture(true)
                        dragOrigin = start ? item.effectiveTrimStart : item.effectiveTrimEnd
                    }
                    onTrim(start, (dragOrigin ?? 0) + value.translation.width / scale)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    onTrimGesture(false)
                })
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
    @Binding var audioTrack: Int
    let shuttleRate: Float
    let onShuttle: (Int) -> Void
    let onTime: (Double) -> Void
    let onTogglePlayback: () -> Void
    let onFit: () -> Void
    let onZoom: (Int) -> Void
    let onAddMarker: () -> Void
    let onSplit: () -> Void
    let onDeleteSelection: () -> Void
    let onClearRange: () -> Bool
    let onToggleRange: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onRippleTrim: (Bool) -> Void
    let onFinished: () -> Void
    let onAssets: ([URL]) -> Void
    @StateObject private var controller: PreviewPlayerController
    @State private var playbackTime: Double = 0
    @State private var finished = false
    @State private var active = false
    @State private var requestedTime: Double
    @State private var preparedID: UUID?

    init(item: Binding<VideoItem>, initialTime: Double, seekRequest: StitchingSeek, isPlaying: Binding<Bool>, audioTrack: Binding<Int>, shuttleRate: Float,
         onTime: @escaping (Double) -> Void, onTogglePlayback: @escaping () -> Void, onShuttle: @escaping (Int) -> Void, onFit: @escaping () -> Void, onZoom: @escaping (Int) -> Void, onAddMarker: @escaping () -> Void, onSplit: @escaping () -> Void, onDeleteSelection: @escaping () -> Void, onClearRange: @escaping () -> Bool, onToggleRange: @escaping () -> Void, onUndo: @escaping () -> Void, onRedo: @escaping () -> Void, onRippleTrim: @escaping (Bool) -> Void, onFinished: @escaping () -> Void, onAssets: @escaping ([URL]) -> Void) {
        _item = item
        self.initialTime = initialTime
        self.seekRequest = seekRequest
        _isPlaying = isPlaying
        _audioTrack = audioTrack
        self.shuttleRate = shuttleRate
        self.onShuttle = onShuttle
        self.onTime = onTime
        self.onTogglePlayback = onTogglePlayback
        self.onFit = onFit
        self.onZoom = onZoom
        self.onAddMarker = onAddMarker
        self.onSplit = onSplit
        self.onDeleteSelection = onDeleteSelection
        self.onClearRange = onClearRange
        self.onToggleRange = onToggleRange
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onRippleTrim = onRippleTrim
        _requestedTime = State(initialValue: initialTime)
        self.onFinished = onFinished
        self.onAssets = onAssets
        var previewItem = item.wrappedValue
        previewItem.loopPlayback = false
        _controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: previewItem))
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
            SourceAudioMeterPanel(controller: controller, item: item, time: requestedTime,
                                  isPlaying: isPlaying && controller.isReady) { position in
                // Preserve sequence/shuttle intent without the controller's delayed
                // toggle-to-resume, which could restart playback after a user pause.
                controller.pause()
                controller.selectAudioTrack(at: position)
                audioTrack = position
                playIfReady()
            }
        }
    }

    private var preview: some View {
        PreviewPlayerContent(item: $item, controller: controller, showsPlaybackControls: false,
                             togglePlaybackControls: {}, keyHandler: { key, modifiers, _ in
            guard item.status != .converting,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
            let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
            // The preview uses AppKit event monitors, so Escape does not always
            // reach SwiftUI's onExitCommand. Handle range clearing here as well.
            if (key.lowercased() == "x" && shortcutModifiers == .option)
                || (key == "\u{1b}" && shortcutModifiers.isEmpty) {
                return onClearRange()
            }
            if key.lowercased() == "z", shortcutModifiers == .shift {
                onFit()
                return true
            }
            if key.lowercased() == "z", shortcutModifiers == .command {
                onUndo()
                return true
            }
            if key.lowercased() == "z", shortcutModifiers == [.command, .shift] {
                onRedo()
                return true
            }
            if key.lowercased() == "b", shortcutModifiers == .command {
                onSplit()
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
            case "\u{7f}", "\u{08}": onDeleteSelection()
            case "r": onToggleRange()
            case "m": onAddMarker()
            case "q": onRippleTrim(true)
            case "w": onRippleTrim(false)
            default: return false
            }
            return true
        }, currentPlaybackTime: $playbackTime)
        .clipped()
        .accessibilityElement(children: controller.errorMessage == nil ? .ignore : .contain)
        .accessibilityLabel(previewAccessibilityLabel)
        .accessibilityIdentifier("stitching.preview")
        .onAppear {
            active = true
            preparedID = item.id
            controller.playbackDidFinish = finish
            controller.selectedAudioTrackOrderIndex = audioTrack
            controller.preparePreview(startTime: initialTime, resetAudioSelection: false)
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
            Text(StitchingTimeline.timeDisplay(playbackTime, frameRate: StitchingTimeline.frameRate(for: item) ?? 30))
                .font(.caption.monospacedDigit())
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .padding(8)
                .help("Relative clip timecode (HH:MM:SS:FF)")
                .accessibilityIdentifier("stitching.backendTime")
                .accessibilityValue(String(controller.currentPlaybackTime))
                .allowsHitTesting(false)
        }
    }

    private var previewAccessibilityLabel: String {
#if DEBUG
        if ProcessInfo.processInfo.environment["AMC_UI_TEST_SESSION"] == "1" {
            if controller.errorMessage != nil { return "failed" }
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
