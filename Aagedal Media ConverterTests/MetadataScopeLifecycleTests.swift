import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class MetadataScopeLifecycleTests: XCTestCase {
    func testC2PATimeoutRetainsAccessUntilLateProbeFinishes() async throws {
        try await verifyScopeLifetime(camera: false, cancel: false)
    }

    func testCameraTimeoutRetainsAccessUntilLateProbeFinishes() async throws {
        try await verifyScopeLifetime(camera: true, cancel: false)
    }

    func testC2PACancellationRetainsAccessUntilLateProbeFinishes() async throws {
        try await verifyScopeLifetime(camera: false, cancel: true)
    }

    func testCameraCancellationRetainsAccessUntilLateProbeFinishes() async throws {
        try await verifyScopeLifetime(camera: true, cancel: true)
    }

    private func verifyScopeLifetime(camera: Bool, cancel: Bool) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataScope-\(UUID().uuidString).mov")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let probeStarted = expectation(description: "Probe started with independent access")
        let accessReleased = expectation(description: "Late probe released independent access")
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let scope = MetadataScopeRecorder()
        let startAccess: @Sendable (URL) -> SecurityScopedAccess = { accessedURL in
            scope.start()
            return .direct(accessedURL)
        }
        let stopAccess: @Sendable (SecurityScopedAccess) -> Void = { access in
            guard case .direct(let accessedURL) = access else {
                XCTFail("Expected worker-owned direct access")
                return
            }
            XCTAssertEqual(accessedURL, url)
            scope.stop()
            accessReleased.fulfill()
        }
        let waitForRelease: @Sendable () async -> Void = {
            XCTAssertEqual(scope.counts.started, 1)
            XCTAssertEqual(scope.counts.stopped, 0)
            await withCheckedContinuation { continuation in
                probeStarted.fulfill()
                DispatchQueue.global(qos: .utility).async {
                    _ = releaseProbe.wait(timeout: .now() + 10)
                    continuation.resume()
                }
            }
        }
        let timeout: Duration = cancel ? .seconds(10) : .seconds(1)
        let task = Task {
            if camera {
                return await VideoFileUtils.fetchCameraMetadata(
                    for: url,
                    timeout: timeout,
                    startAccess: startAccess,
                    stopAccess: stopAccess,
                    metadataProbe: { _ in
                        await waitForRelease()
                        return nil
                    }
                ) == nil
            }
            return await VideoFileUtils.fetchC2PAMetadata(
                for: url,
                timeout: timeout,
                startAccess: startAccess,
                stopAccess: stopAccess,
                metadataProbe: { _ in
                    await waitForRelease()
                    return nil
                }
            ) == nil
        }
        await fulfillment(of: [probeStarted], timeout: 3)
        let start = ContinuousClock.now
        if cancel { task.cancel() }
        let returnedNil = await task.value
        XCTAssertTrue(returnedNil)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(scope.counts.started, 1)
        XCTAssertEqual(scope.counts.stopped, 0, "Returning must not revoke a late parser's access")

        releaseProbe.signal()
        await fulfillment(of: [accessReleased], timeout: 3)
        XCTAssertEqual(scope.counts.stopped, 1)
    }
}

private final class MetadataScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0

    var counts: (started: Int, stopped: Int) {
        lock.withLock { (started, stopped) }
    }

    func start() { lock.withLock { started += 1 } }
    func stop() { lock.withLock { stopped += 1 } }
}
