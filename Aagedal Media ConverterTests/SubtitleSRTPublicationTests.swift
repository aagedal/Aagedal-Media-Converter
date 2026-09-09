import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class SubtitleSRTPublicationTests: XCTestCase {
    @MainActor
    func testRemovedRowCannotPublishStagedFile() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let row = PublicationRow(directory: fixture.directory)
        row.items.removeAll()

        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged,
            destinationURL: fixture.destination,
            isCurrent: { row.isCurrent }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testSupersededAttemptPreservesReplacementAtSamePath() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let row = PublicationRow(directory: fixture.directory)
        row.items[0].subtitleOperationID = UUID()
        try "replacement subtitle".write(to: fixture.destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged,
            destinationURL: fixture.destination,
            isCurrent: { row.isCurrent }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "replacement subtitle")
    }

    @MainActor
    func testServiceCancellationDuringQueueValidationPreventsCommit() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let publication = SubtitleSRTPublication()

        XCTAssertThrowsError(try publication.publish(
            stagedURL: fixture.staged,
            destinationURL: fixture.destination,
            isCurrent: {
                publication.cancel()
                return true
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @MainActor
    func testTaskCancellationDuringQueueValidationPreventsCommit() async throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        try "existing subtitle".write(to: fixture.destination, atomically: true, encoding: .utf8)
        let publication = SubtitleSRTPublication()

        let task = Task { @MainActor in
            try publication.publish(
                stagedURL: fixture.staged,
                destinationURL: fixture.destination,
                isCurrent: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            )
        }
        do {
            try await task.value
            XCTFail("Task cancellation during validation must prevent publication")
        } catch is CancellationError {
            // Expected even though queue ownership remains valid.
        }

        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "existing subtitle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testCancellationAfterValidPublicationPreservesCompletedOutput() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let publication = SubtitleSRTPublication()
        try "old subtitle".write(to: fixture.destination, atomically: true, encoding: .utf8)

        try publication.publish(
            stagedURL: fixture.staged,
            destinationURL: fixture.destination,
            isCurrent: { true }
        )
        publication.cancel()

        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "generated subtitle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testWhisperRemovedRowDiscardsLateStaging() async throws {
        try await checkRejectedServicePublication(method: .whisper, removeRow: true)
    }

    @MainActor
    func testWhisperSupersededRowPreservesReplacementSubtitle() async throws {
        try await checkRejectedServicePublication(method: .whisper, removeRow: false)
    }

    @MainActor
    func testParakeetRemovedRowDiscardsLateStaging() async throws {
        try await checkRejectedServicePublication(method: .parakeet, removeRow: true)
    }

    @MainActor
    func testParakeetSupersededRowPreservesReplacementSubtitle() async throws {
        try await checkRejectedServicePublication(method: .parakeet, removeRow: false)
    }

    @MainActor
    private func checkRejectedServicePublication(method: SubtitleSRTMethod, removeRow: Bool) async throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.staged)
        let row = PublicationRow(directory: fixture.directory)
        let runner = PublicationOutputRunner {
            try await MainActor.run {
                if removeRow {
                    row.items.removeAll()
                } else {
                    row.items[0].subtitleOperationID = UUID()
                    try "replacement subtitle".write(to: fixture.destination, atomically: true, encoding: .utf8)
                }
            }
        }

        do {
            switch method {
            case .whisper:
                let service = WhisperService(
                    modelManager: PublicationModelProvider(path: fixture.directory.appendingPathComponent("model.bin")),
                    subprocessRunner: runner,
                    ffmpegPathProvider: { "/fixture/ffmpeg" }
                )
                _ = try await service.generateSubtitlesOnly(
                    inputFile: fixture.directory.appendingPathComponent("clip.mov"),
                    model: .base,
                    language: "auto",
                    operationID: row.followUp.subtitleOperationID,
                    publicationIsCurrent: { row.isCurrent }
                ) { _ in }
            case .parakeet:
                let service = ParakeetService(
                    subprocessRunner: runner,
                    parakeetPathProvider: { "/fixture/parakeet-mlx" },
                    ffmpegPathProvider: { "/fixture/ffmpeg" },
                    chunkDurationProvider: { AppConstants.defaultParakeetChunkDuration },
                    overlapDurationProvider: { AppConstants.defaultParakeetOverlapDuration }
                )
                _ = try await service.generateSubtitlesOnly(
                    inputFile: fixture.directory.appendingPathComponent("clip.mov"),
                    model: ParakeetModel.allModels[0],
                    language: "en",
                    operationID: row.followUp.subtitleOperationID,
                    publicationIsCurrent: { row.isCurrent }
                ) { _ in }
            case .ocr:
                XCTFail("OCR uses the shared publication gate directly")
                return
            }
            XCTFail("A removed or superseded row must reject publication")
        } catch let error as WhisperServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        } catch let error as ParakeetServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        if removeRow {
            XCTAssertTrue(files.isEmpty, "Abandoned run left files: \(files)")
        } else {
            XCTAssertEqual(files, ["clip.srt"])
            XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "replacement subtitle")
        }
    }
}

private struct PublicationFiles {
    let directory: URL
    let staged: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitlePublication-\(UUID().uuidString)")
        staged = directory.appendingPathComponent(".attempt.srt")
        destination = directory.appendingPathComponent("clip.srt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "generated subtitle".write(to: staged, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class PublicationRow {
    var items: [VideoItem]
    let followUp: ConversionFollowUp

    init(directory: URL) {
        var item = VideoItem(
            url: directory.appendingPathComponent("clip.mov"),
            name: "clip.mov",
            size: 0,
            duration: "00:00:01",
            status: .done,
            progress: 1,
            eta: nil,
            outputURL: directory.appendingPathComponent("clip.mp4")
        )
        item.subtitleEnabled = true
        followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        items = [item]
        followUp.reserveSubtitles(in: &items)
    }

    var isCurrent: Bool { followUp.canBeginSubtitles(in: items) }
}

private struct PublicationModelProvider: WhisperModelProviding {
    let path: URL
    func modelPath(for model: WhisperModel) -> URL { path }
    func isModelDownloaded(_ model: WhisperModel) -> Bool { true }
}

/// Returns successful engine output after the queue changes, without cancelling
/// the subprocess. This reproduces the ownership race independently of stop timing.
private struct PublicationOutputRunner: SubprocessRunning {
    let beforeCompletion: @Sendable () async throws -> Void

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let staged: URL
        if let index = request.arguments.firstIndex(of: "--output-dir") {
            staged = URL(fileURLWithPath: request.arguments[index + 1]).appendingPathComponent("input.srt")
        } else {
            let index = try XCTUnwrap(request.arguments.firstIndex(of: "-af"))
            let filter = request.arguments[index + 1]
            let start = try XCTUnwrap(filter.range(of: "destination=")?.upperBound)
            let end = try XCTUnwrap(filter.range(of: ":use_gpu=true", range: start..<filter.endIndex)?.lowerBound)
            staged = URL(fileURLWithPath: String(filter[start..<end]))
        }
        try "1\n00:00:00,000 --> 00:00:01,000\nLate result\n".write(to: staged, atomically: true, encoding: .utf8)
        try await beforeCompletion()
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(1)
        )
    }
}
