// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit
import OSLog
import ImageIO

struct TrimTimelineView: View {
    @Binding private var trimStart: Double
    @Binding private var trimEnd: Double

    let duration: Double
    let playbackTime: Double
    let thumbnails: [URL]?
    let quickThumbnailImages: [NSImage]
    let nativeWaveformImage: NSImage?
    let channelWaveformImages: [NSImage]
    let channelWaveformLabels: [String]
    let waveformURL: URL?
    let waveformChunks: [WaveformChunk]
    let chunkTotalDuration: Double
    let chapters: [Chapter]
    let showChapters: Bool
    let isLoading: Bool
    let step: Double
    let hideFilmstrip: Bool
    let compactMode: Bool
    let onEditingChanged: (Bool) -> Void
    let onSeek: (Double) -> Void

    // Cached images loaded in background
    @State private var cachedThumbnailImages: [NSImage] = []
    @State private var cachedThumbnailImagesById: [Int: NSImage] = [:]  // For progressive loading
    @State private var cachedWaveformImage: NSImage?
    @State private var cachedChunkImages: [Int: NSImage] = [:]
    @State private var failedChunkLoads: [Int: Int] = [:]  // Track retry counts for failed loads

    // Expected thumbnail count matches PreviewAssetGenerator.thumbnailCount
    private let expectedThumbnailCount = 6

    // Key tracking for range selection (Cmd), range sliding (Shift), and symmetric scaling (Option)
    @State private var isCommandKeyPressed: Bool = false
    @State private var isShiftKeyPressed: Bool = false
    @State private var isOptionKeyPressed: Bool = false

    // Mirrored from TrimHandlesInteractionLayer so the cursor overlay can hold
    // the resize cursor while a handle is being dragged.
    @State private var isDraggingStartHandle: Bool = false
    @State private var isDraggingEndHandle: Bool = false

    private let filmstripHeight: CGFloat = 72
    private let waveformHeight: CGFloat = 66
    private let combinedHeight: CGFloat = 138
    private let compactHeight: CGFloat = 20

    init(
        trimStart: Binding<Double>,
        trimEnd: Binding<Double>,
        duration: Double,
        playbackTime: Double,
        thumbnails: [URL]?,
        quickThumbnailImages: [NSImage] = [],
        nativeWaveformImage: NSImage? = nil,
        channelWaveformImages: [NSImage] = [],
        channelWaveformLabels: [String] = [],
        waveformURL: URL?,
        waveformChunks: [WaveformChunk] = [],
        chunkTotalDuration: Double = 0,
        chapters: [Chapter] = [],
        showChapters: Bool = true,
        isLoading: Bool,
        step: Double = 0.1,
        hideFilmstrip: Bool = false,
        compactMode: Bool = false,
        onEditingChanged: @escaping (Bool) -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
        self._trimStart = trimStart
        self._trimEnd = trimEnd
        self.duration = duration
        self.playbackTime = playbackTime
        self.thumbnails = thumbnails
        self.quickThumbnailImages = quickThumbnailImages
        self.nativeWaveformImage = nativeWaveformImage
        self.channelWaveformImages = channelWaveformImages
        self.channelWaveformLabels = channelWaveformLabels
        self.waveformURL = waveformURL
        self.waveformChunks = waveformChunks
        self.chunkTotalDuration = chunkTotalDuration
        self.chapters = chapters
        self.showChapters = showChapters
        self.isLoading = isLoading
        self.step = step
        self.hideFilmstrip = hideFilmstrip
        self.compactMode = compactMode
        self.onEditingChanged = onEditingChanged
        self.onSeek = onSeek
    }

    // Native sliders expose the custom-drawn timeline to VoiceOver, including
    // standard increment/decrement actions. Keep changes on the same editing
    // callbacks as pointer gestures so playback and trim state stay in sync.
    private var accessibleTimelineControls: some View {
        let timelineDuration = duration.isFinite ? max(0, duration) : 0
        let increment = step.isFinite && step > 0 ? step : 0.1
        let minimumGap = min(increment, timelineDuration)
        return VStack {
            Slider(value: Binding(
                get: { min(max(0, playbackTime), timelineDuration) },
                set: { onSeek(min(max(0, $0), timelineDuration)) }
            ), in: 0...max(timelineDuration, increment), step: increment) {
                Text("Playback position")
            }
            .accessibilityValue("\(playbackTime, specifier: "%.1f") seconds")
            .accessibilityIdentifier("trim.timeline.playbackPosition")

            Slider(value: Binding(
                get: { min(max(0, trimStart), timelineDuration) },
                set: { value in
                    onEditingChanged(true)
                    trimStart = max(0, min(value, trimEnd - minimumGap))
                    onEditingChanged(false)
                }
            ), in: 0...max(timelineDuration, increment), step: increment) {
                Text("Trim start")
            }
            .accessibilityValue("\(trimStart, specifier: "%.1f") seconds")
            .accessibilityIdentifier("trim.timeline.start")

            Slider(value: Binding(
                get: { min(max(0, trimEnd), timelineDuration) },
                set: { value in
                    onEditingChanged(true)
                    trimEnd = min(timelineDuration, max(value, trimStart + minimumGap))
                    onEditingChanged(false)
                }
            ), in: 0...max(timelineDuration, increment), step: increment) {
                Text("Trim end")
            }
            .accessibilityValue("\(trimEnd, specifier: "%.1f") seconds")
            .accessibilityIdentifier("trim.timeline.end")

            if showChapters {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button(chapter.displayTitle(fallbackIndex: index + 1)) {
                        onSeek(min(max(0, chapter.start), timelineDuration))
                    }
                    .accessibilityValue("\(chapter.start, specifier: "%.1f") seconds")
                    .accessibilityIdentifier("trim.timeline.chapter.\(chapter.id)")
                }
            }
        }
        .disabled(timelineDuration <= 0)
    }

