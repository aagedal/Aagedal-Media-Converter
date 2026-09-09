import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class AnalyticsCancellationDrainTests: XCTestCase {
    func testCancellationWaitsForHelperDrainAndDoesNotStartNextMetric() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let started = expectation(description: "Metric started")
        let cancelled = expectation(description: "Metric cancellation requested")
        let runner = AnalyticsDrainRunner(started: [started], cancelled: [cancelled])
        let service = makeService(runner: runner)
        let run = startAnalysis(service: service, fixture: fixture, metrics: [.psnr, .xpsnr])
        await fulfillment(of: [started], timeout: 2)

        var cancellationReturned = false
        let cancellation = Task {
            await service.cancelAnalysis()
            cancellationReturned = true
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(cancellationReturned, "Cancellation returned while the helper still held its inputs")
        await runner.finish(run: 0)
        await cancellation.value
        await assertCancelled(run)
        let runCount = await runner.runCount
        XCTAssertTrue(cancellationReturned)
        XCTAssertEqual(runCount, 1)
    }

    func testSSIMULACRACancellationDrainsExtractionAndRemovesScratchBeforeReturning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let started = expectation(description: "Frame extraction started")
        let cancelled = expectation(description: "Frame extraction cancellation requested")
        let runner = AnalyticsDrainRunner(started: [started], cancelled: [cancelled])
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" },
            ssimulacra2PathProvider: { "/fixture/ssimulacra2" },
            mediaInfoProvider: AnalyticsDrainMediaInfoProvider()
        )
        let run = startAnalysis(service: service, fixture: fixture, metrics: [.ssimulacra2])
        await fulfillment(of: [started], timeout: 2)
        let requests = await runner.requests
        let framePath = try XCTUnwrap(requests.first?.arguments.last)
        let scratch = URL(fileURLWithPath: framePath).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))

        var cancellationReturned = false
        let cancellation = Task {
            await service.cancelAnalysis()
            cancellationReturned = true
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(cancellationReturned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        await runner.finish(run: 0)
        await cancellation.value
        await assertCancelled(run)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1, "Cancelled extraction must not start the second frame or comparison helper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testTargetedCancellationStillDrainsSupersededHelperAndPreservesReplacement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstStarted = expectation(description: "First metric started")
        let replacementStarted = expectation(description: "Replacement metric started")
        let firstCancelled = expectation(description: "First metric cancelled by replacement")
        let runner = AnalyticsDrainRunner(
            started: [firstStarted, replacementStarted], cancelled: [firstCancelled]
        )
        let service = makeService(runner: runner)
        let firstID = UUID()
        let first = startAnalysis(service: service, fixture: fixture, operationID: firstID)
        await fulfillment(of: [firstStarted], timeout: 2)
        let replacement = startAnalysis(service: service, fixture: fixture)
        await fulfillment(of: [firstCancelled, replacementStarted], timeout: 2)

        let returned = expectation(description: "Old cancellation remains suspended during drain")
        returned.isInverted = true
        var drainReleased = false
        var cancellationReturned = false
        let cancellation = Task {
            await service.cancelAnalysis(operationID: firstID)
            cancellationReturned = true
            if !drainReleased { returned.fulfill() }
        }
        await fulfillment(of: [returned], timeout: 0.05)
        XCTAssertFalse(cancellationReturned)
        drainReleased = true
        await runner.finish(run: 0)
        await cancellation.value
        XCTAssertTrue(cancellationReturned)
        await assertCancelled(first)

        await runner.finish(run: 1)
        let results = try await replacement.value
        XCTAssertEqual(results.first?.overallScore, 39.01)
        let cancelledRuns = await runner.cancelledRuns
        XCTAssertEqual(cancelledRuns, [0])
    }

    func testCancelAllWaitsForBothCurrentAndSupersededHelpers() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstStarted = expectation(description: "First metric started")
        let secondStarted = expectation(description: "Second metric started")
        let firstCancelled = expectation(description: "First metric cancellation requested")
        let secondCancelled = expectation(description: "Second metric cancellation requested")
        let runner = AnalyticsDrainRunner(
            started: [firstStarted, secondStarted], cancelled: [firstCancelled, secondCancelled]
        )
        let service = makeService(runner: runner)
        let first = startAnalysis(service: service, fixture: fixture)
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = startAnalysis(service: service, fixture: fixture)
        await fulfillment(of: [firstCancelled, secondStarted], timeout: 2)

        var cancellationReturned = false
        let cancellation = Task {
            await service.cancelAnalysis()
            cancellationReturned = true
        }
        await fulfillment(of: [secondCancelled], timeout: 2)
        await runner.finish(run: 1)
        await assertCancelled(second)
        XCTAssertFalse(cancellationReturned, "The superseded helper is still draining")
        await runner.finish(run: 0)
        await cancellation.value
        await assertCancelled(first)
        XCTAssertTrue(cancellationReturned)
    }

    func testSupersededCleanupCannotClearReplacementWithReusedOperationID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstStarted = expectation(description: "First metric started")
        let secondStarted = expectation(description: "Second metric started")
        let firstCancelled = expectation(description: "First metric cancellation requested")
        let secondCancelled = expectation(description: "Replacement remains cancellable")
        let runner = AnalyticsDrainRunner(
            started: [firstStarted, secondStarted], cancelled: [firstCancelled, secondCancelled]
        )
        let service = makeService(runner: runner)
        let operationID = UUID()
        let first = startAnalysis(service: service, fixture: fixture, operationID: operationID)
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = startAnalysis(service: service, fixture: fixture, operationID: operationID)
        await fulfillment(of: [firstCancelled, secondStarted], timeout: 2)
        await runner.finish(run: 0)
        await assertCancelled(first)

        let cancellation = Task { await service.cancelAnalysis(operationID: operationID) }
        await fulfillment(of: [secondCancelled], timeout: 2)
        await runner.finish(run: 1)
        await cancellation.value
        await assertCancelled(second)
    }

    func testHelperCanRequestItsOwnCancellationWithoutJoiningItself() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cancellationReturned = expectation(description: "Self cancellation returned")
        let runner = SelfCancellingAnalyticsRunner(cancellationReturned: cancellationReturned)
        let service = makeService(runner: runner)
        await runner.setCancellation { await service.cancelAnalysis() }
        let run = startAnalysis(service: service, fixture: fixture)
        guard await XCTWaiter.fulfillment(of: [cancellationReturned], timeout: 2) == .completed else {
            run.cancel()
            XCTFail("The helper deadlocked while requesting its own cancellation")
            return
        }
        await assertCancelled(run)
    }

    private typealias Fixture = (directory: URL, source: URL, output: URL)

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("output.mp4")
        try Data([0]).write(to: source)
        try Data([0]).write(to: output)
        return (directory, source, output)
    }

    private func makeService(runner: any SubprocessRunning) -> AnalyticsService {
        AnalyticsService(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
    }

    private func startAnalysis(
        service: AnalyticsService,
        fixture: Fixture,
        operationID: UUID = UUID(),
        metrics: [QualityMetric] = [.psnr]
    ) -> Task<[MetricResult], Error> {
        Task {
            try await service.runAnalytics(
                sourceFile: fixture.source, encodedFile: fixture.output, enabledMetrics: metrics,
                vmafModel: .vmaf_v0_6_1, operationID: operationID
            ) { _, _ in }
        }
    }

    private func assertCancelled(_ task: Task<[MetricResult], Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancelled analytics")
        } catch AnalyticsError.cancelled {
            // Expected, including when a runner returns a late successful exit.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor AnalyticsDrainRunner: SubprocessRunning {
    private let started: [XCTestExpectation]
    private let cancelled: [XCTestExpectation]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var runCount = 0
    private(set) var cancelledRuns: [Int] = []
    private(set) var requests: [SubprocessRequest] = []

    init(started: [XCTestExpectation], cancelled: [XCTestExpectation]) {
        self.started = started
        self.cancelled = cancelled
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let run = runCount
        runCount += 1
        requests.append(request)
        let cancellation = cancelled.indices.contains(run) ? cancelled[run] : nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[run] = continuation
                if started.indices.contains(run) { started[run].fulfill() }
            }
        } onCancel: {
            cancellation?.fulfill()
        }
        if Task.isCancelled { cancelledRuns.append(run) }
        // Simulate a successful process exit arriving only after cancellation drains.
        return analyticsDrainResult()
    }

    func finish(run: Int) {
        continuations.removeValue(forKey: run)?.resume()
    }
}

private actor SelfCancellingAnalyticsRunner: SubprocessRunning {
    private let cancellationReturned: XCTestExpectation
    private var cancellation: (@Sendable () async -> Void)?

    init(cancellationReturned: XCTestExpectation) {
        self.cancellationReturned = cancellationReturned
    }

    func setCancellation(_ cancellation: @escaping @Sendable () async -> Void) {
        self.cancellation = cancellation
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await cancellation?()
        cancellationReturned.fulfill()
        return analyticsDrainResult()
    }
}

private struct AnalyticsDrainMediaInfoProvider: AnalyticsMediaInfoProviding {
    func duration(for file: URL) async -> Double? { 1 }
    func resolution(for file: URL) async -> (width: Int, height: Int)? { (16, 16) }
}

private func analyticsDrainResult() -> SubprocessResult {
    SubprocessResult(
        terminationStatus: 0, termination: .exited, standardOutput: Data(),
        standardError: Data("PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90".utf8),
        discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1)
    )
}
