import XCTest
import SwiftUI
@testable import Aagedal_Media_Converter

@MainActor
final class DownloadDetailsLifecycleTests: XCTestCase {
    func testCancellationDiscardsMetadataAndAutoEncodeAfterDownloadHasCompleted() async {
        let gate = DownloadDetailsGate()
        let started = expectation(description: "Details probe started")
        let manager = DownloadManager { _ in await gate.wait(started: started) }
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        var encodedItems: [UUID] = []
        manager.onAutoEncode = { encodedItems.append($0) }

        let task = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: items[0].url, autoEncode: true)
        await fulfillment(of: [started], timeout: 2)
        manager.cancelDownload(itemID: itemID)
        await task.value
        await gate.finish(size: 999)

        XCTAssertEqual(items[0].status, .cancelled)
        XCTAssertEqual(items[0].size, 0)
        XCTAssertFalse(items[0].detailsLoaded)
        XCTAssertTrue(encodedItems.isEmpty)
    }

    func testReplacementAtSameURLPublishesOnlyNewMetadataAndAutoEncode() async {
        let oldGate = DownloadDetailsGate()
        let newGate = DownloadDetailsGate()
        let oldStarted = expectation(description: "Old details probe started")
        let newStarted = expectation(description: "New details probe started")
        let sequencer = DownloadDetailsSequence(
            gates: [oldGate, newGate], expectations: [oldStarted, newStarted]
        )
        let manager = DownloadManager { _ in await sequencer.next() }
        var items = [makeItem()]
        let itemID = items[0].id
        let fileURL = items[0].url
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        var encodedItems: [UUID] = []
        manager.onAutoEncode = { encodedItems.append($0) }

        let oldTask = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: fileURL, autoEncode: true)
        await fulfillment(of: [oldStarted], timeout: 2)
        let newTask = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: fileURL, autoEncode: true)
        await fulfillment(of: [newStarted], timeout: 2)
        await oldTask.value
        await oldGate.finish(size: 111)
        await newGate.finish(size: 222)
        await newTask.value

        XCTAssertEqual(items[0].size, 222)
        XCTAssertTrue(items[0].detailsLoaded)
        XCTAssertEqual(encodedItems, [itemID])
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/download.mov"), name: "download.mov", size: 0,
            duration: "", durationSeconds: 0, status: .waiting,
            progress: 0, eta: "", outputURL: nil
        )
    }
}

private actor DownloadDetailsSequence {
    let gates: [DownloadDetailsGate]
    let expectations: [XCTestExpectation]
    private var index = 0

    init(gates: [DownloadDetailsGate], expectations: [XCTestExpectation]) {
        self.gates = gates
        self.expectations = expectations
    }

    func next() async -> VideoFileUtils.VideoItemDetails {
        let nextIndex = index
        index += 1
        return await gates[nextIndex].wait(started: expectations[nextIndex])
    }
}

