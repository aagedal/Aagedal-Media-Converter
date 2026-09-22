import XCTest
@testable import Aagedal_Media_Converter

final class StitchMarkerExportTests: XCTestCase {
    func testSourceReferencesUseTrimmedOriginalTimecode() {
        let source = StitchMarkerMedia(duration: 20, frameRate: 25, timecode: "10:00:00:00", chapters: [])
        XCTAssertEqual(StitchMarkerExport.sourceTimecode(source, trimStart: 2.48), "10:00:02:12")
        let drop = StitchMarkerMedia(duration: 20, frameRate: 30_000.0 / 1001, timecode: "00:00:59;29", chapters: [])
        XCTAssertEqual(StitchMarkerExport.sourceTimecode(drop, trimStart: 1001.0 / 30_000), "00:01:00;02")
        let missing = StitchMarkerMedia(duration: 20, frameRate: 25, timecode: nil, chapters: [])
        XCTAssertNil(StitchMarkerExport.sourceTimecode(missing, trimStart: 2))
        XCTAssertNil(StitchMarkerExport.sourceTimecode(source, trimStart: .nan))
        let invalid = StitchMarkerMedia(duration: 20, frameRate: 25, timecode: "bad", chapters: [])
        XCTAssertNil(StitchMarkerExport.sourceTimecode(invalid, trimStart: 0))
    }

    func testSourceReferencesSurviveChapterAndEDLSerialization() throws {
        let cuts = try StitchMarkerExport.cuts(names: ["B.mov", "A.mov", "NoTC.mov"], durations: [5, 5, 5],
                                              sourceTimecodes: ["10:00:02:12", "02:00:00;04", nil])
        XCTAssertEqual(cuts.map(\.start), [0, 5, 10])
        XCTAssertEqual(cuts[0].title, "Cut: B.mov • Source TC: 10:00:02:12")
        XCTAssertEqual(cuts[2].title, "Cut: NoTC.mov")
        let chapters = try StitchMarkerExport.chapterMetadata(StitchMarkerExport.chapters(from: cuts))
        XCTAssertTrue(chapters.contains("Source TC: 10:00:02:12"))
        XCTAssertTrue(chapters.contains("Source TC: 02:00:00\\;04"))
        let edl = try StitchMarkerExport.resolveEDL(title: "Stitched", markers: cuts, frameRate: 25, startTimecode: "01:00:00:00")
        XCTAssertTrue(edl.contains("|M:Cut: B.mov • Source TC: 10:00:02:12"))
        XCTAssertTrue(edl.contains("01:00:05:00 01:00:05:01"))
        XCTAssertThrowsError(try StitchMarkerExport.cuts(names: ["A"], durations: [5], sourceTimecodes: []))
    }

    func testRetainedResolve2997DropFrameFixture() throws {
        try checkFixture("2997", rate: 30_000.0 / 1001,
                         frames: [0, 1, 59, 60, 16241, 16242, 18280], numbers: [1, 2, 3, 4, 6, 7, 8])
    }

    func testRetainedResolve5994DropFrameFixture() throws {
        try checkFixture("5994", rate: 60_000.0 / 1001,
                         frames: [0, 1, 119, 120, 32483, 32484, 36562], numbers: Array(1...7))
    }

