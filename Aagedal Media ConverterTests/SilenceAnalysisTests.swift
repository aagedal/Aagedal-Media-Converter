import XCTest
@testable import Aagedal_Media_Converter

final class SilenceAnalysisTests: XCTestCase {
    func testParserHandlesChunkBoundariesAndExactEOFSilenceEnd() throws {
        let log = """
        [silencedetect @ 0x1] silence_start: 0
        [silencedetect @ 0x1] silence_end: 1.25 | silence_duration: 1.25
        [silencedetect @ 0x1] silence_start: 3e0
        [silencedetect @ 0x1] silence_end: 4.000021 | silence_duration: 1.000021

        """
        let collector = SilenceLogCollector()
        for byte in log.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        complete(collector)
        XCTAssertEqual(try collector.finish(), [.init(start: 0, end: 1.25), .init(start: 3, end: 4.000021)])
    }

    func testNoSilenceRequiresCompleteDecodedAudio() throws {
        let collector = SilenceLogCollector()
        complete(collector)
        XCTAssertEqual(try collector.finish(), [])
        XCTAssertThrowsError(try SilenceLogCollector().finish())
        let empty = SilenceLogCollector()
        empty.consume(.init(stream: .standardOutput, data: Data("out_time_us=0\nprogress=end\n".utf8)))
        XCTAssertThrowsError(try empty.finish())
    }

