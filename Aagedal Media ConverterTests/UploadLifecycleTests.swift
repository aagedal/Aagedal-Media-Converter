import Foundation
import SwiftUI
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class UploadLifecycleTests: XCTestCase {
    func testImmediateCancellationNeverStartsService() async throws {
        let service = ControlledUploadService()
        let manager = makeManager(service: service)
        var items = [makeItem()]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })

        let task = try XCTUnwrap(manager.startUpload(itemID: items[0].id))
        await manager.cancelUpload(itemID: items[0].id)
        await task.value

        let starts = await service.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(items[0].uploadStatus, .cancelled)
        XCTAssertNil(items[0].uploadOperationID)
    }

    func testRetryDrainsOldServiceAndRejectsItsLateCallbacks() async throws {
        let firstStarted = expectation(description: "First upload started")
        let retryStarted = expectation(description: "Retry started after old upload drained")
        let firstCancelled = expectation(description: "First upload cancellation requested")
        let service = ControlledUploadService(started: [firstStarted, retryStarted], cancelled: [firstCancelled])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })

        let first = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [firstStarted], timeout: 2)
        let retry = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [firstCancelled], timeout: 2)
        XCTAssertEqual(items[0].uploadStatus, .pending)
        await service.emitProgress(run: 0, value: 0.8, speed: "Old speed")
        await service.finish(run: 0, remotePath: "/old.mov")
        await first.value
        await fulfillment(of: [retryStarted], timeout: 2)
        XCTAssertEqual(items[0].uploadProgress, 0)
        XCTAssertNil(items[0].uploadSpeed)

        await service.finish(run: 1, remotePath: "/new.mov")
        await retry.value
        await service.emitProgress(run: 0, value: 0.2, speed: "Late speed")
        await Task.yield()
        let maxConcurrent = await service.maximumConcurrentRuns
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(items[0].uploadStatus, .uploaded)
        XCTAssertEqual(items[0].uploadedRemotePath, "/new.mov")
        XCTAssertEqual(items[0].uploadProgress, 1)
        XCTAssertNil(items[0].uploadSpeed)
        XCTAssertNil(items[0].uploadOperationID)
    }

    func testInvalidRetryCancelsPreviousAttemptBeforeReportingConfigurationFailure() async throws {
        let started = expectation(description: "Upload started")
        let cancelled = expectation(description: "Old upload cancelled despite invalid retry")
        let service = ControlledUploadService(started: [started], cancelled: [cancelled])
        var config: UploadConfig? = Self.config
        let manager = UploadManager(
            rcloneService: service, configurationProvider: { config }, rcloneAvailability: { true }
        )
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })

        let first = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [started], timeout: 2)
        config = nil
        XCTAssertNil(manager.startUpload(itemID: itemID))
        await fulfillment(of: [cancelled], timeout: 2)
        await service.emitProgress(run: 0, value: 1, speed: "Old speed")
        await service.finish(run: 0)
        await first.value

        XCTAssertEqual(items[0].uploadStatus, .failed("Upload not configured"))
        XCTAssertEqual(items[0].uploadProgress, 0)
        XCTAssertNil(items[0].uploadedRemotePath)
        XCTAssertNil(items[0].uploadOperationID)
    }

    func testConversionTeardownWaitsForCancelledUploadAndRejectsLateSuccess() async throws {
        let started = expectation(description: "Upload started")
        let cancelled = expectation(description: "Upload cancellation requested")
        let service = ControlledUploadService(started: [started], cancelled: [cancelled])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        let task = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [started], timeout: 2)
        var teardownReturned = false
        let teardown = Task {
            await manager.cancelUploadBeforeConversion(itemID: itemID)
            teardownReturned = true
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(teardownReturned)
        XCTAssertEqual(items[0].uploadStatus, .cancelled)
        XCTAssertNil(items[0].uploadOperationID)

        await service.finish(run: 0)
        await teardown.value
        await task.value
        XCTAssertTrue(teardownReturned)
        XCTAssertEqual(items[0].uploadStatus, .cancelled)
        XCTAssertNil(items[0].uploadedRemotePath)
    }

    func testSamePathConversionResetRejectsOldUploadCompletion() async throws {
        let started = expectation(description: "Upload started")
        let service = ControlledUploadService(started: [started])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        let task = try XCTUnwrap(manager.startUpload(itemID: items[0].id))
        await fulfillment(of: [started], timeout: 2)

        items[0].resetConversionState()
        items[0].status = .done
        await service.finish(run: 0)
        await task.value

        XCTAssertEqual(items[0].uploadStatus, .notQueued)
        XCTAssertNil(items[0].uploadedRemotePath)
        XCTAssertNil(items[0].uploadOperationID)
    }

    func testChangedOutputCannotReceiveOldUploadCompletion() async throws {
        let started = expectation(description: "Upload started")
        let service = ControlledUploadService(started: [started])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        let task = try XCTUnwrap(manager.startUpload(itemID: items[0].id))
        await fulfillment(of: [started], timeout: 2)

        items[0].outputURL = URL(fileURLWithPath: "/fixture/replacement.mov")
        await service.finish(run: 0)
        await task.value

        XCTAssertEqual(items[0].uploadStatus, .cancelled)
        XCTAssertNil(items[0].uploadOperationID)
        XCTAssertNil(items[0].uploadedRemotePath)
    }

    func testDisablingSourceUploadDoesNotLeaveItsRowActiveAfterCompletion() async throws {
        let started = expectation(description: "Source upload started")
        let service = ControlledUploadService(started: [started])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        items[0].uploadSourceFile = true
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        let task = try XCTUnwrap(manager.startUpload(itemID: items[0].id))
        await fulfillment(of: [started], timeout: 2)

        items[0].uploadSourceFile = false
        await service.finish(run: 0)
        await task.value

        XCTAssertEqual(items[0].uploadStatus, .cancelled)
        XCTAssertEqual(items[0].uploadProgress, 0)
        XCTAssertNil(items[0].uploadSpeed)
        XCTAssertNil(items[0].uploadOperationID)
        XCTAssertNil(items[0].uploadedRemotePath)
    }

    func testSourceReplacementPreservesUploadButConversionWaitsForOldOutputReader() async throws {
        let outputStarted = expectation(description: "Output upload started")
        let sourceStarted = expectation(description: "Source replacement started")
        let outputCancelled = expectation(description: "Output upload cancellation requested")
        let service = ControlledUploadService(started: [outputStarted, sourceStarted], cancelled: [outputCancelled])
        let manager = makeManager(service: service)
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        let outputTask = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [outputStarted], timeout: 2)

        items[0].uploadSourceFile = true
        let sourceTask = try XCTUnwrap(manager.startUpload(itemID: itemID))
        await fulfillment(of: [outputCancelled], timeout: 2)
        items[0].resetConversionState()
        var drained = false
        let teardownStarted = expectation(description: "Conversion teardown started")
        let teardown = Task {
            teardownStarted.fulfill()
            await manager.cancelUploadBeforeConversion(itemID: itemID)
            drained = true
        }
        await fulfillment(of: [teardownStarted], timeout: 2)
        XCTAssertFalse(drained)
        await service.finish(run: 0)
        await outputTask.value
        await teardown.value
        XCTAssertTrue(drained)
        await fulfillment(of: [sourceStarted], timeout: 2)
        await service.finish(run: 1, remotePath: "/source.mov")
        await sourceTask.value

        XCTAssertEqual(items[0].uploadStatus, .uploaded)
        XCTAssertEqual(items[0].uploadedRemotePath, "/source.mov")
        XCTAssertNil(items[0].uploadOperationID)
    }

    func testManagerReleaseCancelsServiceWithoutWaitingForItToReturn() async throws {
        let started = expectation(description: "Upload started")
        let cancelled = expectation(description: "Deinit cancelled service")
        let service = ControlledUploadService(started: [started], cancelled: [cancelled])
        var manager: UploadManager? = makeManager(service: service)
        var items = [makeItem()]
        manager?.videoItems = Binding(get: { items }, set: { items = $0 })
        let task = try XCTUnwrap(manager?.startUpload(itemID: items[0].id))
        await fulfillment(of: [started], timeout: 2)
        weak var releasedManager = manager

        manager = nil
        XCTAssertNil(releasedManager)
        await fulfillment(of: [cancelled], timeout: 2)
        await service.finish(run: 0)
        await task.value
    }

    private func makeManager(service: ControlledUploadService) -> UploadManager {
        UploadManager(
            rcloneService: service,
            configurationProvider: { Self.config },
            rcloneAvailability: { true }
        )
    }

    private static var config: UploadConfig {
        UploadConfig(server: "fixture", port: 22, username: "editor", backendType: .sftp, sftpKeyFilePath: "/fixture/key")
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/source.mov"), name: "source.mov", size: 0,
            duration: "00:00:10", durationSeconds: 10, status: .done,
            progress: 1, eta: nil, outputURL: URL(fileURLWithPath: "/fixture/output.mov")
        )
    }
}

