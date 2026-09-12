import XCTest
@testable import Aagedal_Media_Converter

final class DenoExtractionDrainTests: XCTestCase {
    func testReplacementWaitsForCancelledRunnerToDrain() async throws {
        let runner = DenoDrainRunner()
        let service = YTDLPUpdateService(subprocessRunner: runner)
        let old = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/old")) }
        try await runner.waitForStarts(1)
        await service.cancelDownload(.deno)
        let replacement = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/new")) }
        try await runner.waitForCancellation()
        try await Task.sleep(for: .milliseconds(30))
        let startsBeforeDrain = await runner.paths
        XCTAssertEqual(startsBeforeDrain, ["/fixture/old"])

        await runner.finish(0)
        try await runner.waitForStarts(2)
        await assertCancelled(old)
        await runner.finish(1)
        let result = try await replacement.value
        try FileManager.default.removeItem(at: result.workingDirectoryURL)
    }

    func testCancelledQueuedReplacementRetainsPredecessorDrainForNextRequest() async throws {
        let runner = DenoDrainRunner()
        // A regression may launch the cancelled middle runner and suspend its
        // caller indefinitely. Bound every task join, not only start polling.
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            XCTFail("Deno extraction drain chain did not complete within three seconds")
            await runner.close()
        }
        defer { deadline.cancel() }
        let service = YTDLPUpdateService(subprocessRunner: runner)
        let old = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/old")) }
        try await runner.waitForStarts(1)
        let queued = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/queued")) }
        try await runner.waitForCancellation()
        queued.cancel()
        let replacement = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/new")) }
        try await Task.sleep(for: .milliseconds(30))
        let startsBeforeDrain = await runner.paths
        XCTAssertEqual(startsBeforeDrain, ["/fixture/old"])

        await runner.finish(0)
        await assertCancelled(old)
        await assertCancelled(queued)
        try await runner.waitForStarts(2)
        let paths = await runner.paths
        XCTAssertEqual(paths, ["/fixture/old", "/fixture/new"])
        await runner.finish(1)
        let result = try await replacement.value
        try FileManager.default.removeItem(at: result.workingDirectoryURL)
    }

    func testAlreadyCancelledCallerPreservesRunningExtraction() async throws {
        let runner = DenoDrainRunner()
        let service = YTDLPUpdateService(subprocessRunner: runner)
        let old = Task { try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/old")) }
        try await runner.waitForStarts(1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.extractDenoArchive(from: URL(fileURLWithPath: "/fixture/cancelled"))
        }
        await assertCancelled(cancelled)
        let cancellationCount = await runner.cancellationCount
        XCTAssertEqual(cancellationCount, 0)
        await runner.finish(0)
        let result = try await old.value
        try FileManager.default.removeItem(at: result.workingDirectoryURL)
        let paths = await runner.paths
        XCTAssertEqual(paths, ["/fixture/old"])
    }

    private func assertCancelled(_ task: Task<DenoArchiveExtraction, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Cancellation is observed immediately, but completion requires an explicit drain.
private actor DenoDrainRunner: SubprocessRunning {
    private var continuations: [Int: CheckedContinuation<SubprocessResult, Never>] = [:]
    private var closed = false
    private var directories: [Int: URL] = [:]
    private(set) var paths: [String] = []
    private(set) var cancellationCount = 0

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        guard !closed else { throw CancellationError() }
        let index = paths.count
        paths.append(request.arguments[1])
        directories[index] = URL(fileURLWithPath: request.arguments[2])
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuations[index] = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() { cancellationCount += 1 }

    func waitForStarts(_ count: Int) async throws {
        try await waitUntil { self.paths.count >= count }
    }

    func waitForCancellation() async throws {
        try await waitUntil { self.cancellationCount > 0 }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                close()
                throw WaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct WaitTimeout: Error {}

    func close() {
        closed = true
        for index in Array(continuations.keys) { finish(index) }
    }

    func finish(_ index: Int) {
        // Model the helper's last write immediately before its drain completes.
        if let directory = directories.removeValue(forKey: index) {
            try? Data("runtime".utf8).write(to: directory.appendingPathComponent("deno"))
        }
        continuations.removeValue(forKey: index)?.resume(returning: SubprocessResult(
            terminationStatus: 0, termination: .exited,
            standardOutput: Data(), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
            duration: .milliseconds(1)
        ))
    }
}
