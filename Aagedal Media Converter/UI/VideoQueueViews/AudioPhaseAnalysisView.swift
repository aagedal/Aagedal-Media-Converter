// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts
import UniformTypeIdentifiers

struct AudioPhaseAnalysisRequest: Identifiable {
    let id = UUID()
    let file: URL
    let tracks: [AudioTrackInfo]
}

/// Offline source measurements, kept separate from output-device metering.
struct AudioPhaseAnalysisView: View {
    let file: URL
    let tracks: [AudioTrackInfo]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayer()
    @State private var configuration: AudioAnalysisConfiguration
    @State private var previewReady = false
    @State private var previewFailed = false
    @State private var groupValidated = false
    @State private var groupingError: String?
    @State private var result: AudioPhaseAnalysisResult?
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
            kind: tracks.contains { $0.channels == 2 } ? .track : .stereo,
            trackIndex: tracks.first { $0.channels == 2 }?.streamIndex ?? 0,
            monoIndices: (0..<6).map { mono.indices.contains($0) ? mono[$0] : (mono.first ?? 0) }
        ))
    }

    private var monoTracks: [AudioTrackInfo] { tracks.filter { $0.channels == 1 } }
    private var presentation: LoudnessPresentation { configuration.presentation }
    private var stereoTracks: [AudioTrackInfo] { tracks.filter { $0.channels == 2 } }
    private var validPresentation: Bool {
        if case .track(let index) = presentation { return stereoTracks.contains { $0.streamIndex == index } }
        return configuration.kind == .stereo && presentation.isValid(for: tracks)
    }
    private var isAnalyzing: Bool { analysisID != nil }
    private var timelineDuration: Double {
        max(0.1, player.duration.isFinite ? player.duration : 0, result?.duration ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stereo Phase and Mono Compatibility").font(.title2.bold())
                    Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("analysis.phase.close")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    settings
                    HStack {
                        Button("Scan Audio") { analyze() }
                            .disabled(isAnalyzing || !validPresentation || !groupValidated)
                            .accessibilityIdentifier("analysis.phase.run")
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.phase.cancel")
                        }
                        Button("Export JSON") { exportJSON() }
                            .disabled(isAnalyzing || result == nil)
                            .accessibilityIdentifier("analysis.phase.export")
                    }
                    Text("Measures source stereo correlation and mono fold-down in 4,800-sample windows. Volume, mute and conversion trims do not affect analysis.")
                        .font(.caption).foregroundStyle(.secondary)
                    if configuration.kind != .track && validPresentation && !groupValidated && groupingError == nil {
                        ProgressView("Validating grouped audio…").controlSize(.small)
                    }
                    if let groupingError {
                        Text(groupingError).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.phase.group.error")
                    }
                    if previewFailed {
                        Text("Preview unavailable")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("analysis.phase.preview.error")
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                    if let result { windowList(result) }
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
                    .frame(maxHeight: 150)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button { player.togglePause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        .accessibilityIdentifier("analysis.phase.play")
                        .disabled(!previewReady)
                        Slider(value: Binding(get: { position }, set: { seconds in seek(seconds) }), in: 0...timelineDuration)
                            .accessibilityLabel("Inspection playback position")
                            .disabled(!previewReady)
                        Text(verbatim: time(position))
                            .font(.caption).monospacedDigit()
                            .accessibilityIdentifier("analysis.phase.time")
                    }
                    if let result {
                        phaseScope(result)
                        timeline(result)
                        if result.windows.count > 2_000 {
                            Text("Chart shows the first 2,000 windows. All windows remain in the list and JSON report.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Select a window boundary to seek and pause on the file timeline.")
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
                if !stereoTracks.isEmpty {
                    Text("Audio track").tag(AudioAnalysisConfiguration.Kind.track)
                }
                if monoTracks.count >= 2 {
                    Text("Mono pair").tag(AudioAnalysisConfiguration.Kind.stereo)
                }
            }
            .accessibilityIdentifier("analysis.phase.kind")
            if configuration.kind == .track {
                Picker("Audio track", selection: $configuration.trackIndex) {
                    ForEach(stereoTracks, id: \.streamIndex) { track in
                        Text(track.displayLabel).tag(track.streamIndex)
                    }
                }
                .accessibilityIdentifier("analysis.phase.track")
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
                            .accessibilityIdentifier("analysis.phase.channel.\(offset)")
                        }
                    }
                }
                if !validPresentation {
                    Text("Choose a different mono track for each channel.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if stereoTracks.isEmpty && monoTracks.count < 2 {
                Text("Choose a stereo track or two distinct mono tracks.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(isAnalyzing)
    }

    private func windowList(_ result: AudioPhaseAnalysisResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Whole-source phase").font(.headline)
                    .accessibilityIdentifier("analysis.phase.summary")
                LabeledContent("Correlation", value: correlation(result.totals.correlation))
                    .accessibilityIdentifier("analysis.phase.correlation")
                LabeledContent("Mono fold-down", value: delta(result.totals.monoFoldDownDeltaDB))
                    .accessibilityIdentifier("analysis.phase.mono")
                LabeledContent("Mid RMS", value: rms(result.totals.midRMS))
                LabeledContent("Side RMS", value: rms(result.totals.sideRMS))
                DisclosureGroup("About") {
                    Text("Correlation: +1 means matching polarity, 0 means no linear correlation, and −1 means opposite polarity. A silent channel has no correlation value. Negative windows may cancel in mono; a whole-source average can hide local problems.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Mono fold-down compares the energy of (L + R) / 2 with mean left/right energy. 0 dB preserves matching channels; −3 dB is typical for uncorrelated audio; −∞ means complete cancellation. Both silent channels have no comparison. Mid = (L + R) / 2; side = (L − R) / 2. These are unweighted source checks, not loudness or frequency-dependent phase measurements.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.windows.enumerated()), id: \.offset) { index, window in
                        HStack {
                            Button { seek(window.start) } label: { Text(verbatim: time(window.start)) }
                                .accessibilityLabel(Text("Start") + Text(verbatim: ": \(time(window.start))"))
                                .accessibilityIdentifier("analysis.phase.start.\(index)")
                            Button { seek(window.end) } label: { Text(verbatim: time(window.end)) }
                                .accessibilityLabel(Text("End") + Text(verbatim: ": \(time(window.end))"))
                                .accessibilityIdentifier("analysis.phase.end.\(index)")
                            Spacer()
                            Text(verbatim: correlation(window.measurement.correlation))
                                .foregroundStyle((window.measurement.correlation ?? 0) < 0 ? Color.orange : Color.primary)
                            Text(verbatim: delta(window.measurement.monoFoldDownDeltaDB))
                        }
                        .font(.caption).monospacedDigit()
                        .disabled(!previewReady)
                    }
                }
            }
        }
        .accessibilityIdentifier("analysis.phase.results")
    }

    private func correlation(_ value: Double?) -> String {
        value.map { String(format: "%+.3f", $0) } ?? "—"
    }

    private func delta(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.isFinite ? String(format: "%.2f dB", value) : "−∞ dB"
    }

    private func rms(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f dBFS", 20 * log10(value)) : "−∞ dBFS"
    }

    private func phaseScope(_ result: AudioPhaseAnalysisResult) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                Text("Mid").font(.caption2)
                Canvas { context, size in
                    let dimension = result.scope.dimension
                    let maximum = max(1, result.scope.bins.max() ?? 1)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var axes = Path()
                    axes.move(to: CGPoint(x: 0, y: center.y))
                    axes.addLine(to: CGPoint(x: size.width, y: center.y))
                    axes.move(to: CGPoint(x: center.x, y: 0))
                    axes.addLine(to: CGPoint(x: center.x, y: size.height))
                    context.stroke(axes, with: .color(.gray.opacity(0.4)), lineWidth: 1)
                    for (index, count) in result.scope.bins.enumerated() where count > 0 {
                        let x = Double(index % dimension) / Double(dimension - 1) * size.width
                        let y = (1 - Double(index / dimension) / Double(dimension - 1)) * size.height
                        let strength = log1p(Double(count)) / log1p(Double(maximum))
                        let dot = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                        context.fill(Path(ellipseIn: dot), with: .color(.blue.opacity(0.2 + 0.8 * strength)))
                    }
                }
                .frame(width: 120, height: 120)
                .border(.secondary.opacity(0.3))
                .accessibilityLabel("Whole-source phase scope")
                .accessibilityIdentifier("analysis.phase.scope")
                Text("Side").font(.caption2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Whole-source phase scope").font(.caption.bold())
                Text("Each dot shows source-sample density: matching channels form a vertical line; opposite polarity forms a horizontal line. Fixed ±1 full-scale axes; samples outside the display are clamped to its edges.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Clamped samples")
                    Text(verbatim: "\(result.scope.clippedSampleCount)")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func timeline(_ result: AudioPhaseAnalysisResult) -> some View {
        Chart {
            RuleMark(y: .value("Correlation", 0)).foregroundStyle(.secondary)
            ForEach(Array(result.windows.prefix(2_000).enumerated()), id: \.offset) { _, window in
                if let value = window.measurement.correlation {
                    RectangleMark(xStart: .value("Start", window.start), xEnd: .value("End", window.end),
                                  yStart: .value("Correlation", 0), yEnd: .value("Correlation", value))
                        .foregroundStyle(value < 0 ? Color.orange.opacity(0.7) : Color.blue.opacity(0.7))
                }
            }
            RuleMark(x: .value("Position", position)).foregroundStyle(.primary)
        }
        .chartXScale(domain: 0...timelineDuration)
        .chartYScale(domain: -1...1)
        .chartYAxis { AxisMarks(values: [-1.0, 0, 1]) }
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
        .accessibilityLabel("Stereo phase correlation timeline")
        .accessibilityIdentifier("analysis.phase.chart")
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
        panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent)_audio_phase.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        do {
            try AnalyticsExporter.exportAudioPhaseJSON(result: result, sourceFile: file,
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
        analysisTask = Task { @MainActor in
            do {
                let measured = try await AudioPhaseAnalysisService.shared.analyze(file: file, presentation: presentation)
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