// MARK: - Interaction Layer

private struct TrimHandlesInteractionLayer: View {
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let duration: Double
    let step: Double
    let isSymmetricScalingActive: Bool
    let onEditingChanged: (Bool) -> Void
    @Binding var isDraggingStart: Bool
    @Binding var isDraggingEnd: Bool

    // Visual bar is 2px wide (see handleView); this is the hit-test/drag width
    // around it — wide enough that clicks aimed at the handle don't slip
    // through to the scrub layer below.
    static let handleWidth: CGFloat = 30
    private var handleWidth: CGFloat { Self.handleWidth }

    @State private var startInitialValue: Double?
    @State private var endInitialValue: Double?

    // For symmetric scaling, we need to store both initial values
    @State private var symmetricInitialStart: Double?
    @State private var symmetricInitialEnd: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = geometry.size.height
            let startX = position(for: trimStart, width: width)
            let endX = position(for: trimEnd, width: width)
            let clampedStartX = max(0, min(width, startX))
            let clampedEndX = max(0, min(width, endX))

            ZStack(alignment: .topLeading) {
                // Start handle
                handleView(isLeading: true, isActive: isDraggingStart)
                    .frame(width: handleWidth, height: height)
                    .offset(x: clampedStartX - handleWidth / 2)
                    .gesture(startGesture(width: width))
                    .zIndex(isDraggingStart ? 2 : 1)

                // End handle
                handleView(isLeading: false, isActive: isDraggingEnd)
                    .frame(width: handleWidth, height: height)
                    .offset(x: clampedEndX - handleWidth / 2)
                    .gesture(endGesture(width: width))
                    .zIndex(isDraggingEnd ? 2 : 1)
            }
            .allowsHitTesting(duration > 0)
        }
    }

    private func handleView(isLeading: Bool, isActive: Bool) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.blue.opacity(isActive ? 1.0 : 0.8))
                .frame(width: 2)
        }
    }

    private func startGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDraggingStart {
                    isDraggingStart = true
                    startInitialValue = trimStart
                    symmetricInitialStart = trimStart
                    symmetricInitialEnd = trimEnd
                    onEditingChanged(true)
                }

                let baseValue = startInitialValue ?? trimStart
                let deltaValue = delta(for: value.translation.width, width: width)
                let proposed = baseValue + deltaValue
                let snapped = snap(proposed)

                if isSymmetricScalingActive {
                    // Symmetric scaling: move end handle in opposite direction
                    let initialStart = symmetricInitialStart ?? trimStart
                    let initialEnd = symmetricInitialEnd ?? trimEnd

                    var newStart = snap(initialStart + deltaValue)
                    var newEnd = snap(initialEnd - deltaValue)

                    // Clamp to valid bounds
                    newStart = max(0, newStart)
                    newEnd = min(duration, newEnd)

                    // Ensure they don't cross
                    let minGap = max(step, 0.0001)
                    if newStart >= newEnd - minGap {
                        let midpoint = (initialStart + initialEnd) / 2
                        newStart = midpoint - minGap / 2
                        newEnd = midpoint + minGap / 2
                    }

                    trimStart = newStart
                    trimEnd = newEnd
                } else {
                    trimStart = clampStart(snapped)
                }
            }
            .onEnded { _ in
                if isDraggingStart {
                    isDraggingStart = false
                    startInitialValue = nil
                    symmetricInitialStart = nil
                    symmetricInitialEnd = nil
                    onEditingChanged(false)
                }
            }
    }

    private func endGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDraggingEnd {
                    isDraggingEnd = true
                    endInitialValue = trimEnd
                    symmetricInitialStart = trimStart
                    symmetricInitialEnd = trimEnd
                    onEditingChanged(true)
                }

                let baseValue = endInitialValue ?? trimEnd
                let deltaValue = delta(for: value.translation.width, width: width)
                let proposed = baseValue + deltaValue
                let snapped = snap(proposed)

                if isSymmetricScalingActive {
                    // Symmetric scaling: move start handle in opposite direction
                    let initialStart = symmetricInitialStart ?? trimStart
                    let initialEnd = symmetricInitialEnd ?? trimEnd

                    var newStart = snap(initialStart - deltaValue)
                    var newEnd = snap(initialEnd + deltaValue)

                    // Clamp to valid bounds
                    newStart = max(0, newStart)
                    newEnd = min(duration, newEnd)

                    // Ensure they don't cross
                    let minGap = max(step, 0.0001)
                    if newStart >= newEnd - minGap {
                        let midpoint = (initialStart + initialEnd) / 2
                        newStart = midpoint - minGap / 2
                        newEnd = midpoint + minGap / 2
                    }

                    trimStart = newStart
                    trimEnd = newEnd
                } else {
                    trimEnd = clampEnd(snapped)
                }
            }
            .onEnded { _ in
                if isDraggingEnd {
                    isDraggingEnd = false
                    endInitialValue = nil
                    symmetricInitialStart = nil
                    symmetricInitialEnd = nil
                    onEditingChanged(false)
                }
            }
    }

    private func clampStart(_ value: Double) -> Double {
        let maxStart = trimEnd - max(step, 0.0001)
        return min(max(0, value), maxStart)
    }

    private func clampEnd(_ value: Double) -> Double {
        let minEnd = trimStart + max(step, 0.0001)
        return max(min(duration, value), minEnd)
    }

    private func delta(for translation: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(translation / width) * duration
    }

    private func snap(_ value: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(value / duration) * width
    }
}

