import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AnalyticsAttemptTests: XCTestCase {
    func testCancelledAttemptCannotOverwriteRetryOrExportOldResults() {
        var item = makeItem()
        let outputURL = item.outputURL!
        let oldAttempt = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        item.analyticsOperationID = nil
        item.analyticsStatus = .notQueued
        let retry = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        var items = [item]
        var exportCount = 0
        XCTAssertFalse(oldAttempt.apply(to: &items) { item in
            item.analyticsStatus = .completed
            exportCount += 1
        })
        XCTAssertFalse(oldAttempt.apply(to: &items) { $0.analyticsStatus = .failed("Old failure") })
        XCTAssertEqual(items[0].analyticsStatus, .pending)
        XCTAssertEqual(items[0].analyticsOperationID, retry.operationID)
        XCTAssertEqual(exportCount, 0)

        XCTAssertTrue(retry.apply(to: &items) { item in
            item.analyticsStatus = .completed
            item.analyticsOperationID = nil
            exportCount += 1
        })
        XCTAssertFalse(retry.apply(to: &items) { $0.analyticsStatus = .running(metric: .psnr, progress: 0.5) })
        XCTAssertEqual(items[0].analyticsStatus, .completed)
        XCTAssertEqual(exportCount, 1)
    }

    func testResetRemovalAndChangedOutputRejectManualPublication() {
        var item = makeItem()
        let outputURL = item.outputURL!
        let attempt = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        var items = [item]
        items[0].resetConversionState()
        XCTAssertNil(items[0].analyticsOperationID)
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Reset row accepted old result") })
        items = [item]
        items[0].outputURL = URL(fileURLWithPath: "/fixture/replacement.mp4")
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Changed output accepted old result") })
        items = []
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Removed row accepted old result") })
    }

    func testDelayedCancellationForOldOperationDoesNotCancelNewServiceRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("output.mp4")
        try Data([0]).write(to: source)
        try Data([0]).write(to: output)
        let started = expectation(description: "Replacement analytics running")
        let runner = AnalyticsAttemptRunner(started: started)
        let service = AnalyticsService(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let task = Task {
            try await service.runAnalytics(
                sourceFile: source, encodedFile: output, enabledMetrics: [.psnr],
                vmafModel: .vmaf_v0_6_1, operationID: UUID()
            ) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        await service.cancelAnalysis(operationID: UUID())
        await runner.finish()
        let results = try await task.value
        XCTAssertEqual(results.first?.overallScore, 39.01)
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/source.mov"), name: "source.mov", size: 0,
            duration: "00:00:10", durationSeconds: 10, status: .done,
            progress: 1, eta: nil, outputURL: URL(fileURLWithPath: "/fixture/output.mp4")
        )
    }
}

private actor AnalyticsAttemptRunner: SubprocessRunning {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) {
        self.started = started
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        try Task.checkCancellation()
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(),
            standardError: Data("PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90".utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1)
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
