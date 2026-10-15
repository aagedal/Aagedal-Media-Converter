// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

struct SilenceAnalysisRequest: Identifiable {
    let id = UUID()
    let file: URL
    let tracks: [AudioTrackInfo]
}

/// Offline source measurements, kept separate from output-device metering.
struct SilenceAnalysisView: View {
    let file: URL
    let tracks: [AudioTrackInfo]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayer()
    @State private var selectedTrack: Int
    @State private var threshold = -50.0
    @State private var minimumDuration = 1.0
    @State private var result: SilenceAnalysisResult?
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
        max(0.1, player.duration.isFinite ? player.duration : 0, result?.intervals.last?.end ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Detect Silence").font(.title2.bold())
                    Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("analysis.silence.close")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    settings
                    HStack {
                        Button("Scan Audio") { analyze() }
                            .disabled(isAnalyzing || tracks.isEmpty)
                            .accessibilityIdentifier("analysis.silence.run")
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.silence.cancel")
                        }
                    }
                    Text("Scans the complete selected source track. Silence requires every channel to stay below the sample threshold for the minimum duration. Volume and mute do not affect detection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                    if let result { intervalList(result) }
                    Spacer(minLength: 0)
                }
                .frame(width: 310)
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
                            .accessibilityIdentifier("analysis.silence.time")
                    }
                    if let result { timeline(result) }
                    Text("Click an interval or its end to seek and pause. Times are relative to the file; trims and conversion settings are not applied.")
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
        .onChange(of: minimumDuration) { clearResult() }
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
            .accessibilityIdentifier("analysis.silence.track")
            Picker("Silence threshold", selection: $threshold) {
                ForEach([-30.0, -40, -50, -60, -70, -80], id: \.self) { value in
                    Text(verbatim: "\(Int(value)) dBFS").tag(value)
                }
            }
            .accessibilityIdentifier("analysis.silence.threshold")
            Picker("Minimum silence", selection: $minimumDuration) {
                ForEach([0.1, 0.25, 0.5, 1, 2, 3, 5], id: \.self) { value in
                    Text(verbatim: time(value)).tag(value)
                }
            }
            .accessibilityIdentifier("analysis.silence.duration")
        }
        .disabled(isAnalyzing)
    }

    private func intervalList(_ result: SilenceAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected intervals: \(result.intervals.count)").font(.headline)
                .accessibilityIdentifier("analysis.silence.summary")
            if result.intervals.isEmpty {
                Text("No silence meets these settings.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.intervals.enumerated()), id: \.element.id) { index, interval in
                        HStack {
                            Button { seek(interval.start) } label: {
                                Label(time(interval.start), systemImage: "play.circle")
                            }
                            .accessibilityLabel(Text("Start") + Text(verbatim: ": \(time(interval.start))"))
                            .accessibilityIdentifier("analysis.silence.start.\(index)")
                            Button { seek(interval.end) } label: {
                                Text(verbatim: time(interval.end))
                            }
                            .accessibilityLabel(Text("End of silence") + Text(verbatim: ": \(time(interval.end))"))
                            .accessibilityIdentifier("analysis.silence.end.\(index)")
                            Spacer()
                            Text(verbatim: time(interval.duration)).foregroundStyle(.secondary)
                        }
                        .font(.caption).monospacedDigit()
                        .disabled(!player.isFileLoaded)
                    }
                }
            }
        }
    }

    private func timeline(_ result: SilenceAnalysisResult) -> some View {
        Chart {
            ForEach(result.intervals) { interval in
                RectangleMark(xStart: .value("Start", interval.start), xEnd: .value("End", interval.end),
                              yStart: .value("Silence", 0), yEnd: .value("Silence", 1))
                    .foregroundStyle(.blue.opacity(0.4))
            }
            RuleMark(x: .value("Position", position)).foregroundStyle(.primary)
        }
        .chartXScale(domain: 0...timelineDuration)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
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
        .accessibilityLabel("Silence timeline")
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
        let presentation = LoudnessPresentation.track(selectedTrack)
        let settings = SilenceDetectionSettings(thresholdDBFS: threshold, minimumDuration: minimumDuration)
        analysisTask = Task { @MainActor in
            do {
                let measured = try await SilenceAnalysisService.shared.analyze(file: file, presentation: presentation, settings: settings)
                try Task.checkCancellation()
                if analysisID == id { result = measured }
            } catch is CancellationError {
                // Cancelled scans do not publish incomplete intervals.
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
