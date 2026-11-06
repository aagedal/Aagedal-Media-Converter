import XCTest
@testable import Aagedal_Media_Converter

final class VideoEventAnalysisTests: XCTestCase {
    // Lines captured from the bundled FFmpeg 9.0.2.
    private let blackLog = """
    [Parsed_blackdetect_0 @ 0x7b498486c0] black_start:0 black_end:2 black_duration:2
    [Parsed_blackdetect_0 @ 0x7b498486c0] black_start:5 black_end:6 black_duration:1
    [Parsed_blackdetect_0 @ 0x7b498486c0] black_start:9 black_end:10.16 black_duration:1.16

    """
    private let sceneLog = """
    [Parsed_scdet_0 @ 0x74aec31a40] lavfi.scd.score: 30.359, lavfi.scd.time: 4.451333
    [Parsed_scdet_0 @ 0x74aec31a40] lavfi.scd.score: 13.680, lavfi.scd.time: 4.491333
    [Parsed_scdet_0 @ 0x74aec31a40] lavfi.scd.score: 14.580, lavfi.scd.time: 8.211333

    """

    func testParsersReadCapturedFFmpegLines() {
        XCTAssertEqual(VideoEventLogParser.blackEvent(
            "[Parsed_blackdetect_1 @ 0x749302c6c0] black_start:1234.600033 black_end:1235.300733 black_duration:0.7007"),
                       .init(start: 1234.600033, end: 1235.300733, duration: 0.7007))
        XCTAssertEqual(VideoEventLogParser.sceneScore(
            "[Parsed_scdet_1 @ 0x766d0306c0] lavfi.scd.score: 41.847, lavfi.scd.time: 1234.600033"),
                       .init(score: 41.847, time: 1234.600033))
        XCTAssertEqual(VideoEventLogParser.sceneScore(
            "[Parsed_scdet_1 @ 0x76330561c0] lavfi.scd.score: 10.352, lavfi.scd.time: 45.79575"),
                       .init(score: 10.352, time: 45.79575))
        XCTAssertEqual(VideoEventLogParser.progressSeconds("out_time_us=27760000"), 27.76)
        XCTAssertNil(VideoEventLogParser.progressSeconds("out_time_us=N/A"))
        XCTAssertNil(VideoEventLogParser.progressSeconds("out_time_ms=27760000"))
        // Other filters and the input banner (which can echo file names) are ignored.
        XCTAssertNil(VideoEventLogParser.blackEvent("Input #0, mov, from 'black_start:1 black_end:2 black_duration:1.mov':"))
        XCTAssertNil(VideoEventLogParser.sceneScore("[Parsed_metadata_2 @ 0x7b7cc0a400] lavfi.scd.time=4.451333"))
        XCTAssertFalse(VideoEventLogParser.isFilterLine("[Parsed_metadata_2 @ 0x1] lavfi.black_start=5", filter: "blackdetect"))
        XCTAssertTrue(VideoEventLogParser.isFilterLine("[Parsed_blackdetect_12 @ 0x1] unexpected", filter: "blackdetect"))
    }

    func testBlackCollectorHandlesChunkBoundariesAndEOFInterval() throws {
        let collector = VideoEventLogCollector(kind: .black)
        for byte in blackLog.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        complete(collector)
        XCTAssertEqual(try collector.finishBlack(),
                       [.init(start: 0, end: 2), .init(start: 5, end: 6), .init(start: 9, end: 10.16)])
    }

    func testSceneCollectorKeepsEveryCutInOrderWithScores() throws {
        let collector = VideoEventLogCollector(kind: .sceneCuts)
        collector.consume(.init(stream: .standardError, data: Data(sceneLog.utf8)))
        complete(collector)
        XCTAssertEqual(try collector.finishSceneCuts(), [.init(time: 4.451333, score: 30.359),
                                                         .init(time: 4.491333, score: 13.68),
                                                         .init(time: 8.211333, score: 14.58)])
    }

