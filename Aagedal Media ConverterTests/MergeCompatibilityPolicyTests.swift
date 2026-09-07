import XCTest
@testable import Aagedal_Media_Converter

final class MergeCompatibilityPolicyTests: XCTestCase {
    func testEligibilityExcludesUnavailableAndNonWaitingItemsInOriginalOrder() {
        let first = item("first")
        let second = item("second")
        var done = item("done")
        done.status = .done
        var downloading = item("downloading")
        downloading.isDownloading = true
        var scheduled = item("scheduled")
        scheduled.scheduledDownloadTime = Date()
        var sequence = item("sequence")
        sequence.imageSequenceConfig = ImageSequenceConfig(
            pattern: "frame_%04d.png", directory: URL(fileURLWithPath: "/tmp"),
            startNumber: 1, endNumber: 2, imageFormat: .png
        )
        let items = [first, done, downloading, scheduled, sequence, second]
        XCTAssertEqual(MergeCompatibilityPolicy.eligibleItems(items).map(\.id), [first.id, second.id])
        guard case .compatible = MergeCompatibilityPolicy.checkMergeCompatibility(
            items: items, metadata: [first.id: videoMetadata(), second.id: videoMetadata()]
        ) else { return XCTFail("Excluded items must not require metadata") }
    }

    func testCompatibilityPreservesCaseAndNumericToleranceRules() {
        let first = item("first")
        let second = item("second")
        guard case .compatible = MergeCompatibilityPolicy.checkMergeCompatibility(
            items: [first, second], metadata: [
                first.id: videoMetadata(frameRate: 24, codec: "H264", pixelAspectRatio: nil),
                second.id: videoMetadata(frameRate: 24.005)
            ]
        ) else { return XCTFail("Case, near-equal rates, and missing square PAR are compatible") }
        guard case .frameRateMismatch(let mismatch) = MergeCompatibilityPolicy.checkMergeCompatibility(
            items: [first, second], metadata: [
                first.id: videoMetadata(frameRate: 24), second.id: videoMetadata(frameRate: 25)
            ]
        ) else { return XCTFail("Different frame rates must be rejected") }
        XCTAssertEqual(mismatch.id, second.id)
    }

    func testGroupingPreservesFirstMatchAndMissingMetadataSingletons() {
        let items = [item("a"), item("b"), item("missing"), item("c"), item("d")]
        let metadata = [
            items[0].id: videoMetadata(frameRate: 24), items[1].id: videoMetadata(frameRate: 25),
            items[3].id: videoMetadata(frameRate: 24), items[4].id: videoMetadata(frameRate: 25)
        ]
        let groups = MergeCompatibilityPolicy.groupByCompatibility(items: items, metadata: metadata)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [
            [items[0].id, items[3].id], [items[1].id, items[4].id], [items[2].id]
        ])
    }

    func testConformanceIdentifiesVideoChangesAndMissingMetadata() {
        let items = [item("reference"), item("different"), item("missing")]
        let analysis = MergeCompatibilityPolicy.analyzeConformance(
            items: items, referenceItemID: items[0].id, metadata: [
                items[0].id: videoMetadata(), items[1].id: videoMetadata(frameRate: 25, codec: "hevc")
            ]
        )
        XCTAssertEqual(analysis.map(\.id), items.map(\.id))
        XCTAssertFalse(analysis[0].needsConformance)
        XCTAssertTrue(analysis[1].needsVideoReencode)
        XCTAssertFalse(analysis[1].needsAudioReencode)
        XCTAssertEqual(analysis[1].videoMismatches.count, 2)
        XCTAssertEqual(analysis[2].videoMismatches, ["No video metadata"])
        XCTAssertTrue(analysis[2].needsAudioReencode)
        XCTAssertTrue(MergeCompatibilityPolicy.analyzeConformance(
            items: items, referenceItemID: items[2].id, metadata: [:]
        ).isEmpty)
    }

    private func item(_ name: String) -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/tmp/" + name + ".mov"), name: name,
            size: 0, duration: "--:--", thumbnailData: nil, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
    }

    private func videoMetadata(
        timecode: String? = nil,
        frameRate: Double = 24,
        codec: String = "h264",
        pixelAspectRatio: VideoMetadata.Ratio? = VideoMetadata.Ratio(numerator: 1, denominator: 1),
        duration: Double? = 60
    ) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
            formatName: "mov",
            containerLongName: "QuickTime / MOV",
            sizeBytes: nil,
            bitRate: nil,
            comment: nil,
            timecode: timecode,
            timecodes: [],
            frameCount: nil,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [
                VideoMetadata.VideoStream(
                    codec: codec,
                    codecLongName: nil,
                    profile: nil,
                    width: 1920,
                    height: 1080,
                    pixelFormat: "yuv420p",
                    hasAlpha: false,
                    pixelAspectRatio: pixelAspectRatio,
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: frameRate),
                    bitDepth: 8,
                    bitRate: nil,
                    duration: 60,
                    chromaSubsampling: "4:2:0",
                    colorPrimaries: nil,
                    colorTransfer: nil,
                    colorSpace: nil,
                    colorRange: nil,
                    chromaLocation: nil,
                    fieldOrder: nil,
                    isInterlaced: false,
                    title: nil,
                    isDefault: true,
                    isForced: false
                )
            ],
            audioStreams: [],
            subtitleStreams: []
        )
    }

}
