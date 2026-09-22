import XCTest
@testable import Aagedal_Media_Converter

final class CameraCardRecordingMetadataTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/card/0001.mov")
    private let second = URL(fileURLWithPath: "/card/0002.mov")

    func testRecordingUsesFirstSegmentDateAndCompleteDuration() {
        let date = Date(timeIntervalSince1970: 100)
        let result = CameraCardRecordingMetadata.recording(
            resolvedSegmentURLs: [first, second],
            metadata: [first: videoMetadata(containerDate: date, duration: 60),
                       second: videoMetadata(containerDate: date.addingTimeInterval(60), duration: 30)],
            cameraMetadata: [:]
        )
        XCTAssertEqual(result.urls, [first, second])
        XCTAssertEqual(result.start, date)
        XCTAssertEqual(result.duration, 90)
    }

    func testMissingFirstMetadataDoesNotBorrowLaterDateOrPartialDuration() {
        let result = CameraCardRecordingMetadata.recording(
            resolvedSegmentURLs: [first, second],
            metadata: [second: videoMetadata(containerDate: Date(), duration: 60)],
            cameraMetadata: [:]
        )
        XCTAssertNil(result.start)
        XCTAssertNil(result.duration)
    }

    func testInvalidSegmentDurationsDisableGapEstimates() {
        for duration: Double? in [nil, -1, .nan, .infinity] {
            let result = CameraCardRecordingMetadata.recording(
                resolvedSegmentURLs: [first, second],
                metadata: [first: videoMetadata(), second: videoMetadata(duration: duration)],
                cameraMetadata: [:]
            )
            XCTAssertNil(result.duration)
        }
    }

    func testCompatibilityRequiresEverySegmentAndRequiredFields() {
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(for: [], metadata: [:]), .unknown)
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
            for: [first, second], metadata: [first: videoMetadata()]), .unknown)
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
            for: [first], metadata: [first: videoMetadata(codec: nil)]), .unknown)
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
            for: [first], metadata: [first: videoMetadata()]), .compatible)
    }

    func testSpanMismatchStaysIntactInReviewProposal() {
        let metadata = [first: videoMetadata(), second: videoMetadata(frameRate: 25)]
        let recording = CameraCardRecordingMetadata.recording(
            resolvedSegmentURLs: [first, second], metadata: metadata, cameraMetadata: [:])
        let proposal = CameraCardRecordingGrouping.proposal(
            for: [recording], mode: .recordingDay(splitOnLongGaps: true),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ) { CameraCardRecordingMetadata.compatibility(for: $0, metadata: metadata) }
        XCTAssertEqual(proposal.count, 1)
        XCTAssertEqual(proposal.first?.urls, [first, second])
        XCTAssertEqual(proposal.first?.compatibility, .incompatible)
        XCTAssertEqual(proposal.first?.requiresReview, true)
    }

    func testCameraTimestampWinsOverContainerTimestamp() {
        let cameraDate = Date(timeIntervalSince1970: 100)
        let camera = CameraMetadata(
            deviceManufacturer: nil, deviceModelName: nil, deviceSerialNumber: nil,
            lensModelName: nil, timeZone: nil, captureGammaEquation: nil,
            recordingModeType: nil, captureFps: nil, creationDate: cameraDate,
            userDescriptiveMetadata: nil
        )
        let result = CameraCardRecordingMetadata.recording(
            resolvedSegmentURLs: [first],
            metadata: [first: videoMetadata(containerDate: cameraDate.addingTimeInterval(500))],
            cameraMetadata: [first: camera]
        )
        XCTAssertEqual(result.start, cameraDate)
    }

    func testSecondaryAudioTrackCannotBeIgnored() {
        func audio(_ sampleRate: Int?) -> VideoMetadata.AudioStream {
            .init(index: nil, languageCode: nil, title: nil, codec: "aac", codecLongName: nil,
                  profile: nil, sampleRate: sampleRate, channels: 2, channelLayout: "stereo",
                  bitDepth: nil, bitRate: nil, isDefault: false)
        }
        let reference = videoMetadata(audioStreams: [audio(48000), audio(48000)])
        for (tracks, expected): ([VideoMetadata.AudioStream], CameraCardRecordingGrouping.Compatibility) in [
            ([audio(48000), audio(44100)], .incompatible),
            ([audio(48000)], .incompatible),
            ([audio(48000), audio(nil)], .unknown),
            ([audio(48000), audio(48000)], .compatible)
        ] {
            XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
                for: [first, second], metadata: [first: reference, second: videoMetadata(audioStreams: tracks)]
            ), expected)
        }
    }

    func testMultichannelAudioRequiresKnownLayout() {
        let audio = VideoMetadata.AudioStream(
            index: nil, languageCode: nil, title: nil, codec: "aac", codecLongName: nil,
            profile: nil, sampleRate: 48000, channels: 6, channelLayout: nil,
            bitDepth: nil, bitRate: nil, isDefault: false
        )
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
            for: [first], metadata: [first: videoMetadata(audioStreams: [audio])]
        ), .unknown)
    }

    func testSecondaryVideoCodecUsesSharedCompatibilityRules() {
        let common = videoMetadata().videoStreams
        let reference = videoMetadata(videoStreams: common + common)
        let different = videoMetadata(videoStreams: common + videoMetadata(codec: "hevc").videoStreams)
        XCTAssertEqual(CameraCardRecordingMetadata.compatibility(
            for: [first, second], metadata: [first: reference, second: different]
        ), .incompatible)
    }

    private func videoMetadata(
        timecode: String? = nil,
        frameRate: Double = 24,
        codec: String? = "h264",
        containerDate: Date? = nil,
        videoStreams: [VideoMetadata.VideoStream]? = nil,
        audioStreams: [VideoMetadata.AudioStream] = [],
        pixelAspectRatio: VideoMetadata.Ratio? = VideoMetadata.Ratio(numerator: 1, denominator: 1),
        duration: Double? = 60
    ) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
            formatName: "mov",
            containerLongName: "QuickTime / MOV",
            sizeBytes: nil,
            bitRate: nil,
            comment: nil,
            timecode: timecode,
            timecodes: [],
            frameCount: nil,
            containerCreationDate: containerDate,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: videoStreams ?? [
                VideoMetadata.VideoStream(
                    codec: codec,
                    codecLongName: nil,
                    profile: nil,
                    width: 1920,
                    height: 1080,
                    pixelFormat: "yuv420p",
                    hasAlpha: false,
                    pixelAspectRatio: pixelAspectRatio,
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: frameRate),
                    bitDepth: 8,
                    bitRate: nil,
                    duration: 60,
                    chromaSubsampling: "4:2:0",
                    colorPrimaries: nil,
                    colorTransfer: nil,
                    colorSpace: nil,
                    colorRange: nil,
                    chromaLocation: nil,
                    fieldOrder: nil,
                    isInterlaced: false,
                    title: nil,
                    isDefault: true,
                    isForced: false
                )
            ],
            audioStreams: audioStreams,
            subtitleStreams: []
        )
    }

}
