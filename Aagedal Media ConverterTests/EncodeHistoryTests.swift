import Foundation
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class EncodeHistoryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EncodeHistoryTests-\(UUID().uuidString)")
        suiteName = "EncodeHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Tracker

    func testTrackerReportsStartAndFinishTransitions() {
        var tracker = EncodeHistoryTracker()
        let a = UUID(), b = UUID()
        XCTAssertEqual(tracker.update([(a, .waiting), (b, .waiting)]), [])
        XCTAssertEqual(tracker.update([(a, .converting), (b, .waiting)]), [.started(a)])
        XCTAssertEqual(tracker.convertingCount, 1)
        // Progress ticks without status changes produce nothing.
        XCTAssertEqual(tracker.update([(a, .converting), (b, .waiting)]), [])
        XCTAssertEqual(tracker.update([(a, .done), (b, .converting)]), [.finished(a, .completed), .started(b)])
        XCTAssertEqual(tracker.update([(a, .done), (b, .failed)]), [.finished(b, .failed)])
    }

    func testTrackerTreatsRemovalMidEncodeAsCancelled() {
        var tracker = EncodeHistoryTracker()
        let a = UUID()
        _ = tracker.update([(a, .converting)])
        XCTAssertEqual(tracker.update([]), [.finished(a, .cancelled)])
        XCTAssertEqual(tracker.convertingCount, 0)
    }

    func testTrackerStartsRowsThatAppearAlreadyConverting() {
        var tracker = EncodeHistoryTracker()
        let a = UUID()
        XCTAssertEqual(tracker.update([(a, .converting)]), [.started(a)])
        XCTAssertEqual(tracker.update([(a, .cancelled)]), [.finished(a, .cancelled)])
    }

    // MARK: - Recipe

    func testRecipeRoundTripsPerItemSettings() throws {
        var source = makeItem()
        source.trimStart = 1.5
        source.trimEnd = 20
        source.isMuted = true
        source.comment = "note"
        source.outputFileNameOverride = "custom"
        source.timecodeConfig = TimecodeConfig(mode: .manual("01:00:00:00"))
        source.recursiveEncodingGenerations = 3

        let data = try JSONEncoder().encode(EncodeRecipe(item: source))
        let recipe = try JSONDecoder().decode(EncodeRecipe.self, from: data)
        var restored = makeItem()
        recipe.apply(to: &restored)

        XCTAssertEqual(restored.trimStart, 1.5)
        XCTAssertEqual(restored.trimEnd, 20)
        XCTAssertTrue(restored.isMuted)
        XCTAssertEqual(restored.comment, "note")
        XCTAssertEqual(restored.outputFileNameOverride, "custom")
        XCTAssertEqual(restored.timecodeConfig, TimecodeConfig(mode: .manual("01:00:00:00")))
        XCTAssertEqual(restored.recursiveEncodingGenerations, 3)
    }

    // MARK: - Store

    func testStoreRecordsLifecycleAndMarksRunningAsInterruptedOnNextLaunch() {
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap()
        var item = makeItem()
        observe(store, item)
        item.status = .converting
        observe(store, item)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.outcome, .running)
        XCTAssertEqual(store.runningItemCount, 1)
        store.flush()

        // Simulate a crash: a fresh store reads the file without endSession().
        let relaunched = EncodeHistoryStore(directory: directory, defaults: defaults)
        relaunched.bootstrap()
        XCTAssertEqual(relaunched.records.first?.outcome, .interrupted)
        XCTAssertEqual(relaunched.interruptedAtLaunchCount, 1)
        XCTAssertEqual(relaunched.sessions.count, 2)
        XCTAssertEqual(relaunched.sessions.first?.endedCleanly, false)
    }

    func testStoreCompletesRecordWithOutputSize() {
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap()
        var item = makeItem()
        item.status = .converting
        observe(store, item)
        item.status = .done
        item.outputFileSizeBytes = 1234
        observe(store, item)
        XCTAssertEqual(store.records.first?.outcome, .completed)
        XCTAssertEqual(store.records.first?.outputSizeBytes, 1234)
        XCTAssertNotNil(store.records.first?.finishedAt)

        store.endSession()
        let relaunched = EncodeHistoryStore(directory: directory, defaults: defaults)
        relaunched.bootstrap()
        XCTAssertEqual(relaunched.records.first?.outcome, .completed)
        XCTAssertEqual(relaunched.sessions.first?.endedCleanly, true)
    }

    func testDisabledStoreRecordsNothingButStillCountsRunningRows() {
        defaults.set(false, forKey: AppConstants.encodeHistoryEnabledKey)
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap()
        var item = makeItem()
        item.status = .converting
        observe(store, item)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.runningItemCount, 1)
    }

    func testRetentionPrunesOldRecords() {
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        let old = Date().addingTimeInterval(-100 * 86_400)
        store.bootstrap(now: old)
        var item = makeItem()
        item.status = .converting
        observe(store, item, now: old)
        item.status = .done
        observe(store, item, now: old)
        store.endSession(now: old)

        let relaunched = EncodeHistoryStore(directory: directory, defaults: defaults)
        relaunched.bootstrap()
        XCTAssertTrue(relaunched.records.isEmpty)
    }

    // MARK: - Last session

    func testSnapshotSkipsFinishedRowsAndKeepsGroups() {
        var waiting = makeItem()
        waiting.trimStart = 2
        var done = makeItem()
        done.status = .done
        var grouped = makeItem()
        grouped.status = .failed
        let group = EncodingGroup(name: "Card", items: [grouped], preset: .prores, concatEnabled: false)

        let snapshot = LastSessionStore.makeSnapshot(
            files: [waiting, done], groups: [group],
            order: [waiting.id, done.id, group.id], preset: .h265
        )
        XCTAssertEqual(snapshot.items.map(\.id), [waiting.id])
        XCTAssertEqual(snapshot.items.first?.recipe.trimStart, 2)
        XCTAssertEqual(snapshot.groups.first?.name, "Card")
        XCTAssertEqual(snapshot.groups.first?.presetRawValue, ExportPreset.prores.rawValue)
        XCTAssertEqual(snapshot.itemCount, 2)
    }

    func testSnapshotBecomesPendingOnNextLaunchAndIsConsumed() {
        let store = LastSessionStore(directory: directory, defaults: defaults)
        store.bootstrap()
        let item = makeItem()
        store.snapshotProvider = {
            LastSessionStore.makeSnapshot(files: [item], groups: [], order: [item.id], preset: .h265)
        }
        store.flush()

        let relaunched = LastSessionStore(directory: directory, defaults: defaults)
        relaunched.bootstrap()
        XCTAssertEqual(relaunched.pending?.items.map(\.id), [item.id])

        relaunched.consume(itemIDs: [item.id])
        XCTAssertNil(relaunched.pending)

        EncodeHistoryStore.writeQueue.sync {}
        let third = LastSessionStore(directory: directory, defaults: defaults)
        third.bootstrap()
        XCTAssertNil(third.pending)
    }

    func testIgnoredPendingSnapshotSurvivesAnEmptySession() {
        let first = LastSessionStore(directory: directory, defaults: defaults)
        first.bootstrap()
        let item = makeItem()
        first.snapshotProvider = { LastSessionStore.makeSnapshot(files: [item], groups: [], order: [item.id], preset: .h265) }
        first.flush()

        // Second run: offer shown but ignored, queue stays empty.
        let second = LastSessionStore(directory: directory, defaults: defaults)
        second.bootstrap()
        second.snapshotProvider = { LastSessionStore.makeSnapshot(files: [], groups: [], order: [], preset: .h265) }
        second.flush()

        let third = LastSessionStore(directory: directory, defaults: defaults)
        third.bootstrap()
        XCTAssertEqual(third.pending?.items.map(\.id), [item.id])
    }

    // MARK: - Restore requests

    func testRequeuedRecordsKeepTheirPresetPerItem() {
        let records = [makeRecord(preset: .prores), makeRecord(preset: .h264), makeRecord(preset: .prores)]
        let resolved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.source.url) })

        let request = QueueRestoreRequest.fromRecords(records, resolved: resolved)
        XCTAssertTrue(request.groups.isEmpty)
        XCTAssertEqual(request.items.map(\.preset), [.prores, .h264, .prores])
        // An empty queue adopts the most common preset.
        XCTAssertEqual(request.preset, .prores)
    }

    func testUnresolvedRecordsAreSkipped() {
        let record = makeRecord(preset: .h264)
        let request = QueueRestoreRequest.fromRecords([record], resolved: [:])
        XCTAssertTrue(request.isEmpty)
    }

    func testSnapshotRestoreKeepsPerItemPresetOverrides() {
        let plain = makeItem()
        var overridden = makeItem()
        overridden.presetOverride = .prores
        let snapshot = LastSessionStore.makeSnapshot(
            files: [plain, overridden], groups: [], order: [plain.id, overridden.id], preset: .h264
        )
        let request = QueueRestoreRequest.fromSnapshot(
            snapshot, selectedIDs: [plain.id, overridden.id],
            resolved: [plain.id: plain.url, overridden.id: overridden.url]
        )
        XCTAssertEqual(request.preset, .h264)
        XCTAssertEqual(request.items.map(\.preset), [.h264, .prores])
        XCTAssertTrue(request.groups.isEmpty)
    }

    func testRecipeCarriesPresetOverride() {
        var item = makeItem()
        item.presetOverride = .prores
        var restored = makeItem()
        EncodeRecipe(item: item).apply(to: &restored)
        XCTAssertEqual(restored.presetOverride, .prores)
    }

    func testSiblingRelinkFindsFilesMovedTogether() throws {
        let newFolder = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for name in ["a.mov", "b.mov"] {
            FileManager.default.createFile(atPath: newFolder.appendingPathComponent(name).path, contents: Data())
        }
        let matches = HistoryRelinker.siblingMatches(
            missingPaths: ["/gone/a.mov", "/gone/b.mov", "/gone/c.mov", "/elsewhere/b.mov"],
            relinkedFrom: "/gone/a.mov",
            to: newFolder.appendingPathComponent("a.mov")
        )
        XCTAssertEqual(Set(matches.keys), ["/gone/b.mov"])
    }

    // MARK: - Tolerant decoding

    /// A file as written before rollups existed, with fields trimmed to the
    /// bare minimum the way an older or hand-edited file might look.
    func testOldHistoryFileWithMissingFieldsLoads() throws {
        let session = UUID(), record = UUID()
        try writeHistory("""
        {
          "sessions": [{"id": "\(session)", "startedAt": "2026-10-20T10:00:00Z", "endedAt": "2026-10-20T11:00:00Z",
                        "endedCleanly": true, "deviceName": "Old Mac"}],
          "records": [{"id": "\(record)", "sessionID": "\(session)", "startedAt": "2026-10-20T10:05:00Z",
                       "outcome": "completed", "source": {"path": "/clips/a.mov"},
                       "recipe": {"trimStart": 2}, "presetRawValue": "VideoLoop"}]
        }
        """)
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap(now: date("2026-10-24T10:00:00Z"))
        XCTAssertEqual(store.records.map(\.id), [record])
        let loaded = try XCTUnwrap(store.records.first)
        XCTAssertEqual(loaded.recipe.trimStart, 2)
        XCTAssertTrue(loaded.recipe.includeDateTag)
        XCTAssertEqual(loaded.presetDisplayName, "VideoLoop")
        XCTAssertEqual(loaded.kind, .file)
        XCTAssertFalse(loaded.merged)
        XCTAssertNil(loaded.sourceFacts.durationSeconds)
        XCTAssertEqual(store.sessions.first?.endedCleanly, true)
        XCTAssertFalse(backups().contains { $0.contains("corrupt") })

        store.flush()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, EncodeHistoryFile.currentVersion)
    }

    func testOneCorruptRecordIsDroppedAndTheRestKept() throws {
        let session = UUID(), good = UUID()
        try writeHistory("""
        {
          "version": 1,
          "sessions": [{"id": "\(session)", "startedAt": "2026-10-20T10:00:00Z", "endedCleanly": true, "deviceName": "Mac"},
                       {"startedAt": 12}],
          "records": [
            {"id": "\(good)", "sessionID": "\(session)", "startedAt": "2026-10-20T10:05:00Z", "outcome": "failed",
             "source": {"path": "/clips/good.mov"}, "sourceFacts": {"width": "wide", "height": 1080},
             "recipe": {"cropConfig": {"unexpected": true}, "comment": "kept"},
             "presetRawValue": "VideoLoop", "presetDisplayName": "Loop", "deviceName": "Mac"},
            {"id": "\(UUID())", "sessionID": "\(session)", "startedAt": "not a date",
             "source": {"path": "/clips/bad.mov"}}
          ]
        }
        """)
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap(now: date("2026-10-24T10:00:00Z"))
        XCTAssertEqual(store.records.map(\.id), [good])
        XCTAssertEqual(store.records.first?.recipe.comment, "kept")
        XCTAssertNil(store.records.first?.recipe.cropConfig)
        XCTAssertNil(store.records.first?.sourceFacts.width)
        XCTAssertEqual(store.records.first?.sourceFacts.height, 1080)
        // The damaged original is kept next to the rewritten file.
        XCTAssertTrue(backups().contains { $0.contains("corrupt") })
    }

    func testNewerVersionFileIsBackedUpBeforeRewrite() throws {
        let session = UUID(), record = UUID()
        try writeHistory("""
        {
          "version": 99,
          "futureField": {"anything": [1, 2, 3]},
          "sessions": [{"id": "\(session)", "startedAt": "2026-10-20T10:00:00Z", "endedAt": "2026-10-20T11:00:00Z",
                        "endedCleanly": true, "deviceName": "Mac", "newSessionField": 1}],
          "records": [{"id": "\(record)", "sessionID": "\(session)", "startedAt": "2026-10-20T10:05:00Z",
                       "outcome": "teleported", "source": {"path": "/clips/a.mov"}, "presetRawValue": "VideoLoop",
                       "recipe": {"newRecipeField": "x"}, "deviceName": "Mac"}],
          "rollups": [{"month": "2026-01", "deviceName": "Mac", "encodeCount": 3, "newRollupField": 1}]
        }
        """)
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap(now: date("2026-10-24T10:00:00Z"))
        XCTAssertEqual(store.records.map(\.id), [record])
        // Unknown outcomes are treated as unfinished.
        XCTAssertEqual(store.records.first?.outcome, .interrupted)
        XCTAssertEqual(store.rollups.first?.encodeCount, 3)

        let backup = try XCTUnwrap(backups().first { $0.contains("v99") })
        let original = try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8)
        XCTAssertTrue(original.contains("futureField"))
    }

    func testUnreadableHistoryFileIsKeptAndStoreStartsFresh() throws {
        try writeHistory("this is not json")
        let store = EncodeHistoryStore(directory: directory, defaults: defaults)
        store.bootstrap()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(backups().contains { $0.contains("corrupt") })
    }

    func testLegacySnapshotStatusLabelIsStillShown() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = UUID()
        let json = """
        {"savedAt": "\(ISO8601DateFormatter().string(from: Date()))", "presetRawValue": "VideoLoop",
         "items": [{"id": "\(item)", "source": {"path": "/clips/a.mov"}, "recipe": {}, "statusLabel": "Venter"},
                   {"source": 5}],
         "groups": []}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("last-session.json"))
        let store = LastSessionStore(directory: directory, defaults: defaults)
        store.bootstrap()
        XCTAssertEqual(store.pending?.items.map(\.id), [item])
        XCTAssertEqual(store.pending?.items.first?.statusLabel, "Venter")
    }

    func testSnapshotPersistsRawStatusAndSourceBookmark() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.mov")
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data([0]))
        var item = makeItem(path: sourceURL.path)
        item.status = .failed

        let store = LastSessionStore(directory: directory, defaults: defaults)
        store.bootstrap()
        store.snapshotProvider = { LastSessionStore.makeSnapshot(files: [item], groups: [], order: [item.id], preset: .h265) }
        store.flush()

        let raw = try String(contentsOf: directory.appendingPathComponent("last-session.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"status\":\"failed\""))
        XCTAssertFalse(raw.contains("statusLabel"))

        let relaunched = LastSessionStore(directory: directory, defaults: defaults)
        relaunched.bootstrap()
        let pending = try XCTUnwrap(relaunched.pending?.items.first)
        XCTAssertEqual(pending.status, .failed)
        XCTAssertNotNil(pending.source.bookmark)
        XCTAssertEqual(pending.source.resolve()?.standardizedFileURL.path, sourceURL.standardizedFileURL.path)
    }

    // MARK: - Helpers

    private var historyURL: URL { directory.appendingPathComponent(EncodeHistoryStore.fileName) }

    private func writeHistory(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: historyURL)
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 != EncodeHistoryStore.fileName && $0.hasPrefix("encode-history") }
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func observe(_ store: EncodeHistoryStore, _ item: VideoItem, now: Date = Date()) {
        store.observe([(item.id, item.status)], resolve: { _ in
            HistoryObservedRow(item: item, preset: .h265, groupName: nil, merged: false)
        }, now: now)
    }

    private func makeItem(path: String = "/fixture/clip-\(UUID().uuidString).mov") -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: path), name: "clip.mov", size: 10,
            duration: "00:01:40", durationSeconds: 100, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
    }

    private func makeRecord(preset: ExportPreset) -> EncodeRecord {
        let item = makeItem()
        return EncodeRecord(
            sessionID: UUID(), startedAt: Date(),
            source: HistoryFileReference(path: item.url.path),
            sourceFacts: SourceFacts(item: item),
            recipe: EncodeRecipe(item: item),
            presetRawValue: preset.rawValue, presetDisplayName: preset.rawValue,
            deviceName: "Test"
        )
    }
}
