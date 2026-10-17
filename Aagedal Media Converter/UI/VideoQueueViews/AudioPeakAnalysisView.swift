// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts
import UniformTypeIdentifiers

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
    @State private var configuration: AudioAnalysisConfiguration
    @State private var previewReady = false
    @State private var previewFailed = false
    @State private var groupValidated = false
    @State private var groupingError: String?
    @State private var threshold = -1.0
    @State private var imbalanceThreshold = 6.0
    @State private var result: AudioPeakAnalysisResult?
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
                            .disabled(isAnalyzing || !validPresentation || !groupValidated)
                            .accessibilityIdentifier("analysis.peaks.run")
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.peaks.cancel")
                        }
                        Button("Export JSON") { exportJSON() }
                            .disabled(isAnalyzing || result == nil)
                            .accessibilityIdentifier("analysis.peaks.export")
                    }
                    Text("Scans the complete selected source presentation in short analysis windows. Markers locate windows containing source sample peaks at or above the threshold; they are not true-peak measurements.")
                        .font(.caption).foregroundStyle(.secondary)
                    if configuration.kind != .track && validPresentation && !groupValidated && groupingError == nil {
                        ProgressView("Validating grouped audio…").controlSize(.small)
                    }
                    if let groupingError {
                        Text(groupingError).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.peaks.group.error")
                    }
                    if previewFailed {
                        Text("Preview unavailable")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.peaks.preview.error")
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
        .task(id: presentation.id) {
            groupValidated = false
            groupingError = nil
            guard validPresentation else { return }
            do {
                try await AudioPeakAnalysisService.shared.validateGroupedTracks(file: file, presentation: presentation)
                try Task.checkCancellation()
                groupValidated = true
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
            groupValidated = false
            player.pause()
        }
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
            Picker("Analyze", selection: $configuration.kind) {
                Text("Audio track").tag(AudioAnalysisConfiguration.Kind.track)
                if monoTracks.count >= 2 {
                    Text("Mono pair").tag(AudioAnalysisConfiguration.Kind.stereo)
                }
                if monoTracks.count >= 6 {
                    Text("5.1 multi-mono").tag(AudioAnalysisConfiguration.Kind.surround)
                }
            }
            .accessibilityIdentifier("analysis.peaks.kind")
            if configuration.kind == .track {
                Picker("Audio track", selection: $configuration.trackIndex) {
                    ForEach(tracks, id: \.streamIndex) { track in
                        Text(track.displayLabel).tag(track.streamIndex)
                    }
                }
                .accessibilityIdentifier("analysis.peaks.track")
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
                            .accessibilityIdentifier("analysis.peaks.channel.\(offset)")
                        }
                    }
                }
                if !validPresentation {
                    Text("Choose a different mono track for each channel.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
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
                            channelLabel(channel.channel, presentation: result.presentation)
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
                            channelLabel(interval.channel, presentation: result.presentation)
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
                        .disabled(!previewReady)
                    }
                }
            }
        }
        .accessibilityIdentifier("analysis.peaks.results")
    }

    private func channelLabel(_ channel: Int, presentation: LoudnessPresentation?) -> Text {
        let roles: [String]
        switch presentation {
        case .stereo: roles = ["L", "R"]
        case .surround51: roles = ["L", "R", "C", "LFE", "Ls", "Rs"]
        default: roles = []
        }
        if roles.indices.contains(channel - 1) { return Text(verbatim: roles[channel - 1]) }
        return Text("Channel \(channel)")
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
        .chartYAxisLabel(String(localized: "Channel"))
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
        .frame(height: result.channels.count > 2 ? 160 : 100)
        .accessibilityLabel("Peak timeline")
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
        panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent)_audio_peaks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        do {
            try AnalyticsExporter.exportAudioPeakJSON(result: result, sourceFile: file,
                                                       timestamp: timestamp, to: url)
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
        let settings = AudioPeakSettings(thresholdDBFS: threshold, imbalanceThresholdDB: imbalanceThreshold)
        analysisTask = Task { @MainActor in
            do {
                let measured = try await AudioPeakAnalysisService.shared.analyze(file: file, presentation: presentation, settings: settings)
                try Task.checkCancellation()
                if analysisID == id {
                    result = measured
                    analysisTimestamp = Date()
                }
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
