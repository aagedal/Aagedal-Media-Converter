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
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private var exporting: Bool { exportTask != nil }

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
            Group {
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
            }
            .disabled(exporting)
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
                Button("Cancel") {
                    exportTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export PDF…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSelection || exporting)
                    .accessibilityIdentifier("analysis.export.save")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { exportTask?.cancel() }
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
        errorMessage = nil
        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let content = try await reportContent()
                try Task.checkCancellation()
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

    /// Bitrate scans run here rather than up front; the service caches them per file. A file
    /// whose scan fails, such as an audio-only encode of a video source, is left out of the
    /// report; the export only fails when nothing else was selected.
    private func reportContent() async throws -> AnalysisReportContent {
        var content = AnalysisReportContent()
        var bitrateError: Error?
        func scan(_ file: URL, stream: BitrateStreamKind) async throws -> BitrateTimeline? {
            do {
                return try await BitrateAnalysisService.shared.analyze(file: file, stream: stream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                bitrateError = bitrateError ?? error
                return nil
            }
        }
        if let quality, !metrics.isEmpty {
            content.quality = AnalyticsResults(sourceFileName: quality.sourceFileName,
                                               encodedFileName: quality.encodedFileName,
                                               metrics: quality.metrics.filter { metrics.contains($0.metric) },
                                               timestamp: quality.timestamp,
                                               durationSeconds: quality.durationSeconds)
            if qualityBitrate, qualityOutputMatches, let outputFile {
                content.qualityBitrate = try await scan(outputFile, stream: .video)
            }
        }
        if sourceBitrate, let timeline = try await scan(sourceFile, stream: bitrateStream) {
            content.bitrateFiles.append(.init(
                label: String(localized: "Source"), fileName: sourceFile.lastPathComponent,
                timeline: timeline, isEncoded: false))
        }
        if encodedBitrate, let outputFile, let timeline = try await scan(outputFile, stream: bitrateStream) {
            content.bitrateFiles.append(.init(
                label: String(localized: "Encoded"), fileName: outputFile.lastPathComponent,
                timeline: timeline, isEncoded: true))
        }
        if let loudness {
            content.loudness = loudness.results.filter { loudnessReports.contains($0.presentation.id) }
            content.loudnessFileName = loudness.file.lastPathComponent
            content.loudnessTimestamp = loudness.timestamp
        }
        if let bitrateError, content.quality == nil, content.bitrateFiles.isEmpty, content.loudness.isEmpty {
            throw bitrateError
        }
        return content
    }
}
