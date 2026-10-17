import XCTest
@testable import Aagedal_Media_Converter

final class GroupedAudioPeakAnalysisTests: XCTestCase {
    func testGroupedGraphsKeepExplicitRolesAndUnpaddedSourceSamples() {
        let graph = AudioPeakAnalysisService.filterGraph(for: .surround51([5, 4, 3, 2, 1, 0]))
        XCTAssertTrue(graph.contains("[0:a:5]channelmap=map=0-FC:channel_layout=mono,asetnsamples=n=4800:p=0[group_0]"))
        XCTAssertTrue(graph.contains("map=0-FL|1-FR|2-FC|3-LFE|4-SL|5-SR"))
        XCTAssertFalse(graph.contains("aresample"))
        XCTAssertFalse(graph.contains("amix"))
    }

    func testCompleteTimingRejectsDifferentLengthsRatesStartsAndDiscontinuities() throws {
        let good = timing(0, frame: 0, pts: 0, samples: 1024) + timing(1, frame: 0, pts: 0, samples: 1024)
        for bad in [
            timing(0, frame: 1, pts: 1024, samples: 100) + timing(1, frame: 1, pts: 1024, samples: 99),
            timing(0, frame: 1, pts: 1024, samples: 100, rate: 44100),
            timing(0, frame: 1, pts: 2048, samples: 100) + timing(1, frame: 1, pts: 2048, samples: 100)
        ] {
            let collector = GroupedPeakTimingCollector(trackCount: 2)
            feed(good + bad, collector)
            XCTAssertThrowsError(try collector.finish())
        }
        let offset = GroupedPeakTimingCollector(trackCount: 2)
        feed(timing(0, frame: 0, pts: 0, samples: 100) + timing(1, frame: 0, pts: 1, samples: 100), offset)
        XCTAssertThrowsError(try offset.finish())
        let valid = GroupedPeakTimingCollector(trackCount: 2)
        feed(good + timing(0, frame: 1, pts: 1008, samples: 137) + timing(1, frame: 1, pts: 1008, samples: 137), valid)
        XCTAssertEqual(try valid.finish().samples, 1161, "Millisecond container rounding must not change sample totals")
    }

