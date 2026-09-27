import XCTest
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
                       "[0:a:0][0:a:1][0:a:2][0:a:3][0:a:4][0:a:5]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,ebur128=peak=true[metered]")
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
        [Parsed_ebur128_0] t: 0.399  TARGET:-23 LUFS M: -19.5 S:-120.7 I: -19.5 LUFS LRA: 0.0 LU
        [Parsed_ebur128_0] t: 3.099  TARGET:-23 LUFS M: -22.0 S: -21.0 I: -20.5 LUFS LRA: 1.0 LU
        [Parsed_ebur128_0] Summary:
          Integrated loudness:
            I:         -20.5 LUFS
            Threshold: -30.5 LUFS
          Loudness range:
            LRA:         1.0 LU
          True peak:
            Peak:      -1.5 dBFS
        """
        let runner = LoudnessTestRunner(stderr: log)
        let service = LoudnessAnalysisService(runner: runner, ffmpegPathProvider: { "/private/tmp/fake-ffmpeg" })
        let result = try await service.analyze(file: URL(fileURLWithPath: "/private/tmp/loudness-test.mov"), presentation: .track(0))
        XCTAssertEqual(result.integratedLUFS, -20.5)
        XCTAssertEqual(result.loudnessRangeLU, 1)
        XCTAssertEqual(result.maximumTruePeakDBTP, -1.5)
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertNil(result.samples[0].shortTermLUFS)
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

    init(stderr: String) { self.stderr = stderr }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        let bytes = Data(stderr.utf8)
        let midpoint = bytes.count / 2
        outputHandler?(SubprocessOutputChunk(stream: .standardError, data: bytes.prefix(midpoint)))
        outputHandler?(SubprocessOutputChunk(stream: .standardError, data: bytes.suffix(from: midpoint)))
        return SubprocessResult(terminationStatus: 0, termination: .exited,
                                standardOutput: Data(), standardError: bytes,
                                discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
                                duration: .zero)
    }
}