private actor DownloadDetailsGate {
    private var continuation: CheckedContinuation<VideoFileUtils.VideoItemDetails, Never>?

    func wait(started: XCTestExpectation) async -> VideoFileUtils.VideoItemDetails {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(size: Int64) {
        continuation?.resume(returning: VideoFileUtils.VideoItemDetails(
            size: size, duration: "00:00:01", durationSeconds: 1,
            thumbnailData: nil, outputURL: nil, hasVideoStream: true, metadata: nil
        ))
        continuation = nil
    }
}

final class ScheduledDownloadStoreTests: XCTestCase {
    private func withStore(_ body: (UserDefaults, ScheduledDownloadStore) throws -> Void) rethrows {
        let suite = "ScheduledDownloadStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, ScheduledDownloadStore(defaults: defaults))
    }

    private func entry(audioOnly: Bool = true) -> PersistedScheduledDownload {
        PersistedScheduledDownload(
            itemID: UUID(), url: "https://example.com/video",
            scheduledTime: Date(timeIntervalSince1970: 2_000_000_000),
            liveFromStart: true, autoEncode: false, uploadEnabled: true, audioOnly: audioOnly
        )
    }

    func testLegacyScheduleMigratesOnlyAbsentAudioOnlyKey() throws {
        let original = entry()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "audioOnly")
        let decoded = try JSONDecoder().decode(PersistedScheduledDownload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.audioOnly)
        XCTAssertEqual(decoded.itemID, original.itemID)
        XCTAssertEqual(decoded.scheduledTime, original.scheduledTime)
        for invalid: Any in [NSNull(), "true", 1] {
            json["audioOnly"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(PersistedScheduledDownload.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testCorruptStorageIsRetainedThroughEveryMutation() throws {
        try withStore { defaults, store in
            for invalid: Any in [Data("broken".utf8), "wrong-type", Data("{}".utf8)] {
                defaults.set(invalid, forKey: ScheduledDownloadStore.key)
                let before = defaults.object(forKey: ScheduledDownloadStore.key) as? NSObject
                XCTAssertThrowsError(try store.load())
                XCTAssertThrowsError(try store.append(entry()))
                XCTAssertThrowsError(try store.remove(itemID: UUID()))
                XCTAssertThrowsError(try store.save([]))
                XCTAssertEqual(defaults.object(forKey: ScheduledDownloadStore.key) as? NSObject, before)
            }
        }
    }

    func testRoundTripReplacementAndRemovalPreserveOtherSchedules() throws {
        try withStore { defaults, store in
            XCTAssertEqual(try store.load(), [])
            let first = entry()
            let second = entry(audioOnly: false)
            try store.append(first)
            try store.append(second)
            try store.append(first)
            XCTAssertEqual(try store.load(), [second, first])
            try store.remove(itemID: first.itemID)
            XCTAssertEqual(try store.load(), [second])
            try store.remove(itemID: UUID())
            XCTAssertEqual(try store.load(), [second])
            try store.remove(itemID: second.itemID)
            XCTAssertNil(defaults.object(forKey: ScheduledDownloadStore.key))
        }
    }

    @MainActor
    func testCorruptRestoreLeavesQueueAndPersistedDataUntouched() {
        withStore { defaults, _ in
            let data = Data("unreadable schedules".utf8)
            defaults.set(data, forKey: ScheduledDownloadStore.key)
            let manager = DownloadManager(defaults: defaults)
            var items: [VideoItem] = []
            manager.restoreScheduledDownloads(
                items: Binding(get: { items }, set: { items = $0 }),
                outputFolder: URL(fileURLWithPath: NSTemporaryDirectory())
            )
            XCTAssertTrue(items.isEmpty)
            XCTAssertTrue(manager.hasScheduledDownloadStorageError)
            XCTAssertNil(manager.videoItems)
            XCTAssertNil(manager.outputFolder)
            XCTAssertEqual(defaults.data(forKey: ScheduledDownloadStore.key), data)
        }
    }

    func testExplicitResetReplacesDamagedStorageAndEmptyResetClearsIt() throws {
        try withStore { defaults, store in
            for invalid: Any in [Data("broken".utf8), "wrong-type", Data("{}".utf8)] {
                defaults.set(invalid, forKey: ScheduledDownloadStore.key)
                let replacement = entry()
                try store.reset(with: [replacement])
                XCTAssertEqual(try store.load(), [replacement])
                try store.reset(with: [])
                XCTAssertNil(defaults.object(forKey: ScheduledDownloadStore.key))
            }
        }
    }

    func testResetEncodingFailureRetainsDamagedStorage() throws {
        try withStore { defaults, store in
            let damaged = Data("broken".utf8)
            defaults.set(damaged, forKey: ScheduledDownloadStore.key)
            let invalid = PersistedScheduledDownload(
                itemID: UUID(), url: "https://example.com/video",
                scheduledTime: Date(timeIntervalSinceReferenceDate: .infinity),
                liveFromStart: false, autoEncode: false, uploadEnabled: false, audioOnly: false
            )
            XCTAssertThrowsError(try store.reset(with: [invalid]))
            XCTAssertEqual(defaults.data(forKey: ScheduledDownloadStore.key), damaged)
        }
    }

    @MainActor
    func testNewScheduleRemainsSessionOnlyUntilExplicitRecovery() async throws {
        let suite = "ScheduledDownloadRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let damaged = Data("broken".utf8)
        defaults.set(damaged, forKey: ScheduledDownloadStore.key)
        let manager = DownloadManager(defaults: defaults)
        var items: [VideoItem] = []
        let id = await manager.scheduleDownload(
            url: "https://example.com/video", at: Date().addingTimeInterval(86_400),
            items: Binding(get: { items }, set: { items = $0 }),
            outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()), audioOnly: true
        )
        let itemID = try XCTUnwrap(id)
        defer { manager.cancelScheduledDownload(itemID: itemID) }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(manager.hasScheduledDownloadStorageError)
        XCTAssertEqual(defaults.data(forKey: ScheduledDownloadStore.key), damaged)
        manager.resetScheduledDownloadStorage()
        XCTAssertFalse(manager.hasScheduledDownloadStorageError)
        let saved = try ScheduledDownloadStore(defaults: defaults).load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.itemID, itemID)
        XCTAssertEqual(saved.first?.audioOnly, true)
    }

    @MainActor
    func testRecoverySavesOnlyCurrentlyScheduledQueueItemsAndClearsWarning() throws {
        try withStore { defaults, store in
            let damaged = Data("broken".utf8)
            defaults.set(damaged, forKey: ScheduledDownloadStore.key)
            let manager = DownloadManager(defaults: defaults)
            var scheduled = VideoItem(
                url: URL(fileURLWithPath: "/fixture/scheduled"), name: "Scheduled",
                size: 0, duration: "", durationSeconds: 0, status: .waiting,
                progress: 0, eta: "", outputURL: nil
            )
            scheduled.sourceURL = "https://example.com/video"
            scheduled.scheduledDownloadTime = Date(timeIntervalSince1970: 2_000_000_000)
            scheduled.downloadLiveFromStart = true
            scheduled.downloadAudioOnly = true
            scheduled.autoEncodeAfterDownload = true
            scheduled.uploadEnabled = true
            var completed = scheduled
            completed.scheduledDownloadTime = nil
            var items = [scheduled, completed]
            let binding = Binding(get: { items }, set: { items = $0 })
            manager.videoItems = binding
            manager.restoreScheduledDownloads(items: binding, outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()))
            XCTAssertTrue(manager.hasScheduledDownloadStorageError)
            XCTAssertEqual(defaults.data(forKey: ScheduledDownloadStore.key), damaged)
            manager.resetScheduledDownloadStorage()
            XCTAssertFalse(manager.hasScheduledDownloadStorageError)
            XCTAssertEqual(try store.load(), [PersistedScheduledDownload(
                itemID: scheduled.id, url: scheduled.sourceURL!, scheduledTime: scheduled.scheduledDownloadTime!,
                liveFromStart: true, autoEncode: true, uploadEnabled: true, audioOnly: true
            )])
            XCTAssertEqual(items.count, 2)
        }
    }

    func testMalformedEntryDoesNotPartiallyRestoreOrOverwriteValidSibling() throws {
        try withStore { defaults, store in
            let good = entry()
            var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry())) as? [String: Any])
            bad["audioOnly"] = NSNull()
            let validJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
            let data = try JSONSerialization.data(withJSONObject: [validJSON, bad])
            defaults.set(data, forKey: ScheduledDownloadStore.key)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.append(entry()))
            XCTAssertEqual(defaults.data(forKey: ScheduledDownloadStore.key), data)
        }
    }
}
