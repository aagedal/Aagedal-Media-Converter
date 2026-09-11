import XCTest
@testable import Aagedal_Media_Converter

final class YTDLPUpdateOwnershipTests: XCTestCase {
    func testSettingsCancellationDuringPostDownloadWorkDrainsBeforeRetry() async throws {
        let gate = UpdatePhaseGate()
        let service = YTDLPUpdateService()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            XCTFail("Update ownership did not drain within three seconds")
            await gate.close()
        }
        defer { deadline.cancel() }
        let old = Task {
            try await service.runYTDLPUpdate {
                await gate.run()
            }
        }
        try await gate.waitForStarts(1)
        // There is deliberately no URLSession download here: cancellation must
        // still reach the update while checksum/publication work is pending.
        await service.cancelDownload(.ytdlp)
        let queued = Task {
            try await service.runYTDLPUpdate { await gate.run() }
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        let replacement = Task {
            try await service.runYTDLPUpdate { await gate.run() }
        }
        try await Task.sleep(for: .milliseconds(30))
        let beforeDrain = await gate.starts
        XCTAssertEqual(beforeDrain, 1)
        await gate.finish(0)
        await assertCancelled(old)
        await assertCancelled(queued)
        try await gate.waitForStarts(2)
        await gate.finish(1)
        try await replacement.value
        let starts = await gate.starts
        XCTAssertEqual(starts, 2)
    }

    private func assertCancelled(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            XCTFail("Expected cancelled update")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor UpdatePhaseGate {
    private(set) var starts = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var closed = false

    func run() async {
        guard !closed else { return }
        let index = starts
        starts += 1
        await withCheckedContinuation { continuations[index] = $0 }
    }

    func finish(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }

    func close() {
        closed = true
        for index in Array(continuations.keys) { finish(index) }
    }

    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while starts < count {
            guard ContinuousClock.now < deadline else {
                close()
                throw WaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct WaitTimeout: Error {}
}
