import XCTest
import PDFKit
@testable import Aagedal_Media_Converter

final class AudioRoutingPlanTests: XCTestCase {
    func testLoudnessPresetsDoNotTreatMixedStreamsAsSplitMono() {
        let presentations = LoudnessPresentation.presets(for: tracks)
        XCTAssertEqual(presentations, [.track(0), .track(1)])
    }

    func testSixMonoLoudnessPresetsHaveExplicitPlayoutOrder() {
        let mono = (0..<6).map {
            AudioTrackInfo(streamIndex: $0, channels: 1, channelLayout: "mono", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000)
        }
        let presentations = LoudnessPresentation.presets(for: mono)
        XCTAssertEqual(presentations.count, 11)
        XCTAssertEqual(presentations[presentations.count - 2], .surround51([0, 1, 2, 3, 4, 5]))
        XCTAssertEqual(presentations.last, .surround51([0, 1, 2, 5, 3, 4]))
        XCTAssertEqual(LoudnessAnalysisService.filterGraph(for: .surround51([0, 1, 2, 3, 4, 5])),
                       "[0:a:0][0:a:1][0:a:2][0:a:3][0:a:4][0:a:5]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,"
                       + "asetpts=PTS-STARTPTS,ebur128=metadata=1:peak=true:framelog=verbose,"
                       + "astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level+RMS_level,ametadata=print:file=-[metered]")
    }

    func testGraphReductionRetainsMomentaryAndShortTermExtremes() {
        var samples = (0..<120).map {
            LoudnessSample(seconds: Double($0) / 10, momentaryLUFS: -24, shortTermLUFS: -25)
        }
        samples[31] = LoudnessSample(seconds: 3.1, momentaryLUFS: -4, shortTermLUFS: -25)
        samples[75] = LoudnessSample(seconds: 7.5, momentaryLUFS: -24, shortTermLUFS: -10)
        let results = LoudnessResults(presentation: .track(0), integratedLUFS: -23,
                                      loudnessRangeLU: 5, maximumTruePeakDBTP: -1,
                                      samples: samples)
        let graph = results.graphSamples(maxBuckets: 4)
        XCTAssertTrue(graph.contains(samples[31]))
        XCTAssertTrue(graph.contains(samples[75]))
        XCTAssertLessThan(graph.count, samples.count)
    }

    func testLoudnessCollectorUsesFinalProgramSummary() async throws {
        let log = """
        [Parsed_ebur128_0] Summary:
          Integrated loudness:
            I:         -20.5 LUFS
            Threshold: -30.5 LUFS
          Loudness range:
            LRA:         1.0 LU
          True peak:
            Peak:      -1.5 dBFS
        """
        let metadata = """
        frame:0 pts:14400 pts_time:0.3
        lavfi.r128.M=-19.5
        lavfi.r128.S=-120.7
        lavfi.r128.I=-19.5
        lavfi.astats.Overall.Peak_level=-3.0
        lavfi.astats.Overall.RMS_level=-22.5
        frame:1 pts:144000 pts_time:3.0
        lavfi.r128.M=-22.0
        lavfi.r128.S=-21.0
        lavfi.r128.I=-20.5
        lavfi.astats.Overall.Peak_level=-6.0
        lavfi.astats.Overall.RMS_level=-25.5
        """
        let runner = LoudnessTestRunner(stderr: log, stdout: metadata)
        let service = LoudnessAnalysisService(runner: runner, ffmpegPathProvider: { "/private/tmp/fake-ffmpeg" })
        let result = try await service.analyze(file: URL(fileURLWithPath: "/private/tmp/loudness-test.mov"), presentation: .track(0))
        XCTAssertEqual(result.integratedLUFS, -20.5)
        XCTAssertEqual(result.loudnessRangeLU, 1)
        XCTAssertEqual(result.maximumTruePeakDBTP, -1.5)
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertNil(result.samples[0].shortTermLUFS)
        XCTAssertEqual(result.samples[0].peakDBFS, -3)
        XCTAssertEqual(result.samples[0].rmsDBFS, -22.5)
        XCTAssertEqual(result.samples[1].shortTermLUFS, -21)
        XCTAssertEqual(result.samples[1].rmsDBFS, -25.5)
    }

