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

final class DownloadPartialFileOwnershipTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testMissingDestinationNeverAdoptsAnotherRecentRecording() throws {
        let unrelated = try write("Other recording.mp4.part")
        let control = YTDLPDownloadControl()
        XCTAssertNil(control.partialFile(in: folder))
        control.recordOutputPath("Recording.mp4", in: folder)
        XCTAssertNil(control.partialFile(in: folder))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("fixture".utf8))
    }

    func testExactPartialIsPreferredOverPreviousCompletedFileAndNewerUnrelatedFile() throws {
        _ = try write("Recording.mp4")
        let partial = try write("Recording.mp4.part")
        _ = try write("Other Recording.mp4.part")
        let control = YTDLPDownloadControl()
        control.recordOutputPath("Recording.mp4", in: folder)
        XCTAssertEqual(control.partialFile(in: folder), partial)
    }

    func testAbsoluteAndAlreadyPartialDestinationsAreSupportedWithoutAgeCutoff() throws {
        let partial = try write("Recording.mp4.part")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: partial.path)
        let control = YTDLPDownloadControl()
        control.recordOutputPath(partial.path, in: folder)
        XCTAssertEqual(control.partialFile(in: folder), partial)
    }

    func testCompletedDestinationIsAvailableAfterFinalization() throws {
        let completed = try write("Recording.mp4")
        let control = YTDLPDownloadControl()
        control.recordOutputPath(completed.path, in: folder, finalized: true)
        XCTAssertEqual(control.partialFile(in: folder), completed)
    }

    func testUnchangedCompletedDestinationIsNotAdoptedBeforePartialCreation() throws {
        let completed = try write("Recording.mp4")
        let control = YTDLPDownloadControl()
        control.recordOutputPath(completed.path, in: folder)
        XCTAssertNil(control.partialFile(in: folder))
        XCTAssertEqual(try Data(contentsOf: completed), Data("fixture".utf8))
    }

    func testNoPartRecordingCanBeRecoveredAfterDestinationStartsGrowing() throws {
        let completed = try write("Recording.mp4")
        let control = YTDLPDownloadControl()
        control.recordOutputPath(completed.path, in: folder)
        try Data("growing recording".utf8).write(to: completed)
        XCTAssertEqual(control.partialFile(in: folder), completed)
    }

    func testEscapingPathsSymlinksAndDirectoriesCannotBeRecovered() throws {
        let outside = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = folder.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let directory = folder.appendingPathComponent("directory.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let control = YTDLPDownloadControl()
        for path in [outside.path, "../" + outside.lastPathComponent, link.path, directory.path] {
            control.recordOutputPath(path, in: folder)
            XCTAssertNil(control.partialFile(in: folder), path)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    private func write(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }
}

@MainActor
final class DownloadRetryDrainTests: XCTestCase {
    func testRetryWaitsForPreviousProcessToDrain() async throws {
        try await checkDrain(forceOverwrite: false, explicitCancel: false, rapidRetry: false)
    }

    func testForceRedownloadAfterExplicitCancellationWaitsForDrain() async throws {
        try await checkDrain(forceOverwrite: true, explicitCancel: true, rapidRetry: false)
    }

    func testRapidRetriesKeepWaitingForOriginalProcess() async throws {
        try await checkDrain(forceOverwrite: false, explicitCancel: false, rapidRetry: true)
    }

    func testCancellingWaitingRetryNeverStartsAnotherProcess() async throws {
        let started = expectation(description: "Original process started")
        let cancelled = expectation(description: "Original process cancellation requested")
        let unexpected = expectation(description: "Cancelled replacement must not start")
        unexpected.isInverted = true
        let runner = DownloadDrainRunner(started: [started, unexpected], cancelled: cancelled)
        let (manager, itemID) = makeManager(runner: runner)
        await manager.forceRedownload(itemID: itemID)
        await fulfillment(of: [started], timeout: 2)
        await manager.retryDownload(itemID: itemID)
        await fulfillment(of: [cancelled], timeout: 2)
        manager.cancelDownload(itemID: itemID)
        runner.finish(run: 0)
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(manager.videoItems?.wrappedValue.first?.status, .cancelled)
    }

    func testCancellingPlaylistSubmissionCancelsCurrentProcessAndSkipsRemainingEntries() async throws {
        let started = expectation(description: "Playlist process started")
        let cancelled = expectation(description: "Playlist cancellation reaches subprocess")
        let runner = DownloadDrainRunner(started: [started], cancelled: cancelled)
        let (manager, _) = makeManager(runner: runner)
        let items = try XCTUnwrap(manager.videoItems)
        let playlist = Task {
            await manager.startPlaylistDownload(
                url: "https://example.com/playlist", items: items,
                outputFolder: FileManager.default.temporaryDirectory
            )
        }
        await fulfillment(of: [started], timeout: 2)
        playlist.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        runner.finish(run: 0)
        let ids = await playlist.value
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(runner.startCount, 1)
        for id in ids {
            XCTAssertEqual(items.wrappedValue.first { $0.id == id }?.status, .cancelled)
        }
    }

    func testPlaylistCancellationBeforeChildStartsClearsDownloadingState() async throws {
        let unexpected = expectation(description: "Cancelled playlist must not launch a download")
        unexpected.isInverted = true
        let runner = DownloadDrainRunner(started: [unexpected], cancelled: XCTestExpectation(description: "Unused cancellation"))
        let (manager, _) = makeManager(runner: runner)
        var items: [VideoItem] = []
        var playlist: Task<[UUID], Never>?
        let binding = Binding<[VideoItem]>(get: { items }, set: {
            items = $0
            // Cancel precisely after the playlist marks its first row downloading,
            // before the tracked child and its cancellation handler begin running.
            if items.contains(where: { $0.isDownloading }) { playlist?.cancel() }
        })
        playlist = Task {
            await manager.startPlaylistDownload(
                url: "https://example.com/playlist", items: binding,
                outputFolder: FileManager.default.temporaryDirectory
            )
        }
        let ids = await playlist?.value
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(ids?.count, 2)
        XCTAssertEqual(runner.startCount, 0)
        XCTAssertTrue(items.allSatisfy { $0.status == .cancelled && !$0.isDownloading })
    }

    private func checkDrain(forceOverwrite: Bool, explicitCancel: Bool, rapidRetry: Bool) async throws {
        let started = expectation(description: "Original process started")
        let replacementStarted = expectation(description: "Replacement starts after drain")
        let cancelled = expectation(description: "Original process cancellation requested")
        let runner = DownloadDrainRunner(started: [started, replacementStarted], cancelled: cancelled)
        let (manager, itemID) = makeManager(runner: runner)
        await manager.forceRedownload(itemID: itemID)
        await fulfillment(of: [started], timeout: 2)
        if explicitCancel { manager.cancelDownload(itemID: itemID) }
        if forceOverwrite {
            await manager.forceRedownload(itemID: itemID)
        } else {
            await manager.retryDownload(itemID: itemID)
        }
        if rapidRetry { await manager.retryDownload(itemID: itemID) }
        await fulfillment(of: [cancelled], timeout: 2)
        // The runner deliberately ignores cancellation until finish, modeling pipe drain.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(manager.videoItems?.wrappedValue.first?.isDownloading, true)
        runner.finish(run: 0)
        await fulfillment(of: [replacementStarted], timeout: 2)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertEqual(runner.maximumConcurrentRuns, 1)
        manager.cancelDownload(itemID: itemID)
        runner.finish(run: 1)
    }

    private func makeManager(runner: DownloadDrainRunner) -> (DownloadManager, UUID) {
        let service = YTDLPService(updateService: DownloadDrainResolver(), subprocessRunner: runner)
        let manager = DownloadManager(ytdlpService: service, ytdlpAvailability: true)
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/download"), name: "Fixture", size: 0,
            duration: "--:--", durationSeconds: 0, thumbnailData: nil,
            status: .failed, progress: 0, eta: nil, outputURL: nil
        )
        item.sourceURL = "https://example.com/fixture"
        var items = [item]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        manager.outputFolder = FileManager.default.temporaryDirectory
        return (manager, item.id)
    }
}

private struct DownloadDrainResolver: YTDLPUpdating {
    func resolveYTDLPPath() async -> String? { "/fixture/yt-dlp" }
    func ensureDenoInstalled() async -> String? { nil }
}

private final class DownloadDrainRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let started: [XCTestExpectation]
    private let cancelled: XCTestExpectation
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var starts = 0
    private var maximum = 0

    init(started: [XCTestExpectation], cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    var startCount: Int { lock.withLock { starts } }
    var maximumConcurrentRuns: Int { lock.withLock { maximum } }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        if request.arguments.contains("--flat-playlist") {
            let json = #"{"entries":[{"url":"https://example.com/one","title":"One"},{"url":"https://example.com/two","title":"Two"}]}"#
            return SubprocessResult(
                terminationStatus: 0, termination: .exited, standardOutput: Data(json.utf8),
                standardError: Data(), discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0, duration: .milliseconds(1)
            )
        }
        // Optional thumbnail metadata must not suspend or count as a download.
        if request.arguments.contains("--no-download") {
            throw CocoaError(.fileReadUnknown)
        }
        let run = lock.withLock { let run = starts; starts += 1; return run }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    continuations[run] = continuation
                    maximum = max(maximum, continuations.count)
                }
                if run < started.count { started[run].fulfill() }
            }
        } onCancel: {
            if run == 0 { self.cancelled.fulfill() }
        }
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(),
            standardError: Data(), discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0, duration: .milliseconds(1)
        )
    }

    func finish(run: Int) {
        lock.withLock { continuations.removeValue(forKey: run) }?.resume()
    }
}
