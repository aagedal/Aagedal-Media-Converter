import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class PresetAutoMuteTests: XCTestCase {
    func testQueuePresetChangeSkipsRowsWithPresetOverride() {
        var items = [makeItem(), makeItem(override: .prores)]
        PresetManager.shared.applyAutoMuteSettings(
            to: &items, oldPreset: .h264, newPreset: .videoLoop, videoLoopDefaultMuted: true
        )
        XCTAssertTrue(items[0].isMuted)
        XCTAssertFalse(items[1].isMuted, "A ProRes override must keep its audio")
    }

    func testLeavingVideoLoopDoesNotUnmuteOverriddenRow() {
        var items = [makeItem(muted: true), makeItem(override: .videoLoop, muted: true)]
        PresetManager.shared.applyAutoMuteSettings(
            to: &items, oldPreset: .videoLoop, newPreset: .h264, videoLoopDefaultMuted: true
        )
        XCTAssertFalse(items[0].isMuted)
        XCTAssertTrue(items[1].isMuted)
    }

    func testMergingAppliesQueuePresetToOverriddenRows() {
        var items = [makeItem(override: .prores)]
        PresetManager.shared.applyAutoMuteSettings(
            to: &items, oldPreset: .h264, newPreset: .videoLoop, videoLoopDefaultMuted: true,
            respectingPresetOverrides: false
        )
        XCTAssertTrue(items[0].isMuted)
    }

    func testOnlyWaitingRowsChange() {
        var items = [makeItem(status: .done)]
        PresetManager.shared.applyAutoMuteSettings(
            to: &items, oldPreset: .h264, newPreset: .videoLoop, videoLoopDefaultMuted: true
        )
        XCTAssertFalse(items[0].isMuted)
    }

    func testSingleRowTransition() {
        var item = makeItem()
        PresetManager.applyAutoMuteTransition(to: &item, from: .h264, to: .videoLoop, videoLoopDefaultMuted: true)
        XCTAssertTrue(item.isMuted)
        PresetManager.applyAutoMuteTransition(to: &item, from: .videoLoop, to: .prores, videoLoopDefaultMuted: true)
        XCTAssertFalse(item.isMuted)

        // Respect the setting and leave manual choices alone when nothing changes.
        PresetManager.applyAutoMuteTransition(to: &item, from: .h264, to: .videoLoop, videoLoopDefaultMuted: false)
        XCTAssertFalse(item.isMuted)
        item.isMuted = false
        PresetManager.applyAutoMuteTransition(to: &item, from: .videoLoop, to: .videoLoop, videoLoopDefaultMuted: true)
        XCTAssertFalse(item.isMuted)
    }

    func testGroupPresetChangeUsesEffectivePresets() {
        var group = EncodingGroup(name: "Group", items: [makeItem(), makeItem(status: .done)])
        group.setPreset(.videoLoop, queuePreset: .h264, videoLoopDefaultMuted: true)
        XCTAssertEqual(group.preset, .videoLoop)
        XCTAssertTrue(group.items[0].isMuted)
        XCTAssertFalse(group.items[1].isMuted)

        // Clearing back to a queue preset of Video Loop keeps the effective preset.
        group.items[0].isMuted = false
        group.setPreset(nil, queuePreset: .videoLoop, videoLoopDefaultMuted: true)
        XCTAssertFalse(group.items[0].isMuted)

        group.items[0].isMuted = true
        group.setPreset(.h265, queuePreset: .videoLoop, videoLoopDefaultMuted: true)
        XCTAssertFalse(group.items[0].isMuted)
    }

    private func makeItem(
        override: ExportPreset? = nil,
        muted: Bool = false,
        status: ConversionManager.ConversionStatus = .waiting
    ) -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/\(UUID().uuidString).mov"), name: "Fixture", size: 0,
            duration: "--:--", durationSeconds: 0, thumbnailData: nil,
            status: status, progress: 0, eta: nil, outputURL: nil
        )
        item.presetOverride = override
        item.isMuted = muted
        return item
    }
}

