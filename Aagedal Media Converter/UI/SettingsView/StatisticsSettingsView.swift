// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Charts
import SwiftUI

/// Settings → Statistics: totals and charts from the encode history plus the
/// monthly rollups of records retention already pruned.
struct StatisticsSettingsView: View {
    @AppStorage(AppConstants.encodeHistoryEnabledKey)
    private var historyEnabled = AppConstants.defaultEncodeHistoryEnabled

    @State private var store = EncodeHistoryStore.shared
    @State private var period: StatisticsPeriod = .month

    private var completedSeries: String { String(localized: "Completed", comment: "Statistics chart series.") }
    private var failedSeries: String { String(localized: "Failed", comment: "Statistics chart series.") }
    private var otherSeries: String {
        String(localized: "Cancelled or interrupted", comment: "Statistics chart series for encodes that didn't finish.")
    }

    var body: some View {
        let summary = store.statistics(for: period)
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(StatisticsPeriod.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                if !historyEnabled {
                    Text("History recording is off, so new encodes aren’t counted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if summary.encodeCount == 0 && summary.sessionCount == 0 {
                Section {
                    Text("No encodes in this period.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            } else {
                overviewSection(summary)
                timelineSection(summary)
                rankedSection("Top Presets", summary.topPresets) { $0 }
                rankedSection("Top Video Codecs", summary.topVideoCodecs) { $0.uppercased() }
                rankedSection("Top Containers", summary.topContainers) { $0.uppercased() }
                rankedSection("Top Resolutions", summary.topResolutions) { ResolutionBucket.label(forKey: $0) }
            }

            Section {
                Text("Statistics combine the detailed encode history with monthly summaries of encodes that are older than the history retention period. Monthly summaries only count toward a period when the whole month lies inside it, so the 7- and 30-day figures come from the detailed history alone. Clearing the history also resets the statistics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private func overviewSection(_ summary: EncodeStatisticsSummary) -> some View {
        Section("Overview") {
            statRow("Encodes", "\(summary.encodeCount)")
            statRow("Completed", "\(summary.count(.completed))")
            statRow("Failed", "\(summary.count(.failed))", tint: summary.count(.failed) > 0 ? .red : nil)
            statRow("Cancelled", "\(summary.count(.cancelled))")
            statRow("Interrupted", "\(summary.count(.interrupted))",
                    tint: summary.count(.interrupted) > 0 ? .orange : nil)
                .help("Encodes that were still running when the app quit or crashed")
            statRow("Unexpected exits", "\(summary.unexpectedExitCount)",
                    tint: summary.unexpectedExitCount > 0 ? .orange : nil)
                .help("App sessions that ended without a normal quit, such as a crash or force quit")
            statRow("Media encoded", Self.hours(summary.mediaSecondsEncoded))
            statRow("Time spent encoding", Self.hours(summary.encodeWallSeconds))
            if let speed = summary.averageSpeed {
                statRow("Average speed",
                        String(localized: "\(speed.formatted(.number.precision(.fractionLength(1))))× realtime",
                               comment: "Statistics: average encode speed relative to the media duration."))
            }
            if summary.bytesIn > 0 {
                statRow("Source data", EncodeHistoryFormat.bytes(summary.bytesIn))
                statRow("Output data", EncodeHistoryFormat.bytes(summary.bytesOut))
                statRow(summary.bytesSaved >= 0 ? "Space saved" : "Space added",
                        EncodeHistoryFormat.bytes(abs(summary.bytesSaved)))
                    .help("Difference between source and output sizes of completed encodes")
            }
        }
    }

    private func timelineSection(_ summary: EncodeStatisticsSummary) -> some View {
        let unit: Calendar.Component = period.granularity
        return Section("Encodes over Time") {
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
            .frame(height: 180)
            .accessibilityLabel("Encodes over time")
        }
    }

    private func series(_ bucket: StatisticsTimelineBucket) -> [(name: String, count: Int)] {
        [(completedSeries, bucket.completed), (failedSeries, bucket.failed), (otherSeries, bucket.other)]
    }

    @ViewBuilder
    private func rankedSection(
        _ title: LocalizedStringKey,
        _ items: [RankedCount],
        label: @escaping (String) -> String
    ) -> some View {
        if !items.isEmpty {
            let maximum = Double(items.map(\.count).max() ?? 1)
            Section(title) {
                ForEach(items) { item in
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
                        Text(verbatim: label(item.key))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func statRow(_ title: LocalizedStringKey, _ value: String, tint: Color? = nil) -> some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .monospacedDigit()
                .foregroundStyle(tint ?? .secondary)
        }
    }

    // MARK: - Formatting

    private static func hours(_ seconds: Double) -> String {
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
