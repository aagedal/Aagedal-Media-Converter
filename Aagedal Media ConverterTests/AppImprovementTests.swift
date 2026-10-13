import XCTest
import os
@testable import Aagedal_Media_Converter

final class AppImprovementTests: XCTestCase {
    func testSettlingRequiresQuietSizeAndModificationTime() {
        let start = Date(timeIntervalSince1970: 100)
        let first = WatchFolderObservation(size: 100, modifiedAt: start, observedAt: start, previous: nil)
        XCTAssertFalse(first.isStable(at: start.addingTimeInterval(60), interval: 10))
        let quiet = WatchFolderObservation(size: 100, modifiedAt: start, observedAt: start.addingTimeInterval(5), previous: first)
        XCTAssertFalse(quiet.isStable(at: start.addingTimeInterval(5), interval: 10))
        XCTAssertTrue(quiet.isStable(at: start.addingTimeInterval(10), interval: 10))
        let rewritten = WatchFolderObservation(size: 100, modifiedAt: start.addingTimeInterval(10), observedAt: start.addingTimeInterval(10), previous: quiet)
        XCTAssertFalse(rewritten.isStable(at: start.addingTimeInterval(30), interval: 10))
        let growing = WatchFolderObservation(size: 200, modifiedAt: start, observedAt: start.addingTimeInterval(10), previous: quiet)
        XCTAssertFalse(growing.isStable(at: start.addingTimeInterval(30), interval: 10))
    }

    func testInvalidSettlingPreferencesUseSafeDefault() throws {
        let name = "AppImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for value in [0, -1, 10.5, Double.nan, Double.infinity] {
            defaults.set(value, forKey: AppConstants.watchFolderSettlingSecondsKey)
            XCTAssertEqual(WatchFolderObservation.settlingInterval(defaults: defaults), 10)
        }
        defaults.set(30, forKey: AppConstants.watchFolderSettlingSecondsKey)
        XCTAssertEqual(WatchFolderObservation.settlingInterval(defaults: defaults), 30)
    }

    func testCleanupKeepsQueuedAndGrowingFilesButTrashesQuietOldFile() async throws {
        enum Finished: Error { case finished }
        let name = "AppImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: name)
        }
        let queued = folder.appendingPathComponent("queued.mov")
        let growing = folder.appendingPathComponent("growing.mov")
        let quiet = folder.appendingPathComponent("quiet.mov")
        for url in [queued, growing, quiet] { try Data([1]).write(to: url) }
        defaults.set(true, forKey: AppConstants.watchFolderAutoDeleteOlderThanWeekKey)
        defaults.set(1, forKey: AppConstants.watchFolderDeleteDurationValueKey)
        defaults.set("days", forKey: AppConstants.watchFolderDeleteDurationUnitKey)
        defaults.set(folder.path, forKey: WatchFolderSelectionService.writableGrantPathKey)
        let scan = OSAllocatedUnfairLock(initialState: 0)
        let trashed = OSAllocatedUnfairLock(initialState: [URL]())
        let finished = expectation(description: "Cleanup scanned twice")
        let manager = WatchFolderManager(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), settlingInterval: 0, readinessProbe: { _ in true }, trashItem: { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }, pollingWait: {
            let count = scan.withLock { $0 += 1; return $0 }
            if count == 2 { finished.fulfill(); throw Finished.finished }
        }, readResourceValues: { url in
            var values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            values.creationDate = Date(timeIntervalSince1970: 0)
            values.contentModificationDate = Date(timeIntervalSince1970: url == growing ? Double(scan.withLock { $0 }) : 0)
            return values
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { _ in
            XCTFail("Old cleanup candidates must not be imported")
        }, protectedFiles: { [queued] })
        await fulfillment(of: [finished], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(trashed.withLock { $0 }, [quiet])
        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: growing.path))
    }

    func testUnreadableWatchFileRetriesWithoutRepeatedAlerts() async throws {
        enum Finished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.mov")
        try Data([1]).write(to: file)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let imported = OSAllocatedUnfairLock(initialState: [URL]())
        let finished = expectation(description: "Probe eventually succeeds")
        let manager = WatchFolderManager(settlingInterval: 0, readinessProbe: { _ in
            probes.withLock { $0 += 1; return $0 >= 3 }
        }, pollingWait: {
            if !imported.withLock({ $0.isEmpty }) { finished.fulfill(); throw Finished.finished }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            imported.withLock { $0.append(contentsOf: urls) }
        }, onError: { message in errors.withLock { $0.append(message) } })
        await fulfillment(of: [finished], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(imported.withLock { $0 }, [file])
        XCTAssertEqual(probes.withLock { $0 }, 3)
        XCTAssertEqual(errors.withLock { $0.count }, 1)
    }

    func testSlowReadinessProbeDoesNotDelayHealthyImport() async throws {
        enum Finished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let slow = folder.appendingPathComponent("slow.mov")
        let healthy = folder.appendingPathComponent("healthy.mov")
        for url in [slow, healthy] { try Data([1]).write(to: url) }
        let gate = ReadinessProbeGate()
        let imported = expectation(description: "Healthy import arrives while slow probe is blocked")
        let manager = WatchFolderManager(settlingInterval: 0, readinessProbe: { url in
            if url == slow { await gate.wait(); return false }
            return true
        }, pollingWait: {
            if await gate.isOpen { throw Finished.finished }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            XCTAssertEqual(urls, [healthy])
            imported.fulfill()
        })
        await fulfillment(of: [imported], timeout: 3)
        let slowFinished = await gate.isOpen
        XCTAssertFalse(slowFinished)
        await manager.stopMonitoring(generation: 2)
        await gate.release()
    }

    func testDiagnosticUsesBoundedRunnerAndMatchesReplyID() async throws {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": [
            "isError": false,
            "structuredContent": ["presets": ApplicationPresetID.allCases.map { ["id": $0.rawValue] }]
        ]]
        let data = try JSONSerialization.data(withJSONObject: response) + Data("\n{\"id\":1,\"result\":{}}\n".utf8)
        let runner = DiagnosticRunner(output: data)
        let succeeded = try await ApplicationAgentMCPConnectionDiagnostic.test(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        XCTAssertTrue(succeeded)
        let captured = await runner.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.timeout, .seconds(15))
        let messages = try XCTUnwrap(request.standardInput).split(separator: 0x0A)
        XCTAssertEqual(messages.count, 3)
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[2])) as? [String: Any])
        XCTAssertEqual(call["method"] as? String, "tools/call")
    }

    func testDiagnosticRejectsTruncatedOutput() async throws {
        let runner = DiagnosticRunner(output: Data(), discarded: 1)
        let succeeded = try await ApplicationAgentMCPConnectionDiagnostic.test(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        XCTAssertFalse(succeeded)
    }
}

private actor DiagnosticRunner: SubprocessRunning {
    var request: SubprocessRequest?
    let output: Data
    let discarded: Int

    init(output: Data, discarded: Int = 0) {
        self.output = output
        self.discarded = discarded
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        self.request = request
        return SubprocessResult(terminationStatus: 0, termination: .exited, standardOutput: output, standardError: Data(), discardedStandardOutputBytes: discarded, discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor ReadinessProbeGate {
    var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
