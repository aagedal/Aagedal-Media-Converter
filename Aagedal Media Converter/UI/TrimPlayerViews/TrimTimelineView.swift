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

struct TrimTimelineView: View {
    @Binding private var trimStart: Double
    @Binding private var trimEnd: Double

    let duration: Double
    let playbackTime: Double
    let thumbnails: [URL]?
    let quickThumbnailImages: [NSImage]
    let waveformURL: URL?
    let isLoading: Bool
    let fallbackPreviewRange: ClosedRange<Double>?
    let loadedChunks: Set<Int>?
    let step: Double
    let onEditingChanged: (Bool) -> Void
    let onSeek: (Double) -> Void

    private let filmstripHeight: CGFloat = 72
    private let waveformHeight: CGFloat = 36
    private let combinedHeight: CGFloat = 108
    private let chunkDuration: TimeInterval = 5.0

    init(
        trimStart: Binding<Double>,
        trimEnd: Binding<Double>,
        duration: Double,
        playbackTime: Double,
        thumbnails: [URL]?,
        quickThumbnailImages: [NSImage] = [],
        waveformURL: URL?,
        isLoading: Bool,
        fallbackPreviewRange: ClosedRange<Double>? = nil,
        loadedChunks: Set<Int>? = nil,
        step: Double = 0.1,
        onEditingChanged: @escaping (Bool) -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
        self._trimStart = trimStart
        self._trimEnd = trimEnd
        self.duration = duration
        self.playbackTime = playbackTime
        self.thumbnails = thumbnails
        self.quickThumbnailImages = quickThumbnailImages
        self.waveformURL = waveformURL
        self.isLoading = isLoading
        self.fallbackPreviewRange = fallbackPreviewRange
        self.loadedChunks = loadedChunks
        self.step = step
        self.onEditingChanged = onEditingChanged
        self.onSeek = onSeek
    }

// MARK: - Interaction Layer

private struct TrimHandlesInteractionLayer: View {
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let duration: Double
    let step: Double
    let onEditingChanged: (Bool) -> Void

    private let handleWidth: CGFloat = 16

    @State private var startInitialValue: Double?
    @State private var endInitialValue: Double?
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

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
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(isActive ? 0.55 : 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.9 : 0.6), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 0)
            .overlay(
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.5))
                    .rotationEffect(.degrees(isLeading ? -90 : 90))
            )
    }

    private func startGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDraggingStart {
                    isDraggingStart = true
                    startInitialValue = trimStart
                    onEditingChanged(true)
                }

                let baseValue = startInitialValue ?? trimStart
                let proposed = baseValue + delta(for: value.translation.width, width: width)
                let snapped = snap(proposed)
                trimStart = clampStart(snapped)
            }
            .onEnded { _ in
                if isDraggingStart {
                    isDraggingStart = false
                    startInitialValue = nil
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
                    onEditingChanged(true)
                }

                let baseValue = endInitialValue ?? trimEnd
                let proposed = baseValue + delta(for: value.translation.width, width: width)
                let snapped = snap(proposed)
                trimEnd = clampEnd(snapped)
            }
            .onEnded { _ in
                if isDraggingEnd {
                    isDraggingEnd = false
                    endInitialValue = nil
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // For audio-only files (no thumbnails), show waveform spanning full height
                    if let thumbnails, !thumbnails.isEmpty {
                        filmstripSection
                        waveformSection
                    } else {
                        // Audio-only: waveform spans combined height
                        GeometryReader { geo in
                            waveformContent(width: geo.size.width)
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
                
                // Preview range overlay (shows unavailable chunks in orange)
                if fallbackPreviewRange != nil {
                    ChunkedPreviewOverlay(
                        duration: duration,
                        loadedChunks: loadedChunks ?? [],
                        chunkDuration: chunkDuration
                    )
                    .allowsHitTesting(false)
                }
                
                // Scrubbing layer (behind handles)
                TimelineScrubLayer(
                    duration: duration,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    onSeek: onSeek
                )
                
                TrimHandlesInteractionLayer(
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    duration: duration,
                    step: step,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .frame(height: combinedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            waveformContent(width: geometry.size.width)
        }
        .frame(height: waveformHeight)
    }

    // MARK: - Content Builders

    @ViewBuilder
    private func filmstripContent(width: CGFloat, height: CGFloat) -> some View {
        if let thumbnails, !thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(thumbnails.enumerated()), id: \.0) { _, url in
                    Group {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            placeholderOverlay(systemName: "film")
                        }
                    }
                    .frame(width: width / CGFloat(thumbnails.count), height: height)
                    .clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.25))
        } else if !quickThumbnailImages.isEmpty {
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
            placeholderSection(systemName: "film", text: isLoading ? "Generating thumbnails…" : "No thumbnails")
        }
    }

    @ViewBuilder
    private func waveformContent(width: CGFloat) -> some View {
        if let waveformURL {
            Group {
                if let image = NSImage(contentsOf: waveformURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .background(Color.black.opacity(0.35))
                } else {
                    placeholderSection(
                        systemName: "waveform",
                        text: isLoading ? "Generating waveform…" : "Waveform unavailable"
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
        } else {
            placeholderSection(
                systemName: "waveform",
                text: isLoading ? "Generating waveform…" : "Waveform unavailable"
            )
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
                .stroke(Color.white.opacity(0.25), lineWidth: 1)

                Path { path in
                    let clampedPlayhead = min(max(playheadX, 0), width)
                    path.move(to: CGPoint(x: clampedPlayhead, y: 0))
                    path.addLine(to: CGPoint(x: clampedPlayhead, y: height))
                }
                .stroke(Color.white, lineWidth: 2)
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

// MARK: - Scrubbing Layer

private struct TimelineScrubLayer: View {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let onSeek: (Double) -> Void
    
    private let handleWidth: CGFloat = 20
    private let handleMargin: CGFloat = 4
    
    @State private var isScrubbing = false
    
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            
                            // Check if click is near a handle - if so, don't scrub
                            let width = geometry.size.width
                            let startX = position(for: trimStart, width: width)
                            let endX = position(for: trimEnd, width: width)
                            let clickX = value.location.x
                            
                            let nearStartHandle = abs(clickX - startX) < (handleWidth / 2 + handleMargin)
                            let nearEndHandle = abs(clickX - endX) < (handleWidth / 2 + handleMargin)
                            
                            if nearStartHandle || nearEndHandle {
                                return
                            }
                            
                            if !isScrubbing {
                                isScrubbing = true
                            }
                            let time = timeForPosition(clickX, width: width)
                            onSeek(time)
                        }
                        .onEnded { _ in
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
}

// MARK: - Chunked Preview Overlay

private struct ChunkedPreviewOverlay: View {
    let duration: Double
    let loadedChunks: Set<Int>
    let chunkDuration: TimeInterval
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let totalChunks = Int(ceil(duration / chunkDuration))
            
            // Show orange overlay for unloaded chunks
            ForEach(0..<totalChunks, id: \.self) { chunkIndex in
                if !loadedChunks.contains(chunkIndex) {
                    let chunkStart = Double(chunkIndex) * chunkDuration
                    let chunkEnd = min(Double(chunkIndex + 1) * chunkDuration, duration)
                    
                    let startX = position(for: chunkStart, width: width)
                    let endX = position(for: chunkEnd, width: width)
                    let chunkWidth = endX - startX
                    
                    Rectangle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: chunkWidth)
                        .position(x: startX + chunkWidth / 2, y: geometry.size.height / 2)
                }
            }
        }
    }
    
    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(value / duration) * width
    }
}
