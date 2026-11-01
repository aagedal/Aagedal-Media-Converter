import Foundation
import SwiftUI
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class UploadSidecarTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("UploadSidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func touch(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func outputItem(output: URL) -> VideoItem {
        VideoItem(
            url: folder.appendingPathComponent("A001.MXF"), name: "A001.MXF", size: 0,
            duration: "00:00:10", durationSeconds: 10, status: .done,
            progress: 1, eta: nil, outputURL: output
        )
    }

    func testNoSidecarIsUploadedByDefault() throws {
        let suite = "UploadSidecars.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(UploadSidecarSettings(defaults: defaults).enabledKinds.isEmpty)
        defaults.set(true, forKey: AppConstants.uploadCameraMetadataSidecarKey)
        XCTAssertEqual(UploadSidecarSettings(defaults: defaults).enabledKinds, [.cameraMetadata])
    }

    func testEachFormatFollowsItsOwnSwitch() throws {
        let output = try touch("card1.mxf")
        let xml = try touch("card1M01.XML")
        let edl = try touch("card1.cuts.edl")
        let srt = try touch("card1.whisper.srt")
        var item = outputItem(output: output)
        item.outputSidecarURLs = [edl]
        item.subtitleFilePath = srt

        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: Set(UploadSidecarKind.allCases))), [xml, edl, srt])
        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: [.cameraMetadata])), [xml])
        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: [.subtitles])), [srt])
        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: [])), [])

        try FileManager.default.removeItem(at: srt)
        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: [.subtitles])), [], "Missing files are skipped")
    }

    func testSourceUploadSendsTheCardSidecarButNotOutputEDL() throws {
        let source = try touch("A001.MXF")
        let xml = try touch("A001M01.XML")
        var item = outputItem(output: try touch("A001_merge.mxf"))
        item.outputSidecarURLs = [try touch("A001_merge.cuts.edl")]
        item.uploadSourceFile = true
        XCTAssertEqual(item.fileToUpload, source)
        XCTAssertEqual(UploadSidecars.files(for: item, settings: .init(enabledKinds: Set(UploadSidecarKind.allCases))), [xml])
    }

    func testChangingTheOutputForgetsItsSidecars() throws {
        var item = outputItem(output: try touch("one.mxf"))
        item.outputSidecarURLs = [try touch("one.cuts.edl")]
        item.outputURL = try touch("two.mxf")
        XCTAssertTrue(item.outputSidecarURLs.isEmpty)
    }

    func testOutputUploadWaitsOnlyWhenSubtitlesAreUploadedOrEmbedded() throws {
        var item = outputItem(output: try touch("clip.mov"))
        item.subtitleEnabled = true
        let withSubtitles = UploadSidecarSettings(enabledKinds: [.subtitles])
        let without = UploadSidecarSettings(enabledKinds: [.cameraMetadata])
        XCTAssertTrue(UploadSidecars.outputUploadWaitsForSubtitles(item: item, settings: withSubtitles, embedSubtitles: false))
        XCTAssertTrue(UploadSidecars.outputUploadWaitsForSubtitles(item: item, settings: without, embedSubtitles: true))
        XCTAssertFalse(UploadSidecars.outputUploadWaitsForSubtitles(item: item, settings: without, embedSubtitles: false))
        item.uploadSourceFile = true
        XCTAssertFalse(UploadSidecars.outputUploadWaitsForSubtitles(item: item, settings: withSubtitles, embedSubtitles: true))
        item.uploadSourceFile = false
        item.subtitleEnabled = false
        XCTAssertFalse(UploadSidecars.outputUploadWaitsForSubtitles(item: item, settings: withSubtitles, embedSubtitles: true))
    }

    func testManagerUploadsSidecarsAfterMainFile() async throws {
        let output = try touch("card1.mxf")
        let xml = try touch("card1M01.XML")
        let service = RecordingUploadService()
        let manager = makeManager(service: service, kinds: [.cameraMetadata])
        var items = [outputItem(output: output)]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })

        await manager.startUpload(itemID: items[0].id)?.value

        let uploaded = await service.localFiles
        XCTAssertEqual(uploaded, [output, xml])
        XCTAssertEqual(items[0].uploadStatus, .uploaded)
        XCTAssertEqual(items[0].uploadedRemotePath, "/remote/card1.mxf")
    }

    func testSidecarFailureMarksTheRowFailed() async throws {
        let output = try touch("card1.mxf")
        _ = try touch("card1M01.XML")
        let service = RecordingUploadService(failingName: "card1M01.XML")
        let manager = makeManager(service: service, kinds: [.cameraMetadata])
        var items = [outputItem(output: output)]
        manager.videoItems = Binding(get: { items }, set: { items = $0 })

        await manager.startUpload(itemID: items[0].id)?.value

        XCTAssertEqual(items[0].uploadStatus, .failed("Sidecar card1M01.XML: denied"))
    }

    private func makeManager(service: any RcloneUploading, kinds: Set<UploadSidecarKind>) -> UploadManager {
        UploadManager(
            rcloneService: service,
            configurationProvider: {
                UploadConfig(server: "fixture", port: 22, username: "editor", backendType: .sftp, sftpKeyFilePath: "/fixture/key")
            },
            rcloneAvailability: { true },
            sidecarSettingsProvider: { UploadSidecarSettings(enabledKinds: kinds) }
        )
    }
}

private actor RecordingUploadService: RcloneUploading {
    private let failingName: String?
    private(set) var localFiles: [URL] = []

    init(failingName: String? = nil) {
        self.failingName = failingName
    }

    func upload(localFile: URL, config: UploadConfig, progress: @escaping @Sendable (Double, String?) -> Void) async throws -> UploadResult {
        localFiles.append(localFile)
        if localFile.lastPathComponent == failingName { return .failure(error: "denied") }
        return .success(remotePath: "/remote/" + localFile.lastPathComponent, bytes: 1, duration: 0)
    }

    func testConnection(config: UploadConfig) async throws -> Bool { true }
}