// MARK: - Timeline Cursor Overlay

/// Single NSTrackingArea-based cursor manager for the entire trim timeline.
/// Centralizes cursor decisions so the trim handles, the scrub layer, and the
/// modifier-key states (Cmd/Shift/Option) can never push competing cursors
/// onto the global NSCursor stack. Uses `NSCursor.set()` rather than
/// `push()`/`pop()` so there is no shared stack to get out of sync.
private struct TimelineCursorOverlay: NSViewRepresentable {
    let startX: CGFloat
    let endX: CGFloat
    let cursorHitWidth: CGFloat          // Tighter than handle drag zone so the
                                         // cursor only changes when near the
                                         // visible handle line.
    let isSymmetricScalingActive: Bool   // Option held
    let isRangeSelectionActive: Bool     // Cmd held
    let isRangeSlidingActive: Bool       // Shift held
    let isDraggingStart: Bool
    let isDraggingEnd: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingNSView()
        applyState(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackingNSView else { return }
        applyState(to: view)
    }

    private func applyState(to view: TrackingNSView) {
        view.update(
            startX: startX,
            endX: endX,
            cursorHitWidth: cursorHitWidth,
            isSymmetric: isSymmetricScalingActive,
            isRangeSelectionActive: isRangeSelectionActive,
            isRangeSlidingActive: isRangeSlidingActive,
            isDraggingStart: isDraggingStart,
            isDraggingEnd: isDraggingEnd
        )
    }

    final class TrackingNSView: NSView {
        private var startX: CGFloat = 0
        private var endX: CGFloat = 0
        private var cursorHitWidth: CGFloat = 12
        private var isSymmetric: Bool = false
        private var isRangeSelectionActive: Bool = false
        private var isRangeSlidingActive: Bool = false
        private var isDraggingStart: Bool = false
        private var isDraggingEnd: Bool = false
        private var trackingArea: NSTrackingArea?
        private var lastMouseLocation: CGPoint?
        private var isInside: Bool = false

        func update(startX: CGFloat, endX: CGFloat, cursorHitWidth: CGFloat,
                    isSymmetric: Bool,
                    isRangeSelectionActive: Bool, isRangeSlidingActive: Bool,
                    isDraggingStart: Bool, isDraggingEnd: Bool) {
            self.startX = startX
            self.endX = endX
            self.cursorHitWidth = cursorHitWidth
            self.isSymmetric = isSymmetric
            self.isRangeSelectionActive = isRangeSelectionActive
            self.isRangeSlidingActive = isRangeSlidingActive
            self.isDraggingStart = isDraggingStart
            self.isDraggingEnd = isDraggingEnd
            applyCursor()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            isInside = true
            lastMouseLocation = convert(event.locationInWindow, from: nil)
            applyCursor()
        }

        override func mouseMoved(with event: NSEvent) {
            isInside = true
            lastMouseLocation = convert(event.locationInWindow, from: nil)
            applyCursor()
        }

        override func mouseExited(with event: NSEvent) {
            isInside = false
            lastMouseLocation = nil
            // Don't reset during an active drag — the gesture keeps the
            // pointer "captured" and we want the resize cursor to persist.
            if !isDraggingStart && !isDraggingEnd {
                NSCursor.arrow.set()
            }
        }

