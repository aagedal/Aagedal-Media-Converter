// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Charts

/// A single entry point for audio loudness and video quality analysis.
struct MediaAnalysisView: View {
    @Binding var item: VideoItem
    var onRunVideo: ([QualityMetric]?) -> Void
    var onCancelVideo: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: String

    init(item: Binding<VideoItem>, onRunVideo: @escaping ([QualityMetric]?) -> Void,
         onCancelVideo: @escaping () -> Void) {
        _item = item
        self.onRunVideo = onRunVideo
        self.onCancelVideo = onCancelVideo
        _selectedTab = State(initialValue: item.wrappedValue.hasVideoStream ? "video" : "audio")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Media Analysis").font(.title2.bold())
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Analysis", selection: $selectedTab) {
                Text("Audio").tag("audio")
                Text("Video").tag("video")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("analysis.tabs")
            // Keep both tabs alive so switching tabs preserves reports and runs.
            ZStack {
                LoudnessAnalysisView(sourceFile: item.url,
                                     outputFile: item.outputFileExists ? item.outputURL : nil)
                    .opacity(selectedTab == "audio" ? 1 : 0)
                    .allowsHitTesting(selectedTab == "audio")
                    .disabled(selectedTab != "audio")
                    .accessibilityHidden(selectedTab != "audio")
                VideoAnalysisTabView(item: $item, onRun: onRunVideo, onCancel: onCancelVideo)
                    .opacity(selectedTab == "video" ? 1 : 0)
                    .allowsHitTesting(selectedTab == "video")
                    .disabled(selectedTab != "video")
                    .accessibilityHidden(selectedTab != "video")
            }
        }
        .padding(20)
        .frame(width: 920, height: 780)
        .task(id: item.outputURL) { refreshOutputCache() }
        .onChange(of: item.status) {
            if item.status == .done { refreshOutputCache() }
        }
    }

    private func refreshOutputCache() {
        guard let output = item.outputURL else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: output)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        // The output URL can be assigned before encoding creates the file.
        item.refreshOutputFileCache()
    }
}

private struct VideoAnalysisTabView: View {
    @Binding var item: VideoItem
    var onRun: ([QualityMetric]?) -> Void
    var onCancel: () -> Void

