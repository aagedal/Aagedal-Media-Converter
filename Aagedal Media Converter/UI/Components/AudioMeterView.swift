// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Real-time audio level meter visualization
struct AudioMeterView: View {
    let levels: UniversalAudioMeterService.AudioLevels
    let meterHeight: CGFloat
    let chrome: Bool

    private let meterWidth: CGFloat = 12

    init(
        levels: UniversalAudioMeterService.AudioLevels,
        meterHeight: CGFloat = 180,
        showLabels: Bool = true,
        chrome: Bool = true
    ) {
        self.levels = levels
        self.meterHeight = meterHeight
        self.chrome = chrome
    }

    var body: some View {
        HStack(spacing: chrome ? 4 : 1) {
            if chrome {
                levelScale
            }

            meterBar(level: levels.leftChannel, label: "L", height: meterHeight)
            meterBar(level: levels.rightChannel, label: "R", height: meterHeight)
        }
        .padding(chrome ? 8 : 0)
        .background(
            Group {
                if chrome {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                }
            }
        )
        .overlay(
            Group {
                if chrome {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                }
            }
        )
    }
    
    @ViewBuilder
    private func meterBar(level: Float, label: String, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if chrome {
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            LevelBar(level: level, range: -50...0, height: height)
                .frame(width: chrome ? meterWidth : 4)
        }
    }
    
    @ViewBuilder
    private var levelScale: some View {
        VStack(spacing: 0) {
            Text("")
                .font(.system(size: 6))
                .frame(height: 10)
            
            VStack(alignment: .trailing, spacing: 0) {
                dbLabel("0")
                Spacer()
                dbLabel("-10")
                Spacer()
                dbLabel("-20")
                Spacer()
                dbLabel("-30")
                Spacer()
                dbLabel("-40")
                Spacer()
                dbLabel("-50")
            }
            .frame(height: meterHeight)
        }
    }
    
    private func dbLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
    }
}

/// Individual level bar component
private struct LevelBar: View {
    let level: Float // dB value, typically -50 to 0
    let range: ClosedRange<Float>
    let height: CGFloat
    
    init(level: Float, range: ClosedRange<Float> = -50...0, height: CGFloat = 180) {
        self.level = level
        self.range = range
        self.height = height
    }
    
    private var normalizedLevel: CGFloat {
        // Convert dB range to 0.0-1.0
        let dbRange = range.upperBound - range.lowerBound
        let clamped = max(range.lowerBound, min(level, range.upperBound))
        return CGFloat((clamped - range.lowerBound) / dbRange)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                
                // Gradient Source (Full Height, Stationary)
                Rectangle()
                    .fill(levelGradient)
                    .mask(
                        // Mask reveals gradient from bottom up
                        Rectangle()
                            .frame(height: geometry.size.height * normalizedLevel)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    )
                
                // Peak markers at specific dB levels
                VStack(spacing: 0) {
                    peakMarker(at: 0.0) // 0 dB
                    Spacer()
                    peakMarker(at: 0.2) // -10 dB (for -50 to 0 range)
                    Spacer()
                    peakMarker(at: 0.4) // -20 dB
                    Spacer()
                    peakMarker(at: 0.6) // -30 dB
                    Spacer()
                    peakMarker(at: 0.8) // -40 dB
                }
            }
            .clipShape(Rectangle())
        }
        .frame(height: height)
    }
    
    private var levelGradient: LinearGradient {
        // Top (0 dB) = Red
        // Bottom (-50 dB) = Green
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.red, location: 0.0),      // 0 dB (Top)
                .init(color: Color.red, location: 0.2),      // -10 dB
                .init(color: Color.yellow, location: 0.4),   // -20 dB
                .init(color: Color.green, location: 0.6),    // -30 dB
                .init(color: Color.green, location: 1.0)     // -50 dB (Bottom)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private func peakMarker(at position: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.3))
            .frame(height: 1)
    }
}

// MARK: - Previews

#Preview("Active Audio") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: UniversalAudioMeterService.AudioLevels(
                leftChannel: -12.0,
                rightChannel: -8.0,
                peak: -8.0
            ),
            showLabels: false
        )
    }
}

#Preview("With Labels") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: UniversalAudioMeterService.AudioLevels(
                leftChannel: -20.0,
                rightChannel: -18.0,
                peak: -18.0
            ),
            showLabels: true
        )
    }
}

#Preview("Silence") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: .silence,
            showLabels: false
        )
    }
}

/// Source-channel peaks at the playhead. This never enables system-audio capture.
struct SourceAudioMeterPanel: View {
    @ObservedObject var controller: PreviewPlayerController
    let item: VideoItem
    let time: Double
    let isPlaying: Bool
    let onSelectTrack: (Int) -> Void
    @State private var metadata: VideoMetadata?
    @State private var chunks: [SourceAudioMeterRequest: SourceAudioMeterChunk] = [:]
    @State private var cache = SourceAudioMeterCache()
    @State private var isLoading = false
    @State private var failed = false

    private var streamIndex: Int? {
        let position = controller.selectedAudioTrackOrderIndex
        guard controller.audioTrackOptions.indices.contains(position) else { return nil }
        return controller.audioTrackOptions[position].streamIndex
    }

