// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Charts

/// One-file loudness report, with an explicit audio presentation choice. The
/// grouped presets never silently reinterpret multiple mono streams.
struct LoudnessAnalysisView: View {
    let sourceFile: URL
    let outputFile: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFileID = "source"
    @State private var tracks: [AudioTrackInfo] = []
    @State private var selectedPresentationID = ""
    @State private var isProbing = true
    @State private var isAnalyzing = false
    @State private var results: LoudnessResults?
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID: UUID?

    private var presentations: [LoudnessPresentation] {
        LoudnessPresentation.presets(for: tracks)
    }

    private var file: URL {
        selectedFileID == "output" ? outputFile ?? sourceFile : sourceFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Program Loudness")
                        .font(.title2.bold())
                    Text(file.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            if isProbing {
                ProgressView("Reading audio tracks…")
            } else if presentations.isEmpty {
                ContentUnavailableView("No audio tracks found", systemImage: "speaker.slash")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let outputFile {
                        Picker("File", selection: $selectedFileID) {
                            Text("Source: \(sourceFile.lastPathComponent)").tag("source")
                            Text("Output: \(outputFile.lastPathComponent)").tag("output")
                        }
                    }
                    Picker("Audio presentation", selection: $selectedPresentationID) {
                        ForEach(presentations) { presentation in
                            Text(label(for: presentation)).tag(presentation.id)
                        }
                    }
                    Text("Group presets assume the listed stream order is the playout channel order. Check the file's routing or MCA labels before using a grouped result for QC.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(isAnalyzing ? "Analyzing…" : "Analyze Whole File") { analyze() }
                            .disabled(isAnalyzing || selectedPresentationID.isEmpty)
                        if isAnalyzing {
                            Button("Cancel") { analysisTask?.cancel() }
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let results {
                Divider()
                HStack(spacing: 22) {
                    value("Integrated", value: String(format: "%.1f LUFS", results.integratedLUFS))
                    value("Loudness range", value: String(format: "%.1f LU", results.loudnessRangeLU))
                    value("Maximum true peak", value: results.maximumTruePeakDBTP.map {
                        String(format: "%.1f dBTP", $0)
                    } ?? "—")
                }
                Text("Integrated loudness is gated over the complete selected program; it is not an average of the graph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if (results.samples.last?.seconds ?? 0) < 60 {
                    Text("Loudness range is not considered stable for programs shorter than one minute.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Chart {
                    ForEach(results.graphSamples(), id: \.seconds) { sample in
                        if let momentary = sample.momentaryLUFS {
                            LineMark(x: .value("Time", sample.seconds),
                                     y: .value("LUFS", momentary),
                                     series: .value("Window", "Momentary (400 ms)"))
                                .foregroundStyle(by: .value("Window", "Momentary (400 ms)"))
                        }
                        if let shortTerm = sample.shortTermLUFS {
                            LineMark(x: .value("Time", sample.seconds),
                                     y: .value("LUFS", shortTerm),
                                     series: .value("Window", "Short-term (3 s)"))
                                .foregroundStyle(by: .value("Window", "Short-term (3 s)"))
                        }
                    }
                }
                .chartYScale(domain: -70...0)
                .chartXAxisLabel("Seconds")
                .chartYAxisLabel("LUFS")
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 730, height: 560)
        .task(id: file) {
            isProbing = true
            tracks = []
            let probed = await AudioRoutingService.fetchAudioTrackInfo(for: file)
            guard !Task.isCancelled else { return }
            tracks = probed
            selectedPresentationID = presentations.first?.id ?? ""
            isProbing = false
        }
        .onChange(of: selectedFileID) {
            analysisID = nil
            analysisTask?.cancel()
            analysisTask = nil
            tracks = []
            selectedPresentationID = ""
            isProbing = true
            results = nil
            errorMessage = nil
            isAnalyzing = false
        }
        .onDisappear {
            analysisID = nil
            analysisTask?.cancel()
        }
    }

    private func value(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
    }

    private func label(for presentation: LoudnessPresentation) -> String {
        guard case .track(let index) = presentation,
              let track = tracks.first(where: { $0.streamIndex == index }) else {
            return presentation.displayName
        }
        let language = track.languageCode.map { " • \($0.uppercased())" } ?? ""
        return track.displayLabel + language
    }

    private func analyze() {
        guard let presentation = presentations.first(where: { $0.id == selectedPresentationID }) else { return }
        results = nil
        errorMessage = nil
        isAnalyzing = true
        let id = UUID()
        let analyzedFile = file
        analysisID = id
        analysisTask = Task { @MainActor in
            do {
                let measured = try await LoudnessAnalysisService.shared.analyze(file: analyzedFile, presentation: presentation)
                try Task.checkCancellation()
                if analysisID == id { results = measured }
            } catch is CancellationError {
                // The next presentation can be run immediately.
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

struct AnalyticsResultsView: View {
    let results: AnalyticsResults
    var onRunMetrics: (([QualityMetric]) -> Void)?
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
        .frame(width: 500, height: 500)
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
                        Text("Not installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Run") {
                            dismiss()
                            onRunMetrics?([metric])
                        }
                        .controlSize(.small)
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
                        dismiss()
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

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
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

                if result.metric == .psnr || result.metric == .xpsnr {
                    Text("dB")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }

            // Min/Max range
            if let min = result.min, let max = result.max {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("Min:")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", min))
                    }
                    HStack(spacing: 4) {
                        Text("Max:")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", max))
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
                            Text(String(format: "%.2f dB", value))
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
