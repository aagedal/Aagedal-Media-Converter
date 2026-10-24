//
//  EncodeStatistics.swift
//  Aagedal Media Converter
//
//  Pure aggregation for the Statistics settings tab. Statistics combine the
//  live (detailed) history records with monthly rollups of records that
//  retention already pruned. A record is in exactly one of the two: it is
//  folded into a rollup in the same step that deletes it.
//
//  Rollups are monthly, so a period counts a rollup month only when the whole
//  month lies inside the period. Periods shorter than a month (7 and 30 days)
//  therefore only see live records, which is fine with the default 90-day
//  retention; with a shorter retention they show only what is still kept.
//

import Foundation

/// Coarse resolution class for statistics, keyed on the short edge so
/// portrait video lands in the same bucket as landscape.
enum ResolutionBucket: String, CaseIterable, Sendable {
    case audioOnly = "audio"
    case sd
    case hd720 = "720p"
    case hd1080 = "1080p"
    case qhd1440 = "1440p"
    case uhd2160 = "2160p"
    case aboveUHD = "4320p"

    init(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else {
            self = .audioOnly
            return
        }
        switch min(width, height) {
        case ..<720: self = .sd
        case ..<1080: self = .hd720
        case ..<1440: self = .hd1080
        case ..<2160: self = .qhd1440
        case ..<4320: self = .uhd2160
        default: self = .aboveUHD
        }
    }

    var label: String {
        switch self {
        case .audioOnly: return String(localized: "Audio only", comment: "Statistics resolution bucket for files without video.")
        case .sd: return String(localized: "SD", comment: "Statistics resolution bucket: standard definition.")
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .uhd2160: return "4K UHD"
        case .aboveUHD: return "8K+"
        }
    }

    /// Label for a stored key; unknown keys (from newer versions) show as-is.
    static func label(forKey key: String) -> String {
        ResolutionBucket(rawValue: key)?.label ?? key
    }
}

enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "1y"
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return String(localized: "7 Days", comment: "Statistics period picker.")
        case .month: return String(localized: "30 Days", comment: "Statistics period picker.")
        case .quarter: return String(localized: "90 Days", comment: "Statistics period picker.")
        case .year: return String(localized: "1 Year", comment: "Statistics period picker.")
        case .all: return String(localized: "All Time", comment: "Statistics period picker.")
        }
    }

    /// Daily bars for the short periods, monthly for the long ones.
    var granularity: Calendar.Component {
        switch self {
        case .week, .month, .quarter: return .day
        case .year, .all: return .month
        }
    }

    /// First instant counted, or nil for all time. Day periods include today;
    /// one year is the current month plus the eleven before it.
    func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .quarter: return calendar.date(byAdding: .day, value: -89, to: today)
        case .year:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
            return calendar.date(byAdding: .month, value: -11, to: monthStart)
        case .all: return nil
        }
    }
}

/// One bar in the encodes-over-time chart.
struct StatisticsTimelineBucket: Equatable, Identifiable, Sendable {
    var start: Date
    var completed = 0
    var failed = 0
    /// Cancelled, interrupted and still running.
    var other = 0

    var id: Date { start }
    var total: Int { completed + failed + other }
}

struct RankedCount: Equatable, Identifiable, Sendable {
    var key: String
    var count: Int
    var id: String { key }
}

struct EncodeStatisticsSummary: Equatable, Sendable {
    /// Same accumulator as a rollup; `month` and `deviceName` are unused.
    var totals = MonthlyRollup(month: "", deviceName: "")
    var timeline: [StatisticsTimelineBucket] = []
    /// Whether pruned (rolled-up) months contributed to the totals.
    var includesRollups = false

    var encodeCount: Int { totals.encodeCount }
    func count(_ outcome: EncodeOutcome) -> Int { totals.outcomeCounts[outcome.rawValue, default: 0] }
    var unexpectedExitCount: Int { totals.unexpectedExitCount }
    var sessionCount: Int { totals.sessionCount }
    var mediaSecondsEncoded: Double { totals.mediaSecondsEncoded }
    var encodeWallSeconds: Double { totals.encodeWallSeconds }
    var bytesIn: Int64 { totals.bytesIn }
    var bytesOut: Int64 { totals.bytesOut }
    var bytesSaved: Int64 { totals.bytesIn - totals.bytesOut }

    /// Media duration per wall-clock second, e.g. 4.0 = four times realtime.
    var averageSpeed: Double? {
        totals.speedWallSeconds > 0 ? totals.speedMediaSeconds / totals.speedWallSeconds : nil
    }

