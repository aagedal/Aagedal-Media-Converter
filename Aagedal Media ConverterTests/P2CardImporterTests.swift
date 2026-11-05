import XCTest
import os
@testable import Aagedal_Media_Converter

final class P2CardImporterTests: XCTestCase {
    private var card: URL!

    override func setUpWithError() throws {
        card = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2CardImporterTests-\(UUID().uuidString)", isDirectory: true)
        for folder in ["CLIP", "VIDEO", "AUDIO", "PROXY"] {
            try FileManager.default.createDirectory(
                at: card.appendingPathComponent("CONTENTS/\(folder)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: card)
    }

    private func addClip(_ name: String, audio: Int, shot: (id: String, offset: Int)? = nil,
                         next: String? = nil, timecode: String = "00:29:18:09") throws {
        let audioElements = String(repeating: "<Audio><AudioFormat>MXF</AudioFormat></Audio>", count: audio)
        let connection = next.map {
            "<Connection><Top><GlobalClipID>ID-TOP</GlobalClipID></Top><Next><GlobalClipID>ID-\($0)</GlobalClipID></Next></Connection>"
        } ?? ""
        let relation = shot.map {
            "<Relation><OffsetInShot>\($0.offset)</OffsetInShot><GlobalShotID>\($0.id)</GlobalShotID>\(connection)</Relation>"
        } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <P2Main xmlns="urn:schemas-Professional-Plug-in:P2:ClipMetadata:v3.1">
          <ClipContent>
            <ClipName>\(name)</ClipName>
            <GlobalClipID>ID-\(name)</GlobalClipID>
            <Duration>100</Duration>
            <EssenceList>
              <Video><VideoFormat>MXF</VideoFormat><StartTimecode>\(timecode)</StartTimecode></Video>
              \(audioElements)
            </EssenceList>
            \(relation)
            <ClipMetadata>
              <Access><CreationDate>2016-02-13T22:50:38+00:00</CreationDate></Access>
              <Shoot><StartDate>2016-02-13T22:50:40+00:00</StartDate></Shoot>
            </ClipMetadata>
          </ClipContent>
        </P2Main>
        """
        let contents = card.appendingPathComponent("CONTENTS")
        try xml.write(to: contents.appendingPathComponent("CLIP/\(name).XML"), atomically: true, encoding: .utf8)
        try Data().write(to: contents.appendingPathComponent("VIDEO/\(name).MXF"))
        try Data().write(to: contents.appendingPathComponent("PROXY/\(name).MP4"))
        for channel in 0..<audio {
            try Data().write(to: contents.appendingPathComponent(String(format: "AUDIO/%@%02d.MXF", name, channel)))
        }
    }

    func testCardRootIsFoundFromTheCardItsContentsFolderAndItsFiles() throws {
        try addClip("0001AB", audio: 2)
        let root = card.standardizedFileURL
        XCTAssertEqual(P2CardImporter.cardRoot(containing: card)?.path, root.path)
        XCTAssertEqual(P2CardImporter.cardRoot(containing: card.appendingPathComponent("CONTENTS"))?.path, root.path)
        XCTAssertEqual(P2CardImporter.cardRoot(containing: card.appendingPathComponent("CONTENTS/AUDIO/0001AB01.MXF"))?.path, root.path)
        XCTAssertNil(P2CardImporter.cardRoot(containing: FileManager.default.temporaryDirectory))
        // Media next to CONTENTS, as in a folder holding a copied card, is not on the card.
        XCTAssertNil(P2CardImporter.cardRoot(containing: card.appendingPathComponent("export.mov")))
        XCTAssertNil(P2CardImporter.cardRoot(containing: card.appendingPathComponent("Audio/zoom.wav")))
    }

    func testFilesNextToTheCardAndClipsWithoutReadableMetadataPassThrough() async throws {
        try addClip("0001AB", audio: 2)
        try "not xml".write(to: card.appendingPathComponent("CONTENTS/CLIP/0001AB.XML"), atomically: true, encoding: .utf8)
        let urls = [
            card.appendingPathComponent("CONTENTS/VIDEO/0001AB.MXF"),
            card.appendingPathComponent("export.mov"),
        ]
        let resolved = await P2CardImporter.resolveCards(in: urls)
        XCTAssertEqual(resolved.map(\.lastPathComponent), ["0001AB.MXF", "export.mov"])
    }

    func testSaveNextToOriginalUsesTheCardForRewrappedShots() async throws {
        try addClip("0001AB", audio: 2)
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        let output = P2ClipRewrapper.outputURL(for: shot)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try Data().write(to: output)
        // An already rewrapped shot is reused and records its card.
        let rewrapped = try await P2ClipRewrapper.shared.rewrap(shot) { _ in }
        XCTAssertEqual(rewrapped, output)

        let suite = "P2SaveNextToOriginal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        let destination = OutputDestinationSettings(defaults: defaults)
        XCTAssertEqual(
            destination.resolveFolder(for: output, defaultOutputFolder: "/Output", presetSuffix: "_x"),
            card.standardizedFileURL.path
        )
        // Without the card, outputs go to the output folder, never into the rewrap folder.
        try FileManager.default.removeItem(at: card)
        XCTAssertEqual(destination.resolveFolder(for: output, defaultOutputFolder: "/Output", presetSuffix: "_x"), "/Output")
    }

    func testFilesMapToTheirClipName() {
        let contents = URL(fileURLWithPath: "/card/CONTENTS")
        XCTAssertEqual(P2CardImporter.clipName(forFileAt: contents.appendingPathComponent("VIDEO/0004DM.MXF")), "0004DM")
        XCTAssertEqual(P2CardImporter.clipName(forFileAt: contents.appendingPathComponent("AUDIO/0004DM03.MXF")), "0004DM")
        XCTAssertEqual(P2CardImporter.clipName(forFileAt: contents.appendingPathComponent("PROXY/0004DM.MP4")), "0004DM")
    }

    func testClipMetadataAndEssenceFilesAreRead() throws {
        try addClip("0001AB", audio: 4)
        let clips = P2CardImporter.clips(onCard: card)
        XCTAssertEqual(clips.count, 1)
        let clip = try XCTUnwrap(clips.first)
        XCTAssertEqual(clip.name, "0001AB")
        XCTAssertEqual(clip.globalClipID, "ID-0001AB")
        XCTAssertEqual(clip.videoURL?.lastPathComponent, "0001AB.MXF")
        XCTAssertEqual(clip.audioURLs.map(\.lastPathComponent), ["0001AB00.MXF", "0001AB01.MXF", "0001AB02.MXF", "0001AB03.MXF"])
        XCTAssertEqual(clip.startTimecode, "00:29:18:09")
        // The shoot start is preferred over the file creation date.
        XCTAssertEqual(clip.recordingDate, ISO8601DateFormatter().date(from: "2016-02-13T22:50:40Z"))
        XCTAssertNil(clip.shotID)
    }

    func testMissingAudioChannelsAreLeftOut() throws {
        try addClip("0001AB", audio: 4)
        try FileManager.default.removeItem(at: card.appendingPathComponent("CONTENTS/AUDIO/0001AB02.MXF"))
        XCTAssertEqual(P2CardImporter.clips(onCard: card).first?.audioURLs.count, 2)
    }

    func testSpannedClipsJoinInShotOrderAndShotsSortByName() throws {
        try addClip("0003CC", audio: 2)
        try addClip("0002BB", audio: 2, shot: ("SHOT1", 15232))
        try addClip("0001AA", audio: 2, shot: ("SHOT1", 0))
        let shots = P2CardImporter.shots(from: P2CardImporter.clips(onCard: card))
        XCTAssertEqual(shots.map { $0.clips.map(\.name) }, [["0001AA", "0002BB"], ["0003CC"]])
        XCTAssertEqual(shots[0].name, "0001AA")
        XCTAssertNotEqual(shots[0].cacheKey, shots[1].cacheKey)
    }

    func testSpannedShotsReportMissingParts() throws {
        try addClip("0001AA", audio: 2, shot: ("SHOT1", 0), next: "0002BB")
        try addClip("0002BB", audio: 2, shot: ("SHOT1", 100), next: "0003CC")
        try addClip("0003CC", audio: 2, shot: ("SHOT1", 200))
        try addClip("0004DD", audio: 2)
        let clips = P2CardImporter.clips(onCard: card)
        XCTAssertEqual(clips.first { $0.name == "0001AA" }?.nextClipID, "ID-0002BB")
        let complete = P2CardImporter.shots(from: clips)
        XCTAssertEqual(complete.map(\.isMissingParts), [false, false])

        // The middle part on another card that wasn't imported.
        let withoutMiddle = P2CardImporter.shots(from: clips.filter { $0.name != "0002BB" })
        XCTAssertEqual(withoutMiddle.map(\.isMissingParts), [true, false])
        // The last or the first part missing.
        XCTAssertTrue(P2CardImporter.shots(from: clips.filter { $0.name != "0003CC" })[0].isMissingParts)
        XCTAssertTrue(P2CardImporter.shots(from: clips.filter { $0.name != "0001AA" })[0].isMissingParts)
    }

    @MainActor
    func testOverlayStaysUntilEveryImportEndsAndCancelStopsThemAll() {
        let progress = P2ImportProgress()
        let cancelled = OSAllocatedUnfairLock(initialState: 0)
        let first = progress.begin { cancelled.withLock { $0 += 1 } }
        let second = progress.begin { cancelled.withLock { $0 += 1 } }
        progress.cancel()
        XCTAssertEqual(cancelled.withLock { $0 }, 2)
        progress.end(first)
        XCTAssertTrue(progress.isActive)
        XCTAssertNotNil(progress.message)
        progress.end(second)
        XCTAssertFalse(progress.isActive)
        XCTAssertNil(progress.message)

        progress.showFailure("One.")
        progress.showFailure("Two.")
        XCTAssertEqual(progress.failureMessage, "One.\nTwo.")
    }

    func testDuplicateClipsFromACopiedCardAreJoinedOnce() throws {
        try addClip("0001AA", audio: 2, shot: ("SHOT1", 0))
        let clips = P2CardImporter.clips(onCard: card)
        let shots = P2CardImporter.shots(from: clips + clips)
        XCTAssertEqual(shots.map(\.clips.count), [1])
    }

    func testURLsOutsideP2CardsPassThroughUnchanged() async {
        let urls = [URL(fileURLWithPath: "/nonexistent/a.mov"), URL(fileURLWithPath: "/nonexistent/b.mxf")]
        let resolved = await P2CardImporter.resolveCards(in: urls)
        XCTAssertEqual(resolved, urls)
    }
}
