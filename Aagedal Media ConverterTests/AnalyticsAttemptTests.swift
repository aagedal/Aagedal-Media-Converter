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

    func testManualAnalysisRetainsCompletedOutputRangeAfterQueueEdits() {
        var item = makeItem()
        item.analyticsSourceRange = AnalyticsSourceRange(start: 2, end: 4)
        item.trimStart = 7
        item.trimEnd = 9
        let output = item.outputURL!
        let attempt = AnalyticsAttempt(item: &item, encodedURL: output)
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        XCTAssertEqual(attempt.sourceRange, AnalyticsSourceRange(start: 2, end: 4))
        XCTAssertEqual(followUp.sourceRange, attempt.sourceRange)
        item.outputURL = URL(fileURLWithPath: "/fixture/replaced.mp4")
        XCTAssertNil(item.analyticsSourceRange)
        item.analyticsSourceRange = attempt.sourceRange
        item.resetConversionState()
        XCTAssertNil(item.analyticsSourceRange)
    }

    @MainActor
    func testAutomaticReportsPreserveExistingFilesAndNumberRepeatedExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.mp4")
        let metric = MetricResult(metric: .psnr, overallScore: .infinity, min: .infinity,
                                  max: .infinity, unit: "dB", channelScores: ["Y": .infinity])
        let results = AnalyticsResults(sourceFileName: "source.mov", encodedFileName: "output.mp4",
                                       metrics: [metric], timestamp: Date(), durationSeconds: 2)
        XCTAssertEqual(metric.formattedScore, "∞ dB")
        for format in [AnalyticsExportFormat.json, .pdf] {
            let existing = directory.appendingPathComponent("output_analytics.\(format.fileExtension)")
            let sentinel = Data("An existing edited report".utf8)
            try sentinel.write(to: existing)
            let first = try AnalyticsExporter.autoExport(results: results, encodedFileURL: output, format: format)
            let second = try AnalyticsExporter.autoExport(results: results, encodedFileURL: output, format: format)
            XCTAssertEqual(first.lastPathComponent, "output_analytics_1.\(format.fileExtension)")
            XCTAssertEqual(second.lastPathComponent, "output_analytics_2.\(format.fileExtension)")
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertFalse(try Data(contentsOf: first).isEmpty)
            XCTAssertFalse(try Data(contentsOf: second).isEmpty)
            if format == .json {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
                let metrics = try XCTUnwrap(json["metrics"] as? [[String: Any]])
                XCTAssertEqual(metrics[0]["overallScore"] as? String, "Infinity")
            }
        }
    }

    func testBundledMetricsAlignTrimmedLosslessOutputAndAcceptPerfectScores() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let output = directory.appendingPathComponent("trimmed.mkv")
        let runner = SubprocessRunner()
        for arguments in [
            ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=6", "-c:v", "ffv1", source.path],
            ["-ss", "2", "-t", "2", "-i", source.path, "-c:v", "ffv1", output.path]
        ] {
            let generated = try await runner.run(SubprocessRequest(
                executableURL: URL(fileURLWithPath: ffmpeg), arguments: ["-hide_banner", "-nostdin"] + arguments,
                timeout: .seconds(30)
            ))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        }
        let service = AnalyticsService()
        let unaligned = try await service.runAnalytics(sourceFile: source, encodedFile: output,
                                                       enabledMetrics: [.psnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
        XCTAssertTrue(try XCTUnwrap(unaligned.first).overallScore.isFinite)
        let aligned = try await service.runAnalytics(sourceFile: source, encodedFile: output,
                                                     sourceRange: AnalyticsSourceRange(start: 2, end: 4),
                                                     enabledMetrics: [.psnr, .xpsnr, .vmaf, .ssimulacra2],
                                                     vmafModel: .vmaf_v0_6_1, ssimulacra2MaxFrames: 2) { _, _ in }
        XCTAssertEqual(aligned.count, 4)
        XCTAssertEqual(aligned[0].overallScore, .infinity)
        XCTAssertEqual(aligned[1].overallScore, .infinity)
        XCTAssertGreaterThan(aligned[2].overallScore, 99)
        XCTAssertEqual(aligned[3].overallScore, 100, accuracy: 0.1)
    }

    func testInvalidSourceIntervalsAreRejected() async throws {
        let service = AnalyticsService()
        for range in [AnalyticsSourceRange(start: -1), AnalyticsSourceRange(start: .nan),
                      AnalyticsSourceRange(start: 2, end: 2), AnalyticsSourceRange(end: .infinity)] {
            do {
                _ = try await service.runAnalytics(sourceFile: URL(fileURLWithPath: "/unused/source"),
                                                    encodedFile: URL(fileURLWithPath: "/unused/output"),
                                                    sourceRange: range, enabledMetrics: [.psnr],
                                                    vmafModel: .vmaf_v0_6_1) { _, _ in }
                XCTFail("Invalid interval was accepted")
            } catch let error as AnalyticsError {
                guard case .parsingFailed = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
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