/// Deliberately delays draining and returns success even after cancellation, so the
/// manager must own terminal publication independently of a cooperative service.
private actor ControlledUploadService: RcloneUploading {
    private struct Run {
        let continuation: CheckedContinuation<UploadResult, Never>
        let progress: @Sendable (Double, String?) -> Void
    }

    private let started: [XCTestExpectation]
    private let cancelled: [XCTestExpectation]
    private var runs: [Run] = []
    private var activeRuns: Set<Int> = []
    private(set) var maximumConcurrentRuns = 0
    var startCount: Int { runs.count }

    init(started: [XCTestExpectation] = [], cancelled: [XCTestExpectation] = []) {
        self.started = started
        self.cancelled = cancelled
    }

    func upload(localFile: URL, config: UploadConfig, progress: @escaping @Sendable (Double, String?) -> Void) async throws -> UploadResult {
        let index = runs.count
        let cancellation = cancelled.indices.contains(index) ? cancelled[index] : nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runs.append(Run(continuation: continuation, progress: progress))
                activeRuns.insert(index)
                maximumConcurrentRuns = max(maximumConcurrentRuns, activeRuns.count)
                if started.indices.contains(index) { started[index].fulfill() }
            }
        } onCancel: {
            cancellation?.fulfill()
        }
    }

    func testConnection(config: UploadConfig) async throws -> Bool { true }

    func emitProgress(run: Int, value: Double, speed: String?) {
        runs[run].progress(value, speed)
    }

    func finish(run: Int, remotePath: String = "/fixture/upload.mov") {
        guard activeRuns.remove(run) != nil else { return }
        runs[run].continuation.resume(returning: .success(remotePath: remotePath, bytes: 100, duration: 1))
    }
}

