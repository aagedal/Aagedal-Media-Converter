// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Source ranges mapped onto one gapless output sequence.
enum StitchingTimeline {
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

struct StitchingEditorView: View {
    @Binding var group: EncodingGroup
    let isStreamCopy: Bool
    @State private var selectedID: UUID?
    @State private var sourceTime: Double = 0
    @State private var seekRequest = StitchingSeek(time: 0)
    @State private var isPlaying = false
    @State private var zoom: Double = 1
    @State private var fittedDuration: Double?
    @State private var fitRequest = UUID()
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
                StitchingSequencePreview(
                    item: itemBinding(item), initialTime: item.id == selectedID ? sourceTime : item.effectiveTrimStart,
                    seekRequest: seekRequest, isPlaying: $isPlaying,
                    onTime: { time in if selectedIndex.map({ group.items[$0].id }) == item.id { sourceTime = time } },
                    onTogglePlayback: togglePlayback,
                    onFit: fitTimeline,
                    onFinished: { advance(after: item.id) },
                    onAssets: { filmstrips[item.id] = $0 }
                )
                .id(item.id)
                .frame(height: 280)

                HStack {
                    Button(action: togglePlayback) {
                        Label(isPlaying ? "Pause" : "Play sequence", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityIdentifier("stitching.play")
                    Text("\(StitchingTimeline.timeDisplay(sequenceTime, frameRate: sequenceFrameRate)) / \(StitchingTimeline.timeDisplay(total, frameRate: sequenceFrameRate))")
                        .monospacedDigit()
                        .help(sequenceFrameRate.map { "HH:MM:SS:FF · \($0.formatted()) fps · non-drop-frame" }
                              ?? "HH:MM:SS · mixed or unknown frame rates")
                    Spacer()
                    Text("Zoom").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...32).frame(width: 110)
                    Button("Fit", action: fitTimeline)
                        .keyboardShortcut("z", modifiers: [.shift])
                        .help("Fit the timeline (⇧Z)")
                        .accessibilityIdentifier("stitching.fit")
                }
                timeline
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { moveSelection(index, by: -1) } label: { Image(systemName: "arrow.left") }
                        .help("Move clip earlier").disabled(index == 0)
                    Button { moveSelection(index, by: 1) } label: { Image(systemName: "arrow.right") }
                        .help("Move clip later").disabled(index == group.items.count - 1)
                }
                Button("Reset trim") {
                    isPlaying = false
                    guard let i = selectedIndex else { return }
                    group.items[i].trimStart = nil
                    group.items[i].trimEnd = nil
                    seek(item.id, to: 0)
                }
                .disabled(item.durationSeconds <= 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ContentUnavailableView("No clips", systemImage: "film", description: Text("Add files to start stitching."))
            }
            if isStreamCopy {
                Text("Stream Copy keeps the original quality. Cut points may depend on source keyframes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Drag a clip edge to trim. Click or drag in the timeline to scrub the sequence. Changes update the clip list immediately.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .disabled(group.status == .converting)
        .onChange(of: group.items.map(\.id)) { _, ids in
            isPlaying = false
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                sourceTime = group.items.first?.effectiveTrimStart ?? 0
            }
        }
        .onChange(of: group.status) { _, status in if status == .converting { isPlaying = false } }
        .onDisappear { isPlaying = false }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let scale = max(0.01, (geometry.size.width - 20) / (fittedDuration ?? sourceTotal) * zoom)
            let width = max(geometry.size.width - 20, total * scale)
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
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in scrub(value.location.x / scale) })
                        HStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                StitchingTimelineClip(
                                    item: item, selected: selectedIndex == index, scale: scale,
                                    thumbnailURLs: filmstrips[item.id] ?? [],
                                    onSeek: { local in scrub(offset(index) + local) },
                                    onTrim: { start, value in setTrim(item.id, start: start, value: value) }
                                )
                                .frame(width: max(1, StitchingTimeline.duration(item) * scale), height: 116)
                                .id(item.id)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 116)
                    }
                    .frame(width: width, alignment: .leading)
                    .id("stitching.timeline.origin")
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(.red).frame(width: 2, height: 144)
                            .offset(x: min(width - 2, sequenceTime * scale))
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .onChange(of: fitRequest) { _, _ in
                    proxy.scrollTo("stitching.timeline.origin", anchor: .leading)
                }
                .onChange(of: selectedID) { _, id in
                    if let id, isPlaying { proxy.scrollTo(id, anchor: .leading) }
                }
            }
        }
        .frame(height: 166)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
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
    private func scrub(_ time: Double) {
        isPlaying = false
        guard let location = StitchingTimeline.location(at: time, in: group.items) else { return }
        seek(location.id, to: location.sourceTime)
    }
    private func togglePlayback() {
        if isPlaying { isPlaying = false; return }
        if sequenceTime >= total - 0.01 { scrub(0) }
        isPlaying = total > 0
    }
    private func advance(after id: UUID) {
        guard isPlaying, let index = selectedIndex, group.items[index].id == id else { return }
        if let next = group.items.dropFirst(index + 1).first(where: { StitchingTimeline.duration($0) > 0 }) {
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
    private func setTrim(_ id: UUID, start: Bool, value: Double) {
        guard group.status != .converting, let index = group.items.firstIndex(where: { $0.id == id }) else { return }
        isPlaying = false
        StitchingTimeline.trim(&group.items[index], start: start, to: value)
        seek(id, to: start ? group.items[index].effectiveTrimStart : group.items[index].effectiveTrimEnd)
    }
    private func moveSelection(_ index: Int, by offset: Int) {
        guard group.status != .converting, group.items.indices.contains(index + offset) else { return }
        isPlaying = false
        selectedID = group.items[index].id
        group.items.swapAt(index, index + offset)
        group.lastSortMode = nil
        if group.sequentialNamingEnabled { group.normalizeSequentialNaming() }
    }
}

private struct StitchingSeek: Equatable {
    let id = UUID()
    let time: Double
}

private struct StitchingTimelineClip: View {
    let item: VideoItem
    let selected: Bool
    let scale: Double
    let thumbnailURLs: [URL]
    let onSeek: (Double) -> Void
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
                clipReadouts(width: geometry.size.width)
                    .frame(height: 24)
                    .background(Color.black)
                    .offset(y: 92)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek(max(0, $0.location.x / scale)) })
            .overlay(Rectangle().strokeBorder(selected ? Color.accentColor : Color.secondary, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { handle(start: true) }
            .overlay(alignment: .trailing) { handle(start: false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
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
    let onTime: (Double) -> Void
    let onTogglePlayback: () -> Void
    let onFit: () -> Void
    let onFinished: () -> Void
    let onAssets: ([URL]) -> Void
    @StateObject private var controller: PreviewPlayerController
    @State private var playbackTime: Double = 0
    @State private var finished = false
    @State private var active = false
    @State private var requestedTime: Double

    init(item: Binding<VideoItem>, initialTime: Double, seekRequest: StitchingSeek, isPlaying: Binding<Bool>,
         onTime: @escaping (Double) -> Void, onTogglePlayback: @escaping () -> Void, onFit: @escaping () -> Void, onFinished: @escaping () -> Void, onAssets: @escaping ([URL]) -> Void) {
        _item = item
        self.initialTime = initialTime
        self.seekRequest = seekRequest
        _isPlaying = isPlaying
        self.onTime = onTime
        self.onTogglePlayback = onTogglePlayback
        self.onFit = onFit
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
            let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
            if key.lowercased() == "z", shortcutModifiers == .shift {
                onFit()
                return true
            }
            guard shortcutModifiers.isEmpty, key == " " else { return false }
            onTogglePlayback()
            return true
        }, currentPlaybackTime: $playbackTime)
        .clipped()
        .onAppear {
            active = true
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
            controller.pause()
            controller.seekTo(request.time)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { finished = false; playIfReady() } else { controller.pause() }
        }
        .onChange(of: controller.isReady) { _, ready in
            if ready {
                controller.seekTo(requestedTime)
                playIfReady()
            }
        }
        .onChange(of: controller.errorMessage) { _, message in if message != nil { isPlaying = false } }
        .onChange(of: controller.previewAssets?.thumbnails) { _, urls in if let urls { onAssets(urls) } }
        .onReceive(controller.playbackTimePublisher) { time in
            guard active, controller.isReady, !finished, time.isFinite else { return }
            playbackTime = time
            onTime(time)
            if isPlaying && time >= item.effectiveTrimEnd - 0.02 { finish() }
        }
    }

    private func playIfReady() {
        guard active, isPlaying, controller.isReady else { return }
        controller.pause()
        controller.togglePlayback()
    }
    private func finish() {
        guard active, isPlaying, !finished else { return }
        finished = true
        controller.pause()
        onFinished()
    }
}
