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
        // Copies that changed the folder's case are still cards (the file system ignores case).
        XCTAssertEqual(P2CardImporter.cardRoot(containing: card.appendingPathComponent("Contents/AUDIO/0001AB01.MXF"))?.path, root.path)
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
        // Importing a backup copy later keeps the card that is still there.
        let backup = card.deletingLastPathComponent().appendingPathComponent("P2Backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: card, to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }
        let backupShot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: backup)).first)
        _ = try await P2ClipRewrapper.shared.rewrap(backupShot) { _ in }
        XCTAssertEqual(
            destination.resolveFolder(for: output, defaultOutputFolder: "/Output", presetSuffix: "_x"),
            card.standardizedFileURL.path
        )

        // A different card at the same path doesn't receive the outputs.
        let xml = card.appendingPathComponent("CONTENTS/CLIP/0001AB.XML")
        try String(contentsOf: xml, encoding: .utf8).replacingOccurrences(of: "ID-0001AB", with: "ID-OTHER")
            .write(to: xml, atomically: true, encoding: .utf8)
        XCTAssertEqual(destination.resolveFolder(for: output, defaultOutputFolder: "/Output", presetSuffix: "_x"), "/Output")

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

        // Overlapping imports share the bar by size, and an ended import's message goes away.
        let large = progress.begin(weight: 300) {}
        progress.update(large, message: "Large", fraction: 1)
        let small = progress.begin(weight: 100) {}
        XCTAssertEqual(progress.fraction ?? 0, 0.75, accuracy: 0.001)
        progress.update(small, message: "Small", fraction: 0.5)
        XCTAssertEqual(progress.fraction ?? 0, 0.875, accuracy: 0.001)
        XCTAssertEqual(progress.message, "Small")
        progress.update(large, fraction: 0.2)  // Never moves back.
        XCTAssertEqual(progress.fraction ?? 0, 0.875, accuracy: 0.001)
        progress.end(small)
        XCTAssertEqual(progress.message, "Large")
        XCTAssertEqual(progress.fraction ?? 0, 1, accuracy: 0.001)
        progress.end(large)
        progress.update(large, fraction: 0.5)  // Late updates don't bring the overlay back.
        XCTAssertFalse(progress.isActive)

        progress.showFailure("One.")
        progress.showFailure("Two.")
        XCTAssertEqual(progress.failureMessage, "One.\nTwo.")
    }

    // MARK: - Rewrapping real essence

    private var binaries: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Aagedal Media Converter/Binaries", isDirectory: true)
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) async throws -> SubprocessResult {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: binaries.appendingPathComponent(tool), arguments: arguments,
            currentDirectoryURL: directory, timeout: .seconds(60)
        ))
        guard result.succeeded else {
            throw NSError(domain: "P2CardImporterTests", code: Int(result.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool): \(result.standardErrorText)"])
        }
        return result
    }

    /// Replaces a clip's placeholder files with DVCPRO HD 1080i video and two mono PCM
    /// channels as OP-Atom MXF sharing one package, like a P2 camera writes them.
    private func writeP2Essence(for name: String, timecode: String) async throws {
        let work = card.appendingPathComponent("work-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=1440x1080:r=25:d=0.4", "-vf", "setfield=tff",
            "-c:v", "dvvideo", "-pix_fmt", "yuv422p", "-flags", "+ilme+ildct", "-f", "rawvideo", "video.dv"], in: work)
        _ = try await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=f=440:d=0.4:r=48000", "-ac", "2", "-c:a", "pcm_s24le", "audio.wav"], in: work)
        _ = try await run("raw2bmx", ["-t", "avid", "-f", "25", "-y", timecode, "-o", "clip",
                                      "--dv100_1080i", "video.dv", "--wave", "audio.wav"], in: work)
        let contents = card.appendingPathComponent("CONTENTS")
        for (file, destination) in [("clip_v1.mxf", "VIDEO/\(name).MXF"), ("clip_a1.mxf", "AUDIO/\(name)00.MXF"),
                                    ("clip_a2.mxf", "AUDIO/\(name)01.MXF")] {
            let target = contents.appendingPathComponent(destination)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: work.appendingPathComponent(file), to: target)
        }
    }

    /// Rewraps the card's only shot, with no earlier rewrap of it left over.
    private func rewrapOnlyShot() async throws -> URL {
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        let folder = P2ClipRewrapper.outputURL(for: shot).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try await P2ClipRewrapper.shared.rewrap(shot) { _ in }
    }

    private func probe(_ url: URL) async throws -> String {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: binaries.appendingPathComponent("ffmpeg"), arguments: ["-hide_banner", "-i", url.path],
            timeout: .seconds(60)
        ))
        return result.standardErrorText
    }

    func testSpannedShotIsRewrappedToOneMXFWithTimecodeAndFieldOrder() async throws {
        let unique = String(UUID().uuidString.prefix(4))
        try addClip("0001\(unique)", audio: 2, shot: ("SHOT-\(unique)", 0), timecode: "10:00:00:00")
        try addClip("0002\(unique)", audio: 2, shot: ("SHOT-\(unique)", 10), timecode: "10:00:00:10")
        try await writeP2Essence(for: "0001\(unique)", timecode: "10:00:00:00")
        try await writeP2Essence(for: "0002\(unique)", timecode: "10:00:00:10")

        let output = try await rewrapOnlyShot()
        XCTAssertEqual(output.pathExtension, "mxf")
        XCTAssertEqual(output.deletingPathExtension().lastPathComponent, "0001\(unique)")
        let info = try await probe(output)
        XCTAssertTrue(info.contains("timecode        : 10:00:00:00"), info)
        XCTAssertTrue(info.contains("Duration: 00:00:00.80"), info)
        XCTAssertTrue(info.contains("dvvideo") && info.contains("top first"), info)
        XCTAssertEqual(info.components(separatedBy: "Audio: pcm_s24le").count - 1, 2, info)
        // Stream Copy keeps the card's MXF by default.
        let suite = "P2StreamCopy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CodecExportSettings(preset: .streamCopy, defaults: defaults)?.outputExtension(for: output), "mxf")
    }

    func testShotBMXCannotReadIsRewrappedToMatroska() async throws {
        let name = "0001\(UUID().uuidString.prefix(4))"
        try addClip(name, audio: 2)
        // ffmpeg's OP-Atom files each have their own package, which bmx can't join into one clip.
        let contents = card.appendingPathComponent("CONTENTS")
        _ = try await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=25:d=0.4", "-c:v", "dnxhd", "-b:v", "36M",
            "-pix_fmt", "yuv422p", "-f", "mxf_opatom", contents.appendingPathComponent("VIDEO/\(name).MXF").path])
        for channel in 0..<2 {
            _ = try await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=f=440:d=0.4:r=48000", "-c:a", "pcm_s24le", "-f", "mxf_opatom",
                contents.appendingPathComponent(String(format: "AUDIO/%@%02d.MXF", name, channel)).path])
        }

        let output = try await rewrapOnlyShot()
        XCTAssertEqual(output.pathExtension, "mkv")
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: P2ClipRewrapper.outputURL(for: shot).path))
        let info = try await probe(output)
        XCTAssertTrue(info.contains("TIMECODE        : 00:29:18:09"), info)
        XCTAssertTrue(info.contains("Video: dnxhd"), info)
        XCTAssertEqual(info.components(separatedBy: "Audio: pcm_s24le").count - 1, 2, info)

        // The fallback counts as done, so importing the card again doesn't run bmx again.
        XCTAssertEqual(P2ClipRewrapper.cachedRewrap(for: shot), output)
        let again = try await P2ClipRewrapper.shared.rewrap(shot) { _ in }
        XCTAssertEqual(again, output)
    }

    func testMatroskaFrom47IsRedoneAsMXFUnlessTheShotHasNoVideo() throws {
        let name = "0001\(UUID().uuidString.prefix(4))"
        try addClip(name, audio: 2)
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        let matroska = P2ClipRewrapper.matroskaOutputURL(for: shot)
        let folder = matroska.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: matroska)
        XCTAssertNil(P2ClipRewrapper.cachedRewrap(for: shot))

        // An audio-only shot goes to Matroska in 4.8 too.
        try FileManager.default.removeItem(at: card.appendingPathComponent("CONTENTS/VIDEO/\(name).MXF"))
        let audioOnly = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        XCTAssertEqual(audioOnly.cacheKey, shot.cacheKey)
        XCTAssertEqual(P2ClipRewrapper.cachedRewrap(for: audioOnly), matroska)
    }

    func testMXFRewrapMarksTheMatroskaFrom47AsSuperseded() async throws {
        let name = "0001\(UUID().uuidString.prefix(4))"
        try addClip(name, audio: 2, timecode: "10:00:00:00")
        try await writeP2Essence(for: name, timecode: "10:00:00:00")
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        let matroska = P2ClipRewrapper.matroskaOutputURL(for: shot)
        let folder = matroska.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: matroska)

        let output = try await P2ClipRewrapper.shared.rewrap(shot) { _ in }
        XCTAssertEqual(output.pathExtension, "mxf")
        // A restored session may still point at the Matroska, so it stays for now.
        XCTAssertTrue(FileManager.default.fileExists(atPath: matroska.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".matroska-superseded").path))
    }

    func testBMXArgumentsJoinTheClipsInShotOrder() throws {
        try addClip("0001AA", audio: 4, shot: ("SHOT1", 0))
        try addClip("0002BB", audio: 2, shot: ("SHOT1", 100))
        let shot = try XCTUnwrap(P2CardImporter.shots(from: P2CardImporter.clips(onCard: card)).first)
        let output = URL(fileURLWithPath: "/rewrap/0001AA.partial.mxf")
        let arguments = P2ClipRewrapper.bmxArguments(for: shot, channelCount: 2, output: output)
        let contents = card.appendingPathComponent("CONTENTS")
        XCTAssertEqual(arguments, [
            "-p", "-t", "op1a", "--no-reorder", "--clip", "0001AA",
            "-y", "00:29:18:09", "--create-date", "2016-02-13T22:50:40:00",
            "-o", output.path,
            // Only the channels every part has.
            contents.appendingPathComponent("VIDEO/0001AA.MXF").path,
            contents.appendingPathComponent("AUDIO/0001AA00.MXF").path,
            contents.appendingPathComponent("AUDIO/0001AA01.MXF").path,
            contents.appendingPathComponent("VIDEO/0002BB.MXF").path,
            contents.appendingPathComponent("AUDIO/0002BB00.MXF").path,
            contents.appendingPathComponent("AUDIO/0002BB01.MXF").path,
        ])
    }

    func testDuplicateClipsFromACopiedCardAreJoinedOnce() throws {
        try addClip("0001AA", audio: 2, shot: ("SHOT1", 0))
        let clips = P2CardImporter.clips(onCard: card)
        let shots = P2CardImporter.shots(from: clips + clips)
        XCTAssertEqual(shots.map(\.clips.count), [1])
    }

    func testClipsPickedFromACardAndItsCopyAreBothKept() throws {
        try addClip("0001AA", audio: 1)
        try addClip("0002AB", audio: 1)
        let copy = card.deletingLastPathComponent().appendingPathComponent("\(card.lastPathComponent)-copy")
        try FileManager.default.copyItem(at: card, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let assigned = P2CardImporter.assignCards(
            [(card, P2CardImporter.clips(onCard: card)), (copy, P2CardImporter.clips(onCard: copy))],
            requestedClips: [card: ["0001AA"], copy: ["0002AB"]]
        )
        XCTAssertEqual(assigned.clips.count, 2)
        XCTAssertEqual(assigned.cardByClipID["ID-0001AA"], card)
        XCTAssertEqual(assigned.cardByClipID["ID-0002AB"], copy)

        // A whole card and its copy: each clip once, from the first card.
        let both: Set<String> = ["0001AA", "0002AB"]
        let whole = P2CardImporter.assignCards(
            [(card, P2CardImporter.clips(onCard: card)), (copy, P2CardImporter.clips(onCard: copy))],
            requestedClips: [card: both, copy: both]
        )
        XCTAssertEqual(whole.clips.count, 2)
        XCTAssertEqual(Set(whole.cardByClipID.values), [card])
    }

    func testStaleRewrapsOutliveTheSessionOfferAndBusyShotsAreKept() throws {
        XCTAssertGreaterThanOrEqual(P2ClipRewrapper.retention, LastSessionStore.pendingLifetime)

        let folder = card.appendingPathComponent("P2Clips", isDirectory: true)
        let now = Date()
        let old = now.addingTimeInterval(-P2ClipRewrapper.retention - 60)
        for (name, date) in [("P2-OLD-1", old), ("P2-BUSY-1", old), ("P2-NEW-1", now.addingTimeInterval(-8 * 86_400))] {
            let shot = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: shot, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: shot.path)
        }

        P2ClipRewrapper.removeStale(in: folder, now: now, keeping: ["P2-BUSY-1"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["P2-BUSY-1", "P2-NEW-1"])
    }

    func testSupersededMatroskaRewrapIsRemovedAfterTheRetention() throws {
        let folder = card.appendingPathComponent("P2Clips", isDirectory: true)
        let now = Date()
        func shot(_ name: String, supersededAt date: Date) throws -> URL {
            let shot = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: shot, withIntermediateDirectories: true)
            for file in ["0001AA.mxf", "0001AA.mkv"] {
                try Data().write(to: shot.appendingPathComponent(file))
            }
            let marker = shot.appendingPathComponent(".matroska-superseded")
            try Data().write(to: marker)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: marker.path)
            return shot
        }
        let old = try shot("P2-OLD-1", supersededAt: now.addingTimeInterval(-P2ClipRewrapper.retention - 60))
        let recent = try shot("P2-NEW-1", supersededAt: now.addingTimeInterval(-86_400))

        P2ClipRewrapper.removeStale(in: folder, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.path).sorted(), ["0001AA.mxf"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recent.path).sorted(),
                       [".matroska-superseded", "0001AA.mkv", "0001AA.mxf"])
    }

    func testURLsOutsideP2CardsPassThroughUnchanged() async {
        let urls = [URL(fileURLWithPath: "/nonexistent/a.mov"), URL(fileURLWithPath: "/nonexistent/b.mxf")]
        let resolved = await P2CardImporter.resolveCards(in: urls)
        XCTAssertEqual(resolved, urls)
    }
}
