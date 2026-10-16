// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI
import OSLog

/// Exports analytics results to JSON or PDF
enum AnalyticsExporter {

    /// A versioned source report. Channel numbers are one-based decoded order;
    /// the track index is audio-relative, matching the scanner's 0:a:index map.
    /// Keep the schema independent of UI language and never export the source path.
    private struct AudioPeakReport: Encodable {
        let schemaVersion = 1
        let analysis = "source_sample_peaks_and_channel_balance"
        let sourceFileName: String
        let audioRelativeTrackIndex: Int
        let timestamp: Date
        let semantics = Semantics()
        let result: AudioPeakAnalysisResult

        struct Semantics: Encodable {
            let channelNumbering = "one_based_decoded_order"
            let timeUnit = "seconds"
            let timeline = "file_relative_including_initial_audio_offset"
            let duration = "end_of_decoded_audio_on_file_timeline"
            let peakUnit = "dBFS"
            let peakMeasurement = "source_sample_peak_not_intersample_true_peak"
            let windowSamples = 4_800
            let intervalBoundaries = "analysis_windows_merged_per_channel_when_adjacent"
            let thresholdComparison = "greater_than_or_equal"
            let rmsMeasurement = "unweighted_whole_track_sample_weighted_energy"
            let imbalanceUnit = "dB"
            let imbalanceMeasurement = "maximum_minus_minimum_channel_rms"
            let unavailableImbalance = "omitted_for_mono_or_entirely_silent_audio"
            let negativeInfinity = "-Infinity_means_digital_silence"
            let positiveInfinity = "Infinity_means_silent_and_active_channels"
            let scope = "complete_selected_source_track_independent_of_volume_mute_and_conversion_trims"
        }
    }

