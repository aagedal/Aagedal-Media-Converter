import XCTest
import os
@testable import Aagedal_Media_Converter

final class WatchFolderPollingTests: XCTestCase {
    func testCancelledMonitorCannotResumeWhenReplacementStarts() async {
        let oldWaiting = expectation(description: "Old monitor suspended")
        let replacementWaiting = expectation(description: "Replacement monitor suspended")
        let oldGate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let replacementGate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let oldScans = OSAllocatedUnfairLock(initialState: 0)
        let replacementScans = OSAllocatedUnfairLock(initialState: 0)
        let old = Task {
            await WatchFolderPollingLoop.run(wait: {
                await withCheckedContinuation { continuation in
                    oldGate.withLock { $0 = continuation }
                    oldWaiting.fulfill()
                }
            }, scan: {
                oldScans.withLock { $0 += 1 }
                return true
            })
        }
        await fulfillment(of: [oldWaiting], timeout: 2)
        old.cancel()
        let replacement = Task {
            await WatchFolderPollingLoop.run(wait: {
                await withCheckedContinuation { continuation in
                    replacementGate.withLock { $0 = continuation }
                    replacementWaiting.fulfill()
                }
            }, scan: {
                replacementScans.withLock { $0 += 1 }
                return true
            })
        }
        await fulfillment(of: [replacementWaiting], timeout: 2)
        // Simulate a delay returning successfully despite cancellation. Only the
        // replacement is permitted to remain active after this old callback.
        oldGate.withLock { $0?.resume(); $0 = nil }
        await old.value
        XCTAssertEqual(oldScans.withLock { $0 }, 1)
        XCTAssertEqual(replacementScans.withLock { $0 }, 1)
        XCTAssertFalse(replacement.isCancelled)
        replacement.cancel()
        replacementGate.withLock { $0?.resume(); $0 = nil }
        await replacement.value
    }

    func testCancellationDuringScanSkipsPollingDelay() async {
        let scanning = expectation(description: "Scan suspended")
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)
        let task = Task {
            await WatchFolderPollingLoop.run(wait: {
                XCTFail("A cancelled scan must not schedule another delay")
            }, scan: {
                await withCheckedContinuation { continuation in
                    gate.withLock { $0 = continuation }
                    scanning.fulfill()
                }
            })
        }
        await fulfillment(of: [scanning], timeout: 2)
        task.cancel()
        gate.withLock { $0?.resume(returning: true); $0 = nil }
        await task.value
    }

    func testPollingDelayFailureEndsMonitor() async {
        enum DelayFailure: Error { case interrupted }
        let scans = OSAllocatedUnfairLock(initialState: 0)
        await WatchFolderPollingLoop.run(wait: { throw DelayFailure.interrupted }, scan: {
            scans.withLock { $0 += 1 }
            return true
        })
        XCTAssertEqual(scans.withLock { $0 }, 1)
    }
}
