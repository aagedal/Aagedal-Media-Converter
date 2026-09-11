import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class OutputFolderCleanupServiceTests: XCTestCase {
    private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
        var failingURL: URL?

        override func removeItem(at URL: URL) throws {
            if URL.standardizedFileURL.path == failingURL?.standardizedFileURL.path { throw CocoaError(.fileWriteNoPermission) }
            try super.removeItem(at: URL)
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

    private func writeFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("encode".utf8).write(to: url)
        return url
    }

    private func oldMetadata(for url: URL) throws -> URLResourceValues {
        var values = try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
        values.creationDate = Date(timeIntervalSinceNow: -30 * 86_400)
        return values
    }

    func testEnumerationFailureIsVisibleAndReleasesFolderScope() throws {
        let fixture = try fixture()
        let file = try writeFile("not-a-folder", in: fixture.directory)
        fixture.defaults.set(file.path, forKey: "outputFolder")
        var starts: [URL] = []
        var stops: [URL] = []
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { starts.append($0); return true },
            stopScope: { stops.append($0) })
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        service.performCleanupIfNeeded()

        XCTAssertNotNil(service.lastError)
        XCTAssertEqual(starts, [file])
        XCTAssertEqual(stops, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMetadataFailurePreservesUnknownFileAndContinuesOtherDeletions() throws {
        let fixture = try fixture()
        let unreadable = try writeFile("unknown-age.mov", in: fixture.directory)
        let old = try writeFile("old.mov", in: fixture.directory)
        let service = OutputFolderCleanupService(defaults: fixture.defaults, readResourceValues: { url in
            if url.standardizedFileURL.path == unreadable.standardizedFileURL.path { throw CocoaError(.fileReadNoPermission) }
            return try self.oldMetadata(for: url)
        })

        service.performCleanupIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains(unreadable.lastPathComponent))
    }

    func testRemovalFailureIsVisibleAndSuccessOnRetryClearsError() throws {
        let fixture = try fixture()
        let blocked = try writeFile("blocked.mov", in: fixture.directory)
        let other = try writeFile("other.mov", in: fixture.directory)
        let fileManager = FailingRemovalFileManager()
        fileManager.failingURL = blocked
        let service = OutputFolderCleanupService(defaults: fixture.defaults, fileManager: fileManager,
            readResourceValues: { try self.oldMetadata(for: $0) })

        service.performCleanupIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains(blocked.lastPathComponent))
        fileManager.failingURL = nil
        service.performCleanupIfNeeded()
        XCTAssertNil(service.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
    }

    func testCleanupOnlyDeletesOldRegularVisibleFilesAndBalancesAccess() throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        let recent = try writeFile("recent.mov", in: fixture.directory)
        let hidden = try writeFile(".hidden.mov", in: fixture.directory)
        let subdirectory = fixture.directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        let nested = try writeFile("nested.mov", in: subdirectory)
        var active = false
        var scopeStops = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { url in
                XCTAssertEqual(url, fixture.directory)
                active = true
                return true
            }, stopScope: { _ in active = false; scopeStops += 1 })
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            readResourceValues: { url in
                XCTAssertTrue(active)
                if url.standardizedFileURL.path == recent.standardizedFileURL.path {
                    return try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
                }
                return try self.oldMetadata(for: url)
            })

        service.performCleanupIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [recent, hidden, subdirectory, nested] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNil(service.lastError)
        XCTAssertFalse(active)
        XCTAssertEqual(scopeStops, 1)
    }

    func testCleanupRestoresSavedBookmarkWhenDirectAccessIsUnavailable() throws {
        let fixture = try fixture()
        let old = try writeFile("old.mov", in: fixture.directory)
        fixture.defaults.set([fixture.directory.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var starts = 0
        var stops = 0
        var active = false
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { _ in (fixture.directory, false) },
            startScope: { _ in
                starts += 1
                active = starts > 1
                return active
            }, stopScope: { _ in active = false; stops += 1 })
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            readResourceValues: { url in
                XCTAssertTrue(active)
                return try self.oldMetadata(for: url)
            })

        service.performCleanupIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertNil(service.lastError)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(active)
    }

    func testDisabledCleanupDoesNotAcquireAccessOrRemoveFiles() throws {
        let fixture = try fixture()
        let file = try writeFile("old.mov", in: fixture.directory)
        fixture.defaults.set(false, forKey: AppConstants.autoDeleteOldEncodesKey)
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { _ in XCTFail("Disabled cleanup must not acquire access"); return false })
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            readResourceValues: { try self.oldMetadata(for: $0) })

        service.performCleanupIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(service.lastError)
    }

    func testDirectorySymlinkCleanupPreservesSelectedScopeAndUnrelatedFiles() throws {
        let fixture = try fixture()
        let target = fixture.directory.appendingPathComponent("target", isDirectory: true)
        let link = fixture.directory.appendingPathComponent("linked-output", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let old = try writeFile("old.mov", in: target)
        let recent = try writeFile("recent.mov", in: target)
        let hidden = try writeFile(".hidden.mov", in: target)
        let nested = target.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedFile = try writeFile("old.mov", in: nested)
        fixture.defaults.set(link.path, forKey: "outputFolder")
        var active = false
        var stops = 0
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            startScope: { url in XCTAssertEqual(url.path, link.path); active = true; return true },
            stopScope: { url in XCTAssertEqual(url.path, link.path); active = false; stops += 1 })
        let service = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks,
            readResourceValues: { url in
                XCTAssertTrue(active)
                XCTAssertEqual(url.deletingLastPathComponent().path, link.path)
                if url.lastPathComponent == recent.lastPathComponent {
                    return try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
                }
                return try self.oldMetadata(for: url)
            })

        service.performCleanupIfNeeded()

        XCTAssertNil(service.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [recent, hidden, nested, nestedFile, link] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), link.path)
        XCTAssertFalse(active)
        XCTAssertEqual(stops, 1)
    }

    func testUnavailableFolderPreservesSavedGrantAndRecoversInNewServiceInstance() throws {
        let fixture = try fixture()
        let folder = fixture.directory.appendingPathComponent("unavailable-output", isDirectory: true)
        fixture.defaults.set(folder.path, forKey: "outputFolder")
        let savedBookmarks = [folder.absoluteString: Data([7])]
        fixture.defaults.set(savedBookmarks, forKey: "securityScopedBookmarks")
        let bookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { _ in throw CocoaError(.fileReadNoSuchFile) }, startScope: { _ in false })
        let unavailableService = OutputFolderCleanupService(defaults: fixture.defaults, bookmarkManager: bookmarks)

        unavailableService.performCleanupIfNeeded()

        XCTAssertNotNil(unavailableService.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), folder.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks") as? [String: Data], savedBookmarks)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let old = try writeFile("old.mov", in: folder)
        var starts = 0
        var stops = 0
        let restoredBookmarks = SecurityScopedBookmarkManager(defaults: fixture.defaults,
            resolveData: { data in XCTAssertEqual(data, Data([7])); return (folder, false) },
            startScope: { _ in starts += 1; return starts > 1 }, stopScope: { _ in stops += 1 })
        let restartedService = OutputFolderCleanupService(defaults: fixture.defaults,
            bookmarkManager: restoredBookmarks, readResourceValues: { try self.oldMetadata(for: $0) })

        restartedService.performCleanupIfNeeded()

        XCTAssertNil(restartedService.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(fixture.defaults.string(forKey: "outputFolder"), folder.path)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "securityScopedBookmarks") as? [String: Data], savedBookmarks)
    }
}
