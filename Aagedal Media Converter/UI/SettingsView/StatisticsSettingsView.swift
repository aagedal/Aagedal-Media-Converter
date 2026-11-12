// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Statistics.
struct StatisticsSettingsView: View {
    var body: some View {
        EncodeStatisticsView(chartHeight: 180, showsOpenInWindow: true)
    }
}

/// The statistics in their own resizable window, with a taller chart.
struct EncodeStatisticsWindow: View {
    static let id = "encodeStatistics"

    var body: some View {
        EncodeStatisticsView(chartHeight: 320, showsOpenInWindow: false)
            .frame(minWidth: 560, minHeight: 480)
    }
}

/// Totals and charts from the encode history plus the monthly rollups of
/// records retention already pruned.
struct EncodeStatisticsView: View {
    let chartHeight: CGFloat
    let showsOpenInWindow: Bool

    @AppStorage(AppConstants.encodeHistoryEnabledKey)
    private var historyEnabled = AppConstants.defaultEncodeHistoryEnabled
    @AppStorage(AppConstants.encodeStatisticsPeriodKey)
    private var period: StatisticsPeriod = .month

    @Environment(\.openWindow) private var openWindow
    @State private var store = EncodeHistoryStore.shared
    /// Nil for all Macs.
    @State private var deviceFilter: String?
    @State private var exportError: String?

