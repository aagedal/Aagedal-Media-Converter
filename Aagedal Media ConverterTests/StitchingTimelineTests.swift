import XCTest
@testable import Aagedal_Media_Converter

final class StitchingTimelineTests: XCTestCase {
    private func clip(duration: Double, start: Double? = nil, end: Double? = nil) -> VideoItem {
        var item = VideoItem(url: URL(fileURLWithPath: "/tmp/stitching-test.mov"), name: "Test",
                             size: 0, duration: "", status: .waiting, progress: 0, eta: nil, outputURL: nil)
        item.durationSeconds = duration
        item.trimStart = start
        item.trimEnd = end
        return item
    }

    func testSequenceBoundaryMapsToNextTrimmedSource() {
        let first = clip(duration: 20, start: 4, end: 10)
        let second = clip(duration: 30, start: 12, end: 18)
        let before = StitchingTimeline.location(at: 5.5, in: [first, second])
        XCTAssertEqual(before?.id, first.id)
        XCTAssertEqual(before?.sourceTime, 9.5)
        let boundary = StitchingTimeline.location(at: 6, in: [first, second])
        XCTAssertEqual(boundary?.id, second.id)
        XCTAssertEqual(boundary?.sourceTime, 12)
        XCTAssertEqual(StitchingTimeline.location(at: 8, in: [first, second])?.sourceTime, 14)
    }

    func testScrubbingClampsAndSkipsZeroLengthClips() {
        let empty = clip(duration: 0)
        let valid = clip(duration: 20, start: 5, end: 15)
        XCTAssertEqual(StitchingTimeline.location(at: -4, in: [empty, valid])?.sourceTime, 5)
        XCTAssertEqual(StitchingTimeline.location(at: 100, in: [empty, valid])?.sourceTime, 15)
        XCTAssertNil(StitchingTimeline.location(at: .nan, in: [valid]))
        XCTAssertNil(StitchingTimeline.location(at: 0, in: [empty]))
    }

    func testReorderingChangesTimelineMappingWithoutChangingSourceTrims() {
        let first = clip(duration: 20, start: 4, end: 10)
        let second = clip(duration: 30, start: 12, end: 18)
        XCTAssertEqual(StitchingTimeline.location(at: 0, in: [second, first])?.id, second.id)
        XCTAssertEqual(StitchingTimeline.location(at: 6, in: [second, first])?.sourceTime, 4)
        XCTAssertEqual(first.trimStart, 4)
        XCTAssertEqual(second.trimEnd, 18)
    }

    func testTrimCannotCrossOppositeEdgeOrSourceBounds() {
        var item = clip(duration: 10, start: 2, end: 8)
        StitchingTimeline.trim(&item, start: true, to: 50)
        XCTAssertEqual(item.effectiveTrimStart, 7.9, accuracy: 0.0001)
        StitchingTimeline.trim(&item, start: false, to: -50)
        XCTAssertEqual(item.effectiveTrimEnd, 8, accuracy: 0.0001)
        StitchingTimeline.trim(&item, start: true, to: -1)
        XCTAssertNil(item.trimStart)
        StitchingTimeline.trim(&item, start: false, to: 100)
        XCTAssertNil(item.trimEnd)
    }

    func testInvalidTrimInputDoesNotMutateClip() {
        var item = clip(duration: 10, start: 2, end: 8)
        StitchingTimeline.trim(&item, start: true, to: .nan)
        StitchingTimeline.trim(&item, start: false, to: .infinity)
        XCTAssertEqual(item.trimStart, 2)
        XCTAssertEqual(item.trimEnd, 8)
    }

    func testFrameTimecodeAndTrimCountsAt25FPS() {
        XCTAssertEqual(StitchingTimeline.timeDisplay(6.08, frameRate: 25), "00:00:06:02")
        XCTAssertEqual(StitchingTimeline.timeDisplay(6.08, frameRate: 25, compact: true), "00:06:02")
        XCTAssertEqual(StitchingTimeline.frameCount(0.48, rate: 25), 12)
        XCTAssertEqual(StitchingTimeline.timeDisplay(6.08, frameRate: nil), "00:00:06")
    }

    func testFractionalFrameRateUsesActualFrameCount() {
        let rate = 30_000.0 / 1001
        XCTAssertEqual(StitchingTimeline.timeDisplay(60 / rate, frameRate: rate), "00:00:02:00")
        XCTAssertEqual(StitchingTimeline.frameCount(60 / rate, rate: rate), 60)
    }

    func testTrimSnapsToFramesAndKeepsAtLeastOneFrame() {
        var item = clip(duration: 10, start: 2, end: 8)
        item.imageSequenceConfig = ImageSequenceConfig(
            pattern: "frame_%04d.png", directory: URL(fileURLWithPath: "/tmp/sequence"),
            startNumber: 1, endNumber: 250, frameRate: 25, imageFormat: .png
        )
        StitchingTimeline.trim(&item, start: true, to: 2.071)
        XCTAssertEqual(item.effectiveTrimStart, 2.08, accuracy: 0.000001)
        StitchingTimeline.trim(&item, start: true, to: 50)
        XCTAssertEqual(item.effectiveTrimStart, 7.96, accuracy: 0.000001)
        StitchingTimeline.trim(&item, start: false, to: 0)
        XCTAssertEqual(item.effectiveTrimEnd, 8, accuracy: 0.000001)
        StitchingTimeline.trim(&item, start: false, to: 20)
        XCTAssertNil(item.trimEnd)
    }

}