    func testParserRejectsTruncatedOrMalformedEvents() {
        let logs = [
            "silence_start: 1\n", // A start at EOF must be closed by the filter.
            "silence_start: 1\nsilence_end: 2 | silence_duration: 1", // Partial final line.
            "silence_end: 2 | silence_duration: 1\n",
            "silence_start: nan\n",
            "silence_start: -1\n",
            "silence_start: 1\nsilence_start: 2\n",
            "silence_start: 2\nsilence_end: 1 | silence_duration: 1\n",
            "silence_start: 1\nsilence_end: inf | silence_duration: 1\n",
            "silence_start: 1\nsilence_end: 2 | silence_duration: 3\n",
            "silence_start: 1\nsilence_end: 2 | silence_duration: 1\nsilence_start: 1.5\n"
        ]
        for log in logs {
            let collector = SilenceLogCollector()
            let prefixed = log.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "[silencedetect @ 0x1] " + $0 }.joined(separator: "\n")
            collector.consume(.init(stream: .standardError, data: Data(prefixed.utf8)))
            complete(collector)
            XCTAssertThrowsError(try collector.finish(), log)
        }
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() throws {
        try SilenceDetectionSettings().validate()
        for threshold in [Double.nan, .infinity, -.infinity, -121, 1] {
            XCTAssertThrowsError(try SilenceDetectionSettings(thresholdDBFS: threshold).validate())
        }
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, 86_401] {
            XCTAssertThrowsError(try SilenceDetectionSettings(minimumDuration: duration).validate())
        }
    }

    func testGraphRetainsFileTimelineAndCombinedChannelSemantics() {
        let graph = SilenceAnalysisService.filterGraph(for: .stereo(left: 3, right: 1), settings: .init())
        XCTAssertEqual(graph, "[0:a:3][0:a:1]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR,"
                       + "asetpts=PTS,silencedetect=noise=-50.0dB:duration=1.0:mono=0[silence]")
        XCTAssertTrue(SilenceAnalysisService.filterGraph(for: .surround51([0, 1, 2, 5, 3, 4]), settings: .init())
            .contains("map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR"))
    }

    func testServiceRejectsFailedProcessEvenWithCompleteReport() async throws {
        let service = SilenceAnalysisService(runner: SilenceFailureRunner(), ffmpegPathProvider: { "/tmp/ffmpeg" })
        do {
            _ = try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.mov"), presentation: .track(0))
            XCTFail("A failed decoder must not return a partial report")
        } catch is CancellationError { XCTFail("Failure was incorrectly reported as cancellation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("decoder failure")) }
    }

    func testCancellationPropagatesAndDrainsRunner() async throws {
        let started = expectation(description: "Silence decoder started")
        let runner = SilenceCancellationRunner(started: started)
        let service = SilenceAnalysisService(runner: runner, ffmpegPathProvider: { "/tmp/ffmpeg" })
        let task = Task { try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.mov"), presentation: .track(0)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis returned success") }
        catch is CancellationError { }
        let active = await runner.active
        XCTAssertFalse(active)
    }

    func testBundledFFmpegRequiresAllSelectedChannelsQuietAndClosesEOF() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "aevalsrc=if(between(t\\,1\\,2)\\,0.5\\,0):s=48000:d=4",
            "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,1)\\,0.5\\,0):s=48000:d=4",
            "-map", "0:a", "-map", "1:a", "-c:a", "flac", file.path
        ])
        let service = SilenceAnalysisService(ffmpegPathProvider: { ffmpeg })
        let settings = SilenceDetectionSettings(thresholdDBFS: -50, minimumDuration: 0.5)
        let left = try await service.analyze(file: file, presentation: .track(0), settings: settings)
        XCTAssertEqual(left.intervals.count, 2)
        XCTAssertEqual(try XCTUnwrap(left.intervals.first).start, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(left.intervals.first).end, 1, accuracy: 0.001)
        let combined = try await service.analyze(file: file, presentation: .stereo(left: 0, right: 1), settings: settings)
        XCTAssertEqual(combined.intervals.count, 1)
        let interval = try XCTUnwrap(combined.intervals.first)
        XCTAssertEqual(interval.start, 2, accuracy: 0.001)
        XCTAssertEqual(interval.end, 4, accuracy: 0.001)
        XCTAssertEqual(interval.duration, 2, accuracy: 0.001)
        let longer = try await service.analyze(file: file, presentation: .stereo(left: 0, right: 1),
                                               settings: .init(minimumDuration: 2.5))
        XCTAssertTrue(longer.intervals.isEmpty)
    }

    func testBundledFFmpegThresholdChangesDetectionAndRetainsExactWholeFileEOF() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        // Constant amplitude 0.01 is −40 dBFS. Use an exact sample count whose
        // duration does not end on a millisecond to catch rounded EOF estimates.
        let sampleCount = 114_001
        let expectedDuration = Double(sampleCount) / 48_000
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "aevalsrc=0.01:s=48000:d=3",
            "-af", "atrim=end_sample=\(sampleCount)", "-c:a", "pcm_f32le", file.path
        ])
        let service = SilenceAnalysisService(ffmpegPathProvider: { ffmpeg })
        let permissive = try await service.analyze(file: file, presentation: .track(0),
                                                  settings: .init(thresholdDBFS: -30, minimumDuration: 0.5))
        XCTAssertEqual(permissive.intervals.count, 1)
        let interval = try XCTUnwrap(permissive.intervals.first)
        XCTAssertEqual(interval.start, 0, accuracy: 0.000001)
        XCTAssertEqual(interval.end, expectedDuration, accuracy: 0.000001)
        XCTAssertEqual(interval.duration, expectedDuration, accuracy: 0.000001)
        let strict = try await service.analyze(file: file, presentation: .track(0),
                                              settings: .init(thresholdDBFS: -50, minimumDuration: 0.5))
        XCTAssertTrue(strict.intervals.isEmpty, "The same −40 dBFS samples exceed a −50 dBFS silence threshold")
    }

    func testBundledFFmpegPreservesDelayedAudioOffsetInFileTimeline() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-silence-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=5",
            "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,1)\\,0\\,0.5):s=48000:d=3",
            "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_s16le", file.path
        ])
        let service = SilenceAnalysisService(ffmpegPathProvider: { ffmpeg })
        let result = try await service.analyze(file: file, presentation: .track(0), settings: .init(minimumDuration: 0.5))
        XCTAssertEqual(result.intervals.count, 1)
        let interval = try XCTUnwrap(result.intervals.first)
        XCTAssertEqual(interval.start, 2, accuracy: 0.002)
        XCTAssertEqual(interval.end, 3, accuracy: 0.002)
    }

    private func complete(_ collector: SilenceLogCollector) {
        collector.consume(.init(stream: .standardOutput, data: Data("out_time_us=4000021\nprogress=end\n".utf8)))
    }

    private func generate(_ ffmpeg: String, arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                                                          arguments: ["-hide_banner", "-nostdin", "-y"] + arguments,
                                                          timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private struct SilenceFailureRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        outputHandler?(.init(stream: .standardOutput, data: Data("out_time_us=1000000\nprogress=end\n".utf8)))
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("decoder failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor SilenceCancellationRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var active = false

    init(started: XCTestExpectation) { self.started = started }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active = true
        defer { active = false }
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