    var body: some View {
        let summary = store.statistics(for: period, deviceID: deviceFilter)
        let deviceIDs = store.historyDeviceIDs
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(StatisticsPeriod.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                if deviceIDs.count > 1 {
                    Picker("Mac", selection: $deviceFilter) {
                        Text("All Macs").tag(String?.none)
                        ForEach(deviceIDs, id: \.self) { id in
                            Text(verbatim: deviceLabel(id)).tag(String?.some(id))
                        }
                    }
                }
                if !historyEnabled {
                    Text("History recording is off, so new encodes aren’t counted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                actions(summary)
            }

            if summary.encodeCount == 0 && summary.sessionCount == 0 {
                Section {
                    Text("No encodes in this period.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            } else {
                Section("Overview") {
                    ForEach(EncodeStatisticsDisplay.overviewRows(summary)) { row in
                        LabeledContent(row.title) {
                            Text(verbatim: row.value)
                                .monospacedDigit()
                                .foregroundStyle(row.tint ?? .secondary)
                        }
                        .help(row.help ?? "")
                    }
                }
                Section("Encodes over Time") {
                    EncodeStatisticsChart(summary: summary, period: period)
                        .frame(height: chartHeight)
                }
                ForEach(rankedGroups(summary)) { group in
                    rankedSection(group)
                }
            }

            Section {
                Text("Statistics combine the detailed encode history with monthly summaries of encodes that are older than the history retention period. Monthly summaries only count toward a period when the whole month lies inside it, so the 7- and 30-day figures come from the detailed history alone. Clearing the history also resets the statistics.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isSyncEnabled {
                    Text("History sync is on, so the statistics include the encodes of your other Macs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Couldn’t Export Statistics", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    private func actions(_ summary: EncodeStatisticsSummary) -> some View {
        HStack {
            Spacer()
            Menu {
                Button("PDF Report…") { export(.pdf, summary: summary) }
                Button("Summary as CSV…") { export(.summaryCSV, summary: summary) }
                Button("Encodes as CSV…") { export(.recordsCSV, summary: summary) }
                    .disabled(store.records(for: period, deviceID: deviceFilter).isEmpty)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(summary.encodeCount == 0 && summary.sessionCount == 0)
            .help("Save these statistics as a PDF report or CSV for a spreadsheet")
            if showsOpenInWindow {
                Button {
                    openWindow(id: EncodeStatisticsWindow.id)
                } label: {
                    Label("Open in Window", systemImage: "macwindow")
                }
                .help("Show the statistics in a larger, resizable window")
            }
        }
    }

    private func deviceLabel(_ id: String) -> String {
        let name = store.deviceName(for: id) ?? id
        guard id == store.deviceID else { return name }
        return String(localized: "\(name) (this Mac)", comment: "Statistics Mac picker: the Mac the app runs on.")
    }

    private var macLabel: String {
        deviceFilter.map(deviceLabel) ?? String(localized: "All Macs")
    }

    private func rankedGroups(_ summary: EncodeStatisticsSummary) -> [StatisticsRankedGroup] {
        EncodeStatisticsDisplay.rankedGroups(summary, includeMacs: deviceFilter == nil, deviceLabel: deviceLabel)
    }

    private func rankedSection(_ group: StatisticsRankedGroup) -> some View {
        let maximum = Double(group.items.map(\.count).max() ?? 1)
        return Section(group.title) {
            ForEach(group.items) { item in
                LabeledContent {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(item.count), total: maximum)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(item.count)")
                            .monospacedDigit()
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                } label: {
                    Text(verbatim: item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Export

    private enum ExportFormat {
        case pdf, summaryCSV, recordsCSV
    }

    private func export(_ format: ExportFormat, summary: EncodeStatisticsSummary) {
        let date = Date()
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = String(localized: "Encode Statistics \(period.label) \(day).pdf",
                                                comment: "Default file name of the statistics PDF report.")
        case .summaryCSV:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = String(localized: "Encode Statistics \(period.label) \(day).csv",
                                                comment: "Default file name of the statistics summary CSV.")
        case .recordsCSV:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = String(localized: "Encodes \(period.label) \(day).csv",
                                                comment: "Default file name of the CSV with one row per encode.")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data: Data
            switch format {
            case .pdf:
                data = try EncodeStatisticsPDF.render(
                    summary: summary, period: period, macLabel: macLabel,
                    includeMacs: deviceFilter == nil, deviceLabel: deviceLabel,
                    includesSync: store.isSyncEnabled, generatedAt: date
                )
            case .summaryCSV:
                data = Self.csvData(EncodeStatisticsExport.summaryCSV(
                    summary, period: period, macLabel: macLabel, deviceLabel: deviceLabel, generatedAt: date
                ))
            case .recordsCSV:
                data = Self.csvData(EncodeStatisticsExport.recordsCSV(
                    store.records(for: period, deviceID: deviceFilter),
                    deviceLabel: { record in
                        record.deviceID.map(deviceLabel) ?? record.deviceName
                    }
                ))
            }
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// UTF-8 with a byte-order mark, so Excel reads non-ASCII names correctly.
    private static func csvData(_ text: String) -> Data {
        Data("\u{FEFF}".utf8) + Data(text.utf8)
    }
}

// MARK: - Shared content

/// Bar chart of encodes per day or month, shared by the views and the PDF.
struct EncodeStatisticsChart: View {
    let summary: EncodeStatisticsSummary
    let period: StatisticsPeriod

    private var completedSeries: String { String(localized: "Completed", comment: "Statistics chart series.") }
    private var failedSeries: String { String(localized: "Failed", comment: "Statistics chart series.") }
    private var otherSeries: String {
        String(localized: "Cancelled or interrupted", comment: "Statistics chart series for encodes that didn't finish.")
    }

    var body: some View {
        let unit: Calendar.Component = period.granularity
        Chart {
            ForEach(summary.timeline) { bucket in
                ForEach(series(bucket), id: \.name) { entry in
                    BarMark(
                        x: .value("Date", bucket.start, unit: unit),
                        y: .value("Encodes", entry.count)
                    )
                    .foregroundStyle(by: .value("Result", entry.name))
                }
            }
        }
        .chartForegroundStyleScale([
            completedSeries: Color.green,
            failedSeries: Color.red,
            otherSeries: Color.orange,
        ])
        .chartLegend(position: .bottom)
        .accessibilityLabel("Encodes over time")
    }

    private func series(_ bucket: StatisticsTimelineBucket) -> [(name: String, count: Int)] {
        [(completedSeries, bucket.completed), (failedSeries, bucket.failed), (otherSeries, bucket.other)]
    }
}

struct StatisticsOverviewRow: Identifiable {
    let title: String
    let value: String
    var tint: Color?
    var help: String?
    var id: String { title }
}

struct StatisticsRankedItem: Identifiable {
    let label: String
    let count: Int
    var id: String { label }
}

struct StatisticsRankedGroup: Identifiable {
    let title: String
    let items: [StatisticsRankedItem]
    var id: String { title }
}

enum EncodeStatisticsDisplay {
    static func overviewRows(_ summary: EncodeStatisticsSummary) -> [StatisticsOverviewRow] {
        var rows = [
            StatisticsOverviewRow(title: String(localized: "Encodes"), value: "\(summary.encodeCount)"),
            StatisticsOverviewRow(title: String(localized: "Completed"), value: "\(summary.count(.completed))"),
            StatisticsOverviewRow(title: String(localized: "Failed"), value: "\(summary.count(.failed))",
                                  tint: summary.count(.failed) > 0 ? .red : nil),
            StatisticsOverviewRow(title: String(localized: "Cancelled"), value: "\(summary.count(.cancelled))"),
            StatisticsOverviewRow(title: String(localized: "Interrupted"), value: "\(summary.count(.interrupted))",
                                  tint: summary.count(.interrupted) > 0 ? .orange : nil,
                                  help: String(localized: "Encodes that were still running when the app quit or crashed")),
            StatisticsOverviewRow(title: String(localized: "Unexpected exits"), value: "\(summary.unexpectedExitCount)",
                                  tint: summary.unexpectedExitCount > 0 ? .orange : nil,
                                  help: String(localized: "App sessions that ended without a normal quit, such as a crash or force quit")),
            StatisticsOverviewRow(title: String(localized: "Media encoded"), value: hours(summary.mediaSecondsEncoded)),
            StatisticsOverviewRow(title: String(localized: "Time spent encoding"), value: hours(summary.encodeWallSeconds)),
        ]
        if let speed = summary.averageSpeed {
            rows.append(StatisticsOverviewRow(
                title: String(localized: "Average speed"),
                value: String(localized: "\(speed.formatted(.number.precision(.fractionLength(1))))× realtime",
                              comment: "Statistics: average encode speed relative to the media duration.")
            ))
        }
        if summary.bytesIn > 0 {
            rows.append(StatisticsOverviewRow(title: String(localized: "Source data"),
                                              value: EncodeHistoryFormat.bytes(summary.bytesIn)))
            rows.append(StatisticsOverviewRow(title: String(localized: "Output data"),
                                              value: EncodeHistoryFormat.bytes(summary.bytesOut)))
            rows.append(StatisticsOverviewRow(
                title: summary.bytesSaved >= 0 ? String(localized: "Space saved") : String(localized: "Space added"),
                value: EncodeHistoryFormat.bytes(abs(summary.bytesSaved)),
                help: String(localized: "Difference between source and output sizes of completed encodes")
            ))
        }
        return rows
    }

    static func rankedGroups(
        _ summary: EncodeStatisticsSummary,
        includeMacs: Bool,
        deviceLabel: (String) -> String
    ) -> [StatisticsRankedGroup] {
        func group(_ title: String, _ items: [RankedCount], _ label: (String) -> String) -> StatisticsRankedGroup? {
            items.isEmpty ? nil : StatisticsRankedGroup(
                title: title, items: items.map { StatisticsRankedItem(label: label($0.key), count: $0.count) }
            )
        }
        var groups = [
            group(String(localized: "Top Presets"), summary.topPresets) { $0 },
            group(String(localized: "Top Video Codecs"), summary.topVideoCodecs) { $0.uppercased() },
            group(String(localized: "Top Containers"), summary.topContainers) { $0.uppercased() },
            group(String(localized: "Top Resolutions"), summary.topResolutions) { ResolutionBucket.label(forKey: $0) },
        ]
        if includeMacs && summary.topDevices.count > 1 {
            groups.append(group(String(localized: "Encodes by Mac"), summary.topDevices, deviceLabel))
        }
        return groups.compactMap { $0 }
    }

    static func hours(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0" }
        if seconds < 3600 {
            return Measurement(value: seconds / 60, unit: UnitDuration.minutes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return Measurement(value: seconds / 3600, unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}
