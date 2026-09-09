import XCTest
@testable import Aagedal_Media_Converter

final class BMXProbeLifecycleTests: XCTestCase {
    func testCancelledInfoProbeRejectsLateSuccess() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = BMXProbeRunner()
        let service = service(runner)
        let task = Task { await service.getMXFInfo(url: url) }
        try await runner.waitForStart(1)
        task.cancel()
        await runner.finish(0, output: "Operational Pattern: OP-1a")
        let result = await task.value
        XCTAssertNil(result)
    }

    func testCancelledMCAProbeDoesNotPopulateCache() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = BMXProbeRunner()
        let service = service(runner)
        let cancelled = Task { await service.getAudioTrackLabels(url: url) }
        try await runner.waitForStart(1)
        cancelled.cancel()
        await runner.finish(0, output: xml(channels: 1))
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)

        let fresh = Task { await service.getAudioTrackLabels(url: url) }
        try await runner.waitForStart(2)
        await runner.finish(1, output: xml(channels: 2))
        let freshResult = await fresh.value
        XCTAssertEqual(freshResult?.first?.channelCount, 2)
    }

    func testInvalidationRejectsInFlightProbe() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = BMXProbeRunner()
        let service = service(runner)
        let task = Task { await service.getAudioTrackLabels(url: url) }
        try await runner.waitForStart(1)
        await service.invalidateMCACache(for: url)
        await runner.finish(0, output: xml(channels: 1))
        let result = await task.value
        XCTAssertNil(result)
    }

    func testInvalidationAndReplacementRejectOldProbeWithoutClearingReplacement() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = BMXProbeRunner()
        let service = service(runner)
        let old = Task { await service.getAudioTrackLabels(url: url) }
        try await runner.waitForStart(1)
        await service.invalidateMCACache(for: url)
        let replacement = Task { await service.getAudioTrackLabels(url: url) }
        try await runner.waitForStart(2)
        await runner.finish(0, output: xml(channels: 1))
        let oldResult = await old.value
        XCTAssertNil(oldResult)
        await runner.finish(1, output: xml(channels: 2))
        let replacementResult = await replacement.value
        XCTAssertEqual(replacementResult?.first?.channelCount, 2)
        let cached = await service.getAudioTrackLabels(url: url)
        XCTAssertEqual(cached?.first?.channelCount, 2)
        let count = await runner.startedCount
        XCTAssertEqual(count, 2)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bmx-probe-\(UUID()).mxf")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func service(_ runner: BMXProbeRunner) -> BMXService {
        BMXService(subprocessRunner: runner, mxf2rawPathProvider: { "/fixture/mxf2raw" })
    }

    private func xml(channels: Int) -> String {
        """
        <bmx><clip><tracks><track index="0"><essence_kind>Sound</essence_kind>
        <sound_descriptor><channel_count>\(channels)</channel_count><sampling_rate>48000/1</sampling_rate></sound_descriptor>
        <mca_labels><channel_label><mca_channel_id>1</mca_channel_id><tag_symbol>chL</tag_symbol><tag_name>Left</tag_name></channel_label></mca_labels>
        </track></tracks></clip></bmx>
        """
    }
}

/// Deliberately returns successful output after cancellation to model a completion race.
private actor BMXProbeRunner: SubprocessRunning {
    private var continuations: [Int: CheckedContinuation<SubprocessResult, Never>] = [:]
    private var isClosed = false
    private(set) var startedCount = 0

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        guard !isClosed else { throw CancellationError() }
        let index = startedCount
        startedCount += 1
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForStart(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while startedCount < count {
            guard ContinuousClock.now < deadline else {
                // Unblock outstanding probes before failing the test. Closing also
                // prevents a task scheduled after the timeout from waiting forever.
                isClosed = true
                for index in Array(continuations.keys) {
                    finish(index, output: "")
                }
                throw StartTimeout(expected: count, actual: startedCount)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct StartTimeout: Error, CustomStringConvertible {
        let expected: Int
        let actual: Int
        var description: String {
            "Expected \(expected) BMX probe starts within two seconds; observed \(actual)"
        }
    }

    func finish(_ index: Int, output: String) {
        continuations.removeValue(forKey: index)?.resume(returning: SubprocessResult(
            terminationStatus: 0, termination: .exited,
            standardOutput: Data(output.utf8), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
            duration: .milliseconds(1)
        ))
    }
}