    var topPresets: [RankedCount] { Self.ranked(totals.presetCounts) }
    var topVideoCodecs: [RankedCount] { Self.ranked(totals.videoCodecCounts) }
    var topContainers: [RankedCount] { Self.ranked(totals.containerCounts) }
    var topResolutions: [RankedCount] { Self.ranked(totals.resolutionCounts) }

    /// Highest count first; ties by name so the order is stable.
    static func ranked(_ counts: [String: Int], limit: Int = 5) -> [RankedCount] {
        counts.filter { $0.value > 0 }
            .map { RankedCount(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Accumulation

extension MonthlyRollup {
    /// Adds one encode. Running encodes count as encodes but contribute no
    /// duration, speed or size figures.
    mutating func add(_ record: EncodeRecord) {
        encodeCount += 1
        outcomeCounts[record.outcome.rawValue, default: 0] += 1
        let preset = record.presetDisplayName.isEmpty ? record.presetRawValue : record.presetDisplayName
        if !preset.isEmpty { presetCounts[preset, default: 0] += 1 }
        let facts = record.sourceFacts
        if let codec = facts.videoCodec?.lowercased(), !codec.isEmpty {
            videoCodecCounts[codec, default: 0] += 1
        }
        if let container = EncodeStatistics.containerKey(for: record) {
            containerCounts[container, default: 0] += 1
        }
        resolutionCounts[ResolutionBucket(width: facts.width, height: facts.height).rawValue, default: 0] += 1

        guard record.outcome == .completed else { return }
        let media = EncodeStatistics.mediaSeconds(for: record)
        let wall = record.encodeDuration.flatMap { $0 > 0 ? $0 : nil }
        if let media { mediaSecondsEncoded += media }
        if let wall { encodeWallSeconds += wall }
        if let media, let wall {
            speedMediaSeconds += media
            speedWallSeconds += wall
        }
        if let input = facts.sizeBytes, let output = record.outputSizeBytes, input > 0, output > 0 {
            bytesIn += input
            bytesOut += output
        }
    }

    /// Adds one finished app session (never the running one).
    mutating func add(_ session: HistorySession) {
        sessionCount += 1
        if EncodeStatistics.isUnexpectedExit(session) { unexpectedExitCount += 1 }
    }

    mutating func merge(_ other: MonthlyRollup) {
        encodeCount += other.encodeCount
        outcomeCounts.merge(other.outcomeCounts, uniquingKeysWith: +)
        presetCounts.merge(other.presetCounts, uniquingKeysWith: +)
        videoCodecCounts.merge(other.videoCodecCounts, uniquingKeysWith: +)
        containerCounts.merge(other.containerCounts, uniquingKeysWith: +)
        resolutionCounts.merge(other.resolutionCounts, uniquingKeysWith: +)
        mediaSecondsEncoded += other.mediaSecondsEncoded
        encodeWallSeconds += other.encodeWallSeconds
        speedMediaSeconds += other.speedMediaSeconds
        speedWallSeconds += other.speedWallSeconds
        bytesIn += other.bytesIn
        bytesOut += other.bytesOut
        sessionCount += other.sessionCount
        unexpectedExitCount += other.unexpectedExitCount
    }
}

enum EncodeStatistics {
    // MARK: Facts

    /// Encoded media length: the trimmed range when trimmed.
    static func mediaSeconds(for record: EncodeRecord) -> Double? {
        guard let duration = record.sourceFacts.durationSeconds, duration > 0 else { return nil }
        let start = max(0, record.recipe.trimStart ?? 0)
        let end = min(duration, record.recipe.trimEnd ?? duration)
        let length = end - start
        return length > 0 ? length : nil
    }

    /// File extension when there is one (what users recognise), otherwise
    /// the first name of ffprobe's format list ("mov,mp4,m4a,…" → "mov").
    static func containerKey(for record: EncodeRecord) -> String? {
        let ext = (record.source.path as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        guard let format = record.sourceFacts.container?.split(separator: ",").first else { return nil }
        let key = format.trimmingCharacters(in: .whitespaces).lowercased()
        return key.isEmpty ? nil : key
    }

    static func isUnexpectedExit(_ session: HistorySession) -> Bool {
        session.endedAt != nil && !session.endedCleanly
    }

    // MARK: Months

    static func monthKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func monthStart(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    // MARK: Folding

    /// Adds records and sessions that are about to be deleted to the rollup
    /// of their month and device.
    static func fold(
        records: [EncodeRecord],
        sessions: [HistorySession],
        into rollups: inout [MonthlyRollup],
        calendar: Calendar = .current
    ) {
        guard !records.isEmpty || !sessions.isEmpty else { return }
        var index: [String: Int] = [:]
        for (position, rollup) in rollups.enumerated() {
            index["\(rollup.month)|\(rollup.deviceName)"] = position
        }
        func withRollup(month: String, device: String, _ change: (inout MonthlyRollup) -> Void) {
            let key = "\(month)|\(device)"
            if let position = index[key] {
                change(&rollups[position])
            } else {
                var rollup = MonthlyRollup(month: month, deviceName: device)
                change(&rollup)
                index[key] = rollups.count
                rollups.append(rollup)
            }
        }
        for record in records {
            withRollup(month: monthKey(for: record.startedAt, calendar: calendar), device: record.deviceName) { $0.add(record) }
        }
        for session in sessions {
            withRollup(month: monthKey(for: session.startedAt, calendar: calendar), device: session.deviceName) { $0.add(session) }
        }
        rollups.sort { $0.month != $1.month ? $0.month < $1.month : $0.deviceName < $1.deviceName }
    }

    // MARK: Summary

    static func summarize(
        records: [EncodeRecord],
        sessions: [HistorySession],
        rollups: [MonthlyRollup],
        period: StatisticsPeriod,
        currentSessionID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EncodeStatisticsSummary {
        let start = period.start(now: now, calendar: calendar)
        func inPeriod(_ date: Date) -> Bool { start.map { date >= $0 } ?? true }

        var summary = EncodeStatisticsSummary()
        let liveRecords = records.filter { inPeriod($0.startedAt) }
        for record in liveRecords { summary.totals.add(record) }
        for session in sessions where session.id != currentSessionID && inPeriod(session.startedAt) {
            summary.totals.add(session)
        }

        // Only whole months inside the period.
        let includedRollups: [(start: Date, rollup: MonthlyRollup)] = rollups.compactMap { rollup in
            guard let monthStart = monthStart(forKey: rollup.month, calendar: calendar), inPeriod(monthStart) else { return nil }
            return (monthStart, rollup)
        }
        for entry in includedRollups { summary.totals.merge(entry.rollup) }
        summary.includesRollups = includedRollups.contains { $0.rollup.encodeCount > 0 || $0.rollup.sessionCount > 0 }

        summary.timeline = timeline(
            records: liveRecords, rollups: includedRollups, period: period,
            start: start, now: now, calendar: calendar
        )
        return summary
    }

    private static func timeline(
        records: [EncodeRecord],
        rollups: [(start: Date, rollup: MonthlyRollup)],
        period: StatisticsPeriod,
        start: Date?,
        now: Date,
        calendar: Calendar
    ) -> [StatisticsTimelineBucket] {
        let component = period.granularity
        func bucketStart(_ date: Date) -> Date {
            calendar.dateInterval(of: component, for: date)?.start ?? calendar.startOfDay(for: date)
        }

        var buckets: [Date: StatisticsTimelineBucket] = [:]
        func add(at date: Date, completed: Int, failed: Int, other: Int) {
            let key = bucketStart(date)
            var bucket = buckets[key] ?? StatisticsTimelineBucket(start: key)
            bucket.completed += completed
            bucket.failed += failed
            bucket.other += other
            buckets[key] = bucket
        }
        for record in records {
            switch record.outcome {
            case .completed: add(at: record.startedAt, completed: 1, failed: 0, other: 0)
            case .failed: add(at: record.startedAt, completed: 0, failed: 1, other: 0)
            default: add(at: record.startedAt, completed: 0, failed: 0, other: 1)
            }
        }
        for (monthStart, rollup) in rollups where rollup.encodeCount > 0 {
            let completed = rollup.outcomeCounts[EncodeOutcome.completed.rawValue, default: 0]
            let failed = rollup.outcomeCounts[EncodeOutcome.failed.rawValue, default: 0]
            add(at: monthStart, completed: completed, failed: failed, other: max(0, rollup.encodeCount - completed - failed))
        }

        // Fill empty days/months so the axis is continuous.
        guard let first = start.map(bucketStart) ?? buckets.keys.min() else { return [] }
        let last = bucketStart(now)
        var result: [StatisticsTimelineBucket] = []
        var cursor = first
        while cursor <= last, result.count < 1_000 {
            result.append(buckets[cursor] ?? StatisticsTimelineBucket(start: cursor))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
