import XCTest
@testable import Aagedal_Media_Converter

final class CameraCardRecordingGroupingTests: XCTestCase {
    private typealias Grouping = CameraCardRecordingGrouping
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func recording(_ name: String, _ start: String?, duration: Double? = 60,
                           segments: Int = 1) -> Grouping.Recording {
        Grouping.Recording(
            urls: (0..<segments).map { URL(fileURLWithPath: "/card/\(name)-\($0).mov") },
            cameraDate: start.map(date), containerDate: nil, duration: duration
        )
    }

    private func counts(_ recordings: [Grouping.Recording], gaps: Bool = true,
                        zone: TimeZone? = nil) -> [Int] {
        Grouping.groups(for: recordings, mode: .recordingDay(splitOnLongGaps: gaps),
                        timeZone: zone ?? utc).map(\.count)
    }

    func testSingleGroupRetainsEveryRecordingAndEmptyInputHasNoGroups() {
        let input = [recording("a", nil), recording("b", "2026-01-01T23:59:00Z"),
                     recording("c", "2026-01-02T04:00:00Z")]
        XCTAssertEqual(Grouping.groups(for: input, mode: .singleGroup, timeZone: utc), [input])
        XCTAssertTrue(Grouping.groups(for: [], mode: .singleGroup, timeZone: utc).isEmpty)
        XCTAssertTrue(counts([]).isEmpty)
    }

    func testReviewerResolvedSegmentsPreserveOrderAndIgnoreFirstContinuationMark() {
        let urls = (1...5).map { URL(fileURLWithPath: "/card/clip\($0).mov") }
        let segments = Grouping.resolvedSegments(
            urls: urls, continuesPrevious: [urls[0], urls[2], urls[3]]
        )
        XCTAssertEqual(segments, [[urls[0]], [urls[1], urls[2], urls[3]], [urls[4]]])
        XCTAssertEqual(segments.flatMap { $0 }, urls)
        XCTAssertTrue(Grouping.resolvedSegments(urls: [], continuesPrevious: []).isEmpty)
    }

    func testDayBoundarySplitsWithoutReorderingOrRecombiningRepeatedDays() {
        let input = [recording("a", "2026-01-01T23:59:00Z"),
                     recording("b", "2026-01-02T00:00:00Z"),
                     recording("c", "2026-01-01T22:00:00Z")]
        let result = Grouping.groups(for: input, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc)
        XCTAssertEqual(result.map(\.count), [1, 1, 1])
        XCTAssertEqual(result.flatMap { $0 }, input)
    }

    func testGapUsesPreviousEndAndIsStrictlyGreaterThanTwoHours() {
        let first = recording("a", "2026-01-01T08:00:00Z", duration: 3_600)
        XCTAssertEqual(counts([first, recording("b", "2026-01-01T11:00:00Z")]), [2])
        XCTAssertEqual(counts([first, recording("b", "2026-01-01T11:00:01Z")]), [1, 1])
        XCTAssertEqual(counts([first, recording("b", "2026-01-01T08:30:00Z")]), [2])
        XCTAssertEqual(counts([first, recording("b", "2026-01-01T07:00:00Z")]), [2])
        XCTAssertEqual(counts([first, recording("b", "2026-01-01T15:00:00Z")], gaps: false), [2])
    }

    func testMissingDatesAreSeparateContiguousRunsWithoutInventingDates() {
        let input = [recording("a", "2026-01-01T08:00:00Z"), recording("b", nil),
                     recording("c", nil), recording("d", "2026-01-01T09:00:00Z")]
        XCTAssertEqual(counts(input), [1, 2, 1])
    }

    func testUnknownAndInvalidDurationsDoNotCreateGapSplits() {
        for duration: Double? in [nil, -.infinity, .infinity, .nan, -1] {
            let first = recording("a", "2026-01-01T08:00:00Z", duration: duration)
            XCTAssertNil(first.duration)
            XCTAssertEqual(counts([first, recording("b", "2026-01-01T18:00:00Z")]), [2])
            XCTAssertEqual(counts([first, recording("b", "2026-01-02T08:00:00Z")]), [1, 1])
        }
    }

    func testSpannedRecordingRemainsIntactAcrossMidnightAndUsesCompleteDuration() {
        let span = recording("span", "2026-01-01T23:00:00Z", duration: 10_800, segments: 3)
        let next = recording("next", "2026-01-02T04:00:00Z")
        let groups = Grouping.groups(for: [span, next], mode: .recordingDay(splitOnLongGaps: true), timeZone: utc)
        XCTAssertEqual(groups, [[span], [next]])
        let daytimeSpan = recording("day", "2026-01-01T08:00:00Z", duration: 10_800, segments: 3)
        XCTAssertEqual(counts([daytimeSpan, recording("next", "2026-01-01T13:00:00Z")]), [2])
    }

