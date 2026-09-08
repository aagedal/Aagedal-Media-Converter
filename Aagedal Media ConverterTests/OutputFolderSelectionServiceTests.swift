import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class OutputFolderSelectionServiceTests: XCTestCase {
    private func fixture() throws -> (directory: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "OutputFolderSelectionServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("/previous/output", forKey: "outputFolder")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return (directory, defaults)
    }

    func testFailedDirectoryPreparationPreservesPreferenceAndDoesNotSaveBookmark() throws {
        let fixture = try fixture()
        let selected = fixture.directory.appendingPathComponent("file.mov")
        try Data("existing".utf8).write(to: selected)
        var starts = 0
        var stops = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in XCTFail("Failed preparation must not save a bookmark"); return Data() },
            startScope: { _ in starts += 1; return true }, stopScope: { _ in stops += 1 })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(selected)) { error in
            guard case OutputFolderSelectionService.FolderError.preparation = error else {
                return XCTFail("Expected directory preparation error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), "/previous/output")
        XCTAssertEqual(try Data(contentsOf: selected), Data("existing".utf8))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testFailedBookmarkPreservesPreviousSelectionAndBookmark() throws {
        let fixture = try fixture()
        let previous = URL(fileURLWithPath: "/previous/output")
        fixture.defaults.set([previous.absoluteString: Data([7])], forKey: "securityScopedBookmarks")
        var activeScopes = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { _, _ in
                XCTAssertEqual(activeScopes, 2)
                throw CocoaError(.fileWriteNoPermission)
            }, startScope: { _ in activeScopes += 1; return true },
            stopScope: { _ in activeScopes -= 1 })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        XCTAssertThrowsError(try service.select(fixture.directory)) { error in
            guard case OutputFolderSelectionService.FolderError.bookmark = error else {
                return XCTFail("Expected bookmark error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), previous.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks") as? [String: Data],
                       [previous.absoluteString: Data([7])])
        XCTAssertEqual(activeScopes, 0)
    }

    func testSelectionCreatesDirectoryAndCommitsOnlyAfterWritableBookmarkIsSaved() throws {
        let fixture = try fixture()
        let selected = fixture.directory.appendingPathComponent("new-output", isDirectory: true)
        var activeScopes = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            createBookmark: { url, options in
                XCTAssertEqual(url, selected)
                XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
                XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), "/previous/output")
                XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
                XCTAssertEqual(activeScopes, 2)
                return Data([1, 2, 3])
            }, startScope: { _ in activeScopes += 1; return true },
            stopScope: { _ in activeScopes -= 1 })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        try service.select(selected)

        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), selected.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks")?[selected.absoluteString] as? Data,
                       Data([1, 2, 3]))
        XCTAssertEqual(activeScopes, 0)
    }

    func testUnavailableRevealPreservesSavedLocationAndDoesNotOpenFinder() throws {
        let fixture = try fixture()
        let missing = fixture.directory.appendingPathComponent("disconnected-drive")
        fixture.defaults.set(missing.path, forKey: "outputFolder")
        var stops = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { _ in true }, stopScope: { _ in stops += 1 })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            openInFinder: { _ in XCTFail("Unavailable folders must not be sent to Finder"); return false })

        XCTAssertThrowsError(try service.reveal(missing)) { error in
            guard case OutputFolderSelectionService.FolderError.unavailable = error else {
                return XCTFail("Expected unavailable-folder error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), missing.path)
        XCTAssertEqual(stops, 1)
    }

    func testRevealRejectsRegularFileAndPreservesSavedLocation() throws {
        let fixture = try fixture()
        let file = fixture.directory.appendingPathComponent("file.mov")
        try Data().write(to: file)
        fixture.defaults.set(file.path, forKey: "outputFolder")
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { _ in false })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            openInFinder: { _ in XCTFail("A regular file must not be opened as the output folder"); return false })

        XCTAssertThrowsError(try service.reveal(file)) { error in
            guard case OutputFolderSelectionService.FolderError.notDirectory = error else {
                return XCTFail("Expected not-a-folder error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), file.path)
    }

    func testRevealAcceptsDirectorySymlinkWithoutChangingSavedPath() throws {
        let fixture = try fixture()
        let target = fixture.directory.appendingPathComponent("target", isDirectory: true)
        let link = fixture.directory.appendingPathComponent("linked-output", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        fixture.defaults.set(link.path, forKey: "outputFolder")
        var opened: [URL] = []
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { _ in false })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            openInFinder: { opened.append($0); return true })

        try service.reveal(link)

        XCTAssertEqual(opened, [link])
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), link.path)
    }

    func testFinderFailureAndSuccessPreserveSavedLocationAndBalanceAccess() throws {
        let fixture = try fixture()
        fixture.defaults.set(fixture.directory.path, forKey: "outputFolder")
        var active = false
        var stops = 0
        var shouldOpen = false
        var opened: [URL] = []
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { _ in active = true; return true },
            stopScope: { _ in active = false; stops += 1 })
        let service = OutputFolderSelectionService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            openInFinder: { url in
                XCTAssertTrue(active)
                opened.append(url)
                return shouldOpen
            })

        XCTAssertThrowsError(try service.reveal(fixture.directory)) { error in
            guard case OutputFolderSelectionService.FolderError.finderRejected = error else {
                return XCTFail("Expected Finder error, got \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), fixture.directory.path)
        XCTAssertFalse(active)
        shouldOpen = true
        try service.reveal(fixture.directory)
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), fixture.directory.path)
        XCTAssertEqual(opened, [fixture.directory, fixture.directory])
        XCTAssertFalse(active)
        XCTAssertEqual(stops, 2)
    }
}
