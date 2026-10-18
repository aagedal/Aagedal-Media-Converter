// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine

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
            if let selectedGroup {
                Picker("Track", selection: Binding(
                    get: { selectedGroup.id },
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

/// Source measurements at the playhead, shared by native and MPV preview playback.
struct PlaybackAudioMeterPanel: View {
    @ObservedObject var controller: PreviewPlayerController
    @State private var metadata: VideoMetadata?
    @State private var chunk: PlaybackAudioMeterChunk?
    @State private var cache = PlaybackAudioMeterCache()
    @State private var failed = false
    @State private var playbackMode = false
    @State private var liveSample: PlaybackAudioMeterSample?
    @State private var liveChannelCount = 0
    @State private var liveUnavailable = false
#if DEBUG
    @State private var timingTrace: [TimingObservation] = []
    @State private var timingTraceSegment = 0
    @State private var timingTraceLastPosition: Double?

    private struct TimingObservation: Encodable {
        let uptime: Double
        let segment: Int
        let position: Double
        let sampleEnd: Double?
        let peaks: [Double?]?
        let rms: [Double?]?
        let momentaryLUFS: Double?
        let shortTermLUFS: Double?
        let playing: Bool
        let playbackMode: Bool
        let unavailable: Bool
        let timestampHistory: Bool
        let ingestSeconds: Double?
        let audioOutput: String?
    }

    private var timingTraceEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["AMC_UI_TEST_SESSION"] == "1" && environment["AMC_UI_TEST_METER_TRACE"] == "1"
    }

    private var timingTraceJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(timingTrace)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private var timingTraceControl: some View {
        Text(verbatim: "Timing trace")
            .font(.system(size: 1))
            .frame(height: 1)
            .accessibilityLabel(Text(verbatim: "Playback meter timing trace"))
            .accessibilityValue(Text(verbatim: timingTraceJSON))
            .accessibilityIdentifier("preview.audioMeter.timingTrace")
            .task {
                // A publisher constructed by body is recreated on every
                // playhead update and can starve while playback is running.
                // Tie this observer to the control's stable view lifetime.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    captureTimingObservation()
                }
            }
    }

    private func captureTimingObservation() {
        guard timingTraceEnabled else { return }
        let position = controller.currentPlaybackTime
        guard position.isFinite else { return }
        if let previous = timingTraceLastPosition, position < previous - 0.25 { timingTraceSegment += 1 }
        timingTraceLastPosition = position
        // Compute through the panel's actual freshness/playback gate at callback
        // time, rather than recording the player's potentially hidden sample.
        let shown = sample
        let player = controller.mpvPlayer
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        timingTrace.append(TimingObservation(
            uptime: ProcessInfo.processInfo.systemUptime, segment: timingTraceSegment, position: position,
            sampleEnd: finite(shown?.seconds), peaks: shown?.peaks.map { finite($0) },
            rms: shown?.rms.map { finite($0) }, momentaryLUFS: finite(shown?.momentaryLUFS),
            shortTermLUFS: finite(shown?.shortTermLUFS), playing: controller.isPlaying,
            playbackMode: playbackMode, unavailable: liveUnavailable,
            timestampHistory: player?.playbackMeterHasTimestampHistory ?? false,
            ingestSeconds: finite(player?.playbackMeterHistoryIngestSeconds), audioOutput: player?.currentAudioOutput))
        if timingTrace.count > 300 { timingTrace.removeFirst(timingTrace.count - 300) }
    }
#endif

    private var streams: [VideoMetadata.AudioStream] {
        (controller.useImageSequence ? metadata : (controller.videoItem.metadata ?? metadata))?.audioStreams ?? []
    }

    private var track: Int? {
        let position = controller.selectedAudioTrackOrderIndex
        if controller.audioTrackOptions.indices.contains(position) {
            return controller.audioTrackOptions[position].streamIndex
        }
        return streams.indices.contains(position) ? position : nil
    }

    private var request: SourceAudioMeterRequest? {
        let time = controller.currentPlaybackTime
        guard !playbackMode, let url = controller.audioMeterSourceURL, let track, streams.indices.contains(track),
              let channels = streams[track].channels, channels > 0,
              time.isFinite, time >= 0 else { return nil }
        return SourceAudioMeterRequest(url: url, track: track,
                                       channels: channels,
                                       window: Int(time / SourceAudioMeterRequest.windowDuration))
    }

    private var sample: PlaybackAudioMeterSample? {
        if playbackMode {
            guard controller.isPlaying, let liveSample,
                  abs(controller.currentPlaybackTime - liveSample.seconds) < 0.5 else { return nil }
            return liveSample
        }
        guard chunk?.request == request else { return nil }
        return chunk?.sample(at: controller.currentPlaybackTime)
    }

    private var labels: [String] {
        if playbackMode {
            return (0..<liveChannelCount).map { "Ch \($0 + 1)" }
        }
        guard let track, streams.indices.contains(track), let channels = streams[track].channels else { return [] }
        return Array(NativeWaveformRenderer.channelNames(count: channels, layout: streams[track].channelLayout).prefix(8))
    }

    var body: some View {
        let currentSample = sample
        // Include measurements in ForEach's data. Stable labels alone let
        // SwiftUI reuse channel content containing obsolete captured readings.
        let channels = labels.enumerated().map { index, label in
            PlaybackMeterChannel(
                id: index, label: label, decoded: playbackMode,
                peak: reading(currentSample?.peaks, at: index), rms: reading(currentSample?.rms, at: index),
                peakLevel: level(currentSample?.peaks, at: index), rmsLevel: level(currentSample?.rms, at: index))
        }
        return VStack(spacing: 6) {
            if controller.useMPV {
                Picker("Meter", selection: $playbackMode) {
                    Text("Source").tag(false)
                    Text("Playback").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("preview.audioMeter.mode")
            }
#if DEBUG
            if timingTraceEnabled { timingTraceControl }
#endif
            Text(playbackMode ? "Decoded peak / RMS" : "Source peak / RMS").font(.caption)
            HStack(alignment: .top, spacing: 5) {
                ForEach(channels) { channel in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            LevelBar(level: channel.rmsLevel, range: -60...0, height: 100)
                            // White line shows the independent 100 ms sample peak;
                            // the filled bar shows RMS over the same interval.
                            GeometryReader { geometry in
                                Rectangle().fill(.white)
                                    .frame(height: 2)
                                    .offset(y: geometry.size.height * (1 - CGFloat((max(-60, min(0, channel.peakLevel)) + 60) / 60)))
                            }
                        }
                        .frame(width: 14, height: 100)
                        Text(channel.label).font(.system(size: 8, design: .monospaced)).lineLimit(1)
                        Text(channel.peak).font(.system(size: 8, design: .monospaced))
                        Text(channel.rms).font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("preview.audioMeter.channel.\(channel.id)")
                    // macOS group elements do not expose a separate AXValue.
                    .accessibilityLabel(channel.decoded
                        ? Text("\(channel.label) decoded audio. Peak \(channel.peak) dBFS, RMS \(channel.rms) dBFS")
                        : Text("\(channel.label) source audio. Peak \(channel.peak) dBFS, RMS \(channel.rms) dBFS"))
                }
            }
            Text("dBFS · peak above RMS").font(.system(size: 9)).foregroundStyle(.secondary)
            Divider()
            loudnessRow("Momentary", value: currentSample?.momentaryLUFS, identifier: "preview.audioMeter.momentary")
            loudnessRow("Short-term", value: currentSample?.shortTermLUFS, identifier: "preview.audioMeter.shortTerm")
            Text("LUFS · 0.4 s / 3 s").font(.system(size: 9)).foregroundStyle(.secondary)
            if playbackMode {
                Text(liveUnavailable ? "Playback meter unavailable" : "Decoded active track; may lead sound")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if failed {
                Text("Meter unavailable").font(.caption2)
            } else if request != nil && chunk?.request != request {
                ProgressView().controlSize(.small)
            } else if labels.isEmpty {
                Text("No audio channels").font(.caption2)
            }
            if (request?.channels ?? 0) > 8 {
                Text("Channels 1–8; LUFS includes the full track").font(.caption2)
            }
            if controller.audioTrackOptions.count > 1 {
                Picker("Audio track", selection: Binding(
                    get: { controller.selectedAudioTrackOrderIndex },
                    set: { controller.selectAudioTrack(at: $0) }
                )) {
                    ForEach(controller.audioTrackOptions) { option in
                        Text(option.title).tag(option.position)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityLabel("Meter and preview audio track")
            }
        }
        .padding(8)
        .frame(width: max(164, CGFloat(labels.count) * 30))
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
        .help(playbackMode ? "Decoded active-track levels before playback volume and mute. Channel layout may differ from the source. Readings may lead audible playback, and polling can miss brief peaks. Loudness history resets after pause, seek or track changes. Use Source for playhead-aligned inspection and Audio Analysis for whole-program loudness." : "Source levels before playback volume, mute and speaker downmixing. White marks show sample peaks; filled bars show RMS. LUFS measures the selected track over the preceding 0.4 and 3 seconds of source audio. Use Audio Analysis for whole-program integrated loudness and true peak.")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview.audioMeter")
        .onChange(of: playbackMode) { _, enabled in
            liveSample = nil
            controller.mpvPlayer?.setPlaybackMeterEnabled(enabled)
        }
        .onChange(of: controller.mpvPlayer) { old, new in
            old?.setPlaybackMeterEnabled(false)
            liveSample = nil
            liveChannelCount = 0
            new?.setPlaybackMeterEnabled(playbackMode)
        }
        .onChange(of: controller.useMPV) { _, useMPV in
            if !useMPV { playbackMode = false }
        }
        .onDisappear { controller.mpvPlayer?.setPlaybackMeterEnabled(false) }
        .onReceive(controller.mpvPlayer?.$playbackMeterSample.eraseToAnyPublisher()
                   ?? Just(nil).eraseToAnyPublisher()) { value in
            liveSample = value
            if let value { liveChannelCount = value.peaks.count }
        }
        .onReceive(controller.mpvPlayer?.$playbackMeterUnavailable.eraseToAnyPublisher()
                   ?? Just(false).eraseToAnyPublisher()) { liveUnavailable = $0 }
        .task(id: controller.audioMeterSourceURL) {
            metadata = nil
            if let url = controller.audioMeterSourceURL, controller.useImageSequence || controller.videoItem.metadata == nil {
                let result = try? await BoundedVideoMetadataProbe.metadata(for: url)
                guard !Task.isCancelled else { return }
                metadata = result
            }
        }
        .task(id: request) {
            chunk = nil
            failed = false
            guard let request else { return }
            do {
                let loaded = try await cache.load(request)
                guard !Task.isCancelled else { return }
                chunk = loaded
                // Decode just one neighboring window ahead of playback.
                if request.start + SourceAudioMeterRequest.windowDuration < controller.effectiveDuration {
                    _ = try? await cache.load(request.adjacent(1))
                }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    private func level(_ values: [Double?]?, at index: Int) -> Float {
        guard controller.isPlaying, let values, values.indices.contains(index), let value = values[index] else { return -60 }
        return Float(value)
    }

    private func reading(_ values: [Double?]?, at index: Int) -> String {
        guard let values, values.indices.contains(index), let value = values[index] else { return "−∞" }
        return String(format: "%.1f", value)
    }

    private func loudnessRow(_ title: LocalizedStringKey, value: Double?, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { $0 < -70 ? "< −70" : String(format: "%.1f", $0) } ?? "—")
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
        .font(.caption2)
    }
}


private struct PlaybackMeterChannel: Identifiable, Equatable {
    let id: Int
    let label: String
    let decoded: Bool
    let peak: String
    let rms: String
    let peakLevel: Float
    let rmsLevel: Float
}
