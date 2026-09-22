import XCTest
@testable import Aagedal_Media_Converter

final class StitchingTimelineTests: XCTestCase {
    func testOutPointReferenceRequiresContinuousCoverageThroughFollowingKeyframe() {
        XCTAssertEqual(StitchingTimeline.followingKeyframeReference(3.2, times: [0, 2, 4], scannedRanges: [0...6]), 4)
        XCTAssertEqual(StitchingTimeline.followingKeyframeReference(4, times: [0, 2, 4], scannedRanges: [0...6]), 4)
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(3.2, times: [0, 2, 40], scannedRanges: [0...6, 35...45]))
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(6, times: [0, 2, 4], scannedRanges: [0...6]))
        // A half-open reader range must not establish knowledge at its excluded end.
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(4, times: [0, 4], scannedRanges: [0...Double(4).nextDown]))
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(.nan, times: [0, 4], scannedRanges: [0...6]))
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(.infinity, times: [0, 4], scannedRanges: [0...6]))
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(-1, times: [0, 4], scannedRanges: [0...6]))
        XCTAssertNil(StitchingTimeline.followingKeyframeReference(3, times: [.nan, .infinity], scannedRanges: [0...6]))
    }

    func testSeekCandidateRequiresContinuousScannedCoverageThroughCut() {
        XCTAssertEqual(StitchingTimeline.precedingSeekCandidate(3.2, times: [0, 2, 4], scannedRanges: [0...6]), 2)
        XCTAssertEqual(StitchingTimeline.precedingSeekCandidate(4, times: [0, 2, 4], scannedRanges: [0...6]), 4)
        XCTAssertNil(StitchingTimeline.precedingSeekCandidate(30, times: [0, 2, 40], scannedRanges: [0...6, 35...45]))
        XCTAssertNil(StitchingTimeline.precedingSeekCandidate(1, times: [2, 4], scannedRanges: [0...6]))
        XCTAssertNil(StitchingTimeline.precedingSeekCandidate(.nan, times: [0], scannedRanges: [0...6]))
        XCTAssertNil(StitchingTimeline.precedingSeekCandidate(-1, times: [0], scannedRanges: [0...6]))
    }

    func testPerChannelWaveformPreservesIndependentPeaksAndSilence() {
        let samples: [Float] = [0, 0.8, 0, -0.7, 0.00001, 0, -0.00002, 0]
        let data = samples.withUnsafeBytes { Data($0) }
        let left = WaveformEnvelope(pcmData: data, channelCount: 2, sampleRate: 4,
                                    minimumFramesPerBin: 1, channel: 0)
        let right = WaveformEnvelope(pcmData: data, channelCount: 2, sampleRate: 4,
                                     minimumFramesPerBin: 1, channel: 1)
        XCTAssertEqual(left.peak(from: 0, to: 0.5, level: 0), .init(minimum: 0, maximum: 0))
        XCTAssertEqual(right.peak(from: 0, to: 0.5, level: 0), .init(minimum: -0.7, maximum: 0.8))
        XCTAssertEqual(left.peak(from: 0.5, to: 1, level: 0), .init(minimum: -0.00002, maximum: 0.00001))
        XCTAssertEqual(right.peak(from: 0.5, to: 1, level: 0), .init(minimum: 0, maximum: 0))
        XCTAssertEqual(right.peak(from: 0, to: 1, level: 2), .init(minimum: -0.7, maximum: 0.8))
        XCTAssertEqual(left.duration, 1)
    }

    func testRangeDeletionRetainsSourceGapAndSettings() {
        var source = clip(duration: 60, start: 10, end: 50)
        source.comment = "Keep me"
        var items = [source]
        StitchingTimeline.deleteRange(&items, id: source.id, range: 20...30)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.effectiveTrimStart), [10, 30])
        XCTAssertEqual(items.map(\.effectiveTrimEnd), [20, 50])
        XCTAssertEqual(items[0].id, source.id)
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertEqual(items[1].comment, "Keep me")
        XCTAssertEqual(items.reduce(0) { $0 + StitchingTimeline.duration($1) }, 30)
        var history = StitchingEditHistory()
        history.record(from: [source], to: items)
        history.restore(&items)
        XCTAssertEqual(items, [source])
        history.restore(&items, redo: true)
        XCTAssertEqual(items.count, 2)
    }

    func testRangeDeletionAtEdgesWholeClipAndEmptyRange() {
        let source = clip(duration: 20, start: 2, end: 18)
        for (range, start, end) in [(2.0...8.0, 8.0, 18.0), (12.0...18.0, 2.0, 12.0)] {
            var items = [source]
            StitchingTimeline.deleteRange(&items, id: source.id, range: range)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].id, source.id)
            XCTAssertEqual(items[0].effectiveTrimStart, start)
            XCTAssertEqual(items[0].effectiveTrimEnd, end)
        }
        var items = [source]
        StitchingTimeline.deleteRange(&items, id: source.id, range: 5...5)
        XCTAssertEqual(items, [source])
        StitchingTimeline.deleteRange(&items, id: source.id, range: 0...20)
        XCTAssertTrue(items.isEmpty)
    }

    func testRangeDeletionRejectsBusyClip() {
        var source = clip(duration: 20)
        source.status = .converting
        var items = [source]
        StitchingTimeline.deleteRange(&items, id: source.id, range: 5...10)
        XCTAssertEqual(items, [source])
    }

    func testKeyframeSnappingStaysWithinAllowedTrimBounds() {
        XCTAssertEqual(StitchingTimeline.nearestKeyframe(3.8, in: [0, 2, 4, 6], bounds: 0...3.9), 2)
        XCTAssertEqual(StitchingTimeline.nearestKeyframe(3.8, in: [0, 2, 4, 6], bounds: 0...6), 4)
        XCTAssertNil(StitchingTimeline.nearestKeyframe(3, in: [0, 6], bounds: 2...4))
        XCTAssertNil(StitchingTimeline.nearestKeyframe(3, in: [], bounds: 0...6))
    }

    func testKeyframeTicksFollowTrimAndVisibleSourceRange() {
        let times = [0.0, 2, 4, 6, 8, 10, 12]
        XCTAssertEqual(StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 3, duration: 5, scale: 20, visibleRange: 30...100
        ), [60, 100])
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 3, duration: 5, scale: 20, visibleRange: 120...150
        ).isEmpty)
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 3, duration: 5, scale: 20, visibleRange: 0...0
        ).isEmpty)
    }

    func testAllIntraKeyframeTicksRequireReadableZoomIncludingViewportEdges() {
        let times = (0...250).map { Double($0) / 25 }
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 0, duration: 10, scale: 20, visibleRange: 0...200
        ).isEmpty)
        // A tiny visible slice must still consider neighbors outside the viewport.
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 0, duration: 10, scale: 20, visibleRange: 99.9...100.1
        ).isEmpty)
        let offsets = StitchingTimeline.keyframeTickOffsets(
            in: times, sourceStart: 0, duration: 10, scale: 250, visibleRange: 100...130
        )
        XCTAssertEqual(offsets.count, 4)
        for (offset, expected) in zip(offsets, [100.0, 110, 120, 130]) {
            XCTAssertEqual(offset, expected, accuracy: 0.000001)
        }
    }

    func testKeyframeTicksHideDenseClustersWithoutThinningCandidates() {
        XCTAssertEqual(StitchingTimeline.keyframeTickOffsets(
            in: [0, 2, 2.1, 4, 6], sourceStart: 0, duration: 6,
            scale: 20, visibleRange: 0...120
        ), [0, 80, 120])
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: [0, 2], sourceStart: 0, duration: 2, scale: .nan, visibleRange: 0...100
        ).isEmpty)
        XCTAssertTrue(StitchingTimeline.keyframeTickOffsets(
            in: [], sourceStart: 0, duration: 2, scale: 20, visibleRange: 0...100
        ).isEmpty)
    }

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

    func testSequenceTimecodeFollowsFirstClipAfterReordering() {
        var first = clip(duration: 20, start: 5)
        first.timecodeConfig = TimecodeConfig(mode: .manual("01:00:00:00"))
        var second = clip(duration: 20)
        second.timecodeConfig = TimecodeConfig(mode: .manual("02:00:00:00"))
        XCTAssertEqual(StitchingTimeline.outputStartTimecode(for: [first, second]), "01:00:00:00")
        XCTAssertEqual(StitchingTimeline.outputStartTimecode(for: [second, first]), "02:00:00:00")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(6.08, frameRate: 25,
            startTimecode: StitchingTimeline.outputStartTimecode(for: [first, second])), "01:00:06:02")
        XCTAssertNil(StitchingTimeline.outputStartTimecode(for: []))
        XCTAssertNil(StitchingTimeline.outputStartTimecode(for: [clip(duration: 10)]))
    }

    func testSequenceTimecodeDropFrameRolloverAndRelativeFallback() {
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(1 / (30_000.0 / 1001),
            frameRate: 30_000.0 / 1001, startTimecode: "00:00:59;29"), "00:01:00;02")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(1 / (60_000.0 / 1001),
            frameRate: 60_000.0 / 1001, startTimecode: "00:00:59;59"), "00:01:00;04")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(1, frameRate: 25,
            startTimecode: "23:59:59:00"), "00:00:00:00")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(6.08, frameRate: 25,
            startTimecode: nil), "00:00:06:02")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(6.08, frameRate: nil,
            startTimecode: "01:00:00:00"), "00:00:06")
        XCTAssertEqual(StitchingTimeline.sequenceTimeDisplay(.nan, frameRate: 25,
            startTimecode: nil), "—")
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

