import XCTest
@testable import Aagedal_Media_Converter

final class StitchingTimelineTests: XCTestCase {
    func testUndoRedoSplitAndTrimPreservesCurrentMetadata() {
        let source = clip(duration: 60, start: 10, end: 50)
        var items = [source]
        var history = StitchingEditHistory()
        let original = items
        StitchingTimeline.split(&items, at: 20)
        let split = items
        history.record(from: original, to: items)
        items[0].comment = "Updated metadata"
        history.restore(&items)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].trimEnd, 50)
        XCTAssertEqual(items[0].comment, "Updated metadata")
        history.record(from: split, to: items) // SwiftUI observes the undo itself.
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        history.restore(&items, redo: true)
        XCTAssertEqual(items.map(\.id), split.map(\.id))
        XCTAssertEqual(items[0].comment, "Updated metadata")
        let beforeTrim = items
        StitchingTimeline.trim(&items[1], start: true, to: 35)
        history.record(from: beforeTrim, to: items)
        history.restore(&items)
        XCTAssertEqual(items[1].trimStart, 30)
        XCTAssertEqual(items[0].trimEnd, 30)
        history.restore(&items)
        XCTAssertEqual(items.count, 1)
    }

    func testRemovingBusyClipDoesNotCreateRestorableJobState() {
        var source = clip(duration: 20)
        source.status = .converting
        var history = StitchingEditHistory()
        history.record(from: [source], to: [])
        XCTAssertFalse(history.canUndo)
    }

    func testUndoRemovalOfLastClipAndRedo() {
        let original = [clip(duration: 20, start: 2, end: 15)]
        var items: [VideoItem] = []
        var history = StitchingEditHistory()
        history.record(from: original, to: items)
        history.restore(&items)
        XCTAssertEqual(items.map(\.id), original.map(\.id))
        XCTAssertEqual(items[0].trimStart, 2)
        XCTAssertEqual(items[0].trimEnd, 15)
        history.restore(&items, redo: true)
        XCTAssertTrue(items.isEmpty)
    }

    func testNewEditClearsRedoAndNonTimelineChangesAreIgnored() {
        var items = [clip(duration: 20)]
        var history = StitchingEditHistory()
        let original = items
        items[0].comment = "Metadata only"
        history.record(from: original, to: items)
        XCTAssertFalse(history.canUndo)
        items[0].trimEnd = 10
        history.record(from: original, to: items)
        history.restore(&items)
        XCTAssertTrue(history.canRedo)
        let before = items
        items[0].trimStart = 5
        history.record(from: before, to: items)
        XCTAssertFalse(history.canRedo)
        history.restore(&items)
        XCTAssertNil(items[0].trimStart)
        XCTAssertEqual(items[0].comment, "Metadata only")
    }

    func testSplitPreservesSourceRangesAndIndependentIdentity() {
        var source = clip(duration: 60, start: 10, end: 50)
        source.comment = "Keep settings"
        source.timelineMarkers = [StitchTimelineMarker(sourceTime: 35, text: "Note")]
        var items = [source]
        let id = StitchingTimeline.split(&items, at: 20)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, source.id)
        XCTAssertEqual(items[1].id, id)
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertEqual(items[0].url, items[1].url)
        XCTAssertEqual(items[0].effectiveTrimStart, 10)
        XCTAssertEqual(items[0].effectiveTrimEnd, 30)
        XCTAssertEqual(items[1].effectiveTrimStart, 30)
        XCTAssertEqual(items[1].effectiveTrimEnd, 50)
        XCTAssertEqual(items[1].comment, source.comment)
        XCTAssertNotEqual(items[0].timelineMarkers[0].id, items[1].timelineMarkers[0].id)
        StitchingTimeline.trim(&items[1], start: true, to: 35)
        XCTAssertEqual(items[0].effectiveTrimEnd, 30)
        XCTAssertEqual(items.reduce(0) { $0 + StitchingTimeline.duration($1) }, 35)
    }

    func testSplitRejectsBoundariesInvalidTimesAndBusyItems() {
        var items = [clip(duration: 20), clip(duration: 10)]
        for time in [0.0, 20, 30, -1, Double.nan, Double.infinity] {
            XCTAssertNil(StitchingTimeline.split(&items, at: time))
        }
        items[0].status = .converting
        XCTAssertNil(StitchingTimeline.split(&items, at: 5))
        XCTAssertEqual(items.count, 2)
    }

    func testZoomKeepsPointerTimeFixedAndClampsAtEdges() {
        let offset = StitchingTimeline.zoomOffset(time: 12, scale: 40, anchorX: 210,
                                                  contentWidth: 2000, viewportWidth: 600)
        XCTAssertEqual(offset, 280)
        XCTAssertEqual((offset + 210 - 10) / 40, 12)
        XCTAssertEqual(StitchingTimeline.zoomOffset(time: 0, scale: 40, anchorX: 210,
                                                    contentWidth: 2000, viewportWidth: 600), 0)
        XCTAssertEqual(StitchingTimeline.zoomOffset(time: 99, scale: 40, anchorX: 210,
                                                    contentWidth: 2000, viewportWidth: 600), 1400)
    }

    func testWaveformLODPreservesQuietPeaksAndTransients() {
        let samples: [Float] = [0, 0.00001, -0.00002, 0, 0.8, -0.7, 0, 0]
        let data = samples.withUnsafeBytes { Data($0) }
        let envelope = WaveformEnvelope(pcmData: data, channelCount: 1, sampleRate: 8,
                                        minimumFramesPerBin: 1)
        let quiet = envelope.peak(from: 0.125, to: 0.375, level: 0)
        XCTAssertEqual(quiet.maximum, 0.00001, accuracy: 0.000001)
        XCTAssertEqual(quiet.minimum, -0.00002, accuracy: 0.000001)
        let overview = envelope.peak(from: 0, to: 1, level: 3)
        XCTAssertEqual(overview.maximum, 0.8)
        XCTAssertEqual(overview.minimum, -0.7)
        XCTAssertEqual(envelope.level(secondsPerPixel: 0.125), 0)
        XCTAssertEqual(envelope.level(secondsPerPixel: 1), 3)
    }

    func testWaveformDoesNotCancelOppositePhaseChannelsOrAmplifySilence() {
        let samples: [Float] = [0.5, -0.5, 0, 0]
        let envelope = WaveformEnvelope(pcmData: samples.withUnsafeBytes { Data($0) },
                                        channelCount: 2, sampleRate: 2, minimumFramesPerBin: 1)
        XCTAssertEqual(envelope.peak(from: 0, to: 0.5, level: 0),
                       WaveformEnvelope.Peak(minimum: -0.5, maximum: 0.5))
        XCTAssertEqual(envelope.peak(from: 0.5, to: 1, level: 0),
                       WaveformEnvelope.Peak(minimum: 0, maximum: 0))
    }

    private func clip(duration: Double, start: Double? = nil, end: Double? = nil) -> VideoItem {
        var item = VideoItem(url: URL(fileURLWithPath: "/tmp/stitching-test.mov"), name: "Test",
                             size: 0, duration: "", status: .waiting, progress: 0, eta: nil, outputURL: nil)
        item.durationSeconds = duration
        item.trimStart = start
        item.trimEnd = end
        return item
    }

    func testRippleTrimTargetsPlayheadAndClosesGap() {
        let first = clip(duration: 20, start: 4, end: 10)
        let second = clip(duration: 30, start: 12, end: 18)
        var items = [first, second]
        XCTAssertEqual(StitchingTimeline.rippleTrim(&items, at: 8, start: true), second.id)
        XCTAssertEqual(items[1].effectiveTrimStart, 14)
        XCTAssertEqual(items[0], first)
        XCTAssertEqual(items.reduce(0) { $0 + StitchingTimeline.duration($1) }, 10)
        XCTAssertEqual(StitchingTimeline.rippleTrim(&items, at: 3, start: false), first.id)
        XCTAssertEqual(items[0].effectiveTrimEnd, 7)
        XCTAssertEqual(StitchingTimeline.location(at: 3, in: items)?.id, second.id)
        XCTAssertEqual(items.reduce(0) { $0 + StitchingTimeline.duration($1) }, 7)
    }

    func testRippleTrimAtBoundaryKeepsNonemptyClip() {
        var items = [clip(duration: 5), clip(duration: 5, start: 1, end: 4)]
        let secondID = items[1].id
        XCTAssertEqual(StitchingTimeline.rippleTrim(&items, at: 5, start: false), secondID)
        XCTAssertGreaterThan(StitchingTimeline.duration(items[1]), 0)
        XCTAssertEqual(items[0].effectiveTrimEnd, 5)
    }

    func testResetTrimAppliesToEntireSelectionOnlyAndKeepsMarkers() {
        var items = [clip(duration: 10, start: 1, end: 4),
                     clip(duration: 10, start: 2, end: 5),
                     clip(duration: 10, start: 3, end: 6)]
        items[0].timelineMarkers = [StitchTimelineMarker(sourceTime: 2, text: "Note")]
        let markers = items[0].timelineMarkers
        let third = items[2]
        StitchingTimeline.resetTrims(&items, selection: Set(items.prefix(2).map(\.id)))
        XCTAssertEqual(items.prefix(2).map(\.effectiveTrimStart), [0, 0])
        XCTAssertEqual(items.prefix(2).map(\.effectiveTrimEnd), [10, 10])
        XCTAssertEqual(items[2], third)
        XCTAssertEqual(items[0].timelineMarkers, markers)
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
