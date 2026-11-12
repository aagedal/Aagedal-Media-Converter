import Foundation
import XCTest
@testable import Aagedal_Media_Converter

/// History sync between two simulated Macs that share a temporary "iCloud
/// Drive" folder. Never touches the real sync location.
@MainActor
final class EncodeHistorySyncTests: XCTestCase {
    private var root: URL!
    private var cloud: URL!
    private var suiteNames: [String] = []
    private var calendar: Calendar!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EncodeHistorySyncTests-\(UUID().uuidString)")
        cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        self.calendar = calendar
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
    }

    // MARK: - Per-device files

    func testEachMacWritesOnlyItsOwnFileWithoutBookmarks() async throws {
        let a = makeStore("a"), b = makeStore("b")
        let source = root.appendingPathComponent("source.mov")
        try Data("x".utf8).write(to: source)
        try recordEncode(on: a, path: source.path)
        try recordEncode(on: b)
        a.flush()
        b.flush()

        XCTAssertEqual(try cloudFileNames(), ["device-a.json", "device-b.json"])
        let fileA = try readCloudFile("device-a.json")
        XCTAssertEqual(fileA.deviceID, "device-a")
        XCTAssertEqual(fileA.deviceName, "Mac a")
        XCTAssertEqual(fileA.records.map(\.id), a.records.map(\.id))
        XCTAssertTrue(fileA.sessions.allSatisfy { $0.deviceID == "device-a" })
        // The local record keeps its bookmark; the synced copy never has one.
        XCTAssertNotNil(a.records.first?.source.bookmark)
        XCTAssertNil(fileA.records.first?.source.bookmark)
        XCTAssertFalse(try String(contentsOf: cloud.appendingPathComponent("History/device-a.json"), encoding: .utf8)
            .contains("bookmark"))
        XCTAssertEqual(try readCloudFile("device-b.json").records.map(\.id), b.records.map(\.id))
    }

    func testOtherMacsRecordsAreMergedAndAttributed() async throws {
        let a = makeStore("a"), b = makeStore("b")
        try recordEncode(on: a)
        try recordEncode(on: b)
        b.flush()
        await a.reloadRemote()

        XCTAssertEqual(a.records.count, 1)
        XCTAssertEqual(a.allRecords.count, 2)
        let foreign = try XCTUnwrap(a.allRecords.first { $0.deviceID == "device-b" })
        XCTAssertFalse(a.isFromThisMac(foreign))
        XCTAssertEqual(a.deviceName(for: "device-b"), "Mac b")
        XCTAssertEqual(a.historyDeviceIDs, ["device-a", "device-b"])
        XCTAssertEqual(a.syncDevices.map(\.id), ["device-b"])
        XCTAssertEqual(a.syncDevices.first?.state, .synced)
        XCTAssertEqual(a.syncDevices.first?.recordCount, 1)
        // B's sessions came along, so the browser can group its records.
        XCTAssertTrue(a.allSessions.contains { $0.id == foreign.sessionID })

        XCTAssertEqual(a.statistics(for: .all).encodeCount, 2)
        XCTAssertEqual(a.statistics(for: .all, deviceID: "device-b").encodeCount, 1)
        XCTAssertEqual(a.statistics(for: .all).deviceCounts, ["device-a": 1, "device-b": 1])
    }

    func testClearOnlyAffectsThisMac() async throws {
        let a = makeStore("a"), b = makeStore("b")
        try recordEncode(on: a)
        try recordEncode(on: b)
        b.flush()
        let fileB = try Data(contentsOf: cloud.appendingPathComponent("History/device-b.json"))
        await a.reloadRemote()

        a.clearAll()
        a.flush()
        XCTAssertTrue(a.records.isEmpty)
        XCTAssertEqual(a.allRecords.map(\.deviceID), ["device-b"])
        XCTAssertTrue(try readCloudFile("device-a.json").records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("History/device-b.json")), fileB)
    }

    func testRemovingAnotherMacsRecordIsNotPossible() async throws {
        let a = makeStore("a"), b = makeStore("b")
        try recordEncode(on: b)
        b.flush()
        await a.reloadRemote()
        let foreignID = try XCTUnwrap(a.allRecords.first?.id)
        a.removeRecords([foreignID])
        XCTAssertEqual(a.allRecords.map(\.id), [foreignID])
    }

    func testDisablingSyncRemovesOnlyThisMacsFile() async throws {
        let a = makeStore("a"), b = makeStore("b")
        try recordEncode(on: a)
        try recordEncode(on: b)
        a.flush()
        b.flush()
        await a.reloadRemote()
        XCTAssertEqual(a.allRecords.count, 2)

        a.setSyncEnabled(false)
        XCTAssertEqual(try cloudFileNames(), ["device-b.json"])
        XCTAssertEqual(a.allRecords.map(\.id), a.records.map(\.id))
        XCTAssertTrue(a.syncDevices.isEmpty)
        // Later changes stay local.
        try recordEncode(on: a)
        a.flush()
        XCTAssertEqual(try cloudFileNames(), ["device-b.json"])
    }

    func testRelinkingAnotherMacsRecordDoesNotWriteItsFile() async throws {
        let a = makeStore("a"), b = makeStore("b")
        try recordEncode(on: b, path: "/Volumes/Other Mac/clip.mov")
        b.flush()
        let fileB = try Data(contentsOf: cloud.appendingPathComponent("History/device-b.json"))
        await a.reloadRemote()
        let record = try XCTUnwrap(a.allRecords.first)
        XCTAssertNil(record.source.resolve())

        let moved = root.appendingPathComponent("clip.mov")
        try Data("x".utf8).write(to: moved)
        a.relinkSource(of: [record.id], oldPath: record.source.path, to: moved)
        XCTAssertEqual(a.allRecords.first?.source.path, moved.path)
        XCTAssertEqual(a.allRecords.first?.source.resolve(), moved)
        a.flush()
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("History/device-b.json")), fileB)
    }

    func testUnavailableLocationIsReported() async {
        let a = makeStore("a", locationAvailable: false)
        await a.reloadRemote()
        XCTAssertNotNil(a.syncErrorMessage)
        XCTAssertTrue(a.syncDevices.isEmpty)
    }

    // MARK: - Merge

    func testMergeDeduplicatesByIDPreferringLocalThenTheMoreFinishedCopy() {
        let session = UUID()
        let shared = makeRecord(session: session, daysAgo: 1, finished: true, device: "device-a")
        var remoteCopyOfLocal = shared
        remoteCopyOfLocal.presetDisplayName = "Stale"
        let running = makeRecord(session: session, daysAgo: 1, finished: false, device: "device-b")
        var finished = running
        finished.outcome = .completed
        finished.finishedAt = running.startedAt.addingTimeInterval(30)

        var rollup = MonthlyRollup(month: "2025-01", deviceName: "Mac b", deviceID: "device-b")
        rollup.encodeCount = 3
        var smallerRollup = rollup
        smallerRollup.encodeCount = 2

        let original = remoteFile("device-b", records: [remoteCopyOfLocal, running], rollups: [smallerRollup])
        let conflictCopy = remoteFile("device-b", records: [finished], rollups: [rollup])
        let merged = EncodeHistoryMerge.merge(
            localRecords: [shared], localSessions: [], localRollups: [],
            localDeviceID: "device-a", remote: [original, conflictCopy], cutoff: nil, calendar: calendar
        )

        XCTAssertEqual(merged.records.count, 2)
        XCTAssertEqual(merged.records.first { $0.id == shared.id }?.presetDisplayName, shared.presetDisplayName)
        XCTAssertEqual(merged.records.first { $0.id == running.id }?.outcome, .completed)
        XCTAssertEqual(merged.rollups.map(\.encodeCount), [3])
    }

    func testMergeFillsInDeviceIDsFromTheFile() {
        var legacyLocal = makeRecord(session: UUID(), daysAgo: 1, finished: true, device: nil)
        legacyLocal.deviceName = "Mac a"
        var legacyRemote = makeRecord(session: UUID(), daysAgo: 1, finished: true, device: nil)
        legacyRemote.deviceName = ""
        var file = remoteFile("device-b", records: [legacyRemote])
        file.content?.deviceName = "Mac b"
        let merged = EncodeHistoryMerge.merge(
            localRecords: [legacyLocal], localSessions: [], localRollups: [MonthlyRollup(month: "2025-01", deviceName: "Mac a")],
            localDeviceID: "device-a", remote: [file], cutoff: nil, calendar: calendar
        )
        XCTAssertEqual(Set(merged.records.map(\.deviceID)), ["device-a", "device-b"])
        XCTAssertEqual(merged.records.first { $0.deviceID == "device-b" }?.deviceName, "Mac b")
        XCTAssertEqual(merged.rollups.first?.deviceID, "device-a")
    }

    func testRemoteRecordsFollowThisMacsRetentionButStayInStatistics() {
        let now = Date()
        let old = makeRecord(session: UUID(), daysAgo: 100, finished: true, device: "device-b", now: now)
        let recent = makeRecord(session: UUID(), daysAgo: 2, finished: true, device: "device-b", now: now)
        // A Mac that crashed mid-encode and never came back.
        let abandoned = makeRecord(session: UUID(), daysAgo: 120, finished: false, device: "device-b", now: now)
        let oldSession = HistorySession(id: old.sessionID, startedAt: old.startedAt, endedAt: old.startedAt,
                                        endedCleanly: true, deviceName: "Mac b", deviceID: "device-b")
        let file = remoteFile("device-b", records: [old, recent, abandoned], sessions: [oldSession])

        let merged = EncodeHistoryMerge.merge(
            localRecords: [], localSessions: [], localRollups: [], localDeviceID: "device-a",
            remote: [file], cutoff: EncodeHistoryRetention.cutoff(days: 90, now: now), calendar: calendar
        )
        XCTAssertEqual(merged.records.map(\.id), [recent.id])
        XCTAssertTrue(merged.sessions.isEmpty)
        XCTAssertEqual(merged.rollups.reduce(0) { $0 + $1.encodeCount }, 2)
        XCTAssertEqual(merged.rollups.reduce(0) { $0 + $1.sessionCount }, 1)
        XCTAssertTrue(merged.rollups.allSatisfy { $0.deviceID == "device-b" })

        let summary = EncodeStatistics.summarize(
            records: merged.records, sessions: merged.sessions, rollups: merged.rollups,
            period: .all, currentSessionID: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.encodeCount, 3)

        let keepForever = EncodeHistoryMerge.merge(
            localRecords: [], localSessions: [], localRollups: [], localDeviceID: "device-a",
            remote: [file], cutoff: EncodeHistoryRetention.cutoff(days: 0, now: now), calendar: calendar
        )
        XCTAssertEqual(keepForever.records.count, 3)
    }

    func testRetentionOnlyPrunesThisMacsOwnFile() async throws {
        let a = makeStore("a", bootstrap: false)
        let old = Date().addingTimeInterval(-100 * 86_400)
        a.bootstrap(now: old)
        var item = makeItem()
        item.status = .converting
        observe(a, item, now: old)
        item.status = .done
        observe(a, item, now: old)
        a.endSession(now: old)

        let relaunched = makeStore("a", bootstrap: false)
        relaunched.bootstrap()
        relaunched.flush()
        let file = try readCloudFile("device-a.json")
        XCTAssertTrue(file.records.isEmpty)
        XCTAssertEqual(file.rollups.reduce(0) { $0 + $1.encodeCount }, 1)
    }

    // MARK: - Tolerant reading

    func testForeignFilesAreReadTolerantly() async throws {
        let a = makeStore("a")
        let history = cloud.appendingPathComponent("History", isDirectory: true)
        let valid = remoteFile("device-c", records: [makeRecord(session: UUID(), daysAgo: 1, finished: true, device: nil)])
        let validData = try EncodeHistoryStore.encoder.encode(valid.content!)

        try Data("not json".utf8).write(to: history.appendingPathComponent("device-d.json"))
        try validData.prefix(validData.count / 2).write(to: history.appendingPathComponent("device-e.json"))
        try Data().write(to: history.appendingPathComponent(".device-f.json.icloud"))
        try Data().write(to: history.appendingPathComponent(".DS_Store"))
        // A conflict copy of this Mac's own file.
        try EncodeHistoryStore.encoder.encode(remoteFile("device-a", records: []).content!)
            .write(to: history.appendingPathComponent("device-a 2.json"))
        // A newer version with unknown fields and one damaged record.
        let future = """
        {"version": 99, "deviceID": "device-g", "deviceName": "Future Mac", "futureField": {"x": 1},
         "sessions": [],
         "records": [
           {"id": "\(UUID().uuidString)", "sessionID": "\(UUID().uuidString)", "startedAt": "2026-11-01T10:00:00Z",
            "outcome": "teleported", "source": {"path": "/clips/a.mov", "bookmark": "AAAA"}, "newThing": true},
           {"id": "broken"}
         ],
         "rollups": []}
        """
        try Data(future.utf8).write(to: history.appendingPathComponent("device-g.json"))
        try validData.write(to: history.appendingPathComponent("device-c.json"))

        await a.reloadRemote()

        let states = Dictionary(uniqueKeysWithValues: a.syncDevices.map { ($0.id, $0.state) })
        XCTAssertEqual(states, [
            "device-c": .synced, "device-d": .unreadable, "device-e": .unreadable,
            "device-f": .downloading, "device-g": .newerVersion,
        ])
        XCTAssertEqual(a.syncDevices.first { $0.id == "device-g" }?.name, "Future Mac")
        let futureRecord = try XCTUnwrap(a.allRecords.first { $0.deviceID == "device-g" })
        XCTAssertEqual(futureRecord.outcome, .interrupted)
        XCTAssertNil(futureRecord.source.bookmark)
        XCTAssertEqual(a.allRecords.filter { !a.isFromThisMac($0) }.count, 2)

        // Other Macs' files are never rewritten, damaged or not.
        a.flush()
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("device-d.json")), Data("not json".utf8))
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("device-g.json")), Data(future.utf8))
    }

    func testScanReusesUnchangedFilesAndPicksUpChanges() throws {
        let history = cloud.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let url = history.appendingPathComponent("device-b.json")
        try EncodeHistoryStore.encoder.encode(remoteFile("device-b", records: []).content!).write(to: url)
        let first = HistorySyncFolder.scan(directory: history, excludingDeviceID: "device-a")
        XCTAssertEqual(first.map(\.status), [.loaded])

        let cache = Dictionary(uniqueKeysWithValues: first.map { ($0.url.lastPathComponent, $0) })
        let record = makeRecord(session: UUID(), daysAgo: 1, finished: true, device: "device-b")
        try EncodeHistoryStore.encoder.encode(remoteFile("device-b", records: [record]).content!).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let second = HistorySyncFolder.scan(directory: history, excludingDeviceID: "device-a", cache: cache)
        XCTAssertEqual(second.first?.content?.records.map(\.id), [record.id])
    }

    func testDeviceIDsFromFileNames() {
        XCTAssertEqual(HistorySyncFolder.deviceID(forFileName: "abc.json")?.id, "abc")
        XCTAssertEqual(HistorySyncFolder.deviceID(forFileName: "abc 2.json")?.id, "abc")
        XCTAssertEqual(HistorySyncFolder.deviceID(forFileName: ".abc.json.icloud")?.isPlaceholder, true)
        XCTAssertEqual(HistorySyncFolder.deviceID(forFileName: ".abc.json.icloud")?.id, "abc")
        XCTAssertNil(HistorySyncFolder.deviceID(forFileName: ".DS_Store"))
        XCTAssertNil(HistorySyncFolder.deviceID(forFileName: "notes.txt"))
        XCTAssertNil(HistorySyncFolder.deviceID(forFileName: ".abc.json.sb-1234"))
    }

    func testFallbackDeviceIDIsStable() throws {
        let name = "EncodeHistorySyncTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let id = EncodeHistoryDevice.fallbackID(defaults: defaults)
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(EncodeHistoryDevice.fallbackID(defaults: defaults), id)
        XCTAssertFalse(EncodeHistoryDevice.localID.isEmpty)
        XCTAssertFalse(EncodeHistoryDevice.localID.contains(" "))
    }

    // MARK: - Helpers

    private func makeStore(_ name: String, locationAvailable: Bool = true, bootstrap: Bool = true) -> EncodeHistoryStore {
        let suiteName = "EncodeHistorySyncTests-\(name)-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppConstants.encodeHistorySyncEnabledKey)
        let folder: URL? = locationAvailable ? cloud : nil
        let store = EncodeHistoryStore(
            directory: root.appendingPathComponent("local-\(name)", isDirectory: true),
            defaults: defaults, calendar: calendar,
            deviceID: "device-\(name)", deviceName: "Mac \(name)",
            syncFolder: { folder }
        )
        if bootstrap { store.bootstrap() }
        return store
    }

    private func recordEncode(on store: EncodeHistoryStore, path: String? = nil) throws {
        var item = makeItem(path: path)
        item.status = .converting
        observe(store, item)
        item.status = .done
        observe(store, item)
    }

    private func observe(_ store: EncodeHistoryStore, _ item: VideoItem, now: Date = Date()) {
        store.observe([(item.id, item.status)], resolve: { _ in
            HistoryObservedRow(item: item, preset: .h265, groupName: nil, merged: false)
        }, now: now)
    }

    private func makeItem(path: String? = nil) -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: path ?? "/fixture/clip-\(UUID().uuidString).mov"), name: "clip.mov", size: 10,
            duration: "00:01:40", durationSeconds: 100, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
    }

    private func makeRecord(session: UUID, daysAgo: Int, finished: Bool, device: String?, now: Date = Date()) -> EncodeRecord {
        let started = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return EncodeRecord(
            sessionID: session, startedAt: started,
            finishedAt: finished ? started.addingTimeInterval(30) : nil,
            outcome: finished ? .completed : .running,
            source: HistoryFileReference(path: "/clips/clip-\(UUID().uuidString).mov"),
            sourceFacts: SourceFacts(), recipe: EncodeRecipe(),
            presetRawValue: "h265", presetDisplayName: "HEVC",
            deviceName: device.map { "Mac \($0.dropFirst("device-".count))" } ?? "",
            deviceID: device
        )
    }

    private func remoteFile(
        _ deviceID: String,
        records: [EncodeRecord],
        sessions: [HistorySession] = [],
        rollups: [MonthlyRollup] = []
    ) -> HistorySyncFile {
        let content = HistorySyncFolder.makeFile(
            records: records, sessions: sessions, rollups: rollups,
            deviceID: deviceID, deviceName: "Mac \(deviceID.dropFirst("device-".count))", now: Date()
        )
        return HistorySyncFile(
            url: cloud.appendingPathComponent("History/\(deviceID).json"),
            deviceID: deviceID, status: .loaded, content: content
        )
    }

    private func cloudFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("History").path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func readCloudFile(_ name: String) throws -> EncodeHistoryFile {
        try EncodeHistoryStore.decoder.decode(
            EncodeHistoryFile.self,
            from: Data(contentsOf: cloud.appendingPathComponent("History").appendingPathComponent(name))
        )
    }
}
