import XCTest
@testable import Aagedal_Media_Converter

final class AudioPeakAnalysisTests: XCTestCase {
    func testChunkedParserMergesChannelsAndWeightsRMSByActualSamples() throws {
        let collector = AudioPeakLogCollector(settings: .init(thresholdDBFS: -10))
        let log = frame(0, pts: 0, samples: 4800, peaks: [0, -20], rms: [0, -20])
            + frame(1, pts: 4800, samples: 1201, peaks: [-6, -30], rms: [-6, -30])
        for byte in log.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        complete(collector)
        let result = try collector.finish()
        XCTAssertEqual(result.intervals.count, 1)
        let interval = try XCTUnwrap(result.intervals.first)
        XCTAssertEqual(interval.channel, 1)
        XCTAssertEqual(interval.start, 0)
        XCTAssertEqual(interval.end, 6001.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(interval.peakDBFS, 0)
        XCTAssertEqual(result.duration, interval.end)
        let leftRMS = 10 * log10((4800 + 1201 * pow(10, -0.6)) / 6001)
        let rightRMS = 10 * log10((48 + 1.201) / 6001)
        XCTAssertEqual(result.channels[0].rmsDBFS, leftRMS, accuracy: 1e-10)
        XCTAssertEqual(result.channels[1].rmsDBFS, rightRMS, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result.imbalanceDB), leftRMS - rightRMS, accuracy: 1e-10)
    }

    func testThresholdIsInclusiveAndGapsBreakIntervals() throws {
        let collector = AudioPeakLogCollector(settings: .init(thresholdDBFS: -1))
        consume(frame(0, pts: 96000, samples: 4800, peaks: [-1], rms: [-2])
                + frame(1, pts: 105600, samples: 7, peaks: [0], rms: [-2]), collector)
        complete(collector)
        let result = try collector.finish()
        XCTAssertEqual(result.intervals.count, 2)
        XCTAssertEqual(result.intervals[0].start, 2)
        XCTAssertEqual(result.intervals[1].end, 105607.0 / 48000, accuracy: 1e-12)
        XCTAssertNil(result.imbalanceDB)
    }

    func testSilentChannelAndEntirelySilentTopology() throws {
        for levels in [[-Double.infinity, -Double.infinity], [-6, -Double.infinity], [-6]] {
            let collector = AudioPeakLogCollector(settings: .init())
            consume(frame(0, pts: 0, samples: 100, peaks: levels, rms: levels), collector)
            complete(collector)
            let result = try collector.finish()
            XCTAssertTrue(result.intervals.isEmpty)
            if levels.count == 2, levels[0].isFinite { XCTAssertEqual(result.imbalanceDB, .infinity) }
            else { XCTAssertNil(result.imbalanceDB) }
        }
    }

    func testMalformedIncompleteAndChangingTopologyReportsFailClosed() {
        let good = frame(0, pts: 0, samples: 4800, peaks: [-1, -2], rms: [-3, -4])
        let cases = [
            "", String(good.dropLast()),
            good.replacingOccurrences(of: "lavfi.astats.2.RMS_level=-4.0\n", with: ""),
            good.replacingOccurrences(of: "RMS_level=-3.0", with: "RMS_level=nan"),
            good.replacingOccurrences(of: "RMS_level=-3.0", with: "RMS_level=inf"),
            good.replacingOccurrences(of: "Number_of_samples=4800", with: "Number_of_samples=4799"),
            good.replacingOccurrences(of: "frame:0 pts:0", with: "frame:0 pts:1"),
            good + frame(2, pts: 4800, samples: 100, peaks: [-2, -2], rms: [-3, -3]),
            good + frame(1, pts: 4800, samples: 100, peaks: [-2], rms: [-3]),
            good + frame(1, pts: 4700, samples: 100, peaks: [-2, -2], rms: [-3, -3]),
            good + frame(1, pts: 4800, samples: 100, peaks: [-2, -2], rms: [-3, -3], rate: 44100)
        ]
        for log in cases {
            let collector = AudioPeakLogCollector(settings: .init())
            consume(log, collector)
            complete(collector)
            XCTAssertThrowsError(try collector.finish(), log)
        }
        let incomplete = AudioPeakLogCollector(settings: .init())
        consume(good, incomplete)
        XCTAssertThrowsError(try incomplete.finish())
    }

