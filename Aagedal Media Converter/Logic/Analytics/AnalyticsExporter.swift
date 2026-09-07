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
