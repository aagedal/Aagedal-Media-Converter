import PDFKit
import XCTest
@testable import Aagedal_Media_Converter

final class BitrateAnalysisTests: XCTestCase {
    private func collect(_ text: String, chunkSize: Int = 7) -> BitratePacketCollector {
        let collector = BitratePacketCollector()
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let data = Data(bytes[start..<min(start + chunkSize, bytes.count)])
            collector.consume(SubprocessOutputChunk(stream: .standardOutput, data: data))
        }
        return collector
    }

    func testFramecrcPacketsAreOrderedByPresentationAndRelativeToFirstFrame() throws {
        // B-frame reordering: decode order differs from presentation order, and the
        // first packet's dts is negative. Packets split across chunk boundaries.
        let output = """
        #extradata 0:       46, 0x34b10f92
        #tb 0: 1/1000
        #media_type 0: video
        #codec_id 0: h264
        0,       -500,       1000,      500,     4000, 0xfc2c7c39
        0,          0,       2000,      500,     1000, 0xcdf49b0e, F=0x0
        0,        500,       1500,      500,     2000, 0xe177b042, F=0x0
        0,       1000,       2500,      500,     3000, 0x88cb168c, F=0x1
        0,       1500,        100,      500,     9999, 0x88cb168c, F=0x5

        """
        let timeline = try collect(output).finish(stream: .video)
        XCTAssertEqual(timeline.codec, "h264")
        XCTAssertEqual(timeline.packets.map(\.seconds), [0, 0.5, 1, 1.5], "Discarded packets are not presented")
        XCTAssertEqual(timeline.packets.map(\.bytes), [4000, 2000, 1000, 3000])
        XCTAssertEqual(timeline.keyframeTimes, [0, 1.5])
        XCTAssertEqual(timeline.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(timeline.totalBytes, 10_000)
        XCTAssertEqual(timeline.averageBitsPerSecond, 40_000, accuracy: 1e-9)
    }

    func testMissingPacketsOrMalformedOutputFails() {
        XCTAssertThrowsError(try collect("#tb 0: 1/25\n").finish(stream: .video))
        XCTAssertThrowsError(try collect("#tb 0: 1/25\n0, x, 0, 1, 10, 0x0\n").finish(stream: .video))
        XCTAssertThrowsError(try collect("0, 0, 0, 1, 10, 0x0\n").finish(stream: .video), "A time base is required")
    }

    func testWindowsAverageEachIntervalAndUseTheActualTailLength() {
        let packets = (0..<25).map { BitratePacket(seconds: Double($0) * 0.1, bytes: 1000, isKeyframe: $0 == 0) }
        let timeline = BitrateTimeline(stream: .video, codec: nil, packets: packets, duration: 2.5)
        let windows = timeline.windows(size: 1)
        XCTAssertEqual(windows.map(\.start), [0, 1, 2])
        XCTAssertEqual(windows[0].bitsPerSecond, 80_000, accuracy: 1e-6)
        XCTAssertEqual(windows[1].bitsPerSecond, 80_000, accuracy: 1e-6)
        XCTAssertEqual(windows[2].bitsPerSecond, 80_000, accuracy: 1e-6, "Five packets over the final half second")
        XCTAssertEqual(timeline.bitsPerSecond(around: 1.25, span: 1)!, 80_000, accuracy: 1e-6)
        XCTAssertEqual(timeline.bitsPerSecond(around: 0, span: 1)!, 80_000, accuracy: 1e-6, "Clamped to the stream start")
        XCTAssertTrue(timeline.windows(size: 0).isEmpty)
    }

    func testAutomaticWindowKeepsChartsBounded() {
        XCTAssertEqual(BitrateTimeline.automaticWindow(duration: 60), 0.5)
        XCTAssertEqual(BitrateTimeline.automaticWindow(duration: 7200), 10)
        XCTAssertEqual(BitrateTimeline.automaticWindow(duration: 7200, maxWindows: 500), 30)
        XCTAssertEqual(BitrateTimeline.automaticWindow(duration: 200_000), 200)
        XCTAssertEqual(BitrateTimeline.automaticWindow(duration: .nan), 1)
    }

    func testFormattingSwitchesUnitsAtOneMegabit() {
        XCTAssertEqual(BitrateFormatting.string(nil), "—")
        XCTAssertTrue(BitrateFormatting.string(128_000).hasSuffix("kbit/s"))
        XCTAssertTrue(BitrateFormatting.string(4_200_000).hasSuffix("Mbit/s"))
    }

    func testBundledFFmpegReportsPacketsForVideoAndAudio() async throws {
        guard let executable = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) else {
            throw XCTSkip("Bundled ffmpeg unavailable in this test host")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitrate-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SubprocessRequest(executableURL: executable, arguments: [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=160x120:r=25:d=4",
            "-f", "lavfi", "-i", "sine=d=4", "-c:v", "libx264", "-g", "25", "-sc_threshold", "0", "-c:a", "aac", "-y", url.path
        ], timeout: .seconds(30))
        let generated = try await SubprocessRunner().run(request)
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        guard generated.succeeded else { return }

        let service = BitrateAnalysisService()
        let video = try await service.analyze(file: url, stream: .video)
        XCTAssertEqual(video.packets.count, 100)
        XCTAssertEqual(video.duration, 4, accuracy: 0.05)
        XCTAssertEqual(video.keyframeTimes.count, 4)
        XCTAssertEqual(video.keyframeTimes.first, 0)
        XCTAssertGreaterThan(video.averageBitsPerSecond, 0)
        let audio = try await service.analyze(file: url, stream: .audio)
        XCTAssertEqual(audio.duration, 4, accuracy: 0.1)
        XCTAssertTrue(audio.keyframeTimes.isEmpty)

        let audioOnly = FileManager.default.temporaryDirectory.appendingPathComponent("bitrate-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: audioOnly) }
        let audioRequest = SubprocessRequest(executableURL: executable, arguments: [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac", "-y", audioOnly.path
        ], timeout: .seconds(30))
        let audioGenerated = try await SubprocessRunner().run(audioRequest)
        XCTAssertTrue(audioGenerated.succeeded, audioGenerated.standardErrorText)
        do {
            _ = try await service.analyze(file: audioOnly, stream: .video)
            XCTFail("Expected a missing video stream error")
        } catch {
            XCTAssertEqual(error as? BitrateAnalysisError, .noStream(.video))
        }
    }

    private func timeline(seconds: Int, bytesPerFrame: (Int) -> Int) -> BitrateTimeline {
        let packets = (0..<(seconds * 25)).map {
            BitratePacket(seconds: Double($0) / 25, bytes: bytesPerFrame($0), isKeyframe: $0 % 50 == 0)
        }
        return BitrateTimeline(stream: .video, codec: "h264", packets: packets, duration: Double(seconds))
    }

    func testKeyframeIntervalDescription() {
        XCTAssertEqual(timeline(seconds: 10, bytesPerFrame: { _ in 100 }).keyframeIntervalDescription,
                       2.0.formatted(.number.precision(.fractionLength(2))) + " s")
        let intra = BitrateTimeline(stream: .video, codec: "prores",
                                    packets: (0..<5).map { BitratePacket(seconds: Double($0), bytes: 1, isKeyframe: true) }, duration: 5)
        XCTAssertEqual(intra.keyframeIntervalDescription, String(localized: "Every frame"))
    }

    @MainActor
    func testCombinedReportHoldsQualityBitrateAndLoudnessSections() throws {
        let samples = (0..<240).map { QualitySample(frame: $0, seconds: Double($0) / 24, score: $0 == 120 ? 40 : 92) }
        let quality = AnalyticsResults(
            sourceFileName: "Source.mov", encodedFileName: "Delivery.mp4",
            metrics: [.init(metric: .vmaf, overallScore: 91, min: 40, max: 95, unit: "score", channelScores: nil, samples: samples)],
            timestamp: Date(timeIntervalSince1970: 0), durationSeconds: 10)
        let encoded = timeline(seconds: 10, bytesPerFrame: { $0 % 50 == 0 ? 60_000 : 20_000 })
        let source = timeline(seconds: 12, bytesPerFrame: { _ in 90_000 })
        let loudness = LoudnessResults(presentation: .track(0), integratedLUFS: -23, loudnessRangeLU: 5, maximumTruePeakDBTP: -1.5,
                                       samples: (0..<100).map {
                                           LoudnessSample(seconds: Double($0) / 10, momentaryLUFS: -23, shortTermLUFS: -23,
                                                          peakDBFS: -6, rmsDBFS: -20)
                                       })
        let content = AnalysisReportContent(
            quality: quality, qualityBitrate: encoded,
            bitrateFiles: [.init(label: "Source", fileName: "Source.mov", timeline: source, isEncoded: false),
                           .init(label: "Encoded", fileName: "Delivery.mp4", timeline: encoded, isEncoded: true)],
            loudness: [loudness], loudnessFileName: "Source.mov", loudnessTimestamp: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnalyticsExporter.exportReport(content, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 3)
        for index in 0..<document.pageCount {
            XCTAssertEqual(document.page(at: index)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        }
        let text = try XCTUnwrap(document.string)
        for expected in ["Quality Analytics Report", "Quality timeline", "Encoded bitrate", "Mbit/s",
                         "Bitrate over time", "Delivery.mp4", "Keyframe interval", "Audio Loudness Analysis", "-23.0 LUFS"] {
            XCTAssertTrue(text.contains(expected), "Report missing \(expected)")
        }
        // Sections keep their order: quality, then bitrate, then loudness on the final page.
        XCTAssertTrue(try XCTUnwrap(document.page(at: 0)?.string).contains("VMAF"))
        XCTAssertTrue(try XCTUnwrap(document.page(at: document.pageCount - 1)?.string).contains("Audio Loudness Analysis"))
    }

    @MainActor
    func testReportWithNothingSelectedIsRejected() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID()).pdf")
        XCTAssertThrowsError(try AnalyticsExporter.exportReport(AnalysisReportContent(), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEncodedBitrateIsSkippedWhenTheOutputNoLongerMatchesTheReport() async {
        let results = AnalyticsResults(sourceFileName: "a.mov", encodedFileName: "a_encoded.mp4", metrics: [],
                                       timestamp: Date(), durationSeconds: 1)
        let renamed = await AnalyticsExporter.encodedBitrate(for: URL(fileURLWithPath: "/tmp/other.mp4"), results: results)
        XCTAssertNil(renamed)
        let missing = await AnalyticsExporter.encodedBitrate(for: nil, results: results)
        XCTAssertNil(missing)
    }
}
