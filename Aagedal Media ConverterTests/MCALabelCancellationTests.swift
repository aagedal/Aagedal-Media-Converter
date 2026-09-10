import XCTest
@testable import Aagedal_Media_Converter

final class MCALabelCancellationTests: XCTestCase {
    private static let sourceURL = URL(fileURLWithPath: "/private/source.mxf")
    private static let streams: [FFMPEGProbeService.AudioStreamInfo] = [
        .init(index: 0, channels: 2, channelLayout: "stereo", codecName: "pcm_s24le")
    ]

    func testQueueCancellationWaitsForOwnedMCAProbeDrainAndRejectsLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "MCA stream probe started")
        let cancelled = expectation(description: "MCA probe cancellation received")
        let completed = expectation(description: "Conversion completed as cancelled")
        let probe = MCACancellationDrainProbe(started: started, cancelled: cancelled)
        let converter = FFMPEGConverter(
            subprocessRunner: MCAOutputFixtureRunner(),
            ffmpegPathProvider: { "/fixture/ffmpeg" },
            mcaAudioStreamProvider: { _ in await probe.run() }
        )
        let request = ConversionRequest(
            inputURL: directory.appendingPathComponent("input.mov"),
            outputURL: directory.appendingPathComponent("output"),
            preset: .tvAVCIntra, includeDateTag: false,
            expectedDuration: 1, videoFrameRate: 25
        )
        await converter.convert(request: request, progressUpdate: { _, _ in }, completion: { success, reason in
            XCTAssertFalse(success)
            XCTAssertEqual(reason, "Conversion cancelled")
            completed.fulfill()
        })
        await fulfillment(of: [started], timeout: 10)
        let returned = expectation(description: "Queue stop must wait for probe drain")
        returned.isInverted = true
        let stop = Task.detached {
            await converter.cancelConversion()
            returned.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [returned], timeout: 0.05)
        await probe.finishDraining()
        await stop.value
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output.mxf").path))
    }

    func testSuccessfulMCAProbePublishesLabels() async throws {
        let result = await FFMPEGConverter.prepareAVCIntraMCALabelsFile(
            inputURL: MCALabelCancellationTests.sourceURL,
            audioRoutingConfig: nil,
            targetChannelCount: 2,
            mcaDefaults: .none,
            audioStreamProvider: { _ in MCALabelCancellationTests.streams },
            mcaLabelProvider: { _ in
                [.init(trackNumber: 1, channelCount: 2, sampleRate: 48000,
                       soundfieldGroup: "ST", audioElement: nil, channelLabels: ["L", "R"])]
            }
        )
        let url = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: url) }
        let labels = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(labels.contains("sgST,"), labels)
    }

    func testAlreadyCancelledPreparationSkipsBothProbes() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FFMPEGConverter.prepareAVCIntraMCALabelsFile(
                inputURL: MCALabelCancellationTests.sourceURL,
                audioRoutingConfig: nil,
                targetChannelCount: 2,
                mcaDefaults: .none,
                audioStreamProvider: { _ in
                    XCTFail("Cancelled preparation must not start a stream probe")
                    return MCALabelCancellationTests.streams
                },
                mcaLabelProvider: { _ in
                    XCTFail("Cancelled preparation must not start an MCA probe")
                    return []
                }
            )
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    func testCancellationDuringStreamProbeSkipsMCAProbeAndPublication() async {
        let task = Task.detached {
            await FFMPEGConverter.prepareAVCIntraMCALabelsFile(
                inputURL: MCALabelCancellationTests.sourceURL,
                audioRoutingConfig: nil,
                targetChannelCount: 2,
                mcaDefaults: .none,
                audioStreamProvider: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return MCALabelCancellationTests.streams
                },
                mcaLabelProvider: { _ in
                    XCTFail("Late stream results must not launch an MCA probe")
                    return []
                }
            )
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    func testCancellationDuringMCAProbeDiscardsOtherwiseUsableLabels() async {
        let task = Task.detached {
            await FFMPEGConverter.prepareAVCIntraMCALabelsFile(
                inputURL: MCALabelCancellationTests.sourceURL,
                audioRoutingConfig: nil,
                targetChannelCount: 2,
                mcaDefaults: .none,
                audioStreamProvider: { _ in MCALabelCancellationTests.streams },
                mcaLabelProvider: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return [.init(trackNumber: 1, channelCount: 2, sampleRate: 48000,
                                  soundfieldGroup: "ST", audioElement: nil,
                                  channelLabels: ["L", "R"])]
                }
            )
        }
        let result = await task.value
        if let result { try? FileManager.default.removeItem(at: result) }
        XCTAssertNil(result, "A cancelled probe must not publish a labels file")
    }
}

private actor MCACancellationDrainProbe {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func run() async -> [FFMPEGProbeService.AudioStreamInfo]? {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                cancelled.fulfill()
            }
        }
        // Model a cancelled helper that returns a late usable result after draining.
        return [.init(index: 0, channels: 2, channelLayout: "stereo", codecName: "pcm_s24le")]
    }

    func finishDraining() {
        continuation?.resume()
        continuation = nil
    }
}

private struct MCAOutputFixtureRunner: SubprocessRunning {
    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let outputPath = try XCTUnwrap(request.arguments.last)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: outputPath))
        return SubprocessResult(
            terminationStatus: 0, termination: .exited,
            standardOutput: Data(), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
            duration: .zero
        )
    }
}
