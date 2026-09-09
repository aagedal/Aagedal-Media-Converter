import XCTest
import os
@testable import Aagedal_Media_Converter

final class WatchFolderPollingTests: XCTestCase {
    func testMissingDirectoryReportsOnceAndReportsAgainAfterRecovery() async throws {
        enum PollingFinished: Error { case finished }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("watch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = expectation(description: "Missing, repeated, recovered, and missing scans completed")
        let scanCount = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let manager = WatchFolderManager(pollingWait: {
            let count = scanCount.withLock { value in
                value += 1
                return value
            }
            switch count {
            case 2:
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            case 3:
                try FileManager.default.removeItem(at: folder)
            case 4:
                completed.fulfill()
                throw PollingFinished.finished
            default:
                break
            }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { _ in
            XCTFail("An empty or missing folder must not import files")
        }, onError: { message in
            errors.withLock { $0.append(message) }
        })
        await fulfillment(of: [completed], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        let messages = errors.withLock { $0 }
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    func testDirectoryFailureRequiresTwoSuccessfulScansAfterRecovery() async throws {
        enum PollingFinished: Error { case finished }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("watch")
        let disconnected = root.appendingPathComponent("disconnected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data([1]).write(to: file)
        let completed = expectation(description: "Directory failure and recovery scanned")
        let scan = OSAllocatedUnfairLock(initialState: 1)
        let imports = OSAllocatedUnfairLock(initialState: [(Int, [URL])]())
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let manager = WatchFolderManager(pollingWait: {
            let count = scan.withLock { value in
                defer { value += 1 }
                return value
            }
            switch count {
            case 1:
                try FileManager.default.moveItem(at: folder, to: disconnected)
            case 2:
                try FileManager.default.moveItem(at: disconnected, to: folder)
            case 4:
                completed.fulfill()
                throw PollingFinished.finished
            default:
                break
            }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            let count = scan.withLock { $0 }
            imports.withLock { $0.append((count, urls)) }
        }, onError: { message in
            errors.withLock { $0.append(message) }
        })
        await fulfillment(of: [completed], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(errors.withLock { $0.count }, 1)
        let imported = imports.withLock { $0 }
        XCTAssertEqual(imported.map { $0.0 }, [4])
        XCTAssertEqual(imported.flatMap { $0.1 }, [file])
    }

    func testMetadataFailuresRetryWithoutBlockingHealthyFilesAndResetStability() async throws {
        enum PollingFinished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let affected = folder.appendingPathComponent("affected.mov")
        let healthy = folder.appendingPathComponent("healthy.mov")
        try Data([1]).write(to: affected)
        try Data([1]).write(to: healthy)
        let completed = expectation(description: "Metadata failures and recovery scanned")
        let scan = OSAllocatedUnfairLock(initialState: 1)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let imports = OSAllocatedUnfairLock(initialState: [(Int, [URL])]())
        let manager = WatchFolderManager(pollingWait: {
            let count = scan.withLock { value in
                defer { value += 1 }
                return value
            }
            if count == 7 {
                completed.fulfill()
                throw PollingFinished.finished
            }
        }, readResourceValues: { url in
            let count = scan.withLock { $0 }
            if url == affected, [2, 3, 5].contains(count) {
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            let count = scan.withLock { $0 }
            imports.withLock { $0.append((count, urls)) }
        }, onError: { message in
            errors.withLock { $0.append(message) }
        })
        await fulfillment(of: [completed], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(errors.withLock { $0.count }, 2)
        XCTAssertTrue(errors.withLock { $0.allSatisfy { $0.contains("affected.mov") } })
        let imported = imports.withLock { $0 }
        XCTAssertEqual(imported.filter { $0.1.contains(affected) }.map { $0.0 }, [7])
        XCTAssertTrue(imported.contains { $0.0 == 2 && $0.1.contains(healthy) })
    }

    func testMissingMetadataIsReportedOnceWithBoundedDetails() async throws {
        enum PollingFinished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<7 {
            try Data([1]).write(to: folder.appendingPathComponent("clip-\(index).mov"))
        }
        let completed = expectation(description: "Incomplete metadata retried")
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let manager = WatchFolderManager(pollingWait: {
            let count = scans.withLock { value in value += 1; return value }
            if count == 2 {
                completed.fulfill()
                throw PollingFinished.finished
            }
        }, readResourceValues: { _ in
            URLResourceValues()
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { _ in
            XCTFail("Files without a known size must not be imported")
        }, onError: { message in
            errors.withLock { $0.append(message) }
        })
        await fulfillment(of: [completed], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        let messages = errors.withLock { $0 }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.components(separatedBy: ".mov:").count, 6)
    }

    func testMetadataFailureStateIsIndependentAndClearedForRemovedFiles() {
        let url = URL(fileURLWithPath: "/watch/affected.mov")
        var failures = WatchFolderFailureTracker()
        XCTAssertTrue(failures.shouldReportMetadataFailure(for: url))
        XCTAssertFalse(failures.shouldReportMetadataFailure(for: url))
        XCTAssertTrue(failures.shouldReportCleanupFailure(for: url))
        failures.scanSucceeded(currentFiles: [url])
        XCTAssertFalse(failures.shouldReportMetadataFailure(for: url))
        failures.metadataSucceeded(for: url)
        XCTAssertTrue(failures.shouldReportMetadataFailure(for: url))
        failures.scanSucceeded(currentFiles: [])
        XCTAssertTrue(failures.shouldReportMetadataFailure(for: url))
    }

    func testScanFailureIsReportedOnceUntilRecovery() {
        var failures = WatchFolderFailureTracker()
        XCTAssertTrue(failures.shouldReportScanFailure())
        XCTAssertFalse(failures.shouldReportScanFailure())
        failures.scanSucceeded(currentFiles: [])
        XCTAssertTrue(failures.shouldReportScanFailure())
    }

    func testCleanupFailuresAreDeduplicatedIndependentlyAndResetAfterRecovery() {
        let first = URL(fileURLWithPath: "/watch/first.mov")
        let second = URL(fileURLWithPath: "/watch/second.mov")
        var failures = WatchFolderFailureTracker()
        XCTAssertTrue(failures.shouldReportCleanupFailure(for: first))
        XCTAssertFalse(failures.shouldReportCleanupFailure(for: first))
        XCTAssertTrue(failures.shouldReportCleanupFailure(for: second))
        failures.scanSucceeded(currentFiles: [first, second])
        XCTAssertFalse(failures.shouldReportCleanupFailure(for: first))
        failures.cleanupSucceeded(for: first)
        XCTAssertTrue(failures.shouldReportCleanupFailure(for: first))
        failures.scanSucceeded(currentFiles: [first])
        XCTAssertTrue(failures.shouldReportCleanupFailure(for: second))
    }

    @MainActor
    func testFailedReplacementStopsPriorMonitorAndPreservesErrorWhenDisabled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanned = expectation(description: "Initial watch session scanned")
        let manager = WatchFolderManager(pollingWait: {
            scanned.fulfill()
            try await Task.sleep(for: .seconds(30))
        })
        let coordinator = WatchFolderCoordinator(manager: manager)
        let started = await coordinator.enableWatchMode(currentPath: folder.path, promptForFolder: { nil }, updatePath: { _ in }, onNewFiles: { _ in })
        XCTAssertTrue(started)
        await fulfillment(of: [scanned], timeout: 3)
        let replacement = await coordinator.enableWatchMode(currentPath: folder.appendingPathComponent("missing").path, promptForFolder: { nil }, updatePath: { _ in }, onNewFiles: { _ in })
        XCTAssertFalse(replacement)
        let stillMonitoring = await manager.isCurrentlyMonitoring()
        XCTAssertFalse(stillMonitoring)
        let error = coordinator.errorMessage
        XCTAssertNotNil(error)
        // ContentView turns the toggle off after a failed enable. That cleanup
        // must preserve the error long enough for the alert to be presented.
        await coordinator.disableWatchMode()
        XCTAssertEqual(coordinator.errorMessage, error)
    }

    @MainActor
    func testDisableWhileChoosingFolderDiscardsSelection() async {
        let coordinator = WatchFolderCoordinator()
        let choosing = expectation(description: "Folder picker open")
        let gate = OSAllocatedUnfairLock<CheckedContinuation<URL?, Never>?>(initialState: nil)
        let enabling = Task { @MainActor in
            await coordinator.enableWatchMode(currentPath: "", promptForFolder: {
                await withCheckedContinuation { continuation in
                    gate.withLock { $0 = continuation }
                    choosing.fulfill()
                }
            }, updatePath: { _ in
                XCTFail("A disabled watch session must not save a late selection")
            }, onNewFiles: { _ in
                XCTFail("A disabled watch session must not import files")
            })
        }
        await fulfillment(of: [choosing], timeout: 2)
        await coordinator.disableWatchMode()
        gate.withLock { $0?.resume(returning: URL(fileURLWithPath: "/late-selection")); $0 = nil }
        let enabled = await enabling.value
        XCTAssertFalse(enabled)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testSupersededManagerCommandsCannotRestartOrStopReplacement() async {
        let manager = WatchFolderManager()
        await manager.stopMonitoring(generation: 2)
        await manager.startMonitoring(folderPath: "/missing", generation: 1, onNewFiles: { _ in })
        let stopped = await manager.isCurrentlyMonitoring()
        XCTAssertFalse(stopped)
        await manager.startMonitoring(folderPath: "/missing", generation: 3, onNewFiles: { _ in })
        await manager.stopMonitoring(generation: 2)
        let monitoring = await manager.isCurrentlyMonitoring()
        XCTAssertTrue(monitoring)
        await manager.stopMonitoring(generation: 4)
    }

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
