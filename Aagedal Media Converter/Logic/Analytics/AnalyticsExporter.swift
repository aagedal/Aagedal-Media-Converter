// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI
import OSLog

/// Exports analytics results to JSON or PDF
enum AnalyticsExporter {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AnalyticsExporter")

    /// Automatically exports analytics results next to the encoded file if auto-export is enabled in settings
    @MainActor
    static func autoExportIfEnabled(
        results: AnalyticsResults,
        encodedFileURL: URL,
        settings: AnalyticsAutoExportSettingsSnapshot
    ) {
        guard settings.enabled else { return }
        let format = settings.format

        let baseName = encodedFileURL.deletingPathExtension().lastPathComponent
        let exportURL = encodedFileURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_analytics.\(format.fileExtension)")

        do {
            switch format {
            case .json:
                try exportJSON(results: results, to: exportURL)
            case .pdf:
                try exportPDF(results: results, to: exportURL)
            }
            logger.info("Auto-exported analytics to \(exportURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Auto-export failed: \(error.localizedDescription, privacy: .public)")
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
        let reportView = AnalyticsPDFReportView(results: results)
        let hostingView = NSHostingView(rootView: reportView)

        let pageWidth: CGFloat = 595  // A4 width in points
        let pageHeight: CGFloat = 842 // A4 height in points
        hostingView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let fittingSize = hostingView.fittingSize
        let contentHeight = max(fittingSize.height, pageHeight)
        hostingView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: contentHeight)

        let pdfData = hostingView.dataWithPDF(inside: hostingView.bounds)
        try pdfData.write(to: url)
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
                                Text(String(format: "%.1f", min))
                                    .font(.body)
                            }
                        }

                        if let max = metric.max {
                            VStack(alignment: .leading) {
                                Text("Max")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f", max))
                                    .font(.body)
                            }
                        }
                    }

                    if let channels = metric.channelScores, !channels.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(channels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key): \(String(format: "%.2f", value)) \(metric.unit)")
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
