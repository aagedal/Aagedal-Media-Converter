// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

struct AudioPeakAnalysisRequest: Identifiable {
    let id = UUID()
    let file: URL
    let tracks: [AudioTrackInfo]
}

/// Offline source measurements, kept separate from output-device metering.
struct AudioPeakAnalysisView: View {
    let file: URL
    let tracks: [AudioTrackInfo]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayer()
    @State private var selectedTrack: Int
    @State private var threshold = -1.0
    @State private var imbalanceThreshold = 6.0
    @State private var result: AudioPeakAnalysisResult?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID: UUID?
    @State private var errorMessage: String?
    @State private var position = 0.0
    @State private var previewAccess: SecurityScopedAccess = .none

    init(file: URL, tracks: [AudioTrackInfo]) {
        self.file = file
        self.tracks = tracks
        _selectedTrack = State(initialValue: tracks.first?.streamIndex ?? 0)
    }

    private var isAnalyzing: Bool { analysisID != nil }
    private var timelineDuration: Double {
        max(0.1, player.duration.isFinite ? player.duration : 0, result?.duration ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Peaks and Channel Balance").font(.title2.bold())
                    Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("analysis.peaks.close")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    settings
                    HStack {
                        Button("Scan Audio") { analyze() }
                            .disabled(isAnalyzing || tracks.isEmpty)
                            .accessibilityIdentifier("analysis.peaks.run")
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.peaks.cancel")
                        }
                    }
                    Text("Scans the complete selected track in short analysis windows. Markers locate windows containing source sample peaks at or above the threshold; they are not true-peak measurements.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                    if let result { intervalList(result) }
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        MPVVideoView(player: player, keyHandler: { key, _, _ in
                            guard key == " ", player.isFileLoaded else { return false }
                            player.togglePause()
                            return true
                        })
                        if let error = player.error {
                            Text(error).foregroundStyle(.white).padding()
                        } else if !player.isFileLoaded {
                            ProgressView("Preparing preview…").tint(.white)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button { player.togglePause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        .disabled(!player.isFileLoaded)
                        Slider(value: Binding(get: { position }, set: { seconds in seek(seconds) }), in: 0...timelineDuration)
                            .accessibilityLabel("Inspection playback position")
                            .disabled(!player.isFileLoaded)
                        Text(verbatim: time(position))
                            .font(.caption).monospacedDigit()
                            .accessibilityIdentifier("analysis.peaks.time")
                    }
                    if let result {
                        timeline(result)
                        if result.intervals.count > 1_000 {
                            Text("Timeline shows the first \(1_000) intervals. All intervals remain in the list.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Click a marker or its end to seek and pause on the file timeline.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 900, height: 650)
        .onAppear {
            previewAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
            player.load(url: file)
        }
        .onChange(of: player.isFileLoaded) { _, loaded in
            if loaded { selectPreviewTrack() }
        }
        .onChange(of: player.timePos) { _, seconds in
            if seconds.isFinite { position = max(0, seconds) }
        }
        .onChange(of: selectedTrack) { clearResult(); selectPreviewTrack() }
        .onChange(of: threshold) { clearResult() }
        .onChange(of: imbalanceThreshold) { clearResult() }
        .onDisappear {
            analysisID = nil
            analysisTask?.cancel()
            player.stop()
            SecurityScopedBookmarkManager.shared.stopAccessing(previewAccess)
            previewAccess = .none
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Audio track", selection: $selectedTrack) {
                ForEach(tracks, id: \.streamIndex) { track in
                    Text(track.displayLabel).tag(track.streamIndex)
                }
            }
            .accessibilityIdentifier("analysis.peaks.track")
            Picker("Sample-peak threshold", selection: $threshold) {
                ForEach([0.0, -1, -3, -6, -12, -20], id: \.self) { value in
                    Text(verbatim: "\(Int(value)) dBFS").tag(value)
                }
            }
            .accessibilityIdentifier("analysis.peaks.threshold")
            Picker("Channel difference threshold", selection: $imbalanceThreshold) {
                ForEach([1.0, 3, 6, 10, 20], id: \.self) { value in
                    Text(verbatim: "\(Int(value)) dB").tag(value)
                }
            }
            .accessibilityIdentifier("analysis.peaks.imbalanceThreshold")
        }
        .disabled(isAnalyzing)
    }

    private func intervalList(_ result: AudioPeakAnalysisResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Channel levels").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12) {
                    GridRow {
                        Text("Channel")
                        Text("Sample peak")
                        Text("Whole-track RMS")
                    }.font(.caption.bold())
                    ForEach(result.channels) { channel in
                        GridRow {
                            Text("Channel \(channel.channel)")
                            Text(verbatim: level(channel.peakDBFS))
                            Text(verbatim: level(channel.rmsDBFS))
                        }.font(.caption).monospacedDigit()
                    }
                }
                if let difference = result.imbalanceDB {
                    Text(difference >= imbalanceThreshold ? "Channel difference exceeds threshold" : "Channel difference is within threshold")
                        .foregroundStyle(difference >= imbalanceThreshold ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("analysis.peaks.balance")
                    Text(verbatim: difference.isFinite ? String(format: "%.1f dB", difference) : "∞ dB")
                        .font(.caption).monospacedDigit()
                } else {
                    Text("Channel comparison unavailable").foregroundStyle(.secondary)
                }
                Text("Channel balance compares unweighted whole-track RMS across all decoded channels. Surround and LFE differences may be intentional. Volume, mute and conversion trims do not affect analysis.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Peak intervals: \(result.intervals.count)").font(.headline)
                    .accessibilityIdentifier("analysis.peaks.summary")
                if result.intervals.isEmpty {
                    Text("No sample peaks meet this threshold.").foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.intervals.enumerated()), id: \.element.id) { index, interval in
                        HStack {
                            Text("Channel \(interval.channel)")
                            Button { seek(interval.start) } label: {
                                Text(verbatim: time(interval.start))
                            }
                            .accessibilityLabel(Text("Start") + Text(verbatim: ": \(time(interval.start))"))
                            .accessibilityIdentifier("analysis.peaks.start.\(index)")
                            Button { seek(interval.end) } label: {
                                Text(verbatim: time(interval.end))
                            }
                            .accessibilityLabel(Text("End of peak interval") + Text(verbatim: ": \(time(interval.end))"))
                            .accessibilityIdentifier("analysis.peaks.end.\(index)")
                            Spacer()
                            Text(verbatim: level(interval.peakDBFS))
                        }
                        .font(.caption).monospacedDigit()
                        .disabled(!player.isFileLoaded)
                    }
                }
            }
        }
    }

