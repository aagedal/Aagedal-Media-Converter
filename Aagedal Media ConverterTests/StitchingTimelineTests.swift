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

    func testPlaybackSkipsEmptySourcesAndAdvancesAtTrimOut() {
        let empty = clip(duration: 0)
        let first = clip(duration: 20, start: 4, end: 10)
        let second = clip(duration: 30, start: 12, end: 18)
        let items = [empty, first, empty, second]
        let start = StitchingTimeline.playbackLocation(at: 0, in: items)
        XCTAssertEqual(start?.id, first.id)
        XCTAssertEqual(start?.sourceTime, 4)
        let boundary = StitchingTimeline.playbackLocation(at: 6, in: items)
        XCTAssertEqual(boundary?.id, second.id)
        XCTAssertEqual(boundary?.sourceTime, 12)
    }

    func testPlaybackAtSequenceEndRestartsAtFirstTrimInAfterReorder() {
        let first = clip(duration: 20, start: 4, end: 10)
        let second = clip(duration: 30, start: 12, end: 18)
        let replay = StitchingTimeline.playbackLocation(at: 12, in: [second, first])
        XCTAssertEqual(replay?.id, second.id)
        XCTAssertEqual(replay?.sourceTime, 12)
        let singleReplay = StitchingTimeline.playbackLocation(at: 6, in: [first])
        XCTAssertEqual(singleReplay?.id, first.id)
        XCTAssertEqual(singleReplay?.sourceTime, 4)
    }

    func testPlaybackPreservesLastSubframeInsteadOfRestartingEarly() {
        let item = clip(duration: 10, start: 2, end: 8)
        XCTAssertEqual(StitchingTimeline.playbackLocation(at: 5.999, in: [item])?.sourceTime ?? 0,
                       7.999, accuracy: 0.000001)
        XCTAssertNil(StitchingTimeline.playbackLocation(at: .nan, in: [item]))
        XCTAssertNil(StitchingTimeline.playbackLocation(at: 0, in: [clip(duration: 0)]))
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

    func testMovingMultipleClipsForwardPreservesOrderTrimsAndGaplessMapping() {
        let original = (0..<5).map { _ in clip(duration: 20, start: 4, end: 10) }
        var items = original
        StitchingTimeline.move(&items, selection: [original[1].id, original[2].id], to: 5)
        XCTAssertEqual(items.map(\.id), [original[0], original[3], original[4], original[1], original[2]].map(\.id))
        XCTAssertEqual(items.reduce(0) { $0 + StitchingTimeline.duration($1) }, 30)
        for (index, item) in items.enumerated() {
            XCTAssertEqual(item.trimStart, 4)
            XCTAssertEqual(item.trimEnd, 10)
            XCTAssertEqual(StitchingTimeline.location(at: Double(index * 6), in: items)?.id, item.id)
        }
    }

    func testMovingDiscontiguousClipsToBeginningPreservesSequenceOrder() {
        let original = (0..<5).map { _ in clip(duration: 10) }
        var items = original
        StitchingTimeline.move(&items, selection: [original[1].id, original[3].id], to: 0)
        XCTAssertEqual(items.map(\.id), [original[1], original[3], original[0], original[2], original[4]].map(\.id))
    }

    func testDroppingWithinSelectionOrMovingAllClipsDoesNotChangeOrder() {
        let original = (0..<4).map { _ in clip(duration: 10) }
        for boundary in 1...3 {
            var items = original
            StitchingTimeline.move(&items, selection: [original[1].id, original[2].id], to: boundary)
            XCTAssertEqual(items.map(\.id), original.map(\.id))
        }
        var items = original
        StitchingTimeline.move(&items, selection: Set(original.map(\.id)), to: 4)
        XCTAssertEqual(items.map(\.id), original.map(\.id))
    }

    func testShiftSelectionExtendsInBothDirectionsFromAnchor() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(StitchingTimeline.selectionRange(from: ids[1], through: ids[4], in: ids), Set(ids[1...4]))
        XCTAssertEqual(StitchingTimeline.selectionRange(from: ids[3], through: ids[0], in: ids), Set(ids[0...3]))
        XCTAssertEqual(StitchingTimeline.selectionRange(from: UUID(), through: ids[2], in: ids), [ids[2]])
    }

    func testDropTargetsSnapAtClipMidpointsIncludingTimelineEnds() {
        let widths = [100.0, 20, 200]
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: -20, widths: widths), 0)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 49, widths: widths), 0)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 50, widths: widths), 1)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 110, widths: widths), 2)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 219, widths: widths), 2)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 220, widths: widths), 3)
        XCTAssertEqual(StitchingTimeline.insertionBoundary(at: 500, widths: widths), 3)
    }

}