final class GroupEditorWindowLayoutTests: XCTestCase {
    func testOversizedSavedWindowFitsUsableScreen() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 838)
        let saved = CGRect(x: 0, y: -900, width: 1440, height: 1800)
        XCTAssertEqual(GroupEditorWindowLayout.fittedFrame(saved, within: screen), screen)
    }

    func testValidSavedFrameIsPreserved() {
        let screen = CGRect(x: 0, y: 40, width: 1920, height: 1018)
        let saved = CGRect(x: 100, y: 100, width: 1120, height: 822)
        XCTAssertEqual(GroupEditorWindowLayout.fittedFrame(saved, within: screen), saved)
    }

    func testOffscreenWindowMovesInsideSecondaryDisplayWithoutResizing() {
        let screen = CGRect(x: -1920, y: 40, width: 1920, height: 1018)
        let saved = CGRect(x: 100, y: -400, width: 1120, height: 822)
        let expected = CGRect(x: -1120, y: 40, width: 1120, height: 822)
        XCTAssertEqual(GroupEditorWindowLayout.fittedFrame(saved, within: screen), expected)
    }

    func testDefaultWindowFitsSmallDisplay() {
        let screen = CGRect(x: 0, y: 40, width: 1024, height: 638)
        let initial = CGRect(x: 0, y: 0, width: 1120, height: 822)
        XCTAssertEqual(GroupEditorWindowLayout.fittedFrame(initial, within: screen), screen)
    }
}