    func testGroupedStereoKeepsRoleOrderGainsAndExactFinalSamplesAtSourceRates() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for rate in [44100, 48000, 96000] {
            let file = temporaryFile()
            defer { try? FileManager.default.removeItem(at: file) }
            let count = rate + 137
            try await generate(ffmpeg, arguments: inputs([0.095, 0.95], rate: rate)
                + ["-map", "0:a", "-map", "1:a", "-af", "atrim=end_sample=\(count)", "-c:a", "pcm_f32le", file.path])
            let presentation = LoudnessPresentation.stereo(left: 1, right: 0)
            let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
                .analyze(file: file, presentation: presentation)
            XCTAssertEqual(result.presentation, presentation)
            XCTAssertEqual(result.channels.count, 2)
            XCTAssertEqual(result.channels[0].peakDBFS, 20 * log10(0.95), accuracy: 0.00001)
            XCTAssertEqual(result.channels[1].rmsDBFS, 20 * log10(0.095), accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(result.imbalanceDB), 20, accuracy: 0.00001)
            XCTAssertEqual(result.duration, Double(count) / Double(rate), accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(result.intervals.last).end, result.duration, accuracy: 1e-9)
        }
    }

    func testGroupedSurroundReordersSixAsymmetricMonoTracks() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let levels = [0.05, 0.1, 0.2, 0.3, 0.5, 0.95]
        let order = [5, 3, 1, 4, 2, 0]
        try await generate(ffmpeg, arguments: inputs(levels)
            + levels.indices.flatMap { ["-map", "\($0):a"] }
            + ["-af", "atrim=end_sample=4937", "-c:a", "pcm_f32le", file.path])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            .analyze(file: file, presentation: .surround51(order), settings: .init(thresholdDBFS: -30))
        XCTAssertEqual(result.channels.count, 6)
        for channel in order.indices {
            XCTAssertEqual(result.channels[channel].peakDBFS, 20 * log10(levels[order[channel]]), accuracy: 0.00001)
            XCTAssertEqual(result.channels[channel].rmsDBFS, 20 * log10(levels[order[channel]]), accuracy: 0.00001)
        }
        XCTAssertEqual(result.duration, 4937.0 / 48000, accuracy: 1e-9)
        XCTAssertEqual(result.intervals.count, 6)
        XCTAssertTrue(result.intervals.allSatisfy { abs($0.end - result.duration) < 1e-9 })
    }

    func testGroupedCommonDelayedStartIsPreserved() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: ["-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=4",
            "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.95:s=48000:d=1",
            "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.095:s=48000:d=1",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "ffv1", "-c:a", "pcm_f32le", file.path])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            .analyze(file: file, presentation: .stereo(left: 0, right: 1))
        XCTAssertEqual(try XCTUnwrap(result.intervals.first).start, 2, accuracy: 1e-9)
        XCTAssertEqual(result.duration, 3, accuracy: 1e-9)
    }

    func testGeneratedGroupsRejectUnequalLengthsOffsetsRatesAndMidstreamGaps() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for variant in 0..<4 {
            let file = temporaryFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var arguments = ["-f", "lavfi", "-i", "aevalsrc=0.95:s=48000:d=1"]
            if variant == 1 { arguments += ["-itsoffset", "0.1"] }
            arguments += ["-f", "lavfi", "-i", "aevalsrc=0.095:s=\(variant == 2 ? 44100 : 48000):d=\(variant == 0 ? 0.9 : 1)"]
            if variant == 3 {
                arguments += ["-filter_complex", "[1:a]asetpts=PTS+if(gte(N\\,24000)\\,4800\\,0)[gapped]", "-map", "0:a", "-map", "[gapped]"]
            } else { arguments += ["-map", "0:a", "-map", "1:a"] }
            try await generate(ffmpeg, arguments: arguments + ["-c:a", "pcm_f32le", file.path])
            do {
                _ = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
                    .analyze(file: file, presentation: .stereo(left: 0, right: 1))
                XCTFail("Accepted incompatible grouped timing, variant \(variant)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Grouped peak analysis"), error.localizedDescription) }
        }
    }

    func testGroupedPreflightRejectsDecoderFailureEvenWithCompleteTimingLogs() async {
        let service = AudioPeakAnalysisService(runner: GroupedTimingFailureRunner(), ffmpegPathProvider: { "/tmp/ffmpeg" })
        do {
            try await service.validateGroupedTracks(file: URL(fileURLWithPath: "/tmp/grouped.mkv"),
                                                    presentation: .stereo(left: 0, right: 1))
            XCTFail("Failed decoder returned a successful grouped preflight")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("decoder failure"), error.localizedDescription)
        }
    }

    func testCancelledGroupedPreflightDrainsRunnerBeforeReturning() async throws {
        let started = expectation(description: "Grouped timing decoder started")
        let runner = GroupedTimingCancellationRunner(started: started)
        let service = AudioPeakAnalysisService(runner: runner, ffmpegPathProvider: { "/tmp/ffmpeg" })
        let task = Task {
            try await service.validateGroupedTracks(file: URL(fileURLWithPath: "/tmp/grouped.mkv"),
                                                    presentation: .stereo(left: 0, right: 1))
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled grouped preflight returned success")
        } catch is CancellationError { }
        let active = await runner.active
        let drained = await runner.drained
        XCTAssertFalse(active, "Preflight must await runner teardown before returning and releasing scoped access")
        XCTAssertTrue(drained)
    }

    func testSixFLACTracksWithDifferentBlockSizesKeepSingleSampleFinalWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let levels = [0.05, 0.1, 0.2, 0.3, 0.5, 0.95]
        let order = [5, 3, 1, 4, 2, 0]
        let sources = levels.flatMap {
            ["-f", "lavfi", "-i", "aevalsrc=if(eq(n\\,96000)\\,\($0)\\,0):s=48000:d=3"]
        }
        let blockSizes = [1024, 4096, 2048, 4608, 1152, 8192]
        try await generate(ffmpeg, arguments: sources
            + levels.indices.flatMap { ["-map", "\($0):a"] }
            + ["-af", "atrim=end_sample=96001", "-c:a", "flac"]
            + blockSizes.enumerated().flatMap { ["-frame_size:a:\($0.offset)", String($0.element)] }
            + [file.path])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            .analyze(file: file, presentation: .surround51(order), settings: .init(thresholdDBFS: -30))
        XCTAssertEqual(result.duration, 96001.0 / 48000, accuracy: 1e-9)
        XCTAssertEqual(result.intervals.count, 6)
        for channel in order.indices {
            XCTAssertEqual(result.channels[channel].peakDBFS, 20 * log10(levels[order[channel]]), accuracy: 0.0001)
            XCTAssertEqual(result.channels[channel].rmsDBFS,
                           20 * log10(levels[order[channel]]) - 10 * log10(96001), accuracy: 0.0001)
            let interval = try XCTUnwrap(result.intervals.first { $0.channel == channel + 1 })
            XCTAssertEqual(interval.start, 2, accuracy: 1e-9)
            XCTAssertEqual(interval.end, 96001.0 / 48000, accuracy: 1e-9)
        }
    }

    func testRepeatedSixTrackFLACToneScansRetainTheFinalFullWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let amplitudes = [0.8, 0.08, 0.04, 0.02, 0.01, 0.005]
        let inputs = amplitudes.enumerated().flatMap { index, amplitude in
            ["-f", "lavfi", "-i",
             "aevalsrc=if(between(t\\,1\\,2)\\,\(amplitude)\\,\(index == 0 ? 0.01 : 0.001))*sin(2*PI*\(440 + index * 100)*t):s=48000:d=6"]
        }
        try await generate(ffmpeg, arguments: inputs
            + amplitudes.indices.flatMap { ["-map", "\($0):a"] }
            + ["-c:a", "flac", file.path])
        let service = AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
        var sourceLevels: [AudioChannelLevel] = []
        for index in amplitudes.indices {
            let source = try await service.analyze(file: file, trackIndex: index)
            sourceLevels.append(try XCTUnwrap(source.channels.first))
        }
        // Discrete sine samples need not reach the ideal waveform amplitude.
        // Compare with independent single-track measurements of the same samples.
        // FFmpeg join intermittently dropped the last 4,800 samples for this
        // topology; repeat to cover decoder scheduling variations at EOF.
        for _ in 0..<20 {
            let result = try await service.analyze(file: file, presentation: .surround51(Array(0..<6)))
            XCTAssertEqual(result.duration, 6, accuracy: 1e-9)
            XCTAssertEqual(result.channels.count, 6)
            for channel in amplitudes.indices {
                XCTAssertEqual(result.channels[channel].peakDBFS, sourceLevels[channel].peakDBFS, accuracy: 0.00001)
                XCTAssertEqual(result.channels[channel].rmsDBFS, sourceLevels[channel].rmsDBFS, accuracy: 0.00001)
            }
        }
    }

    private func timing(_ track: Int, frame: Int, pts: Int, samples: Int, rate: Int = 48000) -> String {
        "[ashowinfo@amc_peak_timing_\(track) @ 0x1] n:\(frame) pts:\(pts) pts_time:0 fmt:flt channels:1 chlayout:mono rate:\(rate) nb_samples:\(samples) checksum:0\n"
    }

    private func feed(_ text: String, _ collector: GroupedPeakTimingCollector) {
        for byte in text.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        collector.consume(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("grouped-peaks-\(UUID().uuidString).mkv")
    }

    private func inputs(_ levels: [Double], rate: Int = 48000) -> [String] {
        levels.flatMap { ["-f", "lavfi", "-i", "aevalsrc=\($0):s=\(rate):d=2"] }
    }

    private func generate(_ ffmpeg: String, arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-hide_banner", "-nostdin", "-y"] + arguments, timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private struct GroupedTimingFailureRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest,
             outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        let log = (0..<2).map {
            "[ashowinfo@amc_peak_timing_\($0) @ 0x1] n:0 pts:0 channels:1 rate:48000 nb_samples:4800\n"
        }.joined()
        outputHandler?(.init(stream: .standardError, data: Data(log.utf8)))
        outputHandler?(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("decoder failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor GroupedTimingCancellationRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var active = false
    private(set) var drained = false

    init(started: XCTestExpectation) { self.started = started }

    func run(_ request: SubprocessRequest,
             outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active = true
        defer { active = false; drained = true }
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