    private func checkFixture(_ name: String, rate: Double, frames: [Int], numbers: [Int]) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StitchMarkers/\(name).edl")
        let expected = try Data(contentsOf: url)
        let lines = String(decoding: expected, as: UTF8.self).components(separatedBy: "\r\n")
        // Notes are opaque payloads; frame positions/ranges are independent fixture inputs.
        let notes = lines.filter { $0.hasPrefix(" |C:") }.map {
            $0.components(separatedBy: " |M:")[1].components(separatedBy: " |D:")[0]
        }
        let durations = [1, 1, 3, 1, 3, 1, 1]
        let markers = frames.indices.map { index in
            StitchCutMarker(title: notes[index], start: Double(frames[index]) / rate,
                            end: Double(frames[index] + durations[index]) / rate)
        }
        let result = try StitchMarkerExport.resolveEDL(
            title: "source-a.mov vs source-b.mov Review", markers: markers, frameRate: rate,
            startTimecode: "00:00:58;00", markerNumbers: numbers, includeRanges: true)
        XCTAssertEqual(Data(result.utf8), expected)
    }

    func testNotesRespectTrimAndSequenceOffset() {
        let notes = [0.5, 1.0, 2.0, 3.0].map { StitchTimelineMarker(sourceTime: $0, text: "Note") }
        let result = StitchMarkerExport.notes(notes, trimStart: 1, trimEnd: 3, duration: 2.2, offset: 5)
        XCTAssertEqual(result.map(\.start), [5, 6])
        XCTAssertEqual(result.map(\.title), ["Marked: Note", "Marked: Note"])
    }

    func testCutsAndNotesBecomeNonOverlappingChapters() throws {
        let cuts = try StitchMarkerExport.cuts(names: ["A", "B"], durations: [2, 3])
        let notes = [StitchCutMarker(title: "Marked: Note", start: 1, end: 2),
                     StitchCutMarker(title: "Marked: At cut", start: 2, end: 5)]
        let chapters = StitchMarkerExport.chapters(from: cuts + notes)
        XCTAssertEqual(chapters.map(\.start), [0, 1, 2])
        XCTAssertEqual(chapters.map(\.end), [1, 2, 5])
        XCTAssertTrue(chapters[2].title.contains("Cut: B"))
        XCTAssertTrue(chapters[2].title.contains("Marked: At cut"))
        XCTAssertNoThrow(try StitchMarkerExport.chapterMetadata(chapters))
    }

    func testNotesOnSameOutputFrameShareEDLEntry() throws {
        let points = [StitchCutMarker(title: "Cut: A", start: 0, end: 1),
                      StitchCutMarker(title: "Marked: Note", start: 0.001, end: 1)]
        let result = try StitchMarkerExport.coalescedForEDL(points, frameRate: 24)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Cut: A • Marked: Note")
        XCTAssertNoThrow(try StitchMarkerExport.resolveEDL(title: "Test", markers: result, frameRate: 24, startTimecode: nil))
    }

    func testCutOrderAndMeasuredDurations() throws {
        let cuts = try StitchMarkerExport.cuts(names: ["B", "A"], durations: [2.4, 1.2])
        XCTAssertEqual(cuts.map(\.title), ["Cut: B", "Cut: A"])
        XCTAssertEqual(cuts[1].start, 2.4)
        XCTAssertEqual(cuts[1].end, 3.6, accuracy: 0.000001)
        XCTAssertThrowsError(try StitchMarkerExport.cuts(names: ["A"], durations: [.nan]))
        let edl = try StitchMarkerExport.resolveEDL(title: "Cuts", markers: cuts, frameRate: 25, startTimecode: "01:00:00:00")
        XCTAssertTrue(edl.contains("01:00:02:10 01:00:02:11"))
        XCTAssertEqual(edl.components(separatedBy: "|D:1").count, 3)
    }

    func testRejectsDuplicateFramesAndMidnightWrap() throws {
        let duplicate = [StitchCutMarker(title: "A", start: 0, end: 1),
                         StitchCutMarker(title: "B", start: 0.001, end: 2)]
        XCTAssertThrowsError(try StitchMarkerExport.resolveEDL(title: "", markers: duplicate, frameRate: 25, startTimecode: nil))
        XCTAssertThrowsError(try StitchMarkerExport.resolveEDL(title: "", markers: [duplicate[0]], frameRate: 25, startTimecode: "23:59:59:24"))
        XCTAssertThrowsError(try StitchMarkerExport.resolveEDL(title: "", markers: [duplicate[0]], frameRate: 25, startTimecode: "00:00:00;00"))
        XCTAssertThrowsError(try StitchMarkerExport.resolveEDL(title: "", markers: Array(repeating: duplicate[0], count: 1000), frameRate: 25, startTimecode: nil))
    }

    func testExistingChaptersAreOffsetAndClamped() {
        let media = [
            StitchMarkerMedia(duration: 2, frameRate: 25, timecode: nil,
                              chapters: [.init(title: "Original A", start: -1, end: 4)]),
            StitchMarkerMedia(duration: 3, frameRate: 25, timecode: nil,
                              chapters: [.init(title: "Original B", start: 1, end: 2)])
        ]
        XCTAssertEqual(StitchMarkerExport.concatenateChapters(media), [
            .init(title: "Original A", start: 0, end: 2), .init(title: "Original B", start: 3, end: 4)
        ])
    }

    func testSourceChapterFallbackIntersectsRetainedRange() {
        let chapters = [StitchCutMarker(title: "Before", start: 0, end: 2),
                        StitchCutMarker(title: "Keep A", start: 2, end: 6),
                        StitchCutMarker(title: "Keep B", start: 6, end: 12)]
        XCTAssertEqual(StitchMarkerExport.retainedChapters(chapters, trimStart: 4, duration: 5), [
            .init(title: "Keep A", start: 0, end: 2), .init(title: "Keep B", start: 2, end: 5)
        ])
    }

    func testSidecarDoesNotOverwriteAndUsesActualOutputStem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Camera-2.mov")
        let first = try StitchMarkerExport.writeEDL("original", alongside: output)
        let second = try StitchMarkerExport.writeEDL("new", alongside: output)
        XCTAssertEqual(first.lastPathComponent, "Camera-2.cuts.edl")
        XCTAssertEqual(second.lastPathComponent, "Camera-2.cuts-2.edl")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
    }

    func testRealChapterMuxWithStreamCopy() async throws {
        let executable = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let metadata = directory.appendingPathComponent("chapters.ffmetadata")
        let chapters = StitchMarkerExport.chapters(from:
            try StitchMarkerExport.cuts(names: ["Camera A = æøå; #1", "Camera B"], durations: [1, 1],
                                        sourceTimecodes: ["10:00:02:12", "02:00:00;04"]) +
            [StitchCutMarker(title: "Marked: Review audio", start: 0.5, end: 1)])
        try StitchMarkerExport.chapterMetadata(chapters).write(to: metadata, atomically: true, encoding: .utf8)
        let runner = SubprocessRunner()
        let fixture = try await runner.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["-y", "-f", "lavfi", "-i", "color=size=64x48:rate=25:duration=2", "-c:v", "libx264", source.path],
            timeout: .seconds(15)), outputHandler: nil)
        XCTAssertTrue(fixture.succeeded, fixture.standardErrorText)
        for ext in ["mov", "mp4", "mkv"] {
            let output = directory.appendingPathComponent("stitched.\(ext)")
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: source, outputFileURL: output, preset: .streamCopy,
                comment: "", includeDateTag: false, trimStart: nil, trimEnd: nil,
                chapterMetadataURL: metadata, chapterMetadataTitles: chapters.map(\.title))
            let map = try XCTUnwrap(command.arguments.lastIndex(of: "-map_chapters"))
            XCTAssertEqual(command.arguments[map + 1], "1")
            let result = try await runner.run(SubprocessRequest(
                executableURL: URL(fileURLWithPath: executable), arguments: command.arguments,
                timeout: .seconds(15)), outputHandler: nil)
            XCTAssertTrue(result.succeeded, result.standardErrorText)
            let actual = try await StitchMarkerMedia.read(output)
            XCTAssertTrue(actual.hasChapterMetadata)
            XCTAssertEqual(actual.chapters.map(\.title), chapters.map(\.title))
            XCTAssertEqual(try XCTUnwrap(actual.chapters.last).start, 1, accuracy: 0.001)
        }
    }
}