    func testFixedTimezoneControlsDayRegardlessOfEmbeddedOffsets() {
        let input = [recording("a", "2026-01-01T23:30:00Z"),
                     recording("b", "2026-01-02T02:00:00+02:00")]
        XCTAssertEqual(counts(input), [1, 1])
        XCTAssertEqual(counts(input, zone: TimeZone(secondsFromGMT: 3_600)!), [2])
        let sameInstant = [recording("a", "2026-01-02T00:30:00+02:00"),
                           recording("b", "2026-01-01T22:30:00Z")]
        XCTAssertEqual(counts(sameInstant), [2])
    }

    func testDaylightSavingChangeUsesElapsedSecondsForGap() {
        let input = [recording("a", "2026-03-29T01:00:00+01:00", duration: 3_600),
                     recording("b", "2026-03-29T05:00:00+02:00")]
        XCTAssertEqual(counts(input, zone: TimeZone(identifier: "Europe/Oslo")!), [2])
    }

    func testCameraDateTakesPrecedenceWithContainerFallbackAndNoDateWhenBothMissing() {
        let camera = date("2026-01-01T08:00:00Z")
        let container = date("2026-02-01T08:00:00Z")
        let urls = [URL(fileURLWithPath: "/card/a.mov")]
        XCTAssertEqual(Grouping.Recording(urls: urls, cameraDate: camera, containerDate: container, duration: 1).start, camera)
        XCTAssertEqual(Grouping.Recording(urls: urls, cameraDate: nil, containerDate: container, duration: 1).start, container)
        XCTAssertNil(Grouping.Recording(urls: urls, cameraDate: nil, containerDate: nil, duration: 1).start)
    }

    func testCompatibilityProposalPreservesContiguousOrderAndAllSpanSegments() {
        let input = [recording("a", "2026-01-01T08:00:00Z", segments: 2),
                     recording("b", "2026-01-01T09:00:00Z"),
                     recording("a", "2026-01-01T10:00:00Z")]
        var evaluatedSpan = false
        let result = Grouping.proposal(for: input, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc) { urls in
            if urls == input[0].urls { evaluatedSpan = true }
            let formats = Set(urls.map { $0.lastPathComponent.first! })
            return formats.count == 1 ? .compatible : .incompatible
        }
        XCTAssertTrue(evaluatedSpan)
        XCTAssertEqual(result.map(\.recordings), input.map { [$0] })
        XCTAssertEqual(result.flatMap(\.urls), input.flatMap(\.urls))
        XCTAssertTrue(result.allSatisfy { !$0.requiresReview })
    }

    func testUnknownAndConflictingSpansRemainIntactAndRequireReview() {
        let input = [recording("a", nil), recording("unknown", nil, segments: 3),
                     recording("conflict", nil, segments: 2), recording("b", nil)]
        let result = Grouping.proposal(for: input, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc) { urls in
            if urls.contains(where: { $0.lastPathComponent.hasPrefix("unknown") }) { return .unknown }
            if urls.contains(where: { $0.lastPathComponent.hasPrefix("conflict") }) { return .incompatible }
            return .compatible
        }
        XCTAssertEqual(result.map(\.recordings), input.map { [$0] })
        XCTAssertEqual(result.map(\.compatibility), [.compatible, .unknown, .incompatible, .compatible])
        XCTAssertEqual(result.map(\.requiresReview), [false, true, true, false])
        XCTAssertEqual(result.flatMap(\.urls), input.flatMap(\.urls))
    }

    func testCompatibilityProposalNeverRejoinsDateOrUnknownDateBoundaries() {
        let input = [recording("a", "2026-01-01T08:00:00Z"),
                     recording("b", "2026-01-01T09:00:00Z"),
                     recording("c", nil), recording("d", nil),
                     recording("e", "2026-01-02T08:00:00Z")]
        let result = Grouping.proposal(for: input, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc) { _ in .compatible }
        XCTAssertEqual(result.map { $0.recordings.count }, [2, 2, 1])
        XCTAssertEqual(result.flatMap(\.recordings), input)
    }

    func testRetainingSingleGroupStillReportsIncompatibilityAndDoesNotSplit() {
        let input = [recording("a", "2026-01-01T08:00:00Z"),
                     recording("b", "2026-01-02T09:00:00Z", segments: 3)]
        let result = Grouping.proposal(for: input, mode: .singleGroup, timeZone: utc) { urls in
            XCTAssertEqual(urls, input.flatMap(\.urls))
            return .incompatible
        }
        XCTAssertEqual(result.map(\.recordings), [input])
        XCTAssertEqual(result.first?.requiresReview, true)
        XCTAssertTrue(Grouping.proposal(for: [], mode: .singleGroup, timeZone: utc) { _ in
            XCTFail("Empty input must not invoke the evaluator")
            return .compatible
        }.isEmpty)
    }

