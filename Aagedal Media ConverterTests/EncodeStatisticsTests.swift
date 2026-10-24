import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class EncodeStatisticsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var calendar: Calendar!
    /// 2026-10-24 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_843_200)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EncodeStatisticsTests-\(UUID().uuidString)")
        suiteName = "EncodeStatisticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        self.calendar = calendar
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Facts

    func testResolutionBucketsUseTheShortEdge() {
        XCTAssertEqual(ResolutionBucket(width: nil, height: nil), .audioOnly)
        XCTAssertEqual(ResolutionBucket(width: 720, height: 576), .sd)
        XCTAssertEqual(ResolutionBucket(width: 1280, height: 720), .hd720)
        XCTAssertEqual(ResolutionBucket(width: 1920, height: 1080), .hd1080)
        XCTAssertEqual(ResolutionBucket(width: 1080, height: 1920), .hd1080)
        XCTAssertEqual(ResolutionBucket(width: 3840, height: 2160), .uhd2160)
        XCTAssertEqual(ResolutionBucket(width: 4096, height: 2160), .uhd2160)
        XCTAssertEqual(ResolutionBucket(width: 7680, height: 4320), .aboveUHD)
    }

    func testMediaSecondsUseTheTrimmedRange() {
        var record = makeRecord(daysAgo: 0, duration: 100)
        XCTAssertEqual(EncodeStatistics.mediaSeconds(for: record), 100)
        record.recipe.trimStart = 10
        record.recipe.trimEnd = 40
        XCTAssertEqual(EncodeStatistics.mediaSeconds(for: record), 30)
        record.sourceFacts.durationSeconds = nil
        XCTAssertNil(EncodeStatistics.mediaSeconds(for: record))
    }

    func testContainerKeyPrefersExtensionThenFirstFormatName() {
        var record = makeRecord(daysAgo: 0, path: "/clips/a.MP4")
        record.sourceFacts.container = "mov,mp4,m4a,3gp,3g2,mj2"
        XCTAssertEqual(EncodeStatistics.containerKey(for: record), "mp4")
        record.source = HistoryFileReference(path: "/clips/noext")
        XCTAssertEqual(EncodeStatistics.containerKey(for: record), "mov")
    }

    // MARK: - Summary

    func testSummaryTotalsOutcomesSpeedAndBytes() {
        let records = [
            makeRecord(daysAgo: 1, outcome: .completed, duration: 120, wall: 60, sizeIn: 1_000, sizeOut: 400, preset: "HEVC"),
            makeRecord(daysAgo: 2, outcome: .completed, duration: 60, wall: 60, sizeIn: 500, sizeOut: 100, preset: "HEVC"),
            makeRecord(daysAgo: 2, outcome: .failed, duration: 60, wall: 10, sizeIn: 500, preset: "ProRes"),
            makeRecord(daysAgo: 3, outcome: .cancelled, preset: "ProRes"),
            makeRecord(daysAgo: 3, outcome: .interrupted, preset: "HEVC"),
        ]
        let summary = EncodeStatistics.summarize(
            records: records, sessions: [], rollups: [], period: .week,
            currentSessionID: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.encodeCount, 5)
        XCTAssertEqual(summary.count(.completed), 2)
        XCTAssertEqual(summary.count(.failed), 1)
        XCTAssertEqual(summary.count(.cancelled), 1)
        XCTAssertEqual(summary.count(.interrupted), 1)
        // Only completed encodes contribute durations and sizes.
        XCTAssertEqual(summary.mediaSecondsEncoded, 180)
        XCTAssertEqual(summary.encodeWallSeconds, 120)
        XCTAssertEqual(summary.averageSpeed ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(summary.bytesIn, 1_500)
        XCTAssertEqual(summary.bytesOut, 500)
        XCTAssertEqual(summary.bytesSaved, 1_000)
        XCTAssertEqual(summary.topPresets.map(\.key), ["HEVC", "ProRes"])
        XCTAssertEqual(summary.topPresets.map(\.count), [3, 2])
        XCTAssertEqual(summary.topResolutions.first?.key, ResolutionBucket.hd1080.rawValue)
        XCTAssertEqual(summary.topVideoCodecs.first, RankedCount(key: "h264", count: 5))
    }

    func testPeriodExcludesOlderRecordsAndTimelineCoversEveryDay() {
        let records = [makeRecord(daysAgo: 0), makeRecord(daysAgo: 6), makeRecord(daysAgo: 7), makeRecord(daysAgo: 40)]
        let week = EncodeStatistics.summarize(
            records: records, sessions: [], rollups: [], period: .week,
            currentSessionID: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(week.encodeCount, 2)
        XCTAssertEqual(week.timeline.count, 7)
        XCTAssertEqual(week.timeline.map(\.total).reduce(0, +), 2)
        XCTAssertEqual(week.timeline.last?.completed, 1)

        let all = EncodeStatistics.summarize(
            records: records, sessions: [], rollups: [], period: .all,
            currentSessionID: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(all.encodeCount, 4)
        // Monthly bars from the oldest record's month (September) to October.
        XCTAssertEqual(all.timeline.count, 2)
    }

    func testUnexpectedExitsCountFinishedSessionsOnly() {
        let current = UUID()
        let sessions = [
            HistorySession(startedAt: day(-1), endedAt: day(-1), endedCleanly: true, deviceName: "Mac"),
            HistorySession(startedAt: day(-2), endedAt: day(-2), endedCleanly: false, deviceName: "Mac"),
            HistorySession(id: current, startedAt: now, deviceName: "Mac"),
        ]
        let summary = EncodeStatistics.summarize(
            records: [], sessions: sessions, rollups: [], period: .week,
            currentSessionID: current, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.unexpectedExitCount, 1)
    }

    func testRollupsCountOnlyForWholeMonthsInsideThePeriod() {
        var rollups: [MonthlyRollup] = []
        // August 2026: inside one year, outside 30 and 90 days' whole months.
        EncodeStatistics.fold(
            records: [makeRecord(daysAgo: 70, outcome: .completed), makeRecord(daysAgo: 70, outcome: .failed)],
            sessions: [], into: &rollups, calendar: calendar
        )
        XCTAssertEqual(rollups.map(\.month), ["2026-08"])
        XCTAssertEqual(rollups.first?.encodeCount, 2)

        func count(_ period: StatisticsPeriod) -> Int {
            EncodeStatistics.summarize(
                records: [], sessions: [], rollups: rollups, period: period,
                currentSessionID: nil, now: now, calendar: calendar
            ).encodeCount
        }
        XCTAssertEqual(count(.week), 0)
        XCTAssertEqual(count(.month), 0)
        XCTAssertEqual(count(.year), 2)
        XCTAssertEqual(count(.all), 2)

        let year = EncodeStatistics.summarize(
            records: [], sessions: [], rollups: rollups, period: .year,
            currentSessionID: nil, now: now, calendar: calendar
        )
        XCTAssertTrue(year.includesRollups)
        XCTAssertEqual(year.timeline.count, 12)
        XCTAssertEqual(year.timeline.map(\.completed).reduce(0, +), 1)
        XCTAssertEqual(year.timeline.map(\.failed).reduce(0, +), 1)
    }

    func testFoldMergesIntoExistingMonthAndDevice() {
        var rollups: [MonthlyRollup] = []
        EncodeStatistics.fold(records: [makeRecord(daysAgo: 70)], sessions: [], into: &rollups, calendar: calendar)
        EncodeStatistics.fold(records: [makeRecord(daysAgo: 71)], sessions: [], into: &rollups, calendar: calendar)
        var other = makeRecord(daysAgo: 70)
        other.deviceName = "Other Mac"
        EncodeStatistics.fold(records: [other], sessions: [], into: &rollups, calendar: calendar)
        XCTAssertEqual(rollups.count, 2)
        XCTAssertEqual(rollups.first { $0.deviceName == "Test Mac" }?.encodeCount, 2)
    }

    // MARK: - Store

    func testPruneFoldsExpiredRecordsIntoRollupsExactlyOnce() {
        defaults.set(30, forKey: AppConstants.encodeHistoryRetentionDaysKey)
        let old = now.addingTimeInterval(-60 * 86_400)
        let first = makeStore()
        first.bootstrap(now: old)
        var item = makeItem()
        item.status = .converting
        observe(first, item, now: old)
        item.status = .done
        item.outputFileSizeBytes = 4
        observe(first, item, now: old.addingTimeInterval(50))
        first.endSession(now: old.addingTimeInterval(60))

        let second = makeStore()
        second.bootstrap(now: now)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertEqual(second.rollups.map(\.encodeCount), [1])
        XCTAssertEqual(second.rollups.first?.sessionCount, 1)
        XCTAssertEqual(second.rollups.first?.unexpectedExitCount, 0)
        XCTAssertEqual(second.statistics(for: .all, now: now).encodeCount, 1)
        XCTAssertEqual(second.statistics(for: .all, now: now).count(.completed), 1)
        second.endSession(now: now)

        // Reloading and pruning again must not count the encode twice.
        let third = makeStore()
        third.bootstrap(now: now.addingTimeInterval(60))
        XCTAssertEqual(third.rollups.map(\.encodeCount), [1])
        XCTAssertEqual(third.statistics(for: .all, now: now).encodeCount, 1)
    }

    func testClearAllAlsoResetsStatistics() {
        defaults.set(30, forKey: AppConstants.encodeHistoryRetentionDaysKey)
        let old = now.addingTimeInterval(-60 * 86_400)
        let first = makeStore()
        first.bootstrap(now: old)
        var item = makeItem()
        item.status = .converting
        observe(first, item, now: old)
        item.status = .failed
        observe(first, item, now: old)
        first.endSession(now: old)

        let store = makeStore()
        store.bootstrap(now: now)
        XCTAssertTrue(store.hasClearableData)
        store.clearAll()
        XCTAssertFalse(store.hasClearableData)
        XCTAssertEqual(store.statistics(for: .all, now: now).encodeCount, 0)
        store.flush()

        let reloaded = makeStore()
        reloaded.bootstrap(now: now)
        XCTAssertTrue(reloaded.rollups.isEmpty)
    }

    func testRemovingSingleRecordsDoesNotFoldThem() {
        let store = makeStore()
        store.bootstrap(now: now)
        var item = makeItem()
        item.status = .converting
        observe(store, item, now: now)
        item.status = .done
        observe(store, item, now: now)
        store.removeRecords(Set(store.records.map(\.id)))
        XCTAssertTrue(store.rollups.isEmpty)
        XCTAssertEqual(store.statistics(for: .all, now: now).encodeCount, 0)
    }

    // MARK: - Helpers

    private func makeStore() -> EncodeHistoryStore {
        EncodeHistoryStore(directory: directory, defaults: defaults, calendar: calendar)
    }

    private func day(_ offset: Int) -> Date {
        now.addingTimeInterval(Double(offset) * 86_400)
    }

    private func observe(_ store: EncodeHistoryStore, _ item: VideoItem, now: Date) {
        store.observe([(item.id, item.status)], resolve: { _ in
            HistoryObservedRow(item: item, preset: .h265, groupName: nil, merged: false)
        }, now: now)
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/clip-\(UUID().uuidString).mov"), name: "clip.mov", size: 10,
            duration: "00:01:40", durationSeconds: 100, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
    }

    private func makeRecord(
        daysAgo: Int,
        outcome: EncodeOutcome = .completed,
        duration: Double? = 60,
        wall: TimeInterval = 30,
        sizeIn: Int64? = nil,
        sizeOut: Int64? = nil,
        preset: String = "HEVC",
        path: String = "/clips/clip.mov"
    ) -> EncodeRecord {
        let started = day(-daysAgo)
        var facts = SourceFacts()
        facts.durationSeconds = duration
        facts.videoCodec = "h264"
        facts.width = 1920
        facts.height = 1080
        facts.sizeBytes = sizeIn
        return EncodeRecord(
            sessionID: UUID(), startedAt: started,
            finishedAt: outcome == .running ? nil : started.addingTimeInterval(wall),
            outcome: outcome,
            source: HistoryFileReference(path: path),
            sourceFacts: facts,
            recipe: EncodeRecipe(),
            presetRawValue: preset, presetDisplayName: preset,
            outputSizeBytes: sizeOut,
            deviceName: "Test Mac"
        )
    }
}
