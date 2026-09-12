import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class DownloadHistoryServiceTests: XCTestCase {
    @MainActor
    private func withStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "DownloadHistoryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    func testHistoryRoundTripRefreshesDuplicateAndRemovesOnlySelectedEntry() async throws {
        try withStore { defaults in
            XCTAssertTrue(DownloadHistoryService.getHistory(defaults: defaults).isEmpty)
            XCTAssertFalse(DownloadHistoryService.hasUnreadableHistory(defaults: defaults))
            DownloadHistoryService.addEntry(url: "https://example.test/first", title: "Original", defaults: defaults)
            DownloadHistoryService.addEntry(url: "https://example.test/second", title: "Second", defaults: defaults)
            let second = try XCTUnwrap(DownloadHistoryService.getHistory(defaults: defaults).first)
            DownloadHistoryService.addEntry(url: "https://example.test/first", title: "Updated", outputFileName: "video.mov", defaults: defaults)
            let history = DownloadHistoryService.getHistory(defaults: defaults)
            XCTAssertEqual(history.map(\.title), ["Updated", "Second"])
            XCTAssertEqual(history.first?.outputFileName, "video.mov")
            XCTAssertEqual(history.last, second)
            DownloadHistoryService.removeEntry(id: second.id, defaults: defaults)
            XCTAssertEqual(DownloadHistoryService.getHistory(defaults: defaults), Array(history.prefix(1)))
        }
    }

    @MainActor
    func testAddingHistoryKeepsOnlyMostRecentEntries() async throws {
        try withStore { defaults in
            let entries = (0..<AppConstants.downloadHistoryMaxItems).map {
                DownloadHistoryEntry(url: "https://example.test/\($0)", title: "\($0)")
            }
            defaults.set(try JSONEncoder().encode(entries), forKey: AppConstants.downloadHistoryKey)
            DownloadHistoryService.addEntry(url: "https://example.test/new", title: "New", defaults: defaults)
            let history = DownloadHistoryService.getHistory(defaults: defaults)
            XCTAssertEqual(history.count, AppConstants.downloadHistoryMaxItems)
            XCTAssertEqual(history.first?.title, "New")
            XCTAssertEqual(Array(history.dropFirst()), Array(entries.dropLast()))
        }
    }

    @MainActor
    func testMalformedHistorySurvivesAutomaticAddAndRemove() async throws {
        let valid = DownloadHistoryEntry(url: "https://example.test/valid", title: "Valid")
        let partial = try JSONSerialization.jsonObject(with: JSONEncoder().encode([valid])) as! [[String: Any]]
        let damaged: [Any] = [
            "wrong-storage-type", Data("invalid JSON".utf8), Data("{}".utf8),
            try JSONSerialization.data(withJSONObject: partial + [["url": "missing required fields"]])
        ]
        for stored in damaged {
            withStore { defaults in
                defaults.set(stored, forKey: AppConstants.downloadHistoryKey)
                let before = defaults.dictionaryRepresentation()
                XCTAssertTrue(DownloadHistoryService.getHistory(defaults: defaults).isEmpty)
                XCTAssertTrue(DownloadHistoryService.hasUnreadableHistory(defaults: defaults))
                DownloadHistoryService.addEntry(url: "https://example.test/new", title: "New", defaults: defaults)
                DownloadHistoryService.removeEntry(id: valid.id, defaults: defaults)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
            }
        }
    }

    @MainActor
    func testExplicitClearAllowsRecoveryFromDamagedHistoryAndPreservesOtherSettings() async {
        withStore { defaults in
            defaults.set(Data("damaged".utf8), forKey: AppConstants.downloadHistoryKey)
            defaults.set("preserved", forKey: "unrelated")
            XCTAssertTrue(DownloadHistoryService.hasUnreadableHistory(defaults: defaults))
            DownloadHistoryService.clearHistory(defaults: defaults)
            XCTAssertFalse(DownloadHistoryService.hasUnreadableHistory(defaults: defaults))
            XCTAssertNil(defaults.object(forKey: AppConstants.downloadHistoryKey))
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserved")
            DownloadHistoryService.addEntry(url: "https://example.test/new", title: "New", defaults: defaults)
            XCTAssertEqual(DownloadHistoryService.getHistory(defaults: defaults).map(\.title), ["New"])
        }
    }
}
