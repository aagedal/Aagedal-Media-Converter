import os
import SwiftUI
import XCTest
@testable import Aagedal_Media_Converter

final class NativeMXFMergeTests: XCTestCase {
    // Values from a Sony PXW-FX9 card (50p, timecode counted at 25 with halfStep).
    private func nrtXML(duration: Int, start: String, end: String, lineEnding: String = "\n") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20" lastUpdate="2026-10-20T13:33:18+01:00">
        \t<Duration value="\(duration)"/>
        \t<LtcChangeTable tcFps="25" halfStep="true">
        \t\t<LtcChange frameCount="0" value="\(start)" status="increment"/>
        \t\t<LtcChange frameCount="\(duration - 1)" value="\(end)" status="end"/>
        \t</LtcChangeTable>
        \t<KeyFrame frameCount="0"/>
        \t<BodyUmidBasicChangeTable>
        \t\t<BodyUmidBasicChange frameCount="0" value="060A2B34" status="start"/>
        \t</BodyUmidBasicChangeTable>
        \t<Device manufacturer="Sony" modelName="PXW-FX9V" serialNo="4002063"/>
        \t<AcquisitionRecord>
        \t\t<Group name="CameraUnitMetadataSet">
        \t\t\t<Item name="CaptureGammaEquation" value="s-cinetone"/>
        \t\t</Group>
        \t</AcquisitionRecord>
        </NonRealTimeMeta>
        """.replacingOccurrences(of: "\n", with: lineEnding)
    }

    func testSonyLTCRoundTripsHalfStepValuesFromCameraXML() {
        // 4486: 298 frames from 00:00:00:00 end at 23050080; 4489: 214 frames from 09580200.
        XCTAssertEqual(SonyLTC.frameIndex("00000000", tcFps: 25, halfStep: true), 0)
        XCTAssertEqual(SonyLTC.value(frameIndex: 297, tcFps: 25, halfStep: true), "23050080")
        let start = SonyLTC.frameIndex("09580200", tcFps: 25, halfStep: true)
        XCTAssertEqual(start, 8918)
        XCTAssertEqual(SonyLTC.value(frameIndex: 8918 + 213, tcFps: 25, halfStep: true), "15020380")
        XCTAssertEqual(SonyLTC.frameIndex("06305215", tcFps: 25, halfStep: false), ((15 * 60 + 52) * 60 + 30) * 25 + 6)
        XCTAssertNil(SonyLTC.frameIndex("40000000", tcFps: 30, halfStep: false), "Drop-frame is not supported")
        XCTAssertNil(SonyLTC.frameIndex("0A000000", tcFps: 25, halfStep: false), "Invalid BCD")
    }

    func testMergedXMLUpdatesDurationTimecodeTableAndDropsBodyUmids() throws {
        let first = nrtXML(duration: 298, start: "00000000", end: "23050080")
        let second = nrtXML(duration: 214, start: "09580200", end: "15020380")
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let merged = try XCTUnwrap(NativeMXFMerge.mergedNonRealTimeMeta(
            segments: [
                .init(xml: first, frameCount: 298),
                .init(xml: second, frameCount: 214),
            ],
            now: date, timeZone: TimeZone(secondsFromGMT: 3600)!
        ))
        XCTAssertTrue(merged.contains(#"<Duration value="512"/>"#))
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="0" value="00000000" status="increment"/>"#))
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="298" value="09580200" status="increment"/>"#))
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="511" value="15020380" status="end"/>"#))
        XCTAssertFalse(merged.contains("BodyUmid"))
        XCTAssertTrue(merged.contains(#"lastUpdate="2026-10-14T18:46:40+01:00"#))
        XCTAssertTrue(merged.contains(#"modelName="PXW-FX9V""#))
        XCTAssertTrue(merged.contains(#"value="s-cinetone""#))
        XCTAssertNotNil(try XMLDocument(xmlString: merged))
    }

    func testMergedXMLSkipsIncrementForContinuousTimecodeAndKeepsCRLF() throws {
        let first = nrtXML(duration: 298, start: "00000000", end: "23050080", lineEnding: "\r\n")
        // Recording continued: the second clip starts on the frame after the first ends.
        let second = nrtXML(duration: 50, start: "24050000", end: "23060080", lineEnding: "\r\n")
        let merged = try XCTUnwrap(NativeMXFMerge.mergedNonRealTimeMeta(segments: [
            .init(xml: first, frameCount: 298),
            .init(xml: second, frameCount: 50),
        ]))
        XCTAssertTrue(merged.contains(#"<Duration value="348"/>"#))
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="0" value="00000000" status="increment"/>"#))
        XCTAssertFalse(merged.contains(#"frameCount="298""#))
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="347" value="23060080" status="end"/>"#))
        XCTAssertFalse(merged.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testMergedXMLOmitsTimecodeTableWhenASegmentCannotBeRepresented() throws {
        let good = nrtXML(duration: 298, start: "00000000", end: "23050080")
        let dropFrame = good.replacingOccurrences(of: #"value="00000000""#, with: #"value="40000000""#)
        let merged = try XCTUnwrap(NativeMXFMerge.mergedNonRealTimeMeta(segments: [
            .init(xml: good, frameCount: 298),
            .init(xml: dropFrame, frameCount: 298),
        ]))
        XCTAssertFalse(merged.contains("LtcChange"))
        XCTAssertTrue(merged.contains(#"<Duration value="596"/>"#))
    }

    func testEmbeddedXMLIsExtractedFromHeaderBytes() throws {
        let xml = nrtXML(duration: 298, start: "00000000", end: "23050080")
        let data = Data(repeating: 0x06, count: 300) + Data([0x83, 0, 0x10, 0]) + Data(xml.utf8) + Data(repeating: 0, count: 64)
        XCTAssertEqual(NativeMXFMerge.nonRealTimeMeta(in: data), xml)
        XCTAssertNil(NativeMXFMerge.nonRealTimeMeta(in: Data("no xml".utf8)))
    }

    func testEligibilityRequiresStreamCopyMXFWithoutReencodingFeatures() {
        let a = URL(fileURLWithPath: "/card/A.MXF"), b = URL(fileURLWithPath: "/card/B.MXF")
        func eligible(
            preset: ExportPreset = .streamCopy, ext: String = "mxf", urls: [URL]? = nil,
            trims: Bool = false, routing: Bool = false, timecode: Bool = false
        ) -> Bool {
            NativeMXFMerge.isEligible(
                preset: preset, outputExtension: ext, sourceURLs: urls ?? [a, b], hasTrims: trims,
                hasGeneratedVideo: false, audioRoutingCustomized: routing, hasManualTimecode: timecode
            )
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(ext: "mp4"))
        XCTAssertFalse(eligible(preset: .prores))
        XCTAssertFalse(eligible(routing: true))
        XCTAssertFalse(eligible(timecode: true))
        XCTAssertFalse(eligible(trims: true))
        XCTAssertTrue(NativeMXFMerge.isEligible(
            preset: .streamCopy, outputExtension: "mxf", sourceURLs: [a, b], hasTrims: true, allowsTrimmedMerge: true,
            hasGeneratedVideo: false, audioRoutingCustomized: false, hasManualTimecode: false
        ))
        XCTAssertFalse(eligible(urls: [a]))
        XCTAssertFalse(eligible(urls: [a, URL(fileURLWithPath: "/c.mov")]))
    }

    func testBMXArgumentsCarryIdentificationAndSonyXMLScheme() {
        let xmlURL = URL(fileURLWithPath: "/tmp/nrt.xml")
        let args = NativeMXFMerge.mergeArguments(companyName: "Sony", appVersion: "4.5", embeddedXMLURL: xmlURL)
        XCTAssertEqual(Array(args.prefix(5)), ["-t", "op1a", "--pass-anc", "all", "--no-reorder"])
        let info = args.firstIndex(of: "--prod-info")!
        XCTAssertEqual(Array(args[info...].prefix(6)), ["--prod-info", "Sony", "Aagedal Media Converter", "4.5.0.0.0", "4.5", NativeMXFMerge.productUID])
        XCTAssertEqual(args.suffix(6), ["--xml-scheme-id", NativeMXFMerge.sonyNRTSchemeID, "--xml-lang", "und", "--embed-xml", "/tmp/nrt.xml"])
        XCTAssertFalse(NativeMXFMerge.mergeArguments(companyName: "Aagedal", appVersion: "4", embeddedXMLURL: nil).contains("--embed-xml"))
        XCTAssertEqual(NativeMXFMerge.productVersion("4.5.1.2.9"), "4.5.1.2.0")
    }

    func testCompanyNameComesFromFirstIdentification() {
        let info = """
            Identifications: (2)
              Identification #0:
                company_name    : Sony
                product_name    : Mem
              Identification #1:
                company_name    : BBC
            """
        XCTAssertEqual(NativeMXFMerge.companyName(fromMXFInfo: info), "Sony")
        XCTAssertNil(NativeMXFMerge.companyName(fromMXFInfo: "company_name    : "))
        XCTAssertEqual(NativeMXFMerge.sidecarURL(for: URL(fileURLWithPath: "/out/card1.mxf")).path, "/out/card1M01.XML")
        let tracks = """
                  essence_kind    : Picture
                  essence_kind    : Sound
                  essence_kind    : Data
            """
        XCTAssertEqual(NativeMXFMerge.essenceKinds(fromMXFInfo: tracks), ["Picture", "Sound", "Data"])
    }

    func testTrimmedSegmentShiftsTimecodeAndCountsKeptFrames() throws {
        let first = nrtXML(duration: 298, start: "00000000", end: "23050080")
        let second = nrtXML(duration: 214, start: "09580200", end: "15020380")
        let merged = try XCTUnwrap(NativeMXFMerge.mergedNonRealTimeMeta(segments: [
            .init(xml: first, frameCount: 298),
            .init(xml: second, frameCount: 100, startOffset: 50),
        ]))
        XCTAssertTrue(merged.contains(#"<Duration value="398"/>"#))
        let start = SonyLTC.value(frameIndex: 8918 + 50, tcFps: 25, halfStep: true)
        let end = SonyLTC.value(frameIndex: 8918 + 149, tcFps: 25, halfStep: true)
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="298" value="\#(start)" status="increment"/>"#), merged)
        XCTAssertTrue(merged.contains(#"<LtcChange frameCount="397" value="\#(end)" status="end"/>"#), merged)
    }

    func testPictureTrackAndIntraDetectionFromMXFInfo() {
        let info = """
              Tracks: (3)
                Track #0:
                  essence_kind    : Picture
                  essence_type    : AVCI_100_1080p
                  edit_rate       : 50/1
                Track #1:
                  essence_kind    : Sound
                  essence_type    : WAVE_PCM
                  edit_rate       : 48000/1
            """
        XCTAssertEqual(NativeMXFMerge.pictureTrack(fromMXFInfo: info), .init(essenceType: "AVCI_100_1080p", editRate: 50))
        let ntsc = info.replacingOccurrences(of: "50/1", with: "60000/1001")
        XCTAssertEqual(NativeMXFMerge.pictureTrack(fromMXFInfo: ntsc)?.editRate ?? 0, 59.94, accuracy: 0.001)
        XCTAssertNil(NativeMXFMerge.pictureTrack(fromMXFInfo: "essence_kind : Sound\nedit_rate : 48000/1"))
        XCTAssertTrue(NativeMXFMerge.isIntraCoded(essenceType: "AVCI_100_1080p"))
        XCTAssertTrue(NativeMXFMerge.isIntraCoded(essenceType: "AVC_High_422_Intra"))
        XCTAssertTrue(NativeMXFMerge.isIntraCoded(essenceType: "VC3_1080p_1235"))
        XCTAssertFalse(NativeMXFMerge.isIntraCoded(essenceType: "AVC_High_422"))
        XCTAssertFalse(NativeMXFMerge.isIntraCoded(essenceType: "MPEG2LG_422P_HL_1080I"))
    }

    func testFrameRangeAndSegmentArguments() {
        XCTAssertEqual(NativeMXFMerge.frameRange(trimStart: 1, trimEnd: 3, editRate: 50), .init(start: 50, count: 100))
        XCTAssertEqual(NativeMXFMerge.frameRange(trimStart: nil, trimEnd: nil, editRate: 50), .init(start: 0, count: nil))
        XCTAssertEqual(NativeMXFMerge.frameRange(trimStart: 0.2, trimEnd: nil, editRate: 25), .init(start: 5, count: nil))
        XCTAssertNil(NativeMXFMerge.frameRange(trimStart: 2, trimEnd: 2.001, editRate: 50))
        XCTAssertEqual(NativeMXFMerge.segmentRewrapArguments(range: .init(start: 0, count: nil)), ["-t", "op1a", "--pass-anc", "all"])
        XCTAssertEqual(NativeMXFMerge.segmentRewrapArguments(range: .init(start: 50, count: 100)),
                       ["-t", "op1a", "--pass-anc", "all", "--start", "50", "--dur", "100"])
    }

    func testTemporarySpaceEstimateAndCheck() {
        let gib: Int64 = 1 << 30
        let estimate = NativeMXFMerge.estimatedTemporaryBytes(clips: [(10 * gib, 1), (4 * gib, 0.5)])
        XCTAssertGreaterThan(estimate, 12 * gib)
        XCTAssertLessThan(estimate, 13 * gib)
        XCTAssertEqual(NativeMXFMerge.checkSpace(temporaryBytes: 10, temporaryAvailable: 15, outputAvailable: 15, sameVolume: true),
                       .insufficient(available: 15, required: 20))
        XCTAssertEqual(NativeMXFMerge.checkSpace(temporaryBytes: 10, temporaryAvailable: 20, outputAvailable: 0, sameVolume: true), .sufficient)
        XCTAssertEqual(NativeMXFMerge.checkSpace(temporaryBytes: 10, temporaryAvailable: 15, outputAvailable: 9, sameVolume: false),
                       .insufficient(available: 9, required: 10))
        XCTAssertEqual(NativeMXFMerge.checkSpace(temporaryBytes: 10, temporaryAvailable: 15, outputAvailable: 10, sameVolume: false), .sufficient)
    }

    /// Opt-in: merges real Sony FX9 card clips through the Stream Copy merge path.
    /// Run with TEST_RUNNER_AMC_NATIVE_MXF_CARD=/path/to/XDROOT/Clip.
    func testStreamCopyMergeOfSonyCardUsesBMXAndWritesSidecar() async throws {
        try await assertSonyCardMerge(trimSecondClip: false)
    }

    /// Opt-in: the second clip is trimmed to frames 50..<150, so every clip is rewrapped first.
    func testTrimmedStreamCopyMergeOfSonyCardKeepsCameraMetadata() async throws {
        try await assertSonyCardMerge(trimSecondClip: true)
    }

    private func assertSonyCardMerge(trimSecondClip: Bool) async throws {
        guard let folder = ProcessInfo.processInfo.environment["AMC_NATIVE_MXF_CARD"] else {
            throw XCTSkip("Set AMC_NATIVE_MXF_CARD to a Sony XDROOT/Clip folder")
        }
        let clips = ["732_4486.MXF", "732_4489.MXF", "732_4490.MXF"].map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMXFMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["AMC_NATIVE_MXF_KEEP"] == nil {
            addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        }
        let suite = "NativeMXFMerge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppConstants.exportStitchMarkersKey)
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.nativeMXFTrimmedMergeKey)
        let settings = ConversionPreparationSettings(preset: .streamCopy, defaults: defaults)
        let manager = ConversionManager(preparationSettingsProvider: { _ in settings })
        var items = clips.map { url in
            VideoItem(url: url, name: url.lastPathComponent, size: 0, duration: "--:--", status: .waiting,
                      progress: 0, eta: nil, outputURL: nil)
        }
        for index in items.indices { items[index].includeDateTag = false }
        if trimSecondClip {
            items[1].trimStart = 1
            items[1].trimEnd = 3
        }
        let secondFrames = trimSecondClip ? 100 : 214
        let storage = OSAllocatedUnfairLock(initialState: items)
        let binding = Self.binding(storage)

        await manager.convertGroup(
            items: binding, outputFolder: output.path, preset: .streamCopy,
            concatEnabled: true, groupName: "card1",
            transcriptionEnabled: false, uploadEnabled: false, analyticsEnabled: false
        )
        for _ in 0..<600 where storage.withLock({ $0.contains { $0.status == .converting || $0.status == .waiting } }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        let finished = storage.withLock { $0 }
        XCTAssertEqual(finished.map(\.status), [.done, .done, .done], finished.compactMap(\.conversionError).joined(separator: "; "))
        let merged = try XCTUnwrap(finished.first?.outputURL)
        XCTAssertEqual(merged.lastPathComponent, "card1.mxf")

        // 298 + second-clip frames, plus the third clip's Duration from its sidecar.
        let third = try XCTUnwrap(NativeMXFMerge.loadNonRealTimeMeta(for: clips[2]).flatMap(NativeMXFMerge.durationFrames(in:)))
        let sidecar = try String(contentsOf: NativeMXFMerge.sidecarURL(for: merged), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("<Duration value=\"\(298 + secondFrames + third)\"/>"), sidecar)
        XCTAssertTrue(sidecar.contains(#"modelName="PXW-FX9V""#))
        let secondStart = SonyLTC.value(frameIndex: 8918 + (trimSecondClip ? 50 : 0), tcFps: 25, halfStep: true)
        XCTAssertTrue(sidecar.contains(#"<LtcChange frameCount="298" value="\#(secondStart)" status="increment"/>"#), sidecar)

        let probed = await BMXService.shared.getMXFInfo(url: merged)
        let info = try XCTUnwrap(probed)
        XCTAssertEqual(NativeMXFMerge.companyName(fromMXFInfo: info), "Sony")
        XCTAssertTrue(info.contains("Aagedal Media Converter"))
        XCTAssertTrue(info.contains("ANC_Data"), "Per-frame acquisition metadata track must survive")
        XCTAssertEqual(NativeMXFMerge.essenceKinds(fromMXFInfo: info).filter { $0 == "Picture" }.count, 1, "Video must survive")
        XCTAssertTrue(info.contains("count='\(298 + secondFrames + third)'"), "Merged duration in edit units")
        let embedded = try XCTUnwrap(NativeMXFMerge.embeddedNonRealTimeMeta(in: merged))
        XCTAssertTrue(embedded.contains("<Duration value=\"\(298 + secondFrames + third)\"/>"))
    }

    private nonisolated static func binding(_ storage: OSAllocatedUnfairLock<[VideoItem]>) -> Binding<[VideoItem]> {
        Binding(get: { storage.withLock { $0 } }, set: { value in storage.withLock { $0 = value } })
    }
}
