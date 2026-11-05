// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// Completed loudness reports from the Audio tab, offered in the combined PDF export.
struct LoudnessReportSnapshot: Equatable {
    let results: [LoudnessResults]
    let file: URL
    let timestamp: Date
    /// Display names keyed by presentation ID, matching the Audio tab's report picker.
    let labels: [String: String]
}

/// Chooses which analyses go into one PDF report for the whole analysis sheet.
struct AnalysisReportExportView: View {
    let sourceFile: URL
    let outputFile: URL?
    let hasVideo: Bool
    let quality: AnalyticsResults?
    let loudness: LoudnessReportSnapshot?

    @Environment(\.dismiss) private var dismiss
    @State private var metrics: Set<QualityMetric>
    @State private var qualityBitrate = true
    @State private var sourceBitrate = true
    @State private var encodedBitrate = true
    @State private var loudnessReports: Set<String>
    @State private var exporting = false
    @State private var errorMessage: String?

    init(sourceFile: URL, outputFile: URL?, hasVideo: Bool, quality: AnalyticsResults?, loudness: LoudnessReportSnapshot?) {
        self.sourceFile = sourceFile
        self.outputFile = outputFile
        self.hasVideo = hasVideo
        self.quality = quality
        self.loudness = loudness
        _metrics = State(initialValue: Set(quality?.metrics.map(\.metric) ?? []))
        _loudnessReports = State(initialValue: Set(loudness?.results.map(\.presentation.id) ?? []))
    }

    /// Bitrate is drawn under quality charts only while the output is still the analyzed encode.
    private var qualityOutputMatches: Bool {
        guard let outputFile, let quality else { return false }
        return outputFile.lastPathComponent == quality.encodedFileName
    }

    private var bitrateStream: BitrateStreamKind { hasVideo ? .video : .audio }

    private var hasSelection: Bool {
        !metrics.isEmpty || sourceBitrate || (encodedBitrate && outputFile != nil) || !loudnessReports.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Analysis Report").font(.title2.bold())
                Text("Choose what to include in the PDF.").foregroundStyle(.secondary)
            }
            section("Video quality") {
                if let quality, !quality.metrics.isEmpty {
                    ForEach(quality.metrics, id: \.metric) { result in
                        Toggle(result.metric.displayName, isOn: binding(for: result.metric, in: $metrics))
                            .accessibilityIdentifier("analysis.export.metric.\(result.metric.rawValue)")
                    }
                    Toggle("Show encoded bitrate under quality charts", isOn: $qualityBitrate)
                        .disabled(metrics.isEmpty || !qualityOutputMatches)
                        .accessibilityIdentifier("analysis.export.qualityBitrate")
                } else {
                    Text("Run a video analysis to include quality results.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            section(hasVideo ? "Video Bitrate" : "Audio Bitrate") {
                Toggle(String(format: String(localized: "Source: %@"), sourceFile.lastPathComponent), isOn: $sourceBitrate)
                    .accessibilityIdentifier("analysis.export.sourceBitrate")
                if let outputFile {
                    Toggle(String(format: String(localized: "Encoded: %@"), outputFile.lastPathComponent), isOn: $encodedBitrate)
                        .accessibilityIdentifier("analysis.export.encodedBitrate")
                }
            }
            section("Audio loudness") {
                if let loudness {
                    ForEach(loudness.results, id: \.presentation.id) { report in
                        Toggle(loudness.labels[report.presentation.id] ?? report.presentation.displayName,
                               isOn: binding(for: report.presentation.id, in: $loudnessReports))
                    }
                } else {
                    Text("Run a loudness analysis in the Audio tab to include it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if exporting {
                    ProgressView().controlSize(.small)
                    Text("Preparing report…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export PDF…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSelection || exporting)
                    .accessibilityIdentifier("analysis.export.save")
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(exporting)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }

    private func binding<Value: Hashable>(for value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) },
                set: { included in
                    if included { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
                })
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(sourceFile.deletingPathExtension().lastPathComponent)_analysis.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        errorMessage = nil
        Task { @MainActor in
            defer { exporting = false }
            do {
                let content = try await reportContent()
                let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
                defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                try AnalyticsExporter.exportReport(content, to: url)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Bitrate scans run here rather than up front; the service caches them per file.
    private func reportContent() async throws -> AnalysisReportContent {
        var content = AnalysisReportContent()
        if let quality, !metrics.isEmpty {
            content.quality = AnalyticsResults(sourceFileName: quality.sourceFileName,
                                               encodedFileName: quality.encodedFileName,
                                               metrics: quality.metrics.filter { metrics.contains($0.metric) },
                                               timestamp: quality.timestamp,
                                               durationSeconds: quality.durationSeconds)
            if qualityBitrate, qualityOutputMatches, let outputFile {
                content.qualityBitrate = try await BitrateAnalysisService.shared.analyze(file: outputFile, stream: .video)
            }
        }
        if sourceBitrate {
            content.bitrateFiles.append(.init(
                label: String(localized: "Source"), fileName: sourceFile.lastPathComponent,
                timeline: try await BitrateAnalysisService.shared.analyze(file: sourceFile, stream: bitrateStream),
                isEncoded: false))
        }
        if encodedBitrate, let outputFile {
            content.bitrateFiles.append(.init(
                label: String(localized: "Encoded"), fileName: outputFile.lastPathComponent,
                timeline: try await BitrateAnalysisService.shared.analyze(file: outputFile, stream: bitrateStream),
                isEncoded: true))
        }
        if let loudness {
            content.loudness = loudness.results.filter { loudnessReports.contains($0.presentation.id) }
            content.loudnessFileName = loudness.file.lastPathComponent
            content.loudnessTimestamp = loudness.timestamp
        }
        return content
    }
}