        /// Compute the right cursor for the current state and apply it. Only
        /// touches the cursor when the pointer is inside our bounds (or a
        /// drag is active) so we don't fight neighbouring views for the
        /// cursor when the user mouses off the timeline.
        private func applyCursor() {
            if isDraggingStart {
                (isSymmetric ? NSCursor.resizeLeftRight : NSCursor.resizeLeft).set()
                return
            }
            if isDraggingEnd {
                (isSymmetric ? NSCursor.resizeLeftRight : NSCursor.resizeRight).set()
                return
            }
            guard isInside, let loc = lastMouseLocation else { return }

            let half = cursorHitWidth / 2
            let startDist = abs(loc.x - startX)
            let endDist = abs(loc.x - endX)
            let withinStart = startDist <= half
            let withinEnd = endDist <= half

            // Hover over a handle wins over modifier-key cursors.
            if withinStart && (!withinEnd || startDist <= endDist) {
                (isSymmetric ? NSCursor.resizeLeftRight : NSCursor.resizeLeft).set()
                return
            }
            if withinEnd {
                (isSymmetric ? NSCursor.resizeLeftRight : NSCursor.resizeRight).set()
                return
            }
            if isRangeSelectionActive {
                NSCursor.crosshair.set()
                return
            }
            if isRangeSlidingActive {
                NSCursor.openHand.set()
                return
            }
            NSCursor.arrow.set()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                isInside = false
                lastMouseLocation = nil
                NSCursor.arrow.set()
            }
        }
    }
}

    var body: some View {
        let effectiveHeight = compactMode ? compactHeight : combinedHeight

        return GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // let _ = Logger(subsystem: "com.aagedal.MediaConverter", category: "TrimTimeline").debug("View received waveformURL: \(waveformURL?.path ?? "nil")")
                    // For audio-only files (no thumbnails), show waveform spanning full height
                    // Hide filmstrip when crop mode is active to save space
                    if compactMode {
                        // Compact mode: minimal scrubber bar only
                        Color.clear
                            .frame(height: compactHeight)
                    } else if hideFilmstrip {
                        // Crop mode: waveform spans full height
                        GeometryReader { geo in
                            waveformContent(width: geo.size.width, height: geo.size.height)
                        }
                        .frame(height: combinedHeight)
                    } else if let thumbnails, !thumbnails.isEmpty {
                        filmstripSection
                        waveformSection
                    } else {
                        // Audio-only: waveform spans combined height
                        GeometryReader { geo in
                            waveformContent(width: geo.size.width, height: geo.size.height)
                        }
                        .frame(height: combinedHeight)
                    }
                }

                TrimTimelineOverlay(
                    duration: duration,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    playbackTime: playbackTime
                )
                .allowsHitTesting(false)

                if showChapters && !chapters.isEmpty && duration > 0 {
                    ChapterMarkersLayer(
                        duration: duration,
                        chapters: chapters,
                        compact: compactMode,
                        onSeek: onSeek
                    )
                }

                // Scrubbing layer (behind handles)
                TimelineScrubLayer(
                    duration: duration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    step: step,
                    isRangeSelectionActive: isCommandKeyPressed,
                    isRangeSlidingActive: isShiftKeyPressed,
                    onEditingChanged: onEditingChanged,
                    onSeek: onSeek
                )

                TrimHandlesInteractionLayer(
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    duration: duration,
                    step: step,
                    isSymmetricScalingActive: isOptionKeyPressed,
                    onEditingChanged: onEditingChanged,
                    isDraggingStart: $isDraggingStartHandle,
                    isDraggingEnd: $isDraggingEndHandle
                )

                // Unified cursor overlay: drives the resize / crosshair /
                // open-hand cursors for the whole timeline from one place,
                // so the trim handles and scrub layer never push competing
                // cursors onto the global stack.
                let width = max(geometry.size.width, 1)
                let rawStartX = duration > 0 ? CGFloat(trimStart / duration) * width : 0
                let rawEndX = duration > 0 ? CGFloat(trimEnd / duration) * width : width
                TimelineCursorOverlay(
                    startX: max(0, min(width, rawStartX)),
                    endX: max(0, min(width, rawEndX)),
                    // Cursor zone is intentionally narrower than the drag
                    // hit zone so the resize cursor only appears when the
                    // pointer is right on the handle, while the drag
                    // gesture stays forgiving.
                    cursorHitWidth: 7,
                    isSymmetricScalingActive: isOptionKeyPressed,
                    isRangeSelectionActive: isCommandKeyPressed,
                    isRangeSlidingActive: isShiftKeyPressed,
                    isDraggingStart: isDraggingStartHandle,
                    isDraggingEnd: isDraggingEndHandle
                )
                .allowsHitTesting(false)
            }
        }
        .frame(height: effectiveHeight)
        .accessibilityRepresentation {
            accessibleTimelineControls
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(TimelineKeyTrackerView(isCommandKeyPressed: $isCommandKeyPressed, isShiftKeyPressed: $isShiftKeyPressed, isOptionKeyPressed: $isOptionKeyPressed))
        .onChange(of: thumbnails) { _, newThumbnails in
            // Clear cache when thumbnails array reference changes (e.g., different file selected)
            // Note: Individual thumbnails are loaded progressively in thumbnailSlotView
            if newThumbnails == nil || newThumbnails?.isEmpty == true {
                cachedThumbnailImagesById = [:]
            }
        }
        .onChange(of: waveformChunks) { oldChunks, newChunks in
            // Clear chunk cache when chunks change (different file or audio track selected)
            // We detect a track/file switch by checking if the first chunk's URL changed
            let oldFirstURL = oldChunks.first?.url
            let newFirstURL = newChunks.first?.url

            // Clear cache if:
            // 1. Chunks became empty (file closed)
            // 2. First chunk URL changed (different file or audio track)
            if newChunks.isEmpty || (oldFirstURL != nil && newFirstURL != nil && oldFirstURL != newFirstURL) {
                cachedChunkImages = [:]
                failedChunkLoads = [:]
            }
        }
        .task(id: waveformURL) {
            // Load waveform image in background
            guard let url = waveformURL else {
                cachedWaveformImage = nil
                return
            }
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                        kCGImageSourceShouldCache: false
                      ] as CFDictionary) else {
                    return NSImage(contentsOf: url)
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
            cachedWaveformImage = image
        }
    }

    // MARK: - Sections

    private var filmstripSection: some View {
        GeometryReader { geometry in
            filmstripContent(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: filmstripHeight)
    }

    private var waveformSection: some View {
        GeometryReader { geometry in
            waveformContent(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: waveformHeight)
    }

    // MARK: - Content Builders

    @ViewBuilder
    private func filmstripContent(width: CGFloat, height: CGFloat) -> some View {
        // Progressive loading: show expected slots and fill with images as they become available
        if thumbnails != nil || isLoading {
            progressiveFilmstripContent(width: width, height: height)
        } else if !quickThumbnailImages.isEmpty {
            // Fallback to quick thumbnails when no filmstrip available
            HStack(spacing: 0) {
                ForEach(Array(quickThumbnailImages.enumerated()), id: \.0) { index, image in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(max(1, quickThumbnailImages.count)), height: height)
                        .clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.25))
        } else {
            placeholderSection(systemName: "film", text: "No thumbnails")
        }
    }

    @ViewBuilder
    private func progressiveFilmstripContent(width: CGFloat, height: CGFloat) -> some View {
        let thumbWidth = width / CGFloat(expectedThumbnailCount)
        HStack(spacing: 0) {
            ForEach(0..<expectedThumbnailCount, id: \.self) { index in
                thumbnailSlotView(index: index, slotWidth: thumbWidth, height: height)
            }
        }
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private func thumbnailSlotView(index: Int, slotWidth: CGFloat, height: CGFloat) -> some View {
        // Check if we have this thumbnail URL
        let thumbURL: URL? = {
            guard let urls = thumbnails, index < urls.count else { return nil }
            return urls[index]
        }()

        if let image = cachedThumbnailImagesById[index] {
            // Thumbnail is loaded - display it
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: slotWidth, height: height)
                .clipped()
        } else if let url = thumbURL {
            // Thumbnail exists but not loaded - show placeholder and load async
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: slotWidth, height: height)
                .task {
                    await loadThumbnailImage(at: index, from: url)
                }
        } else {
            // Thumbnail not yet generated - show orange placeholder
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: slotWidth, height: height)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                )
        }
    }

    private func loadThumbnailImage(at index: Int, from url: URL) async {
        guard cachedThumbnailImagesById[index] == nil else { return }

        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else {
                return NSImage(contentsOf: url)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value

        if let image = image {
            cachedThumbnailImagesById[index] = image
        }
    }

    @ViewBuilder
    private func waveformContent(width: CGFloat, height: CGFloat) -> some View {
        if !channelWaveformImages.isEmpty {
            // Per-channel waveform — one waveform per audio channel, stacked vertically
            perChannelWaveformContent(width: width, height: height)
        } else if let image = nativeWaveformImage {
            // Native waveform — direct NSImage, no disk I/O (mono fallback)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else if !waveformChunks.isEmpty || chunkTotalDuration > 0 || duration > 600 {
            // Fallback to chunked waveform (legacy/cached)
            chunkedWaveformContent(width: width, height: height)
        } else if let image = cachedWaveformImage {
            // Fallback to legacy single-image waveform
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
                .id(waveformURL) // Force redraw when URL changes
        } else if waveformURL != nil {
            // Show placeholder while loading legacy waveform
            placeholderSection(
                systemName: "waveform",
                text: "Loading waveform…"
            )
            .frame(width: width, height: height)
        } else {
            placeholderSection(
                systemName: "waveform",
                text: isLoading ? "Generating waveform…" : "Waveform unavailable"
            )
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func perChannelWaveformContent(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(channelWaveformImages.enumerated()), id: \.offset) { index, image in
                ZStack(alignment: .leading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)

                    // Channel label (top-left)
                    if index < channelWaveformLabels.count {
                        Text(channelWaveformLabels[index])
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                            .padding(.leading, 4)
                            .padding(.top, 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // Subtle separator line between channels
                    if index < channelWaveformImages.count - 1 {
                        VStack {
                            Spacer()
                            Rectangle()
                                .fill(Color(white: 0.2))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// Expected number of chunks based on duration
    /// Always uses the video's actual duration (not chunkTotalDuration from assets)
    /// to ensure consistent chunk count during progressive loading
    private var expectedChunkCount: Int {
        guard duration > 0 else { return 0 }
        return Int(ceil(duration / 600.0))  // 10-minute chunks
    }

    /// Calculate proportional width for a chunk
    /// Always uses the video's actual duration for consistent positioning
    private func chunkWidth(for index: Int, totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }

        // Each chunk represents up to 600 seconds (10 minutes)
        let chunkDurationSeconds: Double = 600.0
        let startTime = Double(index) * chunkDurationSeconds
        let endTime = min(startTime + chunkDurationSeconds, duration)
        let thisChunkDuration = endTime - startTime

        return CGFloat(thisChunkDuration / duration) * totalWidth
    }

    @ViewBuilder
    private func chunkedWaveformContent(width: CGFloat, height: CGFloat) -> some View {
        let chunkCount = expectedChunkCount
        if chunkCount > 0 {
            HStack(spacing: 0) {
                ForEach(0..<chunkCount, id: \.self) { index in
                    chunkView(index: index, totalWidth: width, height: height)
                }
            }
            .frame(width: width, height: height)
        } else {
            placeholderSection(
                systemName: "waveform",
                text: isLoading ? "Generating waveform…" : "Waveform unavailable"
            )
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func chunkView(index: Int, totalWidth: CGFloat, height: CGFloat) -> some View {
        let chunk = waveformChunks.first { $0.id == index }
        let chunkW = chunkWidth(for: index, totalWidth: totalWidth)

        if chunk != nil, let image = cachedChunkImages[index] {
            // Chunk is loaded and cached - display it
            // Resize to fill the exact frame dimensions
            Image(nsImage: image)
                .resizable()
                .frame(width: chunkW, height: height)
        } else if let chunk = chunk {
            // Chunk exists but image not loaded yet - show gray placeholder and load async
            // Use task(id:) with chunk count to retry when new chunks arrive
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: chunkW, height: height)
                .task(id: waveformChunks.count) {
                    await loadChunkImage(chunk)
                }
        } else {
            // Chunk not yet generated - show orange placeholder
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: chunkW, height: height)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                )
        }
    }

    private func loadChunkImage(_ chunk: WaveformChunk) async {
        guard cachedChunkImages[chunk.id] == nil else { return }

        // Don't retry more than 3 times
        let retryCount = failedChunkLoads[chunk.id] ?? 0
        guard retryCount < 3 else { return }

        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            // Check if file exists and has non-zero size (not still being written)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: chunk.url.path),
                  let fileSize = attributes[.size] as? Int,
                  fileSize > 100 else {  // PNG header is ~100 bytes minimum
                return nil
            }

            guard let imageSource = CGImageSourceCreateWithURL(chunk.url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else {
                return NSImage(contentsOf: chunk.url)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value

        if let image = image {
            cachedChunkImages[chunk.id] = image
            failedChunkLoads.removeValue(forKey: chunk.id)
        } else {
            // Track failed load for retry limiting
            failedChunkLoads[chunk.id] = retryCount + 1
        }
    }

    private func placeholderSection(systemName: String, text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.15))
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func placeholderOverlay(systemName: String? = nil) -> some View {
        ZStack {
            Color.gray.opacity(0.25)
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            } else if isLoading {
                ProgressView().progressViewStyle(.circular)
            }
        }
    }
}

// MARK: - Overlay

private struct TrimTimelineOverlay: View {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playbackTime: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let startX = width * clampedNormalize(trimStart, duration: duration)
            let endX = width * clampedNormalize(trimEnd, duration: duration, defaultValue: 1)
            let playheadX = width * clampedNormalize(playbackTime, duration: duration)

            ZStack {
                Path { path in
                    if startX > 0 {
                        path.addRect(CGRect(x: 0, y: 0, width: startX, height: height))
                    }
                    if endX < width {
                        path.addRect(CGRect(x: endX, y: 0, width: width - endX, height: height))
                    }
                }
                .fill(Color.black.opacity(0.65))

                // Blue overlay removed for clearer thumbnail visibility
                // Orange overlay for ungenerated chunks is handled by ChunkedPreviewOverlay

                Path { path in
                    let clampedStart = min(max(startX, 0), width)
                    let clampedEnd = min(max(endX, clampedStart), width)
                    path.addRect(CGRect(x: clampedStart, y: 0, width: clampedEnd - clampedStart, height: height))
                }
                .stroke(Color.blue.opacity(0.4), lineWidth: 1)

                Path { path in
                    let clampedPlayhead = min(max(playheadX, 0), width)
                    path.move(to: CGPoint(x: clampedPlayhead, y: 0))
                    path.addLine(to: CGPoint(x: clampedPlayhead, y: height))
                }
                .stroke(Color(red: 1.0, green: 0.071, blue: 0.361), lineWidth: 2) // #FF125C
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 0)
            }
        }
    }

    private func clampedNormalize(_ value: Double, duration: Double, defaultValue: Double = 0) -> CGFloat {
        guard duration > 0 else { return CGFloat(defaultValue) }
        let normalized = value / duration
        return CGFloat(min(max(normalized, 0), 1))
    }
}

// MARK: - Chapter Markers

private struct ChapterMarkersLayer: View {
    let duration: Double
    let chapters: [Chapter]
    let compact: Bool
    let onSeek: (Double) -> Void

    private let tickColor = Color(red: 1.0, green: 0.85, blue: 0.2)
    private let tickWidth: CGFloat = 1.5
    private let hoverSlop: CGFloat = 6  // Extra hit width on each side of the tick
    @State private var hoveredChapterID: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = geometry.size.height

            ZStack(alignment: .topLeading) {
                // Always-visible ticks with invisible wide hit targets
                ForEach(chapters) { chapter in
                    chapterTick(chapter: chapter, width: width, height: height)
                }

                // Single floating label for the hovered chapter — drawn last so it
                // sits on top of every tick without collision resolution or stacking.
                if let hoveredID = hoveredChapterID,
                   let hovered = chapters.first(where: { $0.id == hoveredID }) {
                    hoverLabel(chapter: hovered, width: width)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterTick(chapter: Chapter, width: CGFloat, height: CGFloat) -> some View {
        let x = position(for: chapter.start, width: width)
        let isHovered = hoveredChapterID == chapter.id
        let hitWidth = tickWidth + hoverSlop * 2

        ZStack {
            // Visual tick — thin, non-interactive, always on.
            Rectangle()
                .fill(tickColor.opacity(isHovered ? 1.0 : 0.85))
                .frame(width: tickWidth, height: height)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
                .allowsHitTesting(false)

            // Wider invisible hit target around the tick for hover + click.
            Color.clear
                .frame(width: hitWidth, height: height)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredChapterID = chapter.id
                    } else if hoveredChapterID == chapter.id {
                        hoveredChapterID = nil
                    }
                }
                .onTapGesture {
                    onSeek(chapter.start)
                }
        }
        .frame(width: hitWidth, height: height, alignment: .center)
        .offset(x: x - hitWidth / 2, y: 0)
    }

    @ViewBuilder
    private func hoverLabel(chapter: Chapter, width: CGFloat) -> some View {
        let index = (chapters.firstIndex(where: { $0.id == chapter.id }) ?? 0) + 1
        let title = chapter.displayTitle(fallbackIndex: index)
        let labelText = "\(title) · \(formatTime(chapter.start))"
        let x = position(for: chapter.start, width: width)

        HoverLabelView(text: labelText, preferredX: x, containerWidth: width, compact: compact)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let clamped = min(max(value, 0), duration)
        return CGFloat(clamped / duration) * width
    }
}

/// Floating label shown above the hovered chapter tick. Self-measures and clamps
/// its horizontal position so it stays inside the timeline at the edges.
private struct HoverLabelView: View {
    let text: String
    let preferredX: CGFloat
    let containerWidth: CGFloat
    let compact: Bool

    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.85))
            )
            .fixedSize()
            .padding(.top, compact ? 1 : 2)
            .allowsHitTesting(false)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measuredWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            measuredWidth = newValue
                        }
                }
            )
            .offset(x: clampedLeadingX)
    }

    private var clampedLeadingX: CGFloat {
        let half = measuredWidth / 2
        let desired = preferredX - half
        let maxX = max(0, containerWidth - measuredWidth - 2)
        return min(max(2, desired), maxX)
    }
}