final class RcloneCancellationBoundaryTests: XCTestCase {
    func testCancelledUploadResolutionCannotLaunchRunner() async throws {
        let started = expectation(description: "Resolving upload binary")
        let resolver = SuspendedRcloneResolver(started: started)
        let runner = CancellationIgnoringRcloneRunner()
        let service = RcloneService(updateService: resolver, subprocessRunner: runner)
        let task = Task {
            try await service.upload(localFile: URL(fileURLWithPath: "/fixture/source.mov"), config: config) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await resolver.finish(path: "/fixture/rclone")
        do {
            _ = try await task.value
            XCTFail("Cancelled binary resolution must not start an upload")
        } catch is CancellationError {
            // Expected even when the resolver itself ignores cancellation.
        }
        let starts = await runner.startCount
        XCTAssertEqual(starts, 0)
    }

    func testCancelledConnectionResolutionDoesNotBecomeMissingBinaryFailure() async throws {
        let started = expectation(description: "Resolving connection-test binary")
        let resolver = SuspendedRcloneResolver(started: started)
        let runner = CancellationIgnoringRcloneRunner()
        let service = RcloneService(updateService: resolver, subprocessRunner: runner)
        let task = Task { try await service.testConnection(config: config) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await resolver.finish(path: nil)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation wins over the missing-binary result from the resolver.
        }
        let starts = await runner.startCount
        XCTAssertEqual(starts, 0)
    }

    func testCancelledRunnerSuccessCannotPublishUploadConnectionOrObscureSuccess() async throws {
        for operation in 0..<3 {
            let started = expectation(description: "Runner started operation \(operation)")
            let runner = CancellationIgnoringRcloneRunner(started: started)
            let service = RcloneService(
                updateService: ImmediateRcloneResolver(), subprocessRunner: runner,
                isFileReadable: { _ in true }
            )
            let progress = BoundaryProgressRecorder()
            let task = Task {
                switch operation {
                case 0:
                    _ = try await service.upload(
                        localFile: URL(fileURLWithPath: "/fixture/source.mov"), config: config
                    ) { _, _ in progress.record() }
                case 1:
                    _ = try await service.testConnection(config: config)
                default:
                    _ = try await service.obscurePassword("fixture-password", rclonePath: "/fixture/rclone")
                }
            }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            await runner.finish()
            do {
                try await task.value
                XCTFail("Operation \(operation) published success after cancellation")
            } catch is CancellationError {
                // The service must check cancellation even if the runner returns success.
            }
            XCTAssertEqual(progress.count, 0)
        }
    }
}

private let config = UploadConfig(
    server: "fixture", port: 22, username: "editor", backendType: .sftp,
    sftpKeyFilePath: "/fixture/key"
)

private actor SuspendedRcloneResolver: RcloneUpdating {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String?, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func resolveRclonePath() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(path: String?) {
        continuation?.resume(returning: path)
        continuation = nil
    }
}

private struct ImmediateRcloneResolver: RcloneUpdating {
    func resolveRclonePath() async -> String? { "/fixture/rclone" }
}

private actor CancellationIgnoringRcloneRunner: SubprocessRunning {
    let started: XCTestExpectation?
    private(set) var startCount = 0
    private(set) var lastRequest: SubprocessRequest?
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation? = nil) { self.started = started }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        startCount += 1
        lastRequest = request
        // Unexpected calls in resolution tests fail promptly instead of hanging.
        if let started {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data("obscured\n".utf8),
            standardError: Data(), discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0,
            duration: .milliseconds(1)
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private final class BoundaryProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

final class RcloneScopeLifetimeTests: XCTestCase {
    func testUploadScopesRemainOwnedUntilCancelledRunnerDrains() async throws {
        let started = expectation(description: "Upload running with file and key scopes")
        let runner = CancellationIgnoringRcloneRunner(started: started)
        let localFile = URL(fileURLWithPath: "/fixture/source.mov")
        let keyFile = URL(fileURLWithPath: "/fixture/key")
        let parent = localFile.deletingLastPathComponent()
        let scopes = UploadScopeRecorder(available: [parent, keyFile])
        let service = makeService(runner: runner, scopes: scopes)
        let task = Task {
            try await service.upload(localFile: localFile, config: config) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(scopes.requested, [localFile, parent, keyFile])
        XCTAssertEqual(scopes.activeCount, 2)
        task.cancel()
        XCTAssertTrue(scopes.released.isEmpty, "Requesting cancellation must not revoke the running process's access")

        await runner.finish()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after the runner has drained.
        }
        XCTAssertEqual(scopes.activeCount, 0)
        XCTAssertEqual(scopes.released, [keyFile, parent])
    }

    func testUploadRunnerFailureReleasesBothFileAndKeyScopes() async throws {
        let localFile = URL(fileURLWithPath: "/fixture/source.mov")
        let keyFile = URL(fileURLWithPath: "/fixture/key")
        let scopes = UploadScopeRecorder(available: [localFile, keyFile])
        let service = RcloneService(
            updateService: ImmediateRcloneResolver(),
            subprocessRunner: FailingScopeRunner(),
            startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) },
            resolveBookmark: { _ in nil }, isFileReadable: { _ in true }
        )
        do {
            _ = try await service.upload(localFile: localFile, config: config) { _, _ in }
            XCTFail("Expected failure")
        } catch let error as UploadError {
            guard case .uploadFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(scopes.requested, [localFile, keyFile])
        XCTAssertEqual(scopes.released, [keyFile, localFile])
        XCTAssertEqual(scopes.activeCount, 0)
    }

    func testConnectionOwnsOnlyItsSFTPKeyScopeUntilCompletion() async throws {
        let started = expectation(description: "Connection test running with key scope")
        let runner = CancellationIgnoringRcloneRunner(started: started)
        let keyFile = URL(fileURLWithPath: "/fixture/key")
        let scopes = UploadScopeRecorder(available: [keyFile])
        let service = makeService(runner: runner, scopes: scopes)
        let task = Task { try await service.testConnection(config: config) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(scopes.requested, [keyFile])
        XCTAssertEqual(scopes.activeCount, 1)
        XCTAssertTrue(scopes.released.isEmpty)
        await runner.finish()
        let succeeded = try await task.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(scopes.activeCount, 0)
        XCTAssertEqual(scopes.released, [keyFile])
    }

    func testAccessibleFilesWithoutSecurityScopesStillUpload() async throws {
        let scopes = UploadScopeRecorder(available: [])
        let service = makeService(runner: CancellationIgnoringRcloneRunner(), scopes: scopes)
        let result = try await service.upload(
            localFile: URL(fileURLWithPath: "/fixture/source.mov"), config: config
        ) { _, _ in }
        XCTAssertTrue(result.success)
        XCTAssertEqual(scopes.activeCount, 0)
        XCTAssertTrue(scopes.released.isEmpty)
    }

    func testMovedBookmarkedKeyUsesResolvedPathAndKeepsScopeUntilCancellationDrains() async throws {
        let started = expectation(description: "Upload reads the moved key")
        let runner = CancellationIgnoringRcloneRunner(started: started)
        let localFile = URL(fileURLWithPath: "/fixture/source.mov")
        let originalKey = URL(fileURLWithPath: "/fixture/key")
        let movedKey = URL(fileURLWithPath: "/moved/key")
        let scopes = UploadScopeRecorder(available: [localFile, movedKey])
        let service = RcloneService(
            updateService: ImmediateRcloneResolver(), subprocessRunner: runner,
            startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) },
            resolveBookmark: { url in
                XCTAssertEqual(url, originalKey)
                return movedKey
            },
            isFileReadable: { url in
                XCTAssertEqual(url, movedKey)
                XCTAssertEqual(scopes.activeCount, 2)
                return true
            }
        )
        let task = Task { try await service.upload(localFile: localFile, config: config) { _, _ in } }
        await fulfillment(of: [started], timeout: 2)
        let request = await runner.lastRequest
        XCTAssertEqual(request?.environment?["RCLONE_CONFIG_UPLOAD_KEY_FILE"], movedKey.path)
        XCTAssertFalse(request?.redactedDiagnostic("Key: \(movedKey.path)").contains(movedKey.path) ?? true)
        XCTAssertEqual(scopes.requested, [localFile, movedKey])
        task.cancel()
        XCTAssertTrue(scopes.released.isEmpty)
        await runner.finish()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(scopes.released, [movedKey, localFile])
        XCTAssertEqual(scopes.activeCount, 0)
    }

