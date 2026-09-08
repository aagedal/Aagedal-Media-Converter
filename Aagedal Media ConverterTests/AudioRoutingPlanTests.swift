import XCTest
@testable import Aagedal_Media_Converter

final class AudioRoutingPlanTests: XCTestCase {
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

    private var tracks: [AudioTrackInfo] {
        [
            AudioTrackInfo(streamIndex: 0, channels: 2, channelLayout: "stereo", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000),
            AudioTrackInfo(streamIndex: 1, channels: 6, channelLayout: "5.1", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48000)
        ]
    }
}