// MARK: - Scrubbing Layer

private struct TimelineScrubLayer: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let step: Double
    let isRangeSelectionActive: Bool
    let isRangeSlidingActive: Bool
    let onEditingChanged: (Bool) -> Void
    let onSeek: (Double) -> Void

    private let handleWidth: CGFloat = 12  // Matches handle visual width
    private let handleMargin: CGFloat = 1  // Minimal margin so playhead can reach near trim handles

    @State private var isScrubbing = false
    @State private var isRangeSelecting = false
    @State private var rangeStartTime: Double?

    // Range sliding state
    @State private var isRangeSliding = false
    @State private var slideInitialTrimStart: Double?
    @State private var slideInitialTrimEnd: Double?
    @State private var slideInitialClickTime: Double?

    // Drag-seek throttling: coalesce rapid onChanged events so we don't flood the
    // underlying player (MPV/VLC fallback formats are especially sensitive).
    // Seeks stay frame-accurate; we just cap the rate.
    @State private var lastSeekFireTime: Date = .distantPast
    @State private var pendingSeekTime: Double?
    @State private var pendingSeekTask: Task<Void, Never>?
    private let seekThrottleInterval: TimeInterval = 0.04  // ~25 Hz

    private func throttledSeek(_ time: Double) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSeekFireTime)
        if elapsed >= seekThrottleInterval {
            pendingSeekTask?.cancel()
            pendingSeekTask = nil
            pendingSeekTime = nil
            lastSeekFireTime = now
            onSeek(time)
            return
        }
        pendingSeekTime = time
        guard pendingSeekTask == nil else { return }
        let delay = seekThrottleInterval - elapsed
        pendingSeekTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let t = pendingSeekTime else { return }
            pendingSeekTask = nil
            pendingSeekTime = nil
            lastSeekFireTime = Date()
            onSeek(t)
        }
    }

    private func flushPendingSeek() {
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        if let t = pendingSeekTime {
            pendingSeekTime = nil
            lastSeekFireTime = Date()
            onSeek(t)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }

                            let width = geometry.size.width
                            let clickX = value.location.x
                            let clickTime = timeForPosition(clickX, width: width)

                            // Range selection mode when R is held
                            if isRangeSelectionActive {
                                if !isRangeSelecting {
                                    // Start of range selection - set in-point
                                    isRangeSelecting = true
                                    onEditingChanged(true)
                                    let snapped = snap(clickTime)
                                    rangeStartTime = snapped
                                    trimStart = max(0, snapped)
                                    onSeek(trimStart)
                                    lastSeekFireTime = Date()
                                } else {
                                    // During range selection - update out-point preview
                                    let snapped = snap(clickTime)
                                    // Temporarily update end to show visual feedback
                                    let start = rangeStartTime ?? trimStart
                                    if snapped >= start {
                                        trimEnd = min(duration, snapped)
                                    } else {
                                        // Dragging before start - swap preview
                                        trimStart = max(0, snapped)
                                        trimEnd = min(duration, start)
                                    }
                                    throttledSeek(snapped)
                                }
                                return
                            }

                            // Check handle proximity for scrubbing
                            let startX = position(for: trimStart, width: width)
                            let endX = position(for: trimEnd, width: width)
                            let nearStartHandle = abs(clickX - startX) < (handleWidth / 2 + handleMargin)
                            let nearEndHandle = abs(clickX - endX) < (handleWidth / 2 + handleMargin)

                            // Range sliding mode when Shift is held and click is between trim points
                            if isRangeSlidingActive && !nearStartHandle && !nearEndHandle {
                                let isBetweenTrimPoints = clickTime > trimStart && clickTime < trimEnd

                                if !isRangeSliding && isBetweenTrimPoints {
                                    // Start of range sliding
                                    isRangeSliding = true
                                    onEditingChanged(true)
                                    slideInitialTrimStart = trimStart
                                    slideInitialTrimEnd = trimEnd
                                    slideInitialClickTime = clickTime
                                } else if isRangeSliding {
                                    // During range sliding - move both points by the same delta
                                    guard let initialStart = slideInitialTrimStart,
                                          let initialEnd = slideInitialTrimEnd,
                                          let initialClick = slideInitialClickTime else { return }

                                    let delta = clickTime - initialClick
                                    let rangeDuration = initialEnd - initialStart

                                    // Calculate new positions
                                    var newStart = initialStart + delta
                                    var newEnd = initialEnd + delta

                                    // Clamp to valid bounds
                                    if newStart < 0 {
                                        newStart = 0
                                        newEnd = rangeDuration
                                    }
                                    if newEnd > duration {
                                        newEnd = duration
                                        newStart = duration - rangeDuration
                                    }

                                    // Snap to grid
                                    trimStart = snap(max(0, newStart))
                                    trimEnd = snap(min(duration, newEnd))

                                    // Seek to current position within the range
                                    throttledSeek(clickTime)
                                }
                                return
                            }

                            // Normal scrubbing mode - skip if near handles
                            // But allow scrubbing at the extreme edges (no trim set)
                            let startAtEdge = trimStart <= 0
                            let endAtEdge = trimEnd >= duration
                            if (nearStartHandle && !startAtEdge) || (nearEndHandle && !endAtEdge) {
                                return
                            }

                            if !isScrubbing {
                                isScrubbing = true
                            }
                            throttledSeek(clickTime)
                        }
                        .onEnded { value in
                            flushPendingSeek()

                            if isRangeSelecting {
                                // End of range selection - finalize out-point
                                let width = geometry.size.width
                                let clickX = value.location.x
                                let time = timeForPosition(clickX, width: width)
                                let snapped = snap(time)
                                let start = rangeStartTime ?? trimStart

                                // Ensure start < end, swap if necessary
                                if snapped >= start {
                                    trimStart = max(0, start)
                                    trimEnd = min(duration, snapped)
                                } else {
                                    trimStart = max(0, snapped)
                                    trimEnd = min(duration, start)
                                }

                                onEditingChanged(false)
                            }

                            if isRangeSliding {
                                onEditingChanged(false)
                            }

                            // Always reset all drag states to prevent stuck modes
                            isRangeSelecting = false
                            rangeStartTime = nil
                            isRangeSliding = false
                            slideInitialTrimStart = nil
                            slideInitialTrimEnd = nil
                            slideInitialClickTime = nil
                            isScrubbing = false
                        }
                )
        }
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(value / duration) * width
    }

    private func timeForPosition(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let fraction = Double(max(0, min(x, width)) / width)
        return max(0, min(duration, duration * fraction))
    }

    private func snap(_ value: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}