    func testUnreadableKeyFailsBeforeLaunchAndReleasesAcquiredScopes() async throws {
        for isConnectionTest in [false, true] {
            let runner = CancellationIgnoringRcloneRunner()
            let localFile = URL(fileURLWithPath: "/fixture/source.mov")
            let keyFile = URL(fileURLWithPath: "/fixture/key")
            let scopes = UploadScopeRecorder(available: [localFile, keyFile])
            let service = RcloneService(
                updateService: ImmediateRcloneResolver(), subprocessRunner: runner,
                startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) },
                resolveBookmark: { _ in nil }, isFileReadable: { _ in false }
            )
            do {
                if isConnectionTest {
                    _ = try await service.testConnection(config: config)
                } else {
                    _ = try await service.upload(localFile: localFile, config: config) { _, _ in }
                }
                XCTFail("Expected an actionable key-access failure")
            } catch let error as UploadError {
                guard case .sshKeyAccessDenied = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertFalse(error.localizedDescription.contains(keyFile.path))
            }
            let starts = await runner.startCount
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(scopes.released, isConnectionTest ? [keyFile] : [keyFile, localFile])
            XCTAssertEqual(scopes.activeCount, 0)
        }
    }

    func testLegacyKeyCanUseExistingParentFolderAccess() async throws {
        let keyFile = URL(fileURLWithPath: "/fixture/key")
        let parent = keyFile.deletingLastPathComponent()
        let scopes = UploadScopeRecorder(available: [parent])
        let runner = CancellationIgnoringRcloneRunner()
        let service = RcloneService(
            updateService: ImmediateRcloneResolver(), subprocessRunner: runner,
            startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) },
            resolveBookmark: { _ in nil },
            isFileReadable: { _ in scopes.activeCount == 1 }
        )
        let succeeded = try await service.testConnection(config: config)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(scopes.requested, [keyFile, parent])
        XCTAssertEqual(scopes.released, [parent])
        let request = await runner.lastRequest
        XCTAssertEqual(request?.environment?["RCLONE_CONFIG_UPLOAD_KEY_FILE"], keyFile.path)
    }

    private func makeService(runner: CancellationIgnoringRcloneRunner, scopes: UploadScopeRecorder) -> RcloneService {
        RcloneService(
            updateService: ImmediateRcloneResolver(), subprocessRunner: runner,
            startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) },
            resolveBookmark: { _ in nil }, isFileReadable: { _ in true }
        )
    }
}

private struct FailingScopeRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        throw SubprocessRunnerError.failedToStart(command: request.redactedCommandDescription, underlying: "Fixture launch failure")
    }
}

private final class UploadScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let available: Set<URL>
    private var requests: [URL] = []
    private var releases: [URL] = []
    private var active = 0

    init(available: Set<URL>) { self.available = available }
    var requested: [URL] { lock.withLock { requests } }
    var released: [URL] { lock.withLock { releases } }
    var activeCount: Int { lock.withLock { active } }

    func start(_ url: URL) -> SecurityScopedAccess {
        lock.withLock {
            requests.append(url)
            guard available.contains(url) else { return .none }
            active += 1
            return .bookmark(url)
        }
    }

    func stop(_ access: SecurityScopedAccess) {
        lock.withLock {
            switch access {
            case .bookmark(let url), .direct(let url):
                active -= 1
                releases.append(url)
            case .none:
                break
            }
        }
    }
}
