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
}