final class PlaylistEntryAvailabilityTests: XCTestCase {
    func testUnavailableEntriesAreMarkedAndKept() throws {
        let fixture = """
        {"_type": "playlist", "entries": [
          {"url": "https://www.youtube.com/watch?v=a", "title": "Public clip", "duration": 61.0, "availability": "public"},
          {"url": "https://www.youtube.com/watch?v=b", "title": "[Private video]", "availability": null},
          {"url": "https://www.youtube.com/watch?v=c", "title": "[Deleted video]"},
          {"url": "https://www.youtube.com/watch?v=d", "title": "Members stream", "availability": "subscriber_only"},
          {"url": "https://www.youtube.com/watch?v=e", "title": "Premium film", "availability": "premium_only"},
          {"url": "https://www.youtube.com/watch?v=f", "title": "Age gated", "availability": "needs_auth"},
          {"url": "https://www.youtube.com/watch?v=g", "title": "Hidden", "availability": "private"},
          {"url": "https://www.youtube.com/watch?v=h", "title": "Unlisted clip", "availability": "unlisted"},
          {"title": "No URL"}
        ]}
        """
        let entries = try parse(fixture)
        XCTAssertEqual(entries.map(\.unavailability), [
            nil, .privateVideo, .deleted, .membersOnly, .premiumOnly, .needsAuth, .privateVideo, nil,
        ])
        XCTAssertEqual(entries.filter(\.isAvailable).map(\.url), [
            "https://www.youtube.com/watch?v=a", "https://www.youtube.com/watch?v=h",
        ])
        XCTAssertEqual(entries[0].duration, 61)
    }

    func testSingleVideoResponseBecomesOneEntry() throws {
        let fixture = """
        {"webpage_url": "https://example.com/v", "title": "Solo", "thumbnail": "https://example.com/t.jpg"}
        """
        let entries = try parse(fixture)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isAvailable)
        XCTAssertEqual(entries[0].thumbnailURL?.absoluteString, "https://example.com/t.jpg")
    }

    private func parse(_ json: String) throws -> [YTDLPPlaylistEntry] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return YTDLPPlaylistEntry.parse(playlistJSON: object)
    }
}

final class PendingDownloadEncodabilityTests: XCTestCase {
    func testQueuedPlaylistRowIsNotEncodableOrPlayable() {
        var item = makeItem()
        XCTAssertTrue(item.isEncodable)
        item.isQueuedForDownload = true
        XCTAssertTrue(item.hasPendingDownload)
        XCTAssertFalse(item.isEncodable)
        XCTAssertFalse(item.isPlayable)
    }

    func testConversionQueueSkipsPendingDownloads() {
        var queued = makeItem()
        queued.isQueuedForDownload = true
        var downloading = makeItem()
        downloading.isDownloading = true
        let ready = makeItem()
        XCTAssertEqual(
            ConversionQueueState.nextItem(in: [queued, downloading, ready], allowedItemIDs: nil)?.id, ready.id
        )
        XCTAssertNil(ConversionQueueState.nextItem(in: [queued], allowedItemIDs: [queued.id]))
        XCTAssertTrue(MergeCompatibilityPolicy.eligibleItems([queued, downloading]).isEmpty)
    }

    func testCancellingWaitingConversionsLeavesQueuedDownloadsAlone() {
        var queued = makeItem()
        queued.isQueuedForDownload = true
        var items = [queued, makeItem()]
        ConversionQueueState.cancel(&items, scope: .waitingAndConverting)
        XCTAssertEqual(items[0].status, .waiting)
        XCTAssertEqual(items[1].status, .cancelled)
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/tmp/downloading-\(UUID().uuidString)"), name: "Fixture", size: 0,
            duration: "--:--", durationSeconds: 0, thumbnailData: nil,
            status: .waiting, progress: 0, eta: nil, outputURL: nil
        )
    }
}