final class SourceAudioMeterTests: XCTestCase {
    func testMonoTracksShareOneBankWhileStereoAndSurroundStaySeparate() {
        let groups = SourceAudioMeterGroup.groups(channelCounts: [1, 2, 1, 6, 1])
        XCTAssertEqual(groups.map(\.tracks), [[0, 2, 4], [1], [3]])
        XCTAssertEqual(groups.map(\.isMultiMono), [true, false, false])
        XCTAssertEqual(SourceAudioMeterGroup.groups(channelCounts: [1, 1]).map(\.tracks), [[0, 1]])
        XCTAssertEqual(SourceAudioMeterGroup.groups(channelCounts: [2, 2]).map(\.tracks), [[0], [1]])
        XCTAssertEqual(SourceAudioMeterGroup.groups(channelCounts: [nil, 1, 1]).map(\.tracks), [[0], [1, 2]])
        XCTAssertTrue(SourceAudioMeterGroup.groups(channelCounts: []).isEmpty)
    }

    func testEightChannelPeaksAreIndependentAndUseDBFS() {
        let request = SourceAudioMeterRequest(url: URL(fileURLWithPath: "/tmp/meter.wav"),
                                             track: 1, channels: 8, window: 0)
        let channelSamples: [Float] = [1, 0.5, 0.25, 0.125, 0, -0.5, .nan, .infinity]
        let samples = (0..<480).flatMap { _ in channelSamples }
        let chunk = SourceAudioMeterChunk(request: request, pcm: samples.withUnsafeBytes { Data($0) })
        let levels = chunk.levels(at: 0)
        XCTAssertEqual(levels.count, 8)
        XCTAssertEqual(levels[0], 0, accuracy: 0.001)
        XCTAssertEqual(levels[1], -6.0206, accuracy: 0.001)
        XCTAssertEqual(levels[2], -12.0412, accuracy: 0.001)
        XCTAssertEqual(levels[3], -18.0618, accuracy: 0.001)
        XCTAssertEqual(levels[4], -60)
        XCTAssertEqual(levels[5], -6.0206, accuracy: 0.001)
        XCTAssertEqual(levels[6], -60)
        XCTAssertEqual(levels[7], -60)
    }

