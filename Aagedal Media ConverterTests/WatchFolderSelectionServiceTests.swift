import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class WatchFolderSelectionServiceTests: XCTestCase {
    private func fixture() throws -> (directory: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "WatchFolderSelectionServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("/previous/watch", forKey: AppConstants.watchFolderPathKey)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return (directory, defaults)
    }

    func testMissingSelectionPreservesPreferenceAndDoesNotCreateFolderOrBookmark() throws {
        let fixture = try fixture()
        let missing = fixture.directory.appendingPathComponent("missing")
        var starts = 0
        var stops = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in XCTFail("An unavailable folder must not be saved"); return Data() },
            startScope: { _ in starts += 1; return true }, stopScope: { _ in stops += 1 })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(missing)) { error in
            guard case WatchFolderSelectionService.FolderError.unavailable = error else {
                return XCTFail("Expected unavailable-folder error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), "/previous/watch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testSelectionRejectsRegularFileAndPreservesItsContents() throws {
        let fixture = try fixture()
        let file = fixture.directory.appendingPathComponent("file.mov")
        try Data("source".utf8).write(to: file)
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in XCTFail("A file must not be saved as a watch folder"); return Data() },
            startScope: { _ in false })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(file)) { error in
            guard case WatchFolderSelectionService.FolderError.notDirectory = error else {
                return XCTFail("Expected not-a-folder error, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("source".utf8))
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), "/previous/watch")
    }

    func testFailedBookmarkPreservesPreviousSelectionAndGrant() throws {
        let fixture = try fixture()
        let previous = URL(fileURLWithPath: "/previous/watch")
        fixture.defaults.set([previous.absoluteString: Data([7])], forKey: "securityScopedBookmarks")
        var activeScopes = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in
                XCTAssertEqual(activeScopes, 2)
                throw CocoaError(.fileWriteNoPermission)
            }, startScope: { _ in activeScopes += 1; return true },
            stopScope: { _ in activeScopes -= 1 })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(fixture.directory)) { error in
            guard case WatchFolderSelectionService.FolderError.bookmark = error else {
                return XCTFail("Expected bookmark error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), previous.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks") as? [String: Data],
                       [previous.absoluteString: Data([7])])
        XCTAssertEqual(activeScopes, 0)
    }

    func testSelectionCommitsAfterWritableBookmarkSoLaterTrashCleanupRemainsAuthorized() throws {
        let fixture = try fixture()
        var activeScopes = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { url, options in
                XCTAssertEqual(url, fixture.directory)
                XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), "/previous/watch")
                XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
                XCTAssertEqual(activeScopes, 2)
                return Data([1, 2, 3])
            }, startScope: { _ in activeScopes += 1; return true },
            stopScope: { _ in activeScopes -= 1 })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        try service.select(fixture.directory)

        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), fixture.directory.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks")?[fixture.directory.absoluteString] as? Data,
                       Data([1, 2, 3]))
        XCTAssertEqual(activeScopes, 0)
    }

    func testValidationAcquiresSavedGrantBeforeReadingAndBalancesIt() throws {
        let fixture = try fixture()
        let resolvedScope = fixture.directory.appendingPathComponent("resolved-scope")
        fixture.defaults.set([fixture.directory.absoluteString: Data([7])], forKey: "securityScopedBookmarks")
        let state = ScopeState()
        let fileManager = ScopeCheckingFileManager(state: state)
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in XCTFail("Validation must not replace saved grants"); return Data() },
            resolveData: { _ in (resolvedScope, false) },
            startScope: { url in
                if url == resolvedScope { state.active = true; return true }
                return false
            }, stopScope: { url in XCTAssertEqual(url, resolvedScope); state.active = false })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, fileManager: fileManager,
                                                  bookmarkManager: bookmarks)

        try service.validate(fixture.directory)

        XCTAssertEqual(state.inspections, 2)
        XCTAssertFalse(state.active)
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), "/previous/watch")
    }

    func testEnumerationDenialIsActionableAndDoesNotSaveSelection() throws {
        let fixture = try fixture()
        let state = ScopeState()
        state.denyEnumeration = true
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in XCTFail("Unreadable folders must not be saved"); return Data() },
            startScope: { _ in state.active = true; return true }, stopScope: { _ in state.active = false })
        let service = WatchFolderSelectionService(defaults: fixture.defaults,
            fileManager: ScopeCheckingFileManager(state: state), bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(fixture.directory)) { error in
            guard case WatchFolderSelectionService.FolderError.unavailable(let detail) = error else {
                return XCTFail("Expected read failure, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
        XCTAssertFalse(state.active)
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), "/previous/watch")
    }

    func testUnavailableRevealPreservesSavedPathWithoutOpeningFinder() throws {
        let fixture = try fixture()
        let missing = fixture.directory.appendingPathComponent("disconnected-drive")
        fixture.defaults.set(missing.path, forKey: AppConstants.watchFolderPathKey)
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults, startScope: { _ in false })
        let service = WatchFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            openInFinder: { _ in XCTFail("Unavailable folders must not be sent to Finder"); return false })

        XCTAssertThrowsError(try service.reveal(missing))
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), missing.path)
    }

    func testDirectorySymlinkScanPreservesSelectedParentAndSkipsHiddenFilesAndDescendants() throws {
        let fixture = try fixture()
        let target = fixture.directory.appendingPathComponent("target", isDirectory: true)
        let link = fixture.directory.appendingPathComponent("linked-watch", isDirectory: true)
        let nested = target.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try Data("video".utf8).write(to: target.appendingPathComponent("clip.mov"))
        try Data("hidden".utf8).write(to: target.appendingPathComponent(".hidden.mov"))
        try Data("nested".utf8).write(to: nested.appendingPathComponent("child.mov"))

        let files = try WatchFolderDirectoryContents.list(in: link)

        XCTAssertEqual(Set(files), Set([link.appendingPathComponent("clip.mov"), link.appendingPathComponent("nested")]))
        XCTAssertEqual(try Data(contentsOf: link.appendingPathComponent("clip.mov")), Data("video".utf8))
    }

    func testCoordinatorRejectsUnavailableSavedFolderWithoutPromptingOrStartingWork() async throws {
        let fixture = try fixture()
        let missing = fixture.directory.appendingPathComponent("unavailable-watch-folder")
        let coordinator = WatchFolderCoordinator()

        let enabled = await coordinator.enableWatchMode(
            currentPath: missing.path,
            promptForFolder: { XCTFail("A saved path must produce recovery guidance without an unsolicited picker"); return nil },
            updatePath: { _ in XCTFail("Unavailable saved folders must not change preferences") },
            onNewFiles: { _ in XCTFail("Unavailable saved folders must not start importing files") }
        )

        XCTAssertFalse(enabled)
        XCTAssertFalse(try XCTUnwrap(coordinator.errorMessage).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        await coordinator.disableWatchMode()
    }

    func testFinderFailureAndRetryKeepScopedAccessAndPreserveDirectorySymlink() throws {
        let fixture = try fixture()
        let target = fixture.directory.appendingPathComponent("target", isDirectory: true)
        let link = fixture.directory.appendingPathComponent("linked-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        fixture.defaults.set(link.path, forKey: AppConstants.watchFolderPathKey)
        let state = ScopeState()
        var shouldOpen = false
        var opened: [URL] = []
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { url in XCTAssertEqual(url, link); state.active = true; return true },
            stopScope: { url in XCTAssertEqual(url, link); state.active = false })
        let service = WatchFolderSelectionService(defaults: fixture.defaults,
            fileManager: ScopeCheckingFileManager(state: state), bookmarkManager: bookmarks,
            openInFinder: { url in XCTAssertTrue(state.active); opened.append(url); return shouldOpen })

        XCTAssertThrowsError(try service.reveal(link)) { error in
            guard case WatchFolderSelectionService.FolderError.finderRejected = error else {
                return XCTFail("Expected Finder failure, got \(error)")
            }
        }
        XCTAssertFalse(state.active)
        shouldOpen = true
        try service.reveal(link)
        XCTAssertEqual(opened, [link, link])
        XCTAssertEqual(state.enumeratedURLs, [target.resolvingSymlinksInPath(), target.resolvingSymlinksInPath()])
        XCTAssertFalse(state.active)
        XCTAssertEqual(fixture.defaults.string(forKey: AppConstants.watchFolderPathKey), link.path)
    }
}

private final class ScopeState: @unchecked Sendable {
    var active = false
    var inspections = 0
    var denyEnumeration = false
    var enumeratedURLs: [URL] = []
}

private final class ScopeCheckingFileManager: FileManager, @unchecked Sendable {
    let state: ScopeState

    init(state: ScopeState) { self.state = state; super.init() }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        XCTAssertTrue(state.active, "Inspect the folder only while its scope is held")
        state.inspections += 1
        return try super.attributesOfItem(atPath: path)
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        XCTAssertTrue(state.active, "Enumerate the folder only while its scope is held")
        state.inspections += 1
        state.enumeratedURLs.append(url)
        if state.denyEnumeration { throw CocoaError(.fileReadNoPermission) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