    private func level(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f dBFS", value) : "−∞ dBFS"
    }

    private func timeline(_ result: AudioPeakAnalysisResult) -> some View {
        Chart {
            ForEach(result.intervals.prefix(1_000)) { interval in
                RectangleMark(xStart: .value("Start", interval.start), xEnd: .value("End", interval.end),
                              yStart: .value("Channel", Double(interval.channel) - 0.4), yEnd: .value("Channel", Double(interval.channel) + 0.4))
                    .foregroundStyle(.blue.opacity(0.4))
            }
            RuleMark(x: .value("Position", position)).foregroundStyle(.primary)
        }
        .chartXScale(domain: 0...timelineDuration)
        .chartYScale(domain: 0.5...Double(max(1, result.channels.count)) + 0.5)
        .chartYAxis { AxisMarks(values: result.channels.map(\.channel)) }
        .chartYAxisLabel("Channel")
        .chartXAxisLabel("Seconds")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        if let seconds: Double = proxy.value(atX: x) { seek(seconds) }
                    }
            }
        }
        .frame(height: 100)
        .accessibilityLabel("Peak timeline")
    }

    private func selectPreviewTrack() {
        let ids = player.audioTrackIndexes
        player.pause()
        // Both track inventories use audio-relative container order.
        if ids.indices.contains(selectedTrack) { player.currentAudioTrackIndex = ids[selectedTrack] }
    }

    private func seek(_ seconds: Double) {
        guard seconds.isFinite, player.isFileLoaded else { return }
        // Match MPV's final playable position when an interval extends to EOF.
        // Reported interval boundaries still retain the full measured duration.
        let lastPlayableTime = player.duration > 0 ? max(0, player.duration - 0.05) : timelineDuration
        position = max(0, min(seconds, lastPlayableTime))
        player.pause()
        player.seek(to: position)
    }

    private func clearResult() {
        result = nil
        errorMessage = nil
    }

    private func analyze() {
        guard !isAnalyzing else { return }
        clearResult()
        let id = UUID()
        analysisID = id
        let trackIndex = selectedTrack
        let settings = AudioPeakSettings(thresholdDBFS: threshold, imbalanceThresholdDB: imbalanceThreshold)
        analysisTask = Task { @MainActor in
            do {
                let measured = try await AudioPeakAnalysisService.shared.analyze(file: file, trackIndex: trackIndex, settings: settings)
                try Task.checkCancellation()
                if analysisID == id { result = measured }
            } catch is CancellationError {
                // Cancelled scans do not publish incomplete measurements.
            } catch {
                if analysisID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if analysisID == id {
                analysisID = nil
                analysisTask = nil
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}