    func testSingleGroupConflictDoesNotMislabelCompatibleSpanAsUnmergeable() {
        let span = recording("a", "2026-01-01T08:00:00Z", segments: 2)
        let other = recording("b", "2026-01-01T09:00:00Z")
        let recordings = [span, other]
        let compatibility: ([URL]) -> Grouping.Compatibility = { urls in
            urls.allSatisfy { $0.lastPathComponent.hasPrefix("a") } ? .compatible : .incompatible
        }
        let proposal = Grouping.proposal(
            for: recordings, mode: .singleGroup, timeZone: utc,
            evaluateCompatibility: compatibility
        )
        XCTAssertEqual(proposal.first?.compatibility, .incompatible)
        XCTAssertFalse(Grouping.hasUnmergeableSpan(
            in: recordings, evaluateCompatibility: compatibility
        ))
        XCTAssertTrue(Grouping.hasUnmergeableSpan(in: recordings) { urls in
            urls == span.urls ? .unknown : .compatible
        })
    }

    func testProposalChecksWholeCandidateGroupRatherThanAssumingPairwiseCompatibility() {
        let input = [recording("a", nil), recording("b", nil), recording("c", nil)]
        let result = Grouping.proposal(for: input, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc) { urls in
            urls.count <= 2 ? .compatible : .unknown
        }
        XCTAssertEqual(result.map { $0.recordings.count }, [2, 1])
        XCTAssertEqual(result.flatMap(\.recordings), input)
    }

    func testEmptyLogicalRecordingIsRetainedForReviewWithoutPassingIncompleteInputs() {
        let empty = Grouping.Recording(urls: [], cameraDate: nil, containerDate: nil, duration: nil)
        let result = Grouping.proposal(for: [empty], mode: .recordingDay(splitOnLongGaps: false), timeZone: utc) { _ in
            XCTFail("Incomplete recordings must not be approved by an evaluator")
            return .compatible
        }
        XCTAssertEqual(result.map(\.recordings), [[empty]])
        XCTAssertEqual(result.first?.compatibility, .unknown)
    }

    func testCardScannerKeepsCameraFoldersContiguousAndSortsClipsNaturally() {
        let paths = ["/card/camera10/clip1.mov", "/card/camera2/clip1.mov",
                     "/card/camera1/clip10.mov", "/card/camera1/clip2.mov"]
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let expected = [urls[3], urls[2], urls[1], urls[0]]
        XCTAssertEqual(CameraCardScanner.sortedForImport(urls), expected)
        XCTAssertEqual(CameraCardScanner.sortedForImport(Array(urls.reversed())), expected)
        XCTAssertEqual(Set(CameraCardScanner.sortedForImport(urls)), Set(urls))
    }

    func testPhysicalLikeTwoCameraTreeKeepsContinuationSegmentsAdjacent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-grouping-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraA = root.appendingPathComponent("DCIM/CAMERA_A", isDirectory: true)
        let cameraB = root.appendingPathComponent("DCIM/CAMERA_B", isDirectory: true)
        try FileManager.default.createDirectory(at: cameraA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cameraB, withIntermediateDirectories: true)
        let a1 = cameraA.appendingPathComponent("C0001.MOV")
        let a2 = cameraA.appendingPathComponent("C0002.MOV")
        let b1 = cameraB.appendingPathComponent("C0001.MOV")
        let b2 = cameraB.appendingPathComponent("C0002.MOV")
        for url in [b2, a2, b1, a1] {
            try Data().write(to: url)
        }

        let scanned = CameraCardScanner.scanForVideoFiles(in: root)
        XCTAssertEqual(scanned.map {
            "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)"
        }, ["CAMERA_A/C0001.MOV", "CAMERA_A/C0002.MOV",
            "CAMERA_B/C0001.MOV", "CAMERA_B/C0002.MOV"])
        guard scanned.count == 4 else {
            XCTFail("Expected four scanned clips, found \(scanned.count)")
            return
        }
        let resolved = Grouping.resolvedSegments(
            urls: scanned, continuesPrevious: [scanned[1], scanned[3]]
        )
        XCTAssertEqual(resolved, [Array(scanned[0...1]), Array(scanned[2...3])])

        let day = date("2026-09-01T08:00:00Z")
        let recordings = resolved.enumerated().map { index, urls in
            Grouping.Recording(
                urls: urls, cameraDate: day.addingTimeInterval(Double(index) * 60),
                containerDate: nil, duration: 120
            )
        }
        let groups = Grouping.proposal(
            for: recordings, mode: .recordingDay(splitOnLongGaps: false), timeZone: utc
        ) { _ in .compatible }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].recordings, recordings)
        XCTAssertEqual(groups[0].urls, scanned)
    }

    func testCardScannerEquivalentNaturalNamesDoNotDependOnEnumerationOrder() {
        let urls = ["/card/A/clip01.mov", "/card/a/clip1.mov", "/card/A/clip1.mov"]
            .map { URL(fileURLWithPath: $0) }
        let expected = CameraCardScanner.sortedForImport(urls)
        for rotation in urls.indices {
            let rotated = Array(urls[rotation...]) + Array(urls[..<rotation])
            XCTAssertEqual(CameraCardScanner.sortedForImport(rotated), expected)
            XCTAssertEqual(CameraCardScanner.sortedForImport(Array(rotated.reversed())), expected)
        }
        XCTAssertEqual(expected.count, urls.count)
        XCTAssertEqual(Set(expected), Set(urls))
    }
}
