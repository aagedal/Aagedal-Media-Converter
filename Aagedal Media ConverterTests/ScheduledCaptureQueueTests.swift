import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class ScheduledCaptureQueueTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func capture(at minutes: Double, for duration: Double?) -> ScheduledCapture {
        ScheduledCapture(start: base.addingTimeInterval(minutes * 60), duration: duration.map { $0 * 60 })
    }

    func testRecordingsThatTouchDoNotOverlap() {
        XCTAssertFalse(capture(at: 0, for: 10).overlaps(capture(at: 10, for: 5)))
        XCTAssertTrue(capture(at: 0, for: 10).overlaps(capture(at: 9, for: 5)))
        XCTAssertTrue(capture(at: 9, for: 5).overlaps(capture(at: 0, for: 10)))
    }

    func testRecordingWithoutStopTimeOverlapsEverythingAfterIt() {
        XCTAssertTrue(capture(at: 0, for: nil).overlaps(capture(at: 600, for: 5)))
        XCTAssertTrue(capture(at: 600, for: 5).overlaps(capture(at: 0, for: nil)))
        XCTAssertFalse(capture(at: 10, for: nil).overlaps(capture(at: 0, for: 10)))
    }

    func testSaveKeepsEntriesSortedAndRejectsOverlaps() {
        let queue = ScheduledCaptureQueue(keepsDisplayAwake: false)
        let late = capture(at: 60, for: nil)
        let early = capture(at: 0, for: 30)
        XCTAssertTrue(queue.save(late))
        XCTAssertTrue(queue.save(early))
        XCTAssertEqual(queue.entries, [early, late])

        let clash = capture(at: 20, for: 5)
        XCTAssertEqual(queue.conflict(with: clash), early)
        XCTAssertFalse(queue.save(clash))
        XCTAssertFalse(queue.save(capture(at: 120, for: 5)), "Nothing can follow a recording without a stop time")
        XCTAssertEqual(queue.entries, [early, late])
    }

    func testEditingAnEntryIgnoresItsOwnOldTimes() {
        let queue = ScheduledCaptureQueue(keepsDisplayAwake: false)
        var entry = capture(at: 0, for: nil)
        queue.save(entry)
        entry.duration = 15 * 60
        XCTAssertTrue(queue.save(entry))
        XCTAssertEqual(queue.entries, [entry])
        XCTAssertTrue(queue.save(capture(at: 15, for: 5)), "Adding a stop time makes room after it")
    }

    func testTakeDueOnlyReturnsAStartedEntry() {
        let queue = ScheduledCaptureQueue(keepsDisplayAwake: false)
        let first = capture(at: 0, for: 10)
        let second = capture(at: 10, for: 10)
        queue.save(first)
        queue.save(second)
        XCTAssertNil(queue.takeDue(now: base.addingTimeInterval(-1)))
        XCTAssertFalse(queue.didStartRecording)
        XCTAssertEqual(queue.takeDue(now: base), first)
        XCTAssertNil(queue.takeDue(now: base.addingTimeInterval(60)))
        XCTAssertEqual(queue.entries, [second])
        XCTAssertTrue(queue.didStartRecording)
        queue.reset()
        XCTAssertFalse(queue.didStartRecording)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testMinuteStartDropsSeconds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 57)))
        XCTAssertEqual(ScheduledCapture.minuteStart(of: start.addingTimeInterval(44.5), calendar: calendar), start)
        XCTAssertEqual(ScheduledCapture.minuteStart(of: start, calendar: calendar), start)
    }

    func testSuggestedStartFollowsTheLastRecording() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 3, second: 30)))
        let queue = ScheduledCaptureQueue(keepsDisplayAwake: false)
        XCTAssertEqual(queue.suggestedStart(now: now, calendar: calendar), now.addingTimeInterval(5 * 60 + 30))

        queue.save(ScheduledCapture(start: now.addingTimeInterval(10 * 60), duration: 20 * 60 + 10))
        XCTAssertEqual(queue.suggestedStart(now: now, calendar: calendar), now.addingTimeInterval(30 * 60 + 30))
    }
}
