import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class MetadataTableTests: XCTestCase {
    func testRowsWithoutAnyValueAreOmitted() {
        let sections = MetadataTableBuilder(items: [item("a", metadata: metadata())]).build()
        let general = try? XCTUnwrap(sections.first { $0.id == "general" })
        XCTAssertNotNil(general?.rows.first { $0.label == "Container" })
        XCTAssertNil(general?.rows.first { $0.label == "Artist" })
    }

    func testSearchKeepsMatchingRowsAndTheirStreamHeader() {
        let source = item("a", metadata: metadata(audio: [audio(codec: "aac", language: "eng"), audio(codec: "pcm_s24le", language: "nor")]))
        let sections = MetadataTableBuilder(items: [source]).build()
        let filtered = MetadataTableFilter.apply(sections, query: "pcm_s24", differencesOnly: false)

        let audioSection = try? XCTUnwrap(filtered.first { $0.id == "audio" })
        XCTAssertEqual(filtered.map(\.id), ["audio"])
        XCTAssertEqual(audioSection?.rows.map(\.label), ["Audio 2", "Codec"])
    }

    func testSearchMatchingSectionTitleKeepsWholeSection() {
        let sections = MetadataTableBuilder(items: [item("a", metadata: metadata())]).build()
        let filtered = MetadataTableFilter.apply(sections, query: "video", differencesOnly: false)
        let video = sections.first { $0.id == "video" }
        XCTAssertEqual(filtered.first { $0.id == "video" }?.rows, video?.rows)
    }

    func testDifferencesOnlyKeepsDisagreeingRows() {
        let sections = MetadataTableBuilder(items: [
            item("a", metadata: metadata(width: 1920)),
            item("b", metadata: metadata(width: 1280))
        ]).build()
        let filtered = MetadataTableFilter.apply(sections, query: "", differencesOnly: true)
        let labels = filtered.flatMap(\.rows).map(\.label)
        XCTAssertTrue(labels.contains("Resolution"))
        XCTAssertFalse(labels.contains("Codec"))
    }

    func testMatchRangesAreCaseAndDiacriticInsensitive() {
        XCTAssertEqual(MetadataTableFilter.matchRanges(in: "Bokmål BOKMAL", query: "bokmal").count, 2)
    }

    func testDynamicRangeClassification() {
        XCTAssertEqual(stream(transfer: "smpte2084").dynamicRangeDescription, "PQ")
        var hdr10 = stream(transfer: "smpte2084")
        hdr10.hdr = .init(contentLightLevel: "MaxCLL 1000 / MaxFALL 400 nits")
        XCTAssertEqual(hdr10.dynamicRangeDescription, "HDR10")
        var dolby = stream(transfer: "arib-std-b67")
        dolby.hdr = .init(dolbyVision: "Profile 8.4 (HLG), Level 6")
        XCTAssertEqual(dolby.dynamicRangeDescription, "Dolby Vision, HLG compatible")
        XCTAssertEqual(stream(transfer: "bt709").dynamicRangeDescription, "SDR")
        XCTAssertNil(stream(transfer: nil).dynamicRangeDescription)
    }

    func testTextExportListsEveryColumn() {
        let sections = MetadataTableBuilder(items: [
            item("a", metadata: metadata(width: 1920)),
            item("b", metadata: metadata(width: 1280))
        ]).build()
        let text = MetadataTableTextExporter.text(for: sections, fileNames: ["a.mov", "b.mov"])
        XCTAssertTrue(text.contains("[1] a.mov"))
        XCTAssertTrue(text.contains("Resolution: [1] 1920 × 1080  [2] 1280 × 1080"))
    }


    // MARK: - C2PA

    func testC2PADisplayValuesDescribeSignerActionsAndHistory() {
        var c2pa = C2PAMetadata(
            hasContentCredentials: true, hasSignature: true,
            actionsAction: "c2pa.created", actionsDigitalSourceType: nil,
            claimGenerator: "SONY_CAMERA c2pa-rs/0.40", claimGeneratorInfoName: "SONY_CAMERA",
            manifestStore: "urn:c2pa:1", assertions: ["c2pa.actions.v2"]
        )
        c2pa.claimGeneratorVersion = "2.0"
        c2pa.actions = [
            C2PAActionInfo(action: "c2pa.created", softwareAgent: nil,
                           digitalSourceType: "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture", description: nil),
            C2PAActionInfo(action: "c2pa.color_adjustments", softwareAgent: "Premiere Pro", digitalSourceType: nil, description: nil)
        ]
        c2pa.signature = C2PASignatureInfo(
            signer: "Jane Doe", signerOrganization: "Example News", issuer: "Example CA",
            algorithm: "ES256", timestamp: nil, hasTimestamp: true, certificateExpiry: nil
        )
        c2pa.trainingMining = [C2PATrainingPermission(category: "c2pa.ai_generative_training", use: "notAllowed", constraintInfo: nil)]
        c2pa.history = [
            C2PAManifestSummary(label: "a", generator: "Camera", signer: "Sony", actions: ["Created"]),
            C2PAManifestSummary(label: "b", generator: "Premiere Pro 25", signer: nil, actions: ["Color Adjustments"])
        ]

        XCTAssertEqual(c2pa.displayValue(for: .signedBy), "Jane Doe (Example News)")
        XCTAssertEqual(c2pa.displayValue(for: .signedAt), "Time-stamped")
        XCTAssertEqual(c2pa.displayValue(for: .app), "SONY_CAMERA 2.0")
        XCTAssertEqual(c2pa.displayValue(for: .claimGenerator), "SONY_CAMERA c2pa-rs/0.40")
        XCTAssertEqual(c2pa.displayValue(for: .sourceType), "Digital Capture")
        XCTAssertEqual(c2pa.displayValue(for: .actions), "Created\nColor Adjustments — Premiere Pro")
        XCTAssertEqual(c2pa.displayValue(for: .trainingMining), "Generative AI training: Not allowed")
        XCTAssertEqual(c2pa.displayValue(for: .history),
                       "1. Camera: Created — signed by Sony\n2. Premiere Pro 25: Color Adjustments")

        let unsigned = C2PAMetadata(
            hasContentCredentials: true, hasSignature: false, actionsAction: nil, actionsDigitalSourceType: nil,
            claimGenerator: nil, claimGeneratorInfoName: nil, manifestStore: nil, assertions: nil
        )
        XCTAssertEqual(unsigned.displayValue(for: .signedBy), "Not signed")
        XCTAssertNil(C2PAMetadata.empty.displayValue(for: .signedBy), "No credentials, no detail rows")
    }

    func testC2PAVocabularyNames() {
        XCTAssertEqual(C2PAFormatting.digitalSourceTypeName("http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"),
                       "Created Using Generative AI")
        XCTAssertTrue(C2PAFormatting.isGenerativeAI("compositeWithTrainedAlgorithmicMedia"))
        XCTAssertFalse(C2PAFormatting.isGenerativeAI("digitalCapture"))
        XCTAssertEqual(C2PAFormatting.actionName("c2pa.some_new_action"), "Some New Action")
        XCTAssertEqual(C2PAIngredientInfo(title: "A001.MP4", format: "video/mp4", relationship: "parentOf").summary,
                       "A001.MP4 (MP4, source)")
    }

    func testTimestampReaderFindsGeneralizedTime() throws {
        // A DER fragment with noise, then GeneralizedTime "20251212101530.5Z".
        let time = Array("20251212101530.5Z".utf8)
        let token = Data([0x30, 0x82, 0x01, 0x18, 0x02, 0x01] + [0x18, UInt8(time.count)] + time + [0x04, 0x00])
        let date = try XCTUnwrap(C2PATimestampReader.signingTime(fromToken: token))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2025, 12, 12, 10, 15, 30])
        XCTAssertNil(C2PATimestampReader.signingTime(fromToken: Data([0x18, 0x0F] + Array("notatimestamp!Z".utf8))))
    }

    func testC2PASectionUsesReadableRows() {
        var source = item("a", metadata: metadata())
        source.c2paMetadata = C2PAMetadata(
            hasContentCredentials: true, hasSignature: true, actionsAction: "c2pa.created",
            actionsDigitalSourceType: nil, claimGenerator: nil, claimGeneratorInfoName: "SONY_CAMERA",
            manifestStore: nil, assertions: nil
        )
        let section = MetadataTableBuilder(items: [source]).build().first { $0.id == "c2pa" }
        XCTAssertEqual(section?.rows.map(\.label), ["Content Credentials", "Signed By", "App or Device", "Actions"])
    }

    // MARK: - Fixtures

    private func item(_ name: String, metadata: VideoMetadata) -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/tmp/" + name + ".mov"), name: name,
            size: 0, duration: "--:--", thumbnailData: nil, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
        item.metadata = metadata
        return item
    }

    private func audio(codec: String, language: String) -> VideoMetadata.AudioStream {
        VideoMetadata.AudioStream(
            index: nil, languageCode: language, title: nil, codec: codec, codecLongName: nil,
            profile: nil, sampleRate: 48_000, channels: 2, channelLayout: "stereo",
            bitDepth: nil, bitRate: nil, isDefault: false
        )
    }

    private func stream(width: Int = 1920, transfer: String? = nil) -> VideoMetadata.VideoStream {
        VideoMetadata.VideoStream(
            codec: "h264", codecLongName: nil, profile: nil, width: width, height: 1080,
            pixelFormat: "yuv420p", hasAlpha: false, pixelAspectRatio: nil,
            displayAspectRatio: nil, frameRate: VideoMetadata.FrameRate(double: 25),
            bitDepth: 8, bitRate: nil, duration: 60, chromaSubsampling: "4:2:0",
            colorPrimaries: nil, colorTransfer: transfer, colorSpace: nil, colorRange: nil,
            chromaLocation: nil, fieldOrder: nil, isInterlaced: false, title: nil,
            isDefault: true, isForced: false
        )
    }

    private func metadata(width: Int = 1920, audio: [VideoMetadata.AudioStream] = []) -> VideoMetadata {
        VideoMetadata(
            duration: 60, formatName: "mov", containerLongName: "QuickTime / MOV",
            sizeBytes: 1_000, bitRate: nil, comment: nil, timecode: nil, timecodes: [],
            frameCount: nil, containerCreationDate: nil, containerModificationDate: nil,
            title: nil, artist: nil, gpsLatitude: nil, gpsLongitude: nil, gpsAltitude: nil,
            warnings: [], videoStreams: [stream(width: width)], audioStreams: audio, subtitleStreams: []
        )
    }
}