    var body: some View {
        if !item.hasVideoStream {
            ContentUnavailableView("No video stream", systemImage: "video.slash",
                                   description: Text("Use the Audio tab to analyze this file's loudness."))
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Video analysis settings").font(.headline)
                    Toggle("Analyze after conversion", isOn: $item.analyticsEnabled)
                        .disabled(item.analyticsStatus.isInProgress)
                    Text("Metric settings also apply to queued video analysis.")
                        .font(.caption).foregroundStyle(.secondary)
                    AnalyticsSettingsView(showsAutomation: false)
                }
                .frame(width: 345)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Compare source and encoded video").font(.headline)
                    Text("Source: \(item.url.lastPathComponent)").font(.caption).lineLimit(1)
                    if item.outputFileExists, let output = item.outputURL {
                        Text("Encoded: \(output.lastPathComponent)").font(.caption).lineLimit(1)
                    } else {
                        Text("Encode this file first to compare its video quality with the source.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(item.analyticsResults == nil ? "Analyze Video" : "Run Selected Metrics Again") {
                            onRun(nil)
                        }
                        .disabled(!item.isReadyForAnalytics || item.analyticsStatus.isInProgress)
                        .accessibilityIdentifier("analysis.video.run")
                        if item.analyticsStatus.isInProgress {
                            Button("Cancel", action: onCancel)
                        }
                    }
                    if item.analyticsStatus.isInProgress {
                        ProgressView(value: item.analyticsProgress)
                        Text(item.analyticsStatus.displayText).font(.caption)
                    } else if case .failed(let error) = item.analyticsStatus {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                    if let results = item.analyticsResults {
                        AnalyticsResultsView(results: results, onRunMetrics: { onRun($0) }, isEmbedded: true)
                            .disabled(item.analyticsStatus.isInProgress)
                    } else {
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// One editable card describes one audio program to measure.
private struct AudioAnalysisConfiguration: Identifiable {
    enum Kind: String, CaseIterable {
        case track, stereo, surround

        var title: String {
            switch self {
            case .track: return "Audio track"
            case .stereo: return "Mono pair"
            case .surround: return "5.1 multi-mono"
            }
        }

        var roles: [String] {
            switch self {
            case .track: return ["Track"]
            case .stereo: return ["Left", "Right"]
            case .surround: return ["Left", "Right", "Center", "LFE", "Left surround", "Right surround"]
            }
        }
    }

    let id = UUID()
    var kind: Kind = .track
    var trackIndex: Int
    var monoIndices: [Int]

    var presentation: LoudnessPresentation {
        switch kind {
        case .track: return .track(trackIndex)
        case .stereo: return .stereo(left: monoIndices[0], right: monoIndices[1])
        case .surround: return .surround51(monoIndices)
        }
    }
}

/// Cards define separate playout programs, each with its own report.
struct LoudnessAnalysisView: View {
    let sourceFile: URL
    let outputFile: URL?
    @State private var selectedFileID = "source"
    @State private var tracks: [AudioTrackInfo] = []
    @State private var configurations: [AudioAnalysisConfiguration] = []
    @State private var isProbing = true
    @State private var isAnalyzing = false
    @State private var results: [LoudnessResults] = []
    @State private var activeResultID = ""
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID: UUID?

    private var monoTracks: [AudioTrackInfo] { tracks.filter { $0.channels == 1 } }
    private var file: URL { selectedFileID == "output" ? outputFile ?? sourceFile : sourceFile }
    private var chosenPresentations: [LoudnessPresentation] { configurations.map(\.presentation) }
    private var canAnalyze: Bool {
        !configurations.isEmpty && chosenPresentations.allSatisfy { $0.isValid(for: tracks) }
            && Set(chosenPresentations.map(\.id)).count == configurations.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let outputFile {
                    Picker("File", selection: $selectedFileID) {
                        Text("Source: \(sourceFile.lastPathComponent)").tag("source")
                        Text("Output: \(outputFile.lastPathComponent)").tag("output")
                    }
                    .disabled(isAnalyzing)
                }
                if isProbing {
                    ProgressView("Reading audio tracks…")
                } else if tracks.isEmpty {
                    ContentUnavailableView("No audio tracks found", systemImage: "speaker.slash")
                } else {
                    selectionSection
                    HStack {
                        Button(isAnalyzing ? "Analyzing…" : "Analyze Audio") { analyze() }
                            .disabled(isAnalyzing || !canAnalyze)
                            .accessibilityIdentifier("analysis.audio.run")
                        if isAnalyzing {
                            Button("Cancel") { analysisTask?.cancel() }
                            ProgressView().controlSize(.small)
                            Text("\(results.count) of \(configurations.count) reports complete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
                if !results.isEmpty {
                    Divider()
                    HStack {
                        Picker("Report", selection: $activeResultID) {
                            ForEach(results, id: \.presentation.id) { report in
                                Text(label(for: report.presentation)).tag(report.presentation.id)
                            }
                        }
                        .accessibilityIdentifier("analysis.audio.report")
                        Button("Export PDF") { exportPDF() }.disabled(isAnalyzing)
                    }
                    if results.count > 1 {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow {
                                Text("Presentation").bold()
                                Text("Integrated").bold()
                                Text("True peak").bold()
                            }
                            ForEach(results, id: \.presentation.id) { report in
                                GridRow {
                                    Text(label(for: report.presentation)).lineLimit(1)
                                    Text(report.integratedLUFS <= -70 ? "Below gate" : String(format: "%.1f LUFS", report.integratedLUFS))
                                    Text(report.maximumTruePeakDBTP.map { String(format: "%.1f dBTP", $0) } ?? "—")
                                }
                            }
                        }
                        .font(.caption)
                    }
                    if let report = results.first(where: { $0.presentation.id == activeResultID }) {
                        LoudnessSummaryView(results: report)
                        LoudnessTimelineView(results: report, chartHeight: 180)
                        Text("Integrated loudness is gated over each complete selected program; it is not an average of the graph.")
                            .font(.caption).foregroundStyle(.secondary)
                        if (report.samples.last?.seconds ?? 0) < 60 {
                            Text("Loudness range is not considered stable for programs shorter than one minute.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: file) {
            isProbing = true
            tracks = []
            let probed = await AudioRoutingService.fetchAudioTrackInfo(for: file)
            guard !Task.isCancelled else { return }
            tracks = probed
            configurations = []
            if !tracks.isEmpty { addConfiguration() }
            isProbing = false
        }
        .onChange(of: selectedFileID) {
            analysisID = nil
            analysisTask?.cancel()
            analysisTask = nil
            tracks = []
            configurations = []
            isProbing = true
            results = []
            activeResultID = ""
            errorMessage = nil
            isAnalyzing = false
        }
        .onDisappear {
            analysisID = nil
            analysisTask?.cancel()
        }
    }

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio analyses").font(.headline)
                    Text("Add an analysis for each track or channel group you want to measure.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: addConfiguration) {
                    Label("Add Analysis", systemImage: "plus")
                }
                .accessibilityIdentifier("analysis.audio.add")
            }
            if configurations.isEmpty {
                Text("Add an analysis to choose its audio tracks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(Array(configurations.enumerated()), id: \.element.id) { index, configuration in
                    analysisCard(configuration, number: index + 1)
                }
            }
        }
        .disabled(isAnalyzing)
    }

    private func analysisCard(_ configuration: AudioAnalysisConfiguration, number: Int) -> some View {
        let availableTracks = configuration.kind == .track ? tracks : monoTracks
        let duplicate = configurations.filter { $0.presentation == configuration.presentation }.count > 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Analysis \(number)", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Button {
                    configurations.removeAll { $0.id == configuration.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this analysis")
                .accessibilityLabel("Remove Analysis \(number)")
                .accessibilityIdentifier("analysis.audio.remove.\(number)")
            }
            Picker("Analyze", selection: configurationBinding(configuration.id, \.kind, fallback: configuration.kind)) {
                Text(AudioAnalysisConfiguration.Kind.track.title).tag(AudioAnalysisConfiguration.Kind.track)
                if monoTracks.count >= 2 {
                    Text(AudioAnalysisConfiguration.Kind.stereo.title).tag(AudioAnalysisConfiguration.Kind.stereo)
                }
                if monoTracks.count >= 6 {
                    Text(AudioAnalysisConfiguration.Kind.surround.title).tag(AudioAnalysisConfiguration.Kind.surround)
                }
            }
            .accessibilityIdentifier("analysis.audio.kind.\(number)")
            Divider()
            LazyVGrid(columns: configuration.kind == .track ? [GridItem(.flexible())]
                      : [GridItem(.adaptive(minimum: 165))], alignment: .leading, spacing: 10) {
                ForEach(Array(configuration.kind.roles.enumerated()), id: \.offset) { offset, role in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(role).font(.caption).foregroundStyle(.secondary)
                        Picker(role, selection: Binding(
                            get: {
                                let current = configurations.first(where: { $0.id == configuration.id }) ?? configuration
                                return current.kind == .track ? current.trackIndex : current.monoIndices[offset]
                            },
                            set: { selected in
                                guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else { return }
                                if configuration.kind == .track { configurations[index].trackIndex = selected }
                                else { configurations[index].monoIndices[offset] = selected }
                            }
                        )) {
                            ForEach(availableTracks, id: \.streamIndex) { track in
                                Text(label(for: .track(track.streamIndex))).tag(track.streamIndex)
                            }
                        }
                        // Recreate the native popup when its channel role changes.
                        // Otherwise macOS can retain the previous track title.
                        .id("\(configuration.id)-\(configuration.kind.rawValue)-\(offset)")
                        .labelsHidden()
                        .accessibilityLabel("Analysis \(number) \(role)")
                        .accessibilityIdentifier("analysis.audio.track.\(number).\(offset)")
                    }
                }
            }
            if !configuration.presentation.isValid(for: tracks) {
                Label("Choose a different mono track for each channel.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if duplicate {
                Label("These tracks are already included in another analysis.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(configuration.kind == .track ? "Measures every channel in this track."
                     : "Measures these mono tracks together as one program.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.18)))
    }

    private func configurationBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<AudioAnalysisConfiguration, Value>,
                                             fallback: Value) -> Binding<Value> {
        Binding(
            get: { configurations.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
                configurations[index][keyPath: keyPath] = value
            }
        )
    }

    private func addConfiguration() {
        guard let firstTrack = tracks.first else { return }
        let mono = monoTracks.map(\.streamIndex)
        let indices = (0..<6).map { $0 < mono.count ? mono[$0] : -1 }
        var configuration = AudioAnalysisConfiguration(trackIndex: firstTrack.streamIndex, monoIndices: indices)
        // Prefer the next unused track; when all tracks are represented, offer
        // the next unused mono pairing/group rather than an identical analysis.
        if let next = LoudnessPresentation.presets(for: tracks).first(where: { !chosenPresentations.contains($0) }) {
            switch next {
            case .track(let index): configuration.trackIndex = index
            case .stereo(let left, let right):
                configuration.kind = .stereo
                configuration.monoIndices[0] = left
                configuration.monoIndices[1] = right
            case .surround51(let indices):
                configuration.kind = .surround
                configuration.monoIndices = indices
            }
        }
        configurations.append(configuration)
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent)_loudness.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        do {
            try AnalyticsExporter.exportLoudnessPDF(results: results, fileName: file.lastPathComponent, to: url)
        } catch {
            errorMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    private func label(for presentation: LoudnessPresentation) -> String {
        guard case .track(let index) = presentation,
              let track = tracks.first(where: { $0.streamIndex == index }) else { return presentation.displayName }
        let language = track.languageCode.map { " • \($0.uppercased())" } ?? ""
        return track.displayLabel + language
    }

    private func analyze() {
        guard canAnalyze else { return }
        let chosen = chosenPresentations
        results = []
        activeResultID = ""
        errorMessage = nil
        isAnalyzing = true
        let id = UUID()
        let analyzedFile = file
        analysisID = id
        analysisTask = Task { @MainActor in
            do {
                _ = try await LoudnessAnalysisService.shared.analyze(file: analyzedFile, presentations: chosen) { @MainActor measured in
                    guard analysisID == id, !Task.isCancelled else { return }
                    results.append(measured)
                    results.sort { left, right in
                        chosen.firstIndex(of: left.presentation)! < chosen.firstIndex(of: right.presentation)!
                    }
                    if activeResultID.isEmpty { activeResultID = measured.presentation.id }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                // Preserve completed reports; cancellation drains active meters.
            } catch {
                if analysisID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if analysisID == id {
                isAnalyzing = false
                analysisTask = nil
                analysisID = nil
            }
        }
    }
}

/// Shared by the analysis sheet and the PDF report so units and traces agree.
struct LoudnessSummaryView: View {
    let results: LoudnessResults

    var body: some View {
        HStack(spacing: 22) {
            value("Integrated", text: results.integratedLUFS <= -70
                  ? "Below gate" : String(format: "%.1f LUFS", results.integratedLUFS))
            value("Loudness range", text: String(format: "%.1f LU", results.loudnessRangeLU))
            value("Maximum true peak", text: results.maximumTruePeakDBTP.map {
                String(format: "%.1f dBTP", $0)
            } ?? "—")
        }
    }

    private func value(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.bold())
        }
    }
}

struct LoudnessTimelineView: View {
    let results: LoudnessResults
    var chartHeight: CGFloat = 180

    var body: some View {
        let samples = results.graphSamples()
        let duration = max(0.1, (results.samples.last?.seconds ?? 0) + 0.1)
        let loudnessCeiling = max(0, ceil(samples.compactMap(\.momentaryLUFS).max() ?? 0),
                                  ceil(samples.compactMap(\.shortTermLUFS).max() ?? 0))
        let levelCeiling = max(0, ceil(samples.compactMap(\.peakDBFS).max() ?? 0))
        VStack(alignment: .leading, spacing: 12) {
            Text("Loudness over time").font(.headline)
            Chart {
                ForEach(samples, id: \.seconds) { sample in
                    // Omit the initial incomplete windows. Later silence is
                    // shown at the floor so a line never bridges quiet sections.
                    if sample.seconds >= 0.299 {
                        LineMark(x: .value("Time", sample.seconds),
                                 y: .value("LUFS", max(-70, sample.momentaryLUFS ?? -70)),
                                 series: .value("Window", "Momentary (400 ms)"))
                            .foregroundStyle(by: .value("Window", "Momentary (400 ms)"))
                            .symbol(Circle())
                            .symbolSize(samples.count <= 40 ? 8 : 0)
                    }
                    if sample.seconds >= 2.899 {
                        LineMark(x: .value("Time", sample.seconds),
                                 y: .value("LUFS", max(-70, sample.shortTermLUFS ?? -70)),
                                 series: .value("Window", "Short-term (3 s)"))
                            .foregroundStyle(by: .value("Window", "Short-term (3 s)"))
                            .symbol(Circle())
                            .symbolSize(samples.count <= 40 ? 8 : 0)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                }
            }
            .chartForegroundStyleScale(["Momentary (400 ms)": Color.blue, "Short-term (3 s)": Color.orange])
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: -70...loudnessCeiling)
            .chartXAxisLabel("Seconds")
            .chartYAxisLabel("LUFS")
            .frame(height: chartHeight)

            Text("Audio levels over time").font(.headline)
            Chart {
                ForEach(samples, id: \.seconds) { sample in
                    LineMark(x: .value("Time", sample.seconds),
                             y: .value("Level", max(-90, sample.peakDBFS ?? -90)),
                             series: .value("Level", "Sample peak"))
                        .foregroundStyle(by: .value("Level", "Sample peak"))
                        .symbol(Circle())
                        .symbolSize(samples.count <= 40 ? 8 : 0)
                    LineMark(x: .value("Time", sample.seconds),
                             y: .value("Level", max(-90, sample.rmsDBFS ?? -90)),
                             series: .value("Level", "RMS"))
                        .foregroundStyle(by: .value("Level", "RMS"))
                        .symbol(Circle())
                        .symbolSize(samples.count <= 40 ? 8 : 0)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .chartForegroundStyleScale(["Sample peak": Color.purple, "RMS": Color.teal])
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: -90...levelCeiling)
            .chartXAxisLabel("Seconds")
            .chartYAxisLabel("dBFS")
            .frame(height: chartHeight)
            Text("Peak and RMS use 100 ms windows across the selected channels. Values below -70 LUFS or -90 dBFS are shown at the chart floor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AnalyticsResultsView: View {
    let results: AnalyticsResults
    var onRunMetrics: (([QualityMetric]) -> Void)?
    var isEmbedded = false
    @Environment(\.dismiss) var dismiss

    /// Metrics that have not been run yet
    private var missingMetrics: [QualityMetric] {
        let completedMetrics = Set(results.metrics.map(\.metric))
        return QualityMetric.allCases.filter { !completedMetrics.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
                .padding()

            Divider()

            // Score cards
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(results.metrics, id: \.metric) { metric in
                        MetricScoreCard(result: metric)
                            .accessibilityIdentifier("analysis.result.\(metric.metric.rawValue)")
                    }

                    if !missingMetrics.isEmpty, onRunMetrics != nil {
                        missingMetricsSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer with export and close buttons
            footerSection
                .padding()
        }
        .frame(width: isEmbedded ? nil : 500, height: isEmbedded ? nil : 500)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Analytics")
                .font(.title2)
                .fontWeight(.semibold)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Source:")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(results.sourceFileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text("Encoded:")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(results.encodedFileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(results.timestamp, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Missing Metrics

    private var missingMetricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional Metrics")
                .font(.headline)
                .foregroundColor(.secondary)

            ForEach(missingMetrics, id: \.self) { metric in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.displayName)
                            .font(.subheadline)
                        Text(metric.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if metric == .ssimulacra2 && !BinaryPathResolver.isSSIMULACRA2Available {
                        Text("Tool unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Run") {
                            if !isEmbedded { dismiss() }
                            onRunMetrics?([metric])
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("analysis.metric.run.\(metric.rawValue)")
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            if missingMetrics.count > 1 {
                let runnableMetrics = missingMetrics.filter { metric in
                    metric != .ssimulacra2 || BinaryPathResolver.isSSIMULACRA2Available
                }
                if runnableMetrics.count > 1 {
                    Button("Run All") {
                        if !isEmbedded { dismiss() }
                        onRunMetrics?(runnableMetrics)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Export JSON") {
                exportResults(format: .json)
            }

            Button("Export PDF") {
                exportResults(format: .pdf)
            }

            Spacer()

            if !isEmbedded {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Export

    private func exportResults(format: AnalyticsExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .json
            ? [.json]
            : [.pdf]
        panel.nameFieldStringValue = "\(results.encodedFileName)_analytics.\(format.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .json:
                try AnalyticsExporter.exportJSON(results: results, to: url)
            case .pdf:
                try AnalyticsExporter.exportPDF(results: results, to: url)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Score Card

struct MetricScoreCard: View {
    let result: MetricResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Metric name and rating
            HStack {
                Text(result.metric.displayName)
                    .font(.headline)
                Spacer()
                Text(result.qualityRating)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(ratingColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ratingColor.opacity(0.15))
                    )
            }

            // Main score
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(result.formattedScore)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(ratingColor)

            }

            // Min/Max range
            if let min = result.min, let max = result.max {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("Min:")
                            .foregroundColor(.secondary)
                        Text(min == .infinity ? "∞" : String(format: "%.1f", min))
                    }
                    HStack(spacing: 4) {
                        Text("Max:")
                            .foregroundColor(.secondary)
                        Text(max == .infinity ? "∞" : String(format: "%.1f", max))
                    }
                }
                .font(.caption)
            }

            // Channel scores (PSNR)
            if let channels = result.channelScores, !channels.isEmpty {
                HStack(spacing: 16) {
                    ForEach(channels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 4) {
                            Text("\(key):")
                                .foregroundColor(.secondary)
                            Text(value == .infinity ? "∞ dB" : String(format: "%.2f dB", value))
                        }
                        .font(.caption)
                    }
                }
            }

            // Scale reference
            Text(scaleDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ratingColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var ratingColor: Color {
        switch result.qualityColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .secondary
        }
    }

    private var scaleDescription: String {
        switch result.metric {
        case .vmaf:
            return "Scale: 0-100. >93 Excellent, >80 Good, >60 Fair, <60 Poor"
        case .psnr:
            return "Scale: dB. >40 Excellent, >30 Good, >20 Fair, <20 Poor"
        case .xpsnr:
            return "Scale: dB. >42 Excellent, >32 Good, >22 Fair, <22 Poor"
        case .ssimulacra2:
            return "Scale: 0-100. >90 Excellent, >70 Good, >50 Fair, <50 Poor"
        }
    }
}

#Preview {
    AnalyticsResultsView(results: AnalyticsResults(
        sourceFileName: "test_source.mov",
        encodedFileName: "test_output.mp4",
        metrics: [
            MetricResult(metric: .vmaf, overallScore: 92.5, min: 78.3, max: 99.1, unit: "score", channelScores: nil),
            MetricResult(metric: .psnr, overallScore: 38.7, min: 25.2, max: 48.9, unit: "dB", channelScores: ["Y": 38.7, "U": 42.3, "V": 43.1]),
            MetricResult(metric: .ssimulacra2, overallScore: 85.2, min: 62.4, max: 97.8, unit: "score", channelScores: nil)
        ],
        timestamp: Date(),
        durationSeconds: 120.0
    ))
}
