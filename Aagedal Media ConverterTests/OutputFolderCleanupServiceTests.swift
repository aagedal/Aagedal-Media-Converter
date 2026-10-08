import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class OutputFolderCleanupServiceTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [URL] = []
        private var stops: [URL] = []
        private var trashed: [URL] = []
        private var blockedURL: URL?
        private let firstScopeFails: Bool

        init(firstScopeFails: Bool = false) { self.firstScopeFails = firstScopeFails }

        func start(_ url: URL) -> Bool { lock.withLock { starts.append(url); return !firstScopeFails || starts.count > 1 } }
        func stop(_ url: URL) { lock.withLock { stops.append(url) } }
        func block(_ url: URL?) { lock.withLock { blockedURL = url } }
        func trash(_ url: URL) throws {
            try lock.withLock {
                if url == blockedURL { throw CocoaError(.fileWriteNoPermission) }
                // Never send test fixtures to the user's actual Trash.
                try FileManager.default.removeItem(at: url)
                trashed.append(url)
            }
        }
        var snapshot: (starts: [URL], stops: [URL], trashed: [URL]) {
            lock.withLock { (starts, stops, trashed) }
        }
    }

    private func fixture() throws -> (directory: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "OutputFolderCleanupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: AppConstants.autoDeleteOldEncodesKey)
        defaults.set(7, forKey: AppConstants.autoDeleteOldEncodesDaysKey)
        defaults.set(directory.path, forKey: "outputFolder")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return (directory, defaults)
    }

    private func writeFile(_ name: String, in directory: URL, completedAt: Date? = Date(timeIntervalSinceNow: -30 * 86_400)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("encode".utf8).write(to: url)
        if let completedAt { XCTAssertTrue(FileSafetyUtils.markCompletedOutput(url, completedAt: completedAt)) }
        return url
    }

    func testCleanupPreservesUnmarkedRecentHiddenNestedAndSymlinkFiles() async throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        let unmarked = try writeFile("unrelated.mov", in: fixture.directory, completedAt: nil)
        let recent = try writeFile("recent.mov", in: fixture.directory, completedAt: Date())
        let hidden = try writeFile(".hidden.mov", in: fixture.directory)
        let nested = fixture.directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedFile = try writeFile("nested.mov", in: nested)
        let link = fixture.directory.appendingPathComponent("linked.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nestedFile)
        let state = State()
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults, startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertEqual(state.snapshot.trashed, [old])
        for url in [unmarked, recent, hidden, nested, nestedFile, link] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(state.snapshot.starts, [fixture.directory])
        XCTAssertEqual(state.snapshot.stops, [fixture.directory])
        XCTAssertNil(service.lastError)
    }

    func testMarkerSurvivesRestartButDoesNotAuthorizeReplacementFile() async throws {
        let fixture = try fixture()
        let output = try writeFile("old.mov", in: fixture.directory)
        XCTAssertNotNil(FileSafetyUtils.completedOutputDate(output))
        let state = State()
        let replacement = try writeFile("replacement.mov", in: fixture.directory, completedAt: nil)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: replacement, to: output)
        XCTAssertNil(FileSafetyUtils.completedOutputDate(output))
        let service = OutputFolderCleanupService(defaults: fixture.defaults, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(state.snapshot.trashed.isEmpty)
    }

    func testChangedOutputIsPreservedEvenWhenItsMarkerRemains() async throws {
        let fixture = try fixture()
        let output = try writeFile("old.mov", in: fixture.directory)
        try Data("unrelated replacement content".utf8).write(to: output)
        XCTAssertNil(FileSafetyUtils.completedOutputDate(output))
        let state = State()
        let service = OutputFolderCleanupService(defaults: fixture.defaults, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(state.snapshot.trashed.isEmpty)
    }

    func testCleanupRestoresSavedBookmarkWhenDirectAccessIsUnavailable() async throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        let directory = fixture.directory
        fixture.defaults.set([directory.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        let state = State(firstScopeFails: true)
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { _ in (directory, false) }, startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertEqual(state.snapshot.starts.count, 2)
        XCTAssertEqual(state.snapshot.stops.count, 1)
        XCTAssertEqual(state.snapshot.trashed, [old])
        XCTAssertNil(service.lastError)
    }

    func testUnavailableFolderPreservesSavedGrantAndRecoversAfterReconnect() async throws {
        let fixture = try fixture()
        let folder = fixture.directory.appendingPathComponent("unavailable-output", isDirectory: true)
        fixture.defaults.set(folder.path, forKey: "outputFolder")
        let savedBookmarks = [folder.absoluteString: Data([7])]
        fixture.defaults.set(savedBookmarks, forKey: "securityScopedBookmarks")
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { _ in throw CocoaError(.fileReadNoSuchFile) }, startScope: { _ in false })
        let unavailableService = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks)
        await unavailableService.performCleanupIfNeeded()
        XCTAssertNotNil(unavailableService.lastError)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks") as? [String: Data], savedBookmarks)
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), folder.path)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let old = try writeFile("old.mov", in: folder)
        let state = State(firstScopeFails: true)
        let restoredBookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { _ in (folder, false) }, startScope: state.start, stopScope: state.stop)
        let restartedService = OutputFolderCleanupService(defaults: fixture.defaults,
            bookmarkManager: restoredBookmarks, trashItem: state.trash)
        await restartedService.performCleanupIfNeeded()
        XCTAssertNil(restartedService.lastError)
        XCTAssertEqual(state.snapshot.trashed, [old])
        XCTAssertEqual(state.snapshot.starts.count, 2)
        XCTAssertEqual(state.snapshot.stops.count, 1)
    }

    func testEnumerationFailureIsVisibleAndReleasesFolderScope() async throws {
        let fixture = try fixture()
        let file = try writeFile("not-a-folder", in: fixture.directory)
        fixture.defaults.set(file.path, forKey: "outputFolder")
        let state = State()
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults, startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertNotNil(service.lastError)
        XCTAssertEqual(state.snapshot.starts, [file])
        XCTAssertEqual(state.snapshot.stops, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMetadataFailurePreservesFileAndContinuesCleanup() async throws {
        let fixture = try fixture()
        let unreadable = try writeFile("unreadable.mov", in: fixture.directory)
        let old = try writeFile("old.mov", in: fixture.directory)
        let state = State()
        let service = OutputFolderCleanupService(defaults: fixture.defaults, readResourceValues: { url in
            if url == unreadable { throw CocoaError(.fileReadNoPermission) }
            return try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        }, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertEqual(state.snapshot.trashed, [old])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains(unreadable.lastPathComponent))
    }

    func testTrashFailureIsVisibleAndSuccessfulRetryClearsError() async throws {
        let fixture = try fixture()
        let blocked = try writeFile("blocked.mov", in: fixture.directory)
        let other = try writeFile("other.mov", in: fixture.directory)
        let state = State()
        state.block(blocked)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertEqual(state.snapshot.trashed, [other])
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains(blocked.lastPathComponent))
        state.block(nil)
        await service.performCleanupIfNeeded()
        XCTAssertNil(service.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
    }

    func testDisabledCleanupDoesNotAcquireAccessOrRemoveFiles() async throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        fixture.defaults.set(false, forKey: AppConstants.autoDeleteOldEncodesKey)
        let state = State()
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults, startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertTrue(state.snapshot.starts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testDirectorySymlinkCleanupKeepsSelectedFolderScope() async throws {
        let fixture = try fixture()
        let target = fixture.directory.appendingPathComponent("target", isDirectory: true)
        let link = fixture.directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let old = try writeFile("old.mov", in: target)
        fixture.defaults.set(link.path, forKey: "outputFolder")
        let state = State()
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults, startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks, trashItem: state.trash)

        await service.performCleanupIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(state.snapshot.starts.map(\.path), [link.path])
        XCTAssertEqual(state.snapshot.stops.map(\.path), [link.path])
        XCTAssertEqual(state.snapshot.trashed.map(\.path), [link.appendingPathComponent("old.mov").path])
        XCTAssertNil(service.lastError)
    }

    func testCleanupRunsOffMainThreadAndCoalescesConcurrentRequests() async throws {
        let fixture = try fixture()
        _ = try writeFile("old.mov", in: fixture.directory)
        let entered = expectation(description: "Background worker entered")
        let gate = DispatchSemaphore(value: 0)
        let state = State()
        let service = OutputFolderCleanupService(defaults: fixture.defaults, readResourceValues: { url in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
            return try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        }, trashItem: state.trash)
        let first = Task { await service.performCleanupIfNeeded() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(service.isCleaning)
        let second = Task { await service.performCleanupIfNeeded() }
        await Task.yield()
        gate.signal()
        await first.value
        await second.value
        XCTAssertFalse(service.isCleaning)
        XCTAssertEqual(state.snapshot.trashed.count, 1)
        XCTAssertNil(service.lastError)
    }
    func testDisablingCleanupStopsBeforeTrashingTheInspectedFile() async throws {
        try await assertInterruptedCleanup(change: .disable)
    }

    func testChangingOutputFolderStopsTheOldCleanupPass() async throws {
        try await assertInterruptedCleanup(change: .folder)
    }

    func testChangingRetentionStopsTheOldCleanupPass() async throws {
        try await assertInterruptedCleanup(change: .retention)
    }

    func testCancellingCleanupCallerStopsTheBackgroundWorkerAndReleasesScope() async throws {
        try await assertInterruptedCleanup(change: .cancel)
    }

    private enum CleanupChange { case disable, folder, retention, cancel }

    private func assertInterruptedCleanup(change: CleanupChange) async throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        let another = try writeFile("another.mov", in: fixture.directory)
        let entered = expectation(description: "Worker is inspecting an eligible output")
        let gate = DispatchSemaphore(value: 0)
        let state = State()
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: state.start, stopScope: state.stop)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            readResourceValues: { url in
                entered.fulfill()
                guard gate.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
                return try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            }, trashItem: state.trash)
        let task = Task { await service.performCleanupIfNeeded() }
        await fulfillment(of: [entered], timeout: 5)
        switch change {
        case .disable: fixture.defaults.set(false, forKey: AppConstants.autoDeleteOldEncodesKey)
        case .folder: fixture.defaults.set(fixture.directory.appendingPathComponent("new-folder").path, forKey: "outputFolder")
        case .retention: fixture.defaults.set(31, forKey: AppConstants.autoDeleteOldEncodesDaysKey)
        case .cancel: task.cancel()
        }
        gate.signal()
        await task.value
        XCTAssertTrue(state.snapshot.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: another.path))
        XCTAssertEqual(state.snapshot.starts.count, 1)
        XCTAssertEqual(state.snapshot.stops.count, 1)
        XCTAssertFalse(service.isCleaning)
        XCTAssertNil(service.lastError)
    }

}
