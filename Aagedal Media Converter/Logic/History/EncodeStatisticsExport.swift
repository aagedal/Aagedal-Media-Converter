//
//  EncodeStatisticsExport.swift
//  Aagedal Media Converter
//
//  CSV exports of the encode statistics: the summary shown in Settings ›
//  Statistics, and one row per encode in the detailed history. Column names
//  and values are machine-oriented (English, ISO 8601 dates, raw numbers) so
//  spreadsheets read them the same in every language.
//

import Foundation

enum EncodeStatisticsExport {
    /// The statistics for one period and Mac filter, in long format:
    /// `section,key,value` plus per-outcome columns for the timeline rows.
    static func summaryCSV(
        _ summary: EncodeStatisticsSummary,
        period: StatisticsPeriod,
        macLabel: String,
        deviceLabel: (String) -> String,
        generatedAt: Date
    ) -> String {
        var rows: [[String]] = [["section", "key", "value", "completed", "failed", "other"]]
        func add(_ section: String, _ key: String, _ value: String) { rows.append([section, key, value]) }

        add("report", "period", period.rawValue)
        add("report", "mac", macLabel)
        add("report", "generated_at", timestamp(generatedAt))
        add("report", "includes_monthly_summaries", summary.includesRollups ? "true" : "false")

        add("overview", "encodes", "\(summary.encodeCount)")
        for outcome in EncodeOutcome.allCases where outcome != .running {
            add("overview", outcome.rawValue, "\(summary.count(outcome))")
        }
        add("overview", "unexpected_exits", "\(summary.unexpectedExitCount)")
        add("overview", "sessions", "\(summary.sessionCount)")
        add("overview", "media_seconds_encoded", number(summary.mediaSecondsEncoded))
        add("overview", "encode_seconds", number(summary.encodeWallSeconds))
        add("overview", "average_speed", summary.averageSpeed.map(number) ?? "")
        add("overview", "source_bytes", "\(summary.bytesIn)")
        add("overview", "output_bytes", "\(summary.bytesOut)")

        for bucket in summary.timeline {
            rows.append(["timeline", day(bucket.start), "\(bucket.total)",
                         "\(bucket.completed)", "\(bucket.failed)", "\(bucket.other)"])
        }

        let all = Int.max
        for item in EncodeStatisticsSummary.ranked(summary.totals.presetCounts, limit: all) {
            add("preset", item.key, "\(item.count)")
        }
        for item in EncodeStatisticsSummary.ranked(summary.totals.videoCodecCounts, limit: all) {
            add("video_codec", item.key, "\(item.count)")
        }
        for item in EncodeStatisticsSummary.ranked(summary.totals.containerCounts, limit: all) {
            add("container", item.key, "\(item.count)")
        }
        for item in EncodeStatisticsSummary.ranked(summary.totals.resolutionCounts, limit: all) {
            add("resolution", item.key, "\(item.count)")
        }
        for item in EncodeStatisticsSummary.ranked(summary.deviceCounts, limit: all) {
            add("mac", deviceLabel(item.key), "\(item.count)")
        }
        return csv(rows)
    }

    /// One row per encode in the detailed history. Monthly summaries of
    /// pruned encodes have no per-encode detail, so they aren't included.
    static func recordsCSV(_ records: [EncodeRecord], deviceLabel: (EncodeRecord) -> String) -> String {
        var rows: [[String]] = [[
            "started_at", "finished_at", "outcome", "mac", "source_name", "source_path",
            "preset", "group", "merged", "output_path", "source_bytes", "output_bytes",
            "source_duration_seconds", "media_seconds_encoded", "encode_seconds",
            "container", "video_codec", "width", "height", "frame_rate",
            "audio_codec", "audio_channels", "trim_start", "trim_end", "error",
        ]]
        for record in records {
            let facts = record.sourceFacts
            rows.append([
                timestamp(record.startedAt),
                record.finishedAt.map(timestamp) ?? "",
                record.outcome.rawValue,
                deviceLabel(record),
                record.sourceName,
                record.source.path,
                record.presetDisplayName,
                record.groupName ?? "",
                record.merged ? "true" : "false",
                record.outputPath ?? "",
                facts.sizeBytes.map { "\($0)" } ?? "",
                record.outputSizeBytes.map { "\($0)" } ?? "",
                facts.durationSeconds.map(number) ?? "",
                EncodeStatistics.mediaSeconds(for: record).map(number) ?? "",
                record.encodeDuration.map(number) ?? "",
                EncodeStatistics.containerKey(for: record) ?? "",
                facts.videoCodec ?? "",
                facts.width.map { "\($0)" } ?? "",
                facts.height.map { "\($0)" } ?? "",
                facts.frameRate.map(number) ?? "",
                facts.audioCodec ?? "",
                facts.audioChannels.map { "\($0)" } ?? "",
                record.recipe.trimStart.map(number) ?? "",
                record.recipe.trimEnd.map(number) ?? "",
                record.errorMessage ?? "",
            ])
        }
        return csv(rows)
    }

    // MARK: - Formatting

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting. Text that a spreadsheet would run as a formula
    /// (file names can start with `=`, `+`, `-` or `@`) gets a leading `'`.
    static func field(_ value: String) -> String {
        var text = value
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first),
           Double(text) == nil {
            text = "'" + text
        }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Timeline buckets start at local midnight, so the date is local too.
    private static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