// MARK: - Timeline Key Tracker

/// Tracks modifier keys: Command (range selection), Shift (range sliding), Option (symmetric scaling)
private struct TimelineKeyTrackerView: NSViewRepresentable {
    @Binding var isCommandKeyPressed: Bool
    @Binding var isShiftKeyPressed: Bool
    @Binding var isOptionKeyPressed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TimelineKeyTrackingNSView()
        view.isCommandKeyPressed = $isCommandKeyPressed
        view.isShiftKeyPressed = $isShiftKeyPressed
        view.isOptionKeyPressed = $isOptionKeyPressed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }

    @MainActor
    class TimelineKeyTrackingNSView: NSView {
        var isCommandKeyPressed: Binding<Bool>?
        var isShiftKeyPressed: Binding<Bool>?
        var isOptionKeyPressed: Binding<Bool>?

        private var flagsChangedMonitor: Any? {
            willSet {
                if let oldMonitor = flagsChangedMonitor {
                    NSEvent.removeMonitor(oldMonitor)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window != nil {
                // Initialize from current modifier state immediately
                // This prevents "sticky" modifiers when CMD+T opens the view with CMD held
                let currentFlags = NSEvent.modifierFlags
                isCommandKeyPressed?.wrappedValue = currentFlags.contains(.command)
                isShiftKeyPressed?.wrappedValue = currentFlags.contains(.shift)
                isOptionKeyPressed?.wrappedValue = currentFlags.contains(.option)

                // Monitor modifier flags for Command, Shift, and Option
                // Update synchronously on main thread to avoid race conditions with gesture state
                flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    self?.isCommandKeyPressed?.wrappedValue = event.modifierFlags.contains(.command)
                    self?.isShiftKeyPressed?.wrappedValue = event.modifierFlags.contains(.shift)
                    self?.isOptionKeyPressed?.wrappedValue = event.modifierFlags.contains(.option)
                    return event
                }
            } else {
                flagsChangedMonitor = nil
            }
        }

        override func removeFromSuperview() {
            // Clean up monitors before removal
            flagsChangedMonitor = nil
            super.removeFromSuperview()
        }
    }
}