    private var streams: [VideoMetadata.AudioStream] { (item.metadata ?? metadata)?.audioStreams ?? [] }
    private var groups: [SourceAudioMeterGroup] {
        SourceAudioMeterGroup.groups(channelCounts: streams.map(\.channels))
    }
    private var selectedGroup: SourceAudioMeterGroup? {
        guard let streamIndex else { return nil }
        return groups.first { $0.tracks.contains(streamIndex) }
    }
    private var stream: VideoMetadata.AudioStream? {
        guard let streamIndex, streams.indices.contains(streamIndex) else { return nil }
        return streams[streamIndex]
    }
    private var requests: [SourceAudioMeterRequest] {
        guard let selectedGroup, time.isFinite, time >= 0 else { return [] }
        return selectedGroup.tracks.compactMap { index in
            guard let channels = streams[index].channels, channels > 0 else { return nil }
            return SourceAudioMeterRequest(url: item.url, track: index, channels: channels,
                                           window: Int(time / SourceAudioMeterRequest.windowDuration))
        }
    }
    private var labels: [String] {
        if let group = selectedGroup, group.isMultiMono {
            return group.tracks.map { track in
                controller.audioTrackOptions.first { $0.streamIndex == track }?.title ?? "Track \(track + 1)"
            }
        }
        guard let channels = stream?.channels else { return [] }
        return Array(NativeWaveformRenderer.channelNames(count: channels, layout: stream?.channelLayout).prefix(8))
    }
    private var levels: [Float] {
        guard isPlaying else { return Array(repeating: -60, count: labels.count) }
        return requests.flatMap { request in
            chunks[request]?.levels(at: time) ?? Array(repeating: -60, count: request.displayedChannels)
        }
    }
    private func selectTrack(_ track: Int) {
        if let option = controller.audioTrackOptions.first(where: { $0.streamIndex == track }) {
            onSelectTrack(option.position)
        }
    }
    private func barLabel(_ index: Int) -> String {
        if let group = selectedGroup, group.isMultiMono { return "\(group.tracks[index] + 1)" }
        return labels.count == 2 ? (index == 0 ? "L" : "R") : "\(index + 1)"
    }
    private func groupTitle(_ group: SourceAudioMeterGroup) -> String {
        if group.isMultiMono { return String(localized: "Mono tracks (\(group.tracks.count))") }
        return controller.audioTrackOptions.first { $0.streamIndex == group.id }?.title ?? "Track \(group.id + 1)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Source dBFS").font(.caption)
                .help("Source sample peaks before playback volume and speaker downmixing. Mono tracks are shown together; click a mono meter to choose the preview track.")
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 4) {
                    VStack {
                        Text("0")
                        Spacer()
                        Text("−20")
                        Spacer()
                        Text("−40")
                        Spacer()
                        Text("−60")
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        VStack(spacing: 3) {
                            LevelBar(level: levels.indices.contains(index) ? levels[index] : -60,
                                     range: -60...0, height: max(10, geometry.size.height - 16))
                            Text(barLabel(index))
                                .font(.system(size: 8, design: .monospaced)).lineLimit(1)
                                .help(label)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let group = selectedGroup, group.isMultiMono { selectTrack(group.tracks[index]) }
                        }
                        .accessibilityAction {
                            if let group = selectedGroup, group.isMultiMono { selectTrack(group.tracks[index]) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Channel \(index + 1): \(label)")
                        .accessibilityValue(levels.indices.contains(index) && levels[index] > -60
                                            ? "\(Int(levels[index])) dBFS" : "Silent")
                    }
                }
            }
            .frame(minHeight: 70)
            .overlay {
                if isLoading { ProgressView().controlSize(.small) }
                else if failed { Text("Meter unavailable").font(.caption2) }
                else if labels.isEmpty { Text("No audio channels").font(.caption2) }
            }
            if selectedGroup?.isMultiMono == true, let streamIndex {
                Text("Preview: track \(streamIndex + 1)").font(.caption2)
                    .help("Click a mono meter to listen to that track. All mono meters remain visible.")
            }
            if (stream?.channels ?? 0) > 8 {
                Text("Channels 1–8 of \(stream?.channels ?? 0)").font(.caption2)
            }
            Picker("Track", selection: Binding(
                get: { selectedGroup?.id ?? -1 },
                set: { id in
                    guard let group = groups.first(where: { $0.id == id }),
                          !group.tracks.contains(streamIndex ?? -1) else { return }
                    selectTrack(group.id)
                }
            )) {
                ForEach(groups) { group in
                    Text(groupTitle(group)).tag(group.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(groups.count < 2)
            .accessibilityLabel("Meter and preview audio track")
            .accessibilityIdentifier("stitching.audioTrack")
            .help("Select the audio track for preview playback and metering.")
        }
        .padding(8)
        .frame(width: min(300, max(156, CGFloat(labels.count) * 18 + 32)))
        .background(Color.black.opacity(0.65))
        .accessibilityIdentifier("stitching.audioMeter")
        .task(id: item.url) {
            metadata = nil
            if item.metadata == nil {
                let result = try? await BoundedVideoMetadataProbe.metadata(for: item.url)
                guard !Task.isCancelled else { return }
                metadata = result
            }
        }
        .task(id: requests) {
            chunks = [:]
            failed = false
            let currentRequests = requests
            guard !currentRequests.isEmpty else { isLoading = false; return }
            isLoading = true
            let capacity = currentRequests.count * 3
            // Decode sequentially to avoid one simultaneous decoder per mono track.
            for request in currentRequests {
                do {
                    let loaded = try await cache.load(request, capacity: capacity)
                    guard !Task.isCancelled else { return }
                    chunks[request] = loaded
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
            }
            isLoading = false
            // Warm neighboring windows for every visible track, preserving source offsets.
            for delta in [1, -1] {
                for request in currentRequests {
                    guard !Task.isCancelled else { return }
                    if delta == 1, request.start + SourceAudioMeterRequest.windowDuration >= item.durationSeconds { continue }
                    if delta == -1, request.window == 0 { continue }
                    _ = try? await cache.load(request.adjacent(delta), capacity: capacity)
                }
            }
        }
    }
}
