// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts
import UniformTypeIdentifiers

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
    @State private var configuration: AudioAnalysisConfiguration
    @State private var previewReady = false
    @State private var previewFailed = false
    /// The presentation whose grouped timing passed validation. Keyed by id so
    /// a reset that lands after a fast validation can't strand the preview.
    @State private var validatedPresentationID: String?
    @State private var groupingError: String?
    @State private var threshold = -50.0
    @State private var minimumDuration = 1.0
    @State private var result: SilenceAnalysisResult?
    @State private var analysisTimestamp: Date?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID: UUID?
    @State private var errorMessage: String?
    @State private var position = 0.0
    @State private var previewAccess: SecurityScopedAccess = .none

    init(file: URL, tracks: [AudioTrackInfo]) {
        self.file = file
        self.tracks = tracks
        let mono = tracks.filter { $0.channels == 1 }.map(\.streamIndex)
        _configuration = State(initialValue: AudioAnalysisConfiguration(
            trackIndex: tracks.first?.streamIndex ?? 0,
            monoIndices: (0..<6).map { mono.indices.contains($0) ? mono[$0] : (mono.first ?? 0) }
        ))
    }

    private var monoTracks: [AudioTrackInfo] { tracks.filter { $0.channels == 1 } }
    private var presentation: LoudnessPresentation { configuration.presentation }
    private var validPresentation: Bool { presentation.isValid(for: tracks) }
    private var groupValidated: Bool { validatedPresentationID == presentation.id }
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
                            .disabled(isAnalyzing || !validPresentation || !groupValidated)
                            .accessibilityIdentifier("analysis.silence.run")
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.silence.cancel")
                        }
                        Button("Export JSON") { exportJSON() }
                            .disabled(isAnalyzing || result == nil)
                            .accessibilityIdentifier("analysis.silence.export")
                    }
                    Text("Scans the complete selected source presentation. Silence requires every channel to stay below the sample threshold for the minimum duration. Volume and mute do not affect detection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let groupingError {
                        Text(groupingError).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.silence.group.error")
                    }
                    if previewFailed {
                        Text("Preview unavailable")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.silence.preview.error")
                    }
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
                            guard key == " ", previewReady else { return false }
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
                        .disabled(!previewReady)
                        Slider(value: Binding(get: { position }, set: { seconds in seek(seconds) }), in: 0...timelineDuration)
                            .accessibilityLabel("Inspection playback position")
                            .disabled(!previewReady)
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
        .task(id: presentation.id) {
            let validating = presentation
            groupingError = nil
            guard validPresentation else { return }
            do {
                try await SilenceAnalysisService.shared.validateGroupedTracks(file: file, presentation: validating)
                try Task.checkCancellation()
                validatedPresentationID = validating.id
            } catch {
                guard !Task.isCancelled else { return }
                groupingError = error.localizedDescription
            }
        }
        .task(id: "\(player.isFileLoaded)-\(presentation.id)-\(groupValidated)") {
            previewReady = false
            previewFailed = false
            guard player.isFileLoaded, validPresentation, groupValidated else { return }
            let ready = await player.selectAudioPresentation(presentation)
            guard !Task.isCancelled else { return }
            previewReady = ready
            previewFailed = !ready
        }
        .onChange(of: player.timePos) { _, seconds in
            if seconds.isFinite { position = max(0, seconds) }
        }
        .onChange(of: presentation) {
            clearResult()
            previewReady = false
            player.pause()
        }
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
            Picker("Analyze", selection: $configuration.kind) {
                Text("Audio track").tag(AudioAnalysisConfiguration.Kind.track)
                if monoTracks.count >= 2 {
                    Text("Mono pair").tag(AudioAnalysisConfiguration.Kind.stereo)
                }
                if monoTracks.count >= 6 {
                    Text("5.1 multi-mono").tag(AudioAnalysisConfiguration.Kind.surround)
                }
            }
            .accessibilityIdentifier("analysis.silence.kind")
            if configuration.kind == .track {
                Picker("Audio track", selection: $configuration.trackIndex) {
                    ForEach(tracks, id: \.streamIndex) { track in
                        Text(track.displayLabel).tag(track.streamIndex)
                    }
                }
                .accessibilityIdentifier("analysis.silence.track")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                    ForEach(Array(configuration.kind.roles.enumerated()), id: \.offset) { offset, role in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(role)).font(.caption).foregroundStyle(.secondary)
                            Picker(LocalizedStringKey(role), selection: $configuration.monoIndices[offset]) {
                                ForEach(monoTracks, id: \.streamIndex) { track in
                                    Text(track.displayLabel).tag(track.streamIndex)
                                }
                            }
                            .labelsHidden()
                            .id("\(configuration.kind.rawValue)-\(offset)")
                            .accessibilityIdentifier("analysis.silence.channel.\(offset)")
                        }
                    }
                }
                if !validPresentation {
                    Text("Choose a different mono track for each channel.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
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
                        .disabled(!previewReady)
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

    private func seek(_ seconds: Double) {
        guard seconds.isFinite, previewReady else { return }
        // Match MPV's final playable position when an interval extends to EOF.
        // Reported interval boundaries still retain the full measured duration.
        let lastPlayableTime = player.duration > 0 ? max(0, player.duration - 0.05) : timelineDuration
        position = max(0, min(seconds, lastPlayableTime))
        player.pause()
        player.seek(to: position)
    }

    private func clearResult() {
        result = nil
        analysisTimestamp = nil
        errorMessage = nil
    }

    private func exportJSON() {
        guard let result, let timestamp = analysisTimestamp, !isAnalyzing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent)_audio_silence.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        do {
            try AnalyticsExporter.exportSilenceJSON(result: result, sourceFile: file, timestamp: timestamp, to: url)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Export Failed") + ": " + error.localizedDescription
        }
    }

    private func analyze() {
        guard !isAnalyzing, validPresentation, groupValidated else { return }
        clearResult()
        let id = UUID()
        analysisID = id
        let presentation = presentation
        let settings = SilenceDetectionSettings(thresholdDBFS: threshold, minimumDuration: minimumDuration)
        analysisTask = Task { @MainActor in
            do {
                let measured = try await SilenceAnalysisService.shared.analyze(file: file, presentation: presentation, settings: settings)
                try Task.checkCancellation()
                if analysisID == id {
                    result = measured
                    analysisTimestamp = Date()
                }
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