    func testSeekingOutsideDecodedWindowReturnsSilence() {
        let request = SourceAudioMeterRequest(url: URL(fileURLWithPath: "/tmp/meter.wav"),
                                             track: 0, channels: 1, window: 1)
        let samples = Array(repeating: Float(1), count: 480)
        let chunk = SourceAudioMeterChunk(request: request, pcm: samples.withUnsafeBytes { Data($0) })
        XCTAssertEqual(chunk.levels(at: 8), [0])
        for time in [0.0, 7.99, 8.5, 16, .nan, .infinity] {
            XCTAssertEqual(chunk.levels(at: time), [-60])
        }
    }

    func testDecoderSelectsAudioOrdinalWithoutDownmixing() {
        let request = SourceAudioMeterRequest(url: URL(fileURLWithPath: "/tmp/meter.mkv"),
                                             track: 2, channels: 6, window: 2)
        let arguments = SourceAudioMeterDecoder.arguments(for: request)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-map")! + 1], "0:a:2")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-ss")! + 1], "16.0")
        XCTAssertFalse(arguments.contains("-ac"))
        XCTAssertFalse(arguments.joined().contains("pan="))
        let many = SourceAudioMeterRequest(url: request.url, track: 1, channels: 16, window: 0)
        XCTAssertEqual(many.displayedChannels, 8)
        XCTAssertTrue(SourceAudioMeterDecoder.arguments(for: many).joined().contains("pan=8c|c0=c0|c1=c1"))
    }

    func testDecodedMultitrackFixtureHasSeparateSourceLevels() async throws {
        let path = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meter.mkv")
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-hide_banner", "-loglevel", "error", "-nostdin",
                        "-f", "lavfi", "-i", "aevalsrc=0.5|0.25:s=48000:d=10:c=stereo",
                        "-itsoffset", "0.5", "-f", "lavfi", "-i", "aevalsrc=0.1|0.2|0.3|0.4|0.5|0.6|0.7|0.8:s=48000:d=10:c=7.1",
                        "-map", "0:a", "-map", "1:a", "-c:a", "pcm_f32le", "-y", url.path],
            timeout: .seconds(20)
        ))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
        let stereo = try await SourceAudioMeterDecoder.decode(.init(url: url, track: 0, channels: 2, window: 0))
        XCTAssertEqual(stereo.levels(at: 1)[0], -6.0206, accuracy: 0.01)
        XCTAssertEqual(stereo.levels(at: 1)[1], -12.0412, accuracy: 0.01)
        let delayed = try await SourceAudioMeterDecoder.decode(.init(url: url, track: 1, channels: 8, window: 0))
        XCTAssertEqual(delayed.levels(at: 0.1), Array(repeating: -60, count: 8))
        XCTAssertEqual(delayed.levels(at: 0.75)[0], -20, accuracy: 0.01)
        // Both waveform paths must keep the same source-time origin as playback and metering.
        let waveform = try await NativeWaveformRenderer.generateWaveformAssets(
            url: url, ffmpegPath: path, streamIndex: 1, duration: 10.5,
            width: 800, height: 80, channelCount: 8
        )
        let envelope = try XCTUnwrap(waveform.envelope)
        XCTAssertEqual(envelope.duration, 10.5, accuracy: 0.01)
        XCTAssertEqual(envelope.peak(from: 0.1, to: 0.2, level: 0), .init(minimum: 0, maximum: 0))
        XCTAssertEqual(envelope.peak(from: 0.75, to: 0.8, level: 0).maximum, 0.8, accuracy: 0.001)
        let (_, _, channelEnvelopes) = try await NativeWaveformRenderer.generatePerChannelWaveforms(
            url: url, ffmpegPath: path, streamIndex: 1, channelCount: 8,
            channelLayout: "7.1", duration: 10.5, width: 800, heightPerChannel: 40
        )
        XCTAssertEqual(channelEnvelopes.count, 8)
        for (index, channel) in channelEnvelopes.enumerated() {
            XCTAssertEqual(channel.duration, 10.5, accuracy: 0.01)
            XCTAssertEqual(channel.peak(from: 0.1, to: 0.2, level: 0), .init(minimum: 0, maximum: 0))
            XCTAssertEqual(channel.peak(from: 0.75, to: 0.8, level: 0).maximum,
                           Float(index + 1) / 10, accuracy: 0.001)
        }
        let surround = try await SourceAudioMeterDecoder.decode(.init(url: url, track: 1, channels: 8, window: 1))
        let levels = surround.levels(at: 9)
        XCTAssertEqual(levels.count, 8)
        for index in 0..<8 {
            XCTAssertEqual(levels[index], 20 * log10(Float(index + 1) / 10), accuracy: 0.01)
        }
    }
}