    func testCollectorReportsProgressFromCapturedProgressBlock() {
        let collector = VideoEventLogCollector(kind: .sceneCuts)
        XCTAssertNil(collector.consume(.init(stream: .standardOutput, data: Data("frame=0\nout_time_us=N/A\nprogress=continue\n".utf8))))
        XCTAssertEqual(collector.consume(.init(stream: .standardOutput, data: Data("frame=199\nout_time_us=7966292\nout_time_ms=7966292\n".utf8))),
                       7.966292)
        XCTAssertEqual(VideoEventAnalysisService.fraction(7.5, of: 30), 0.25)
        XCTAssertEqual(VideoEventAnalysisService.fraction(40, of: 30), 1)
        XCTAssertEqual(VideoEventAnalysisService.fraction(5, of: nil), 0)
        XCTAssertEqual(VideoEventAnalysisService.fraction(5, of: 0), 0)
    }

    func testNoEventsRequiresCompleteDecodedVideo() throws {
        let collector = VideoEventLogCollector(kind: .black)
        complete(collector)
        XCTAssertEqual(try collector.finishBlack(), [])
        XCTAssertThrowsError(try VideoEventLogCollector(kind: .black).finishBlack())
        let empty = VideoEventLogCollector(kind: .sceneCuts)
        empty.consume(.init(stream: .standardOutput, data: Data("out_time_us=0\nprogress=end\n".utf8)))
        XCTAssertThrowsError(try empty.finishSceneCuts())
    }