    func testLevelGraphReductionRetainsPeaksAndSilence() {
        var samples = (0..<200).map {
            LoudnessSample(seconds: Double($0) / 10, momentaryLUFS: -24, shortTermLUFS: -25,
                           peakDBFS: -12, rmsDBFS: -27)
        }
        samples[21].peakDBFS = -0.2
        samples[32].rmsDBFS = -8
        samples[43].peakDBFS = nil
        samples[43].rmsDBFS = nil
        let result = LoudnessResults(presentation: .track(0), integratedLUFS: -23,
                                     loudnessRangeLU: 5, maximumTruePeakDBTP: 0.1, samples: samples)
        let graph = result.graphSamples(maxBuckets: 4)
        XCTAssertTrue(graph.contains(samples[21]))
        XCTAssertTrue(graph.contains(samples[32]))
        XCTAssertTrue(graph.contains(samples[43]))
        XCTAssertLessThanOrEqual(graph.count, 40)
        XCTAssertEqual(graph.map(\.seconds), graph.map(\.seconds).sorted())
        XCTAssertEqual(result.graphSamples(maxBuckets: 0), samples)
    }

    func testBundledFFmpegMeasuresWindowLevelsAndSilence() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tone and silence.wav")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-hide_banner", "-nostdin", "-f", "lavfi", "-i",
                        "aevalsrc=if(lt(t\\,2)\\,0.5*sin(2*PI*1000*t)\\,if(lt(t\\,3)\\,0\\,0.05*sin(2*PI*1000*t))):s=48000:d=5",
                        "-c:a", "pcm_f32le", file.path],
            timeout: .seconds(30)
        )
        let generated = try await SubprocessRunner().run(request)
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let tracks = await AudioRoutingService.fetchAudioTrackInfo(for: file)
        XCTAssertEqual(tracks.count, 1, "WAV must be discoverable from the analysis sheet")
        XCTAssertEqual(tracks.first?.channels, 1)
        let result = try await LoudnessAnalysisService.shared.analyze(file: file, presentation: .track(0))
        XCTAssertEqual(result.samples.count, 50)
        XCTAssertEqual(try XCTUnwrap(result.samples.first?.seconds), 0, accuracy: 0.001)
        let loud = try XCTUnwrap(result.samples.first { $0.seconds > 1 && $0.seconds < 1.5 })
        let quiet = try XCTUnwrap(result.samples.first { $0.seconds > 4 && $0.seconds < 4.5 })
        let silence = try XCTUnwrap(result.samples.first { $0.seconds > 2.2 && $0.seconds < 2.8 })
        XCTAssertEqual(try XCTUnwrap(loud.peakDBFS), -6.02, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(loud.rmsDBFS), -9.03, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(quiet.peakDBFS), -26.02, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(quiet.rmsDBFS), -29.03, accuracy: 0.1)
        XCTAssertNil(silence.peakDBFS)
        XCTAssertNil(silence.rmsDBFS)
        XCTAssertTrue(result.integratedLUFS.isFinite)
        XCTAssertEqual(try XCTUnwrap(result.maximumTruePeakDBTP), -6, accuracy: 0.2)
    }

    @MainActor
    func testLoudnessPDFContainsSummaryAndBothTimelinesOnA4Page() throws {
        let samples = (0..<100).map { index in
            LoudnessSample(seconds: Double(index) / 10,
                           momentaryLUFS: -23 + sin(Double(index) / 8) * 5,
                           shortTermLUFS: -24 + sin(Double(index) / 15) * 2,
                           peakDBFS: -6 + sin(Double(index) / 8) * 3,
                           rmsDBFS: -20 + sin(Double(index) / 8) * 5)
        }
        let result = LoudnessResults(presentation: .track(0), integratedLUFS: -23,
                                     loudnessRangeLU: 5, maximumTruePeakDBTP: -1.5, samples: samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnalyticsExporter.exportLoudnessPDF(results: result, fileName: "Example audio.wav", to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 842, accuracy: 1)
        let text = try XCTUnwrap(document.string)
        for label in ["Audio Loudness Analysis", "Example audio.wav", "Track 1", "-23.0 LUFS",
                      "Loudness over time", "Audio levels over time", "dBFS", "RMS", "Sample peak", "chart floor."] {
            XCTAssertTrue(text.contains(label), "PDF missing \(label)")
        }
    }

    func testMixedAndTwelveMonoTracksOfferValidIndependentGroups() {
        let mono = (0..<12).map {
            AudioTrackInfo(streamIndex: $0, channels: 1, channelLayout: "mono", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000)
        }
        let choices = LoudnessPresentation.presets(for: mono)
        XCTAssertTrue(choices.contains(.surround51([6, 7, 8, 9, 10, 11])))
        XCTAssertTrue(choices.contains(.surround51([6, 7, 8, 11, 9, 10])))
        XCTAssertTrue(choices.contains(.stereo(left: 10, right: 11)))
        XCTAssertTrue(choices.allSatisfy { $0.isValid(for: mono) })
        let mixed = [mono[0], tracks[1], mono[2], mono[3]]
        let mixedChoices = LoudnessPresentation.presets(for: mixed)
        XCTAssertTrue(mixedChoices.contains(.stereo(left: 0, right: 2)))
        XCTAssertFalse(mixedChoices.contains(.stereo(left: 0, right: 1)))
        XCTAssertTrue(mixedChoices.allSatisfy { $0.isValid(for: mixed) })
        XCTAssertTrue(LoudnessPresentation.stereo(left: 0, right: 11).isValid(for: mono))
        XCTAssertTrue(LoudnessPresentation.surround51([11, 8, 6, 9, 7, 10]).isValid(for: mono))
        XCTAssertFalse(LoudnessPresentation.stereo(left: 0, right: 0).isValid(for: mono))
        XCTAssertFalse(LoudnessPresentation.surround51([0, 1, 2, 3, 4, 4]).isValid(for: mono))
        XCTAssertFalse(LoudnessPresentation.surround51([0, 1, 2, 3, 4]).isValid(for: mono))
        XCTAssertFalse(LoudnessPresentation.track(99).isValid(for: mono))
        XCTAssertFalse(LoudnessPresentation.stereo(left: 0, right: 1).isValid(for: tracks))
    }

    func testMultiMonoBatchMeasuresLFESeparatelyFromFivePointOneLoudness() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("six mono tracks.mov")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-hide_banner", "-nostdin", "-f", "lavfi", "-i",
                        "aevalsrc=0|0|0|0.5*sin(2*PI*1000*t)|0|0:s=48000:d=4:c=5.1(side)",
                        "-filter_complex", "[0:a]channelsplit=channel_layout=5.1(side)[s0][s1][s2][s3][s4][s5];"
                        + (0..<6).map { "[s\($0)]pan=mono|c0=c0[a\($0)]" }.joined(separator: ";"),
                        "-map", "[a0]", "-map", "[a1]", "-map", "[a2]", "-map", "[a3]", "-map", "[a4]", "-map", "[a5]",
                        "-c:a", "pcm_s16le", file.path], timeout: .seconds(30)
        )
        let generated = try await SubprocessRunner().run(request)
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let probed = await AudioRoutingService.fetchAudioTrackInfo(for: file)
        XCTAssertEqual(probed.count, 6)
        XCTAssertTrue(probed.allSatisfy { $0.channels == 1 })
        let chosen: [LoudnessPresentation] = [.surround51([0, 1, 2, 3, 4, 5]), .track(3), .stereo(left: 3, right: 0)]
        let runner = LoudnessConcurrencyRunner()
        let service = LoudnessAnalysisService(runner: runner, ffmpegPathProvider: { ffmpeg })
        let reports = try await service.analyze(file: file, presentations: chosen)
        XCTAssertEqual(reports.map(\.presentation), chosen)
        XCTAssertEqual(reports.count, 3)
        XCTAssertLessThanOrEqual(reports[0].integratedLUFS, -70, "LFE is excluded from 5.1 loudness weighting")
        XCTAssertGreaterThan(reports[1].integratedLUFS, -20, "The LFE mono track is still measurable independently")
        XCTAssertGreaterThan(reports[2].integratedLUFS, -20, "A custom nonadjacent stereo pair includes its assigned tracks")
        for report in reports {
            XCTAssertEqual(try XCTUnwrap(report.maximumTruePeakDBTP), -6, accuracy: 0.2)
            XCTAssertEqual(report.samples.count, 40)
        }
        let maximumActive = await runner.maximumActive
        XCTAssertEqual(maximumActive, 2, "Batch measurements must bound decoder concurrency")
    }

    func testCancellingBatchDrainsBothMetersAndDoesNotStartNextSelection() async throws {
        let started = expectation(description: "Two meters started")
        started.expectedFulfillmentCount = 2
        let runner = CancellingLoudnessBatchRunner(started: started)
        let service = LoudnessAnalysisService(runner: runner, ffmpegPathProvider: { "/private/tmp/fake-ffmpeg" })
        let task = Task {
            try await service.analyze(file: URL(fileURLWithPath: "/private/tmp/audio.mov"),
                                      presentations: [.track(0), .track(1), .track(2)])
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled audio batch returned success")
        } catch is CancellationError { }
        let active = await runner.active
        let launched = await runner.launched
        XCTAssertEqual(active, 0)
        XCTAssertEqual(launched, 2)
    }

    @MainActor
    func testBatchLoudnessPDFHasOneCompletePagePerPresentation() throws {
        let samples = (0..<40).map {
            LoudnessSample(seconds: Double($0) / 10, momentaryLUFS: -23, shortTermLUFS: -24, peakDBFS: -6, rmsDBFS: -20)
        }
        let presentations: [LoudnessPresentation] = [.track(0), .stereo(left: 2, right: 7), .surround51([0, 1, 2, 5, 3, 4])]
        let reports = presentations.map {
            LoudnessResults(presentation: $0, integratedLUFS: -23, loudnessRangeLU: 5, maximumTruePeakDBTP: -1.5, samples: samples)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnalyticsExporter.exportLoudnessPDF(results: reports, fileName: "Multi-mono.mov", to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        for (index, presentation) in presentations.enumerated() {
            let page = try XCTUnwrap(document.page(at: index))
            let text = try XCTUnwrap(page.string)
            XCTAssertTrue(text.contains(presentation.displayName))
            XCTAssertTrue(text.contains("Loudness over time"))
            XCTAssertTrue(text.contains("Audio levels over time"))
            XCTAssertTrue(text.contains("chart floor."))
            XCTAssertTrue(text.contains("Generated by Aagedal Media Converter"))
            XCTAssertEqual(page.bounds(for: .mediaBox).height, 842, accuracy: 1)
        }
        XCTAssertThrowsError(try AnalyticsExporter.exportLoudnessPDF(results: [], fileName: "Empty", to: url))
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3, "An empty export must preserve the existing destination")
    }

    func testDirectPlanRetainsDuplicateOrderAfterConfigurationChanges() {
        var config = AudioRoutingConfig(inputTracks: tracks, outputTrackIndices: [1, 0, 1])
        let plan = AudioRoutingService.makePlan(config: config)
        config.outputTracks.removeAll()

        XCTAssertEqual(plan, .tracks([
            .init(streamIndex: 1, downmixToStereo: false),
            .init(streamIndex: 0, downmixToStereo: false),
            .init(streamIndex: 1, downmixToStereo: false)
        ]))
        XCTAssertEqual(plan.outputStreamCount, 3)
        XCTAssertEqual(plan.ffmpegArguments, ["-map", "0:a:1", "-map", "0:a:0", "-map", "0:a:1"])
        XCTAssertEqual(AudioRoutingService.makePlan(config: config).ffmpegArguments, [])
    }

    func testMixedDownmixOwnsUniqueOrderedMapsForRepeatedSource() {
        let config = AudioRoutingConfig(inputTracks: tracks, outputTracks: [
            OutputTrack(streamIndex: 1, downmixToStereo: true),
            OutputTrack(streamIndex: 1),
            OutputTrack(streamIndex: 0)
        ])
        let plan = AudioRoutingService.makePlan(config: config)
        XCTAssertEqual(plan.outputStreamCount, 3)
        XCTAssertEqual(plan.ffmpegArguments, [
            "-filter_complex",
            "[0:a:1]aresample=ochl=stereo[aout0];[0:a:1]anull[aout1];[0:a:0]anull[aout2]",
            "-map", "[aout0]", "-map", "[aout1]", "-map", "[aout2]"
        ])
    }

    func testChannelOperationOwnsOutputCountInsteadOfSelectedTrackCount() {
        var config = AudioRoutingConfig(inputTracks: tracks, outputTrackIndices: [0])
        config.channelOperation = .splitToMono(trackIndex: 0)
        let split = AudioRoutingService.makePlan(config: config)
        XCTAssertEqual(split, .splitToMono(streamIndex: 0, layout: "stereo"))
        XCTAssertEqual(split.outputStreamCount, 2)
        XCTAssertEqual(Array(split.ffmpegArguments.suffix(4)), ["-map", "[L]", "-map", "[R]"])

        config.channelOperation = .mergeToStereo(trackIndices: [0, 1])
        XCTAssertEqual(AudioRoutingService.makePlan(config: config).outputStreamCount, 1)
        config.channelOperation = .swapChannels(trackIndex: 0)
        XCTAssertEqual(AudioRoutingService.makePlan(config: config), .swapChannels(streamIndex: 0))
        config.channelOperation = .extractChannel(trackIndex: 1, channelIndex: 5, channelName: "SR")
        XCTAssertEqual(AudioRoutingService.makePlan(config: config), .extractChannel(streamIndex: 1, channelIndex: 5))
    }

    func testInvalidChannelOperationsRetainExistingSimpleMappingFallback() {
        var config = AudioRoutingConfig(inputTracks: tracks, outputTracks: [
            OutputTrack(streamIndex: 1, downmixToStereo: true), OutputTrack(streamIndex: 0)
        ])
        let invalid: [ChannelOperation] = [
            .mergeToStereo(trackIndices: [0]),
            .splitToMono(trackIndex: 1),
            .swapChannels(trackIndex: 1),
            .extractChannel(trackIndex: 0, channelIndex: -1, channelName: "invalid"),
            .extractChannel(trackIndex: 0, channelIndex: 2, channelName: "invalid"),
            .extractChannel(trackIndex: 99, channelIndex: 0, channelName: "invalid")
        ]
        for operation in invalid {
            config.channelOperation = operation
            XCTAssertEqual(AudioRoutingService.makePlan(config: config).ffmpegArguments,
                           ["-map", "0:a:1", "-map", "0:a:0"], "\(operation)")
        }
    }

    func testLegacyRoutingMigrationRetainsOrderDuplicatesAndIntentionalSilence() throws {
        for indices in [[1, 0, 1], []] {
            let decoded = try decodeRoute(["outputTrackIndices": indices])
            XCTAssertEqual(decoded.outputTracks.map(\.streamIndex), indices)
            let encoded = try JSONEncoder().encode(decoded)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(object["outputTrackIndices"])
            let restored = try JSONDecoder().decode(AudioRoutingConfig.self, from: encoded)
            XCTAssertEqual(restored.outputTracks, decoded.outputTracks)
        }
        XCTAssertEqual(try decodeRoute([:]).outputTracks.map(\.streamIndex), [0, 1])
    }

    func testModernRoutingTakesPrecedenceOverLegacySelectionIncludingSilence() throws {
        let config = AudioRoutingConfig(inputTracks: tracks, outputTracks: [
            OutputTrack(streamIndex: 1, downmixToStereo: true), OutputTrack(streamIndex: 1)
        ])
        let encoded = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["outputTrackIndices"] = [0]
        let restored = try decodeRoute(object)
        XCTAssertEqual(restored.outputTracks, config.outputTracks)
        object["outputTracks"] = []
        XCTAssertTrue(try decodeRoute(object).outputTracks.isEmpty)
    }

    func testCorruptRoutingDoesNotSilentlyRestoreTracks() throws {
        for value: Any in [NSNull(), "invalid", [["streamIndex": "invalid"]]] {
            XCTAssertThrowsError(try decodeRoute(["outputTracks": value, "outputTrackIndices": [0]]))
            XCTAssertThrowsError(try decodeRoute(["outputTracks": value]))
        }
        for value: Any in [NSNull(), "invalid", ["invalid"]] {
            XCTAssertThrowsError(try decodeRoute(["outputTrackIndices": value]))
        }
    }

    private func decodeRoute(_ fields: [String: Any]) throws -> AudioRoutingConfig {
        var object = fields
        object["inputTracks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tracks))
        return try JSONDecoder().decode(AudioRoutingConfig.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private var tracks: [AudioTrackInfo] {
        [
            AudioTrackInfo(streamIndex: 0, channels: 2, channelLayout: "stereo", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000),
            AudioTrackInfo(streamIndex: 1, channels: 6, channelLayout: "5.1", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000)
        ]
    }
}

private actor LoudnessTestRunner: SubprocessRunning {
    let stderr: String
    let stdout: String

    init(stderr: String, stdout: String = "") {
        self.stderr = stderr
        self.stdout = stdout
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        let bytes = Data(stderr.utf8)
        // Arbitrary chunks can split frame headers, keys, numbers and newlines.
        for byte in stdout.utf8 {
            outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: Data([byte])))
        }
        outputHandler?(SubprocessOutputChunk(stream: .standardError, data: bytes))
        return SubprocessResult(terminationStatus: 0, termination: .exited,
                                standardOutput: Data(), standardError: bytes,
                                discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
                                duration: .zero)
    }
}

private actor LoudnessConcurrencyRunner: SubprocessRunning {
    private var active = 0
    private(set) var maximumActive = 0

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await SubprocessRunner().run(request, outputHandler: outputHandler)
    }
}

private actor CancellingLoudnessBatchRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var active = 0
    private(set) var launched = 0

    init(started: XCTestExpectation) { self.started = started }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active += 1
        launched += 1
        defer { active -= 1 }
        started.fulfill()
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }
}