    static func audioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                              trackIndex: Int, timestamp: Date) throws -> Data {
        try result.settings.validate()
        guard trackIndex >= 0, timestamp.timeIntervalSince1970.isFinite,
              result.duration.isFinite, result.duration > 0,
              !result.channels.isEmpty,
              result.channels.allSatisfy({
                  ($0.peakDBFS.isFinite || $0.peakDBFS == -.infinity) &&
                  ($0.rmsDBFS.isFinite || $0.rmsDBFS == -.infinity)
              }),
              result.intervals.allSatisfy({
                  $0.start.isFinite && $0.end.isFinite && $0.peakDBFS.isFinite &&
                  $0.start >= 0 && $0.end > $0.start && $0.end <= result.duration
              }),
              result.imbalanceDB.map({ ($0.isFinite && $0 >= 0) || $0 == .infinity }) ?? true else {
            throw EncodingError.invalidValue(result, .init(codingPath: [], debugDescription: "Invalid audio peak report."))
        }
        let report = AudioPeakReport(sourceFileName: sourceFile.lastPathComponent,
                                     audioRelativeTrackIndex: trackIndex, timestamp: timestamp, result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // JSON has no infinity literal. Preserve silence and infinite channel
        // difference explicitly rather than conflating either with missing data.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(report)
    }

    static func exportAudioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                                    trackIndex: Int, timestamp: Date, to url: URL) throws {
        let data = try audioPeakJSON(result: result, sourceFile: sourceFile, trackIndex: trackIndex, timestamp: timestamp)
        try data.write(to: url, options: .atomic)
    }

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AnalyticsExporter")

    /// Automatically exports analytics results next to the encoded file if auto-export is enabled in settings
    @MainActor
    static func autoExportIfEnabled(
        results: AnalyticsResults,
        encodedFileURL: URL,
        settings: AnalyticsAutoExportSettingsSnapshot
    ) {
        guard settings.enabled else { return }
        do {
            let exportURL = try autoExport(results: results, encodedFileURL: encodedFileURL, format: settings.format)
            logger.info("Auto-exported analytics to \(exportURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Auto-export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exclusive creation also protects against another app process exporting concurrently.
    @MainActor
    static func autoExport(results: AnalyticsResults, encodedFileURL: URL, format: AnalyticsExportFormat) throws -> URL {
        let data: Data
        switch format {
        case .json:
            guard let json = results.toJSON() else {
                throw AnalyticsError.parsingFailed("Failed to encode results to JSON")
            }
            data = json
        case .pdf:
            data = pdfData(results: results)
        }
        let baseName = encodedFileURL.deletingPathExtension().lastPathComponent + "_analytics"
        let folder = encodedFileURL.deletingLastPathComponent()
        var suffix = 0
        while true {
            let name = suffix == 0 ? baseName : "\(baseName)_\(suffix)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    /// Exports results to a pretty-printed JSON file
    static func exportJSON(results: AnalyticsResults, to url: URL) throws {
        guard let data = results.toJSON() else {
            throw AnalyticsError.parsingFailed("Failed to encode results to JSON")
        }
        try data.write(to: url)
    }

    /// Exports results to a PDF report
    @MainActor
    static func exportPDF(results: AnalyticsResults, to url: URL) throws {
        try pdfData(results: results).write(to: url, options: .atomic)
    }

    @MainActor
    private static func pdfData(results: AnalyticsResults) -> Data {
        let reportView = AnalyticsPDFReportView(results: results)
        let hostingView = NSHostingView(rootView: reportView)

        let pageWidth: CGFloat = 595  // A4 width in points
        let pageHeight: CGFloat = 842 // A4 height in points
        hostingView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let fittingSize = hostingView.fittingSize
        let contentHeight = max(fittingSize.height, pageHeight)
        hostingView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: contentHeight)

        return hostingView.dataWithPDF(inside: hostingView.bounds)
    }

    /// Render the same summary and timelines as the analysis sheet on an A4 page.
    @MainActor
    static func exportLoudnessPDF(results: LoudnessResults, fileName: String, to url: URL) throws {
        try exportLoudnessPDF(results: [results], fileName: fileName, to: url)
    }

    /// Each independently measured presentation receives its own complete A4 page.
    @MainActor
    static func exportLoudnessPDF(results: [LoudnessResults], fileName: String, to url: URL) throws {
        guard !results.isEmpty else {
            throw AnalyticsError.parsingFailed("No loudness reports to export")
        }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AnalyticsError.parsingFailed("Could not create the loudness PDF report")
        }
        for result in results {
            let report = LoudnessPDFReportView(results: result, fileName: fileName)
                .frame(width: 595, height: 842)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: report)
            renderer.proposedSize = ProposedViewSize(width: 595, height: 842)
            var succeeded = false
            renderer.render { _, render in
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
                succeeded = true
            }
            guard succeeded else {
                context.closePDF()
                throw AnalyticsError.parsingFailed("Could not render the loudness PDF report")
            }
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

}

private struct LoudnessPDFReportView: View {
    let results: LoudnessResults
    let fileName: String
    private let timestamp = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Loudness Analysis").font(.title.bold())
            VStack(alignment: .leading, spacing: 5) {
                Text(fileName).font(.headline).lineLimit(2)
                Text("Audio presentation: \(results.presentation.displayName)")
                Text("Complete file • \(timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Divider()
            LoudnessSummaryView(results: results)
            LoudnessTimelineView(results: results, chartHeight: 180)
            Text("Integrated loudness is the gated whole-program measurement, not an average of graph readings. Below gate indicates no loudness above -70 LUFS. Maximum true peak is measured across the selected channels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if (results.samples.last?.seconds ?? 0) < 60 {
                Text("Loudness range is not considered stable for programs shorter than one minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Generated by Aagedal Media Converter").font(.caption).foregroundStyle(.secondary)
        }
        .padding(36)
    }
}

// MARK: - PDF Report View

/// SwiftUI view designed for PDF rendering
private struct AnalyticsPDFReportView: View {
    let results: AnalyticsResults

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Title
            Text("Quality Analytics Report")
                .font(.title)
                .fontWeight(.bold)

            // File info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Source File:")
                        .fontWeight(.medium)
                    Text(results.sourceFileName)
                }
                HStack {
                    Text("Encoded File:")
                        .fontWeight(.medium)
                    Text(results.encodedFileName)
                }
                HStack {
                    Text("Date:")
                        .fontWeight(.medium)
                    Text(results.timestamp, style: .date)
                    Text(results.timestamp, style: .time)
                }
            }
            .font(.body)

            Divider()

            // Metrics
            ForEach(results.metrics, id: \.metric) { metric in
                VStack(alignment: .leading, spacing: 8) {
                    if let comparison = metric.comparison {
                        Text(comparison.summary).font(.caption).foregroundStyle(.secondary)
                        ForEach(comparison.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text(metric.metric.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("Overall Score")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(metric.formattedScore)
                                .font(.title)
                                .fontWeight(.bold)
                        }

                        VStack(alignment: .leading) {
                            Text("Quality")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(metric.qualityRating)
                                .font(.title3)
                        }

                        if let min = metric.min {
                            VStack(alignment: .leading) {
                                Text("Min")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(min == .infinity ? "∞" : String(format: "%.1f", min))
                                    .font(.body)
                            }
                        }

                        if let max = metric.max {
                            VStack(alignment: .leading) {
                                Text("Max")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(max == .infinity ? "∞" : String(format: "%.1f", max))
                                    .font(.body)
                            }
                        }
                    }

                    if let channels = metric.channelScores, !channels.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(channels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key): \(value == .infinity ? "∞" : String(format: "%.2f", value)) \(metric.unit)")
                                    .font(.caption)
                            }
                        }
                    }

                    Divider()
                }
            }

            Spacer()

            Text("Generated by Aagedal Media Converter")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
    }
}