    func testCollectorsRejectTruncatedOrMalformedEvents() {
        let black = [
            "[Parsed_blackdetect_0 @ 0x1] black_start:1 black_end:2 black_duration:1", // Partial final line.
            "[Parsed_blackdetect_0 @ 0x1] black_start:1 black_end:nan black_duration:1\n",
            "[Parsed_blackdetect_0 @ 0x1] black_start:-1 black_end:2 black_duration:3\n",
            "[Parsed_blackdetect_0 @ 0x1] black_start:2 black_end:1 black_duration:1\n",
            "[Parsed_blackdetect_0 @ 0x1] black_start:1 black_end:2 black_duration:3\n",
            "[Parsed_blackdetect_0 @ 0x1] black_start:1 black_end:3 black_duration:2\n"
                + "[Parsed_blackdetect_0 @ 0x1] black_start:2.5 black_end:4 black_duration:1.5\n",
            "[Parsed_blackdetect_0 @ 0x1] something unexpected\n"
        ]
        for log in black {
            let collector = VideoEventLogCollector(kind: .black)
            collector.consume(.init(stream: .standardError, data: Data(log.utf8)))
            complete(collector)
            XCTAssertThrowsError(try collector.finishBlack(), log)
        }
        let scene = [
            "[Parsed_scdet_0 @ 0x1] lavfi.scd.score: 30.359, lavfi.scd.time: 4.45", // Partial final line.
            "[Parsed_scdet_0 @ 0x1] lavfi.scd.score: inf, lavfi.scd.time: 4.45\n",
            "[Parsed_scdet_0 @ 0x1] lavfi.scd.score: 30, lavfi.scd.time: -1\n",
            "[Parsed_scdet_0 @ 0x1] lavfi.scd.score: 30, lavfi.scd.time: 5\n[Parsed_scdet_0 @ 0x1] lavfi.scd.score: 30, lavfi.scd.time: 5\n",
            "[Parsed_scdet_0 @ 0x1] lavfi.scd.score: 30\n"
        ]
        for log in scene {
            let collector = VideoEventLogCollector(kind: .sceneCuts)
            collector.consume(.init(stream: .standardError, data: Data(log.utf8)))
            complete(collector)
            XCTAssertThrowsError(try collector.finishSceneCuts(), log)
        }
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() throws {
        try BlackDetectionSettings().validate()
        try SceneCutSettings().validate()
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 86_401] {
            XCTAssertThrowsError(try BlackDetectionSettings(minimumDuration: value).validate())
        }
        for value in [Double.nan, .infinity, -1, 0, 1.01] {
            XCTAssertThrowsError(try BlackDetectionSettings(pictureBlackRatio: value).validate())
        }
        for value in [Double.nan, .infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try BlackDetectionSettings(pixelThreshold: value).validate())
        }
        for value in [Double.nan, .infinity, -1, 0, 100.5] {
            XCTAssertThrowsError(try SceneCutSettings(threshold: value).validate())
        }
    }

    func testFilterGraphsUseDocumentedDefaults() {
        XCTAssertEqual(VideoEventAnalysisService.blackFilterGraph(settings: .init()),
                       "[0:V:0]blackdetect=d=0.5:pic_th=0.98:pix_th=0.1[black]")
        XCTAssertEqual(VideoEventAnalysisService.sceneCutFilterGraph(settings: .init(), thumbnails: false),
                       "[0:V:0]scdet=threshold=10.0[cuts]")
        let thumbnails = VideoEventAnalysisService.sceneCutFilterGraph(settings: .init(threshold: 8), thumbnails: true)
        XCTAssertTrue(thumbnails.hasPrefix("[0:V:0]scdet=threshold=8.0,split=3[cuts][first][marked];"))
        XCTAssertTrue(thumbnails.contains("metadata=mode=select:key=lavfi.scd.time"))
    }

    func testServiceRejectsFailedProcessEvenWithCompleteReport() async throws {
        let service = VideoEventAnalysisService(runner: VideoEventFailureRunner(), ffmpegPathProvider: { "/tmp/ffmpeg" })
        do {
            _ = try await service.detectBlack(file: URL(fileURLWithPath: "/tmp/video.mov"))
            XCTFail("A failed decoder must not return a partial report")
        } catch is CancellationError { XCTFail("Failure was incorrectly reported as cancellation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("decoder failure")) }
    }

    func testCancellationPropagatesAndDrainsRunner() async throws {
        let started = expectation(description: "Scene cut decoder started")
        let runner = VideoEventCancellationRunner(started: started)
        let service = VideoEventAnalysisService(runner: runner, ffmpegPathProvider: { "/tmp/ffmpeg" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await service.detectSceneCuts(file: URL(fileURLWithPath: "/tmp/video.mov"),
                                                            thumbnailDirectory: directory) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis returned success") }
        catch is CancellationError { }
        let active = await runner.active
        XCTAssertFalse(active)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "Cancelled scans remove partial thumbnails")
    }

    func testJSONReportsPreserveEveryEventAndContext() throws {
        let black = BlackDetectionResult(settings: .init(minimumDuration: 0.25),
                                         intervals: (0..<1_005).map { .init(start: Double($0) * 2, end: Double($0) * 2 + 0.5) })
        let source = URL(fileURLWithPath: "/private/source folder/clip.mov")
        let timestamp = Date(timeIntervalSince1970: 1_792_152_000)
        let blackData = try AnalyticsExporter.blackJSON(result: black, sourceFile: source, timestamp: timestamp)
        XCTAssertFalse(String(decoding: blackData, as: UTF8.self).contains("source folder"))
        let blackReport = try XCTUnwrap(JSONSerialization.jsonObject(with: blackData) as? [String: Any])
        XCTAssertEqual(blackReport["schemaVersion"] as? Int, 1)
        XCTAssertEqual(blackReport["analysis"] as? String, "source_video_black")
        XCTAssertEqual(blackReport["sourceFileName"] as? String, "clip.mov")
        XCTAssertEqual(blackReport["timestamp"] as? String, ISO8601DateFormatter().string(from: timestamp))
        let blackPayload = try XCTUnwrap(blackReport["result"] as? [String: Any])
        XCTAssertEqual((blackPayload["intervals"] as? [Any])?.count, 1_005)
        XCTAssertEqual(try JSONDecoder().decode(BlackDetectionResult.self,
                                               from: JSONSerialization.data(withJSONObject: blackPayload)), black)

        let cuts = SceneCutResult(settings: .init(threshold: 8), cuts: [.init(time: 4.451333, score: 30.359)])
        let cutData = try AnalyticsExporter.sceneCutJSON(result: cuts, sourceFile: source, timestamp: timestamp)
        let cutReport = try XCTUnwrap(JSONSerialization.jsonObject(with: cutData) as? [String: Any])
        XCTAssertEqual(cutReport["analysis"] as? String, "source_video_scene_cuts")
        let semantics = try XCTUnwrap(cutReport["semantics"] as? [String: Any])
        XCTAssertEqual(semantics["detector"] as? String, "ffmpeg_scdet")
        let cutPayload = try XCTUnwrap(cutReport["result"] as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(SceneCutResult.self,
                                               from: JSONSerialization.data(withJSONObject: cutPayload)), cuts)
    }

    func testJSONReportsRejectInvalidEvents() {
        let file = URL(fileURLWithPath: "/tmp/video.mov")
        let date = Date(timeIntervalSince1970: 0)
        for intervals in [[BlackInterval(start: .nan, end: 1)], [.init(start: 2, end: 1)],
                          [.init(start: 0, end: 2), .init(start: 1, end: 3)]] {
            XCTAssertThrowsError(try AnalyticsExporter.blackJSON(result: .init(settings: .init(), intervals: intervals),
                                                                 sourceFile: file, timestamp: date))
        }
        for cuts in [[SceneCut(time: .infinity, score: 1)], [.init(time: 1, score: -1)], [.init(time: 1, score: 101)],
                     [.init(time: 2, score: 20), .init(time: 1, score: 20)]] {
            XCTAssertThrowsError(try AnalyticsExporter.sceneCutJSON(result: .init(settings: .init(), cuts: cuts),
                                                                    sourceFile: file, timestamp: date))
        }
        XCTAssertThrowsError(try AnalyticsExporter.sceneCutJSON(result: .init(settings: .init(threshold: 0), cuts: []),
                                                                sourceFile: file, timestamp: date))
    }

    func testEDLMarkersUseSourceTimecodeAndFrameRate() throws {
        let cuts = SceneCutResult(settings: .init(), cuts: [.init(time: 1, score: 30.359), .init(time: 2.48, score: 12)])
        let text = try AnalyticsExporter.videoEventEDL(title: "clip.mov Scene Cuts",
                                                       markers: AnalyticsExporter.sceneCutMarkers(cuts),
                                                       frameRate: 25, startTimecode: "01:00:00:00", ranges: false)
        XCTAssertEqual(text, [
            "TITLE: clip.mov Scene Cuts", "FCM: NON-DROP FRAME", "",
            "001  001      V     C        01:00:01:00 01:00:01:01 01:00:01:00 01:00:01:01",
            " |C:ResolveColorBlue |M:Cut 1 • score 30.4 |D:1", "",
            "002  001      V     C        01:00:02:12 01:00:02:13 01:00:02:12 01:00:02:13",
            " |C:ResolveColorBlue |M:Cut 2 • score 12.0 |D:1", ""
        ].joined(separator: "\r\n"))

        let black = BlackDetectionResult(settings: .init(), intervals: [.init(start: 0, end: 2), .init(start: 9, end: 10.16)])
        let blackText = try AnalyticsExporter.videoEventEDL(title: "clip.mov Black Frames",
                                                            markers: AnalyticsExporter.blackMarkers(black),
                                                            frameRate: 25, startTimecode: nil, ranges: true)
        XCTAssertTrue(blackText.contains("001  001      V     C        00:00:00:00 00:00:02:00 00:00:00:00 00:00:02:00\r\n |C:ResolveColorBlue |M:Black 1 • 2.00 s |D:50"))
        XCTAssertTrue(blackText.contains("002  001      V     C        00:00:09:00 00:00:10:04 00:00:09:00 00:00:10:04\r\n |C:ResolveColorBlue |M:Black 2 • 1.16 s |D:29"))
        // Cuts on the same output frame share one Resolve marker.
        let close = SceneCutResult(settings: .init(), cuts: [.init(time: 1, score: 30), .init(time: 1.01, score: 20)])
        let merged = try AnalyticsExporter.videoEventEDL(title: "t", markers: AnalyticsExporter.sceneCutMarkers(close),
                                                         frameRate: 25, startTimecode: nil, ranges: false)
        XCTAssertTrue(merged.contains("|M:Cut 1 • score 30.0 • Cut 2 • score 20.0 |D:1"))
        XCTAssertThrowsError(try AnalyticsExporter.videoEventEDL(title: "t", markers: [], frameRate: 120,
                                                                 startTimecode: nil, ranges: false))
    }

    func testBundledFFmpegFindsBlackIntervalsIncludingEOF() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("black-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        // Black 0–2 s, a 0.2 s black flash at 3 s (below the minimum), black 5–6 s and at the end.
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i",
            "color=black:s=160x120:r=25:d=2[a];testsrc=s=160x120:r=25:d=1[b];color=black:s=160x120:r=25:d=0.2[c];"
                + "testsrc=s=160x120:r=25:d=1.8[d];color=black:s=160x120:r=25:d=1[e];smptebars=s=160x120:r=25:d=3[f];"
                + "color=black:s=160x120:r=25:d=1.2[g];[a][b][c][d][e][f][g]concat=n=7:v=1:a=0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", file.path
        ])
        let service = VideoEventAnalysisService(ffmpegPathProvider: { ffmpeg })
        let progress = ProgressRecorder()
        let result = try await service.detectBlack(file: file, durationSeconds: 10.2) { progress.record($0) }
        XCTAssertEqual(result.intervals.count, 3, "\(result.intervals)")
        XCTAssertEqual(result.intervals[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(result.intervals[0].end, 2, accuracy: 0.001)
        XCTAssertEqual(result.intervals[1].start, 5, accuracy: 0.001)
        XCTAssertEqual(result.intervals[1].end, 6, accuracy: 0.001)
        XCTAssertEqual(result.intervals[2].start, 9, accuracy: 0.001)
        XCTAssertEqual(result.intervals[2].end, 10.16, accuracy: 0.001, "EOF black ends at the last frame")
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 0.05)
        let stricter = try await service.detectBlack(file: file, settings: .init(minimumDuration: 1.1))
        XCTAssertEqual(stricter.intervals.map(\.start), [0, 9])
        let withFlash = try await service.detectBlack(file: file, settings: .init(minimumDuration: 0.1))
        XCTAssertEqual(withFlash.intervals.count, 4)
    }

    func testBundledFFmpegFindsSceneCutsWithThumbnails() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cuts-\(UUID().uuidString).mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cut-thumbs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: directory)
        }
        // Anamorphic 4:3 storage with 2:1 pixels; thumbnails must use display aspect.
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i",
            "testsrc=s=320x240:r=25:d=2[a];smptebars=s=320x240:r=25:d=2[b];rgbtestsrc=s=320x240:r=25:d=2[c];"
                + "[a][b][c]concat=n=3:v=1:a=0,setsar=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", file.path
        ])
        let service = VideoEventAnalysisService(ffmpegPathProvider: { ffmpeg })
        let output = try await service.detectSceneCuts(file: file, thumbnailDirectory: directory)
        XCTAssertEqual(output.result.cuts.map(\.time), [2, 4])
        XCTAssertTrue(output.result.cuts.allSatisfy { $0.score >= 10 && $0.score <= 100 })
        XCTAssertEqual(output.thumbnails.count, 2)
        let image = try XCTUnwrap(NSImage(contentsOf: output.thumbnails[0]))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide, 320)
        XCTAssertEqual(rep.pixelsHigh, 120)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["cut_00002.jpg", "cut_00003.jpg"], "The opening frame is not kept")

        let none = try await service.detectSceneCuts(file: file, settings: .init(threshold: 100),
                                                     thumbnailDirectory: directory)
        XCTAssertEqual(none.result.cuts, [])
        XCTAssertEqual(none.thumbnails, [])
    }

    private func complete(_ collector: VideoEventLogCollector) {
        collector.consume(.init(stream: .standardOutput, data: Data("out_time_us=10160000\nprogress=end\n".utf8)))
    }

    private func generate(_ ffmpeg: String, arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                                                          arguments: ["-hide_banner", "-nostdin", "-y"] + arguments,
                                                          timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var last: Double? { lock.withLock { values.last } }
    func record(_ value: Double) { lock.withLock { values.append(value) } }
}

private struct VideoEventFailureRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        outputHandler?(.init(stream: .standardOutput, data: Data("out_time_us=1000000\nprogress=end\n".utf8)))
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("decoder failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor VideoEventCancellationRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var active = false

    init(started: XCTestExpectation) { self.started = started }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active = true
        defer { active = false }
        if let pattern = request.arguments.last, pattern.hasSuffix("cut_%05d.jpg") {
            let partial = URL(fileURLWithPath: pattern).deletingLastPathComponent().appendingPathComponent("cut_00001.jpg")
            FileManager.default.createFile(atPath: partial.path, contents: Data([0xFF]))
        }
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