    func testMarkerAndMalformedLineLimitsFailExplicitly() {
        let collector = AudioPeakLogCollector(settings: .init(), markerLimit: 1)
        consume(frame(0, pts: 0, samples: 4800, peaks: [0, 0], rms: [-3, -3]), collector)
        complete(collector)
        XCTAssertThrowsError(try collector.finish())
        let malformed = AudioPeakLogCollector(settings: .init())
        consume(String(repeating: "x", count: 65537), malformed)
        complete(malformed)
        XCTAssertThrowsError(try malformed.finish())
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() throws {
        try AudioPeakSettings().validate()
        for value in [Double.nan, .infinity, -.infinity, -121, 1] {
            XCTAssertThrowsError(try AudioPeakSettings(thresholdDBFS: value).validate())
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 121] {
            XCTAssertThrowsError(try AudioPeakSettings(imbalanceThresholdDB: value).validate())
        }
    }

    func testDecoderFailureDoesNotReturnReport() async {
        let service = AudioPeakAnalysisService(runner: PeakFailureRunner(), ffmpegPathProvider: { "/tmp/ffmpeg" })
        do {
            _ = try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.wav"), trackIndex: 0)
            XCTFail("Failed decoder returned a report")
        } catch { XCTAssertTrue(error.localizedDescription.contains("decoder failure")) }
    }

    func testCancellationPropagatesAndDrainsRunner() async throws {
        let started = expectation(description: "Peak decoder started")
        let runner = PeakCancellationRunner(started: started)
        let service = AudioPeakAnalysisService(runner: runner, ffmpegPathProvider: { "/tmp/ffmpeg" })
        let task = Task { try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.wav"), trackIndex: 0) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis returned success") }
        catch is CancellationError { }
        let active = await runner.active
        XCTAssertFalse(active)
    }

    func testBundledFFmpegReportsSelectedTrackPeaksAndExactEOFAtSourceRates() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for rate in [44100, 48000, 96000] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString).mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            let sampleCount = rate + 137
            try await generate(ffmpeg, arguments: [
                "-f", "lavfi", "-i", "aevalsrc=0:s=\(rate):d=2",
                "-f", "lavfi", "-i", "aevalsrc=0.95|0.095:s=\(rate):d=2",
                "-map", "0:a", "-map", "1:a", "-af", "atrim=end_sample=\(sampleCount)",
                "-c:a", "pcm_f32le", file.path
            ])
            let service = AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            let silent = try await service.analyze(file: file, trackIndex: 0)
            XCTAssertTrue(silent.intervals.isEmpty)
            XCTAssertNil(silent.imbalanceDB)
            let result = try await service.analyze(file: file, trackIndex: 1)
            XCTAssertEqual(result.channels.count, 2)
            XCTAssertEqual(result.intervals.count, 1)
            XCTAssertEqual(result.intervals[0].channel, 1)
            XCTAssertEqual(result.intervals[0].start, 0)
            XCTAssertEqual(result.intervals[0].end, Double(sampleCount) / Double(rate), accuracy: 1e-9)
            XCTAssertEqual(result.duration, Double(sampleCount) / Double(rate), accuracy: 1e-9)
            XCTAssertEqual(result.channels[0].peakDBFS, 20 * log10(0.95), accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(result.imbalanceDB), 20, accuracy: 0.00001)
        }
    }

    func testBundledFFmpegRetainsDelayedTimelineAndUnpaddedPartialWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-peaks-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=4",
            "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.95|0:s=48000:d=0.1000208333333333",
            "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_f32le", file.path
        ])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(file: file, trackIndex: 0)
        XCTAssertEqual(result.intervals.count, 1)
        XCTAssertEqual(result.intervals[0].start, 2, accuracy: 0.001)
        XCTAssertEqual(result.duration, 2 + 4801.0 / 48000, accuracy: 1e-9)
        XCTAssertEqual(result.channels[0].rmsDBFS, 20 * log10(0.95), accuracy: 0.00001)
        XCTAssertEqual(result.channels[1].rmsDBFS, -.infinity)
        XCTAssertEqual(result.imbalanceDB, .infinity)
    }

    private func frame(_ index: Int, pts: Int, samples: Int, peaks: [Double], rms: [Double], rate: Int = 48000) -> String {
        var result = "[Parsed_ashowinfo_2 @ 0x1] n:\(index) pts:\(pts) pts_time:0 fmt:dbl channels:\(peaks.count) chlayout:stereo rate:\(rate) nb_samples:\(samples) checksum:0\n"
        result += "[Parsed_ametadata_4 @ 0x1] frame:\(index) pts:\(pts) pts_time:0\n"
        for channel in peaks.indices {
            result += "[Parsed_ametadata_4 @ 0x1] lavfi.astats.\(channel + 1).Peak_level=\(peaks[channel])\n"
            result += "[Parsed_ametadata_4 @ 0x1] lavfi.astats.\(channel + 1).RMS_level=\(rms[channel])\n"
        }
        return result + "[Parsed_ametadata_4 @ 0x1] lavfi.astats.Overall.Number_of_samples=\(samples)\n"
    }

    private func consume(_ text: String, _ collector: AudioPeakLogCollector) {
        collector.consume(.init(stream: .standardError, data: Data(text.utf8)))
    }

    private func complete(_ collector: AudioPeakLogCollector) {
        collector.consume(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
    }

    private func generate(_ ffmpeg: String, arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                                                          arguments: ["-hide_banner", "-nostdin", "-y"] + arguments,
                                                          timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private struct PeakFailureRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        let report = """
        [Parsed_ashowinfo_2 @ 0x1] n:0 pts:0 channels:1 rate:48000 nb_samples:1
        [Parsed_ametadata_4 @ 0x1] frame:0 pts:0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.1.Peak_level=0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.1.RMS_level=0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.Overall.Number_of_samples=1

        """
        outputHandler?(.init(stream: .standardError, data: Data(report.utf8)))
        outputHandler?(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("decoder failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor PeakCancellationRunner: SubprocessRunning {
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
