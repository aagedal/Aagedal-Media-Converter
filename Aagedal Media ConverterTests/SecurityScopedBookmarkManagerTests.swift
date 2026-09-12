import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class SecurityScopedBookmarkManagerTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "SecurityScopedBookmarkManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAccessibleSelectionStillPersistsBookmarkAndBalancesTemporaryAccess() throws {
        let defaults = try isolatedDefaults()
        let url = URL(fileURLWithPath: "/selected/output")
        var starts: [URL] = []
        var stops: [URL] = []
        var options: URL.BookmarkCreationOptions = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: {
            XCTAssertEqual($0, url)
            options = $1
            return Data([1, 2, 3])
        }, startScope: { starts.append($0); return true }, stopScope: { stops.append($0) })

        XCTAssertTrue(manager.saveWritableBookmark(for: url))
        XCTAssertEqual(defaults.dictionary(forKey: "securityScopedBookmarks")?[url.absoluteString] as? Data, Data([1, 2, 3]))
        XCTAssertTrue(options.contains(.withSecurityScope))
        XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
        XCTAssertEqual(starts, [url])
        XCTAssertEqual(stops, [url])
    }

    func testFailedSavePreservesPreviousBookmarkAndReleasesAccess() throws {
        let defaults = try isolatedDefaults()
        let url = URL(fileURLWithPath: "/selected/input")
        defaults.set([url.absoluteString: Data([7])], forKey: "securityScopedBookmarks")
        var stops = 0
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }, startScope: { _ in true }, stopScope: { _ in stops += 1 })

        XCTAssertFalse(manager.saveBookmark(for: url))
        XCTAssertEqual(defaults.dictionary(forKey: "securityScopedBookmarks")?[url.absoluteString] as? Data, Data([7]))
        XCTAssertEqual(stops, 1)
    }

    func testStaleWritableBookmarkRenewsAtOriginalLookupKeyWithoutDowngrade() throws {
        let defaults = try isolatedDefaults()
        let original = URL(fileURLWithPath: "/old/output")
        let moved = URL(fileURLWithPath: "/new/output")
        var created: [(URL, URL.BookmarkCreationOptions)] = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: {
            created.append(($0, $1)); return Data([UInt8(created.count)])
        }, resolveData: { _ in (moved, true) }, startScope: { _ in true }, stopScope: { _ in })
        XCTAssertTrue(manager.saveWritableBookmark(for: original))
        XCTAssertEqual(manager.resolveBookmark(for: original), moved)
        XCTAssertEqual(created.map(\.0), [original, moved])
        XCTAssertTrue(created.allSatisfy { !$0.1.contains(.securityScopeAllowOnlyReadAccess) })
        XCTAssertEqual(defaults.dictionary(forKey: "securityScopedBookmarks")?[original.absoluteString] as? Data, Data([2]))
        XCTAssertNil(defaults.dictionary(forKey: "securityScopedBookmarks")?[moved.absoluteString])
        XCTAssertTrue(manager.saveBookmark(for: original))
        XCTAssertFalse(try XCTUnwrap(created.last).1.contains(.securityScopeAllowOnlyReadAccess))
    }

    func testStaleReadOnlyBookmarkRetainsReadOnlyRestriction() throws {
        let defaults = try isolatedDefaults()
        let url = URL(fileURLWithPath: "/input")
        var modes: [Bool] = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: { _, options in
            modes.append(options.contains(.securityScopeAllowOnlyReadAccess)); return Data([1])
        }, resolveData: { _ in (url, true) }, startScope: { _ in false }, stopScope: { _ in XCTFail("No scope was acquired") })
        XCTAssertTrue(manager.saveBookmark(for: url))
        XCTAssertEqual(manager.resolveBookmark(for: url), url)
        XCTAssertEqual(modes, [true, true])
    }

    func testLegacyBookmarkRenewalDoesNotAddReadOnlyRestriction() throws {
        let defaults = try isolatedDefaults()
        let url = URL(fileURLWithPath: "/legacy/output")
        defaults.set([url.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var options: URL.BookmarkCreationOptions = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: {
            options = $1; return Data([2])
        }, resolveData: { _ in (url, true) }, startScope: { _ in false }, stopScope: { _ in })
        XCTAssertEqual(manager.resolveBookmark(for: url), url)
        XCTAssertTrue(options.contains(.withSecurityScope))
        XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    func testReadingLegacyWritableSelectionDoesNotDowngradeStoredAccess() throws {
        let defaults = try isolatedDefaults()
        let url = URL(fileURLWithPath: "/legacy/output")
        defaults.set([url.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var options: URL.BookmarkCreationOptions = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: {
            options = $1; return Data([2])
        }, startScope: { _ in false }, stopScope: { _ in })
        XCTAssertTrue(manager.saveBookmark(for: url))
        XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    func testOverlappingBorrowersReleaseExactResolvedURLAfterLastStop() throws {
        let defaults = try isolatedDefaults()
        let original = URL(fileURLWithPath: "/original")
        let resolved = URL(fileURLWithPath: "/resolved")
        defaults.set([original.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var resolutions = 0
        var starts: [URL] = []
        var stops: [URL] = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, resolveData: { _ in
            resolutions += 1
            return (resolved, false)
        }, startScope: { starts.append($0); return $0 == resolved }, stopScope: { stops.append($0) })
        let first = manager.startAccessing(url: original)
        let second = manager.startAccessing(url: original)
        // Removing/replacing persisted data while work runs must not affect release.
        defaults.removeObject(forKey: "securityScopedBookmarks")
        manager.stopAccessing(first)
        XCTAssertTrue(stops.isEmpty)
        manager.stopAccessing(second)
        manager.stopAccessingSecurityScopedResource(for: original)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(starts.filter { $0 == resolved }, [resolved])
        XCTAssertEqual(stops, [resolved])
    }

    func testDirectBorrowerReleasesIndependentlyOfActiveBookmark() throws {
        let defaults = try isolatedDefaults()
        let original = URL(fileURLWithPath: "/original")
        let resolved = URL(fileURLWithPath: "/resolved")
        defaults.set([original.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var stops: [URL] = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, resolveData: { _ in (resolved, false) },
            startScope: { _ in true }, stopScope: { stops.append($0) })
        XCTAssertTrue(manager.startAccessingSecurityScopedResource(for: original))
        let direct = manager.startAccessing(url: original)
        manager.stopAccessing(direct)
        XCTAssertEqual(stops, [original])
        manager.stopAccessingSecurityScopedResource(for: original)
        XCTAssertEqual(stops, [original, resolved])
    }

    func testFailedStaleRenewalStillReturnsResolvedURLAndBalancesTemporaryScope() throws {
        let defaults = try isolatedDefaults()
        let original = URL(fileURLWithPath: "/original")
        let resolved = URL(fileURLWithPath: "/resolved")
        defaults.set([original.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        var stops: [URL] = []
        let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }, resolveData: { _ in (resolved, true) }, startScope: { _ in true }, stopScope: { stops.append($0) })
        XCTAssertEqual(manager.resolveBookmark(for: original), resolved)
        XCTAssertEqual(stops, [resolved])
        XCTAssertEqual(defaults.dictionary(forKey: "securityScopedBookmarks")?[original.absoluteString] as? Data, Data([1]))
    }

    func testFailedScopeAcquisitionDoesNotRegisterBorrowerOrStop() throws {
        let defaults = try isolatedDefaults()
        let original = URL(fileURLWithPath: "/original")
        defaults.set([original.absoluteString: Data([1])], forKey: "securityScopedBookmarks")
        let manager = SecurityScopedBookmarkManager(defaults: defaults, resolveData: { _ in (original, false) },
            startScope: { _ in false }, stopScope: { _ in XCTFail("Failed access must not be stopped") })
        XCTAssertFalse(manager.startAccessingSecurityScopedResource(for: original))
        manager.stopAccessingSecurityScopedResource(for: original)
    }
    func testMalformedTopLevelStoresRejectSaveWithoutErasingRecoveryData() throws {
        for key in ["securityScopedBookmarks", "securityScopedBookmarksReadOnly"] {
            for malformed: Any in [Data([0, 1, 2]), "unsupported-schema", ["invalid-array"]] {
                let defaults = try isolatedDefaults()
                defaults.set(malformed, forKey: key)
                let before = defaults.dictionaryRepresentation() as NSDictionary
                var activeScopes = 0
                let manager = SecurityScopedBookmarkManager(defaults: defaults, createBookmark: { _, _ in
                    XCTFail("Malformed state must be rejected before bookmark creation")
                    return Data([3])
                }, startScope: { _ in activeScopes += 1; return true },
                    stopScope: { _ in activeScopes -= 1 })
                XCTAssertFalse(manager.saveWritableBookmark(for: URL(fileURLWithPath: "/new/output")))
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
                XCTAssertEqual(activeScopes, 0)
            }
        }
    }

    func testMalformedSiblingDoesNotBlockValidBookmarkOrDisappearDuringRenewal() throws {
        let defaults = try isolatedDefaults()
        let valid = URL(fileURLWithPath: "/valid/output")
        let malformed = URL(fileURLWithPath: "/recoverable/output")
        defaults.set([valid.absoluteString: Data([1]), malformed.absoluteString: "unsupported-entry"],
                     forKey: "securityScopedBookmarks")
        let manager = SecurityScopedBookmarkManager(defaults: defaults,
            createBookmark: { _, _ in Data([2]) },
            resolveData: { data in
                XCTAssertEqual(data, Data([1]))
                return (valid, true)
            }, startScope: { _ in false }, stopScope: { _ in })
        XCTAssertNil(manager.resolveBookmark(for: malformed))
        XCTAssertEqual(manager.resolveBookmark(for: valid), valid)
        let saved = defaults.dictionary(forKey: "securityScopedBookmarks")
        XCTAssertEqual(saved?[valid.absoluteString] as? Data, Data([2]))
        XCTAssertEqual(saved?[malformed.absoluteString] as? String, "unsupported-entry")
    }

}
