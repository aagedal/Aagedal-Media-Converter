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
            reservation: fixture.reserve(),
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
            reservation: fixture.reserve(),
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
            reservation: fixture.reserve(),
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
                reservation: fixture.reserve(),
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

        try publication.publish(
            stagedURL: fixture.staged,
            reservation: fixture.reserve(),
            isCurrent: { true }
        )
        publication.cancel()

        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "generated subtitle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testConcurrentEnginesReserveAndPublishDistinctOutputs() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let coordinator = SubtitleSRTNaming()
        let reservations = SubtitleSRTMethod.allCases.map {
            coordinator.reserve(directory: fixture.directory, sourceFile: fixture.source, method: $0)
        }
        defer { reservations.forEach { $0.release() } }

        XCTAssertEqual(Set(reservations.map(\.url.lastPathComponent)), ["clip.srt", "clip.whisper.srt", "clip.parakeet.srt"])
        for (index, reservation) in reservations.enumerated() {
            try "engine \(index)".write(to: fixture.staged, atomically: true, encoding: .utf8)
            try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: reservation, isCurrent: { true })
        }
        for (index, reservation) in reservations.enumerated() {
            XCTAssertEqual(try String(contentsOf: reservation.url, encoding: .utf8), "engine \(index)")
        }
    }

    @MainActor
    func testOwnershipSurvivesNewCoordinatorAndRepeatedReplacement() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        for index in 0..<3 {
            let reservation = fixture.reserve(coordinator: SubtitleSRTNaming())
            defer { reservation.release() }
            XCTAssertEqual(reservation.url, fixture.destination)
            try "attempt \(index)".write(to: fixture.staged, atomically: true, encoding: .utf8)
            try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: reservation, isCurrent: { true })
            XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "attempt \(index)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["clip.srt"])
        let attribute = "com.aagedal.MediaConverter.subtitle-owner"
        let count = getxattr(fixture.destination.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        XCTAssertGreaterThan(count, 0)
        guard count > 0 else { return }
        var data = Data(count: count)
        XCTAssertEqual(data.withUnsafeMutableBytes {
            getxattr(fixture.destination.path, attribute, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
        }, count)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let owner = try XCTUnwrap(record["owner"] as? [String: Any])
        XCTAssertEqual(Set(owner.keys), ["method", "sourceIdentityDigest"])
        let digest = try XCTUnwrap(owner["sourceIdentityDigest"] as? String)
        XCTAssertEqual(Data(base64Encoded: digest)?.count, 32)
    }

    @MainActor
    func testUnownedBareAndEngineSuffixedOutputsRemainUntouched() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let suffixed = fixture.directory.appendingPathComponent("clip.whisper.srt")
        try "legacy bare".write(to: fixture.destination, atomically: true, encoding: .utf8)
        try "independent suffix".write(to: suffixed, atomically: true, encoding: .utf8)
        let reservation = fixture.reserve()
        defer { reservation.release() }

        XCTAssertEqual(reservation.url.lastPathComponent, "clip.whisper-2.srt")
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: reservation, isCurrent: { true })
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "legacy bare")
        XCTAssertEqual(try String(contentsOf: suffixed, encoding: .utf8), "independent suffix")
    }

    @MainActor
    func testIndependentSourcesRetainTheirOwnedNumberedOutputOnRetry() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let otherSource = fixture.directory.appendingPathComponent("another/clip.mov")
        let first = fixture.reserve()
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: first, isCurrent: { true })
        first.release()
        let independent = fixture.directory.appendingPathComponent("clip.whisper.srt")
        try "independent output".write(to: independent, atomically: true, encoding: .utf8)
        let other = SubtitleSRTNaming.shared.reserve(directory: fixture.directory, sourceFile: otherSource, method: .whisper)
        XCTAssertEqual(other.url.lastPathComponent, "clip.whisper-2.srt")
        try "other source".write(to: fixture.staged, atomically: true, encoding: .utf8)
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: other, isCurrent: { true })
        other.release()

        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "generated subtitle")
        XCTAssertEqual(try String(contentsOf: independent, encoding: .utf8), "independent output")
        // Removing the bare output must not redirect the other source's retry.
        try FileManager.default.removeItem(at: fixture.destination)
        let retry = SubtitleSRTNaming().reserve(directory: fixture.directory, sourceFile: otherSource, method: .whisper)
        defer { retry.release() }
        XCTAssertEqual(retry.url, other.url)
        XCTAssertEqual(try String(contentsOf: other.url, encoding: .utf8), "other source")
    }

    @MainActor
    func testUserEditedOwnedSubtitleIsPreserved() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let first = fixture.reserve()
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: first, isCurrent: { true })
        first.release()
        // In-place editing retains the xattr; the digest must still reject ownership.
        try Data("edited by user".utf8).write(to: fixture.destination)
        let retry = fixture.reserve()
        defer { retry.release() }
        XCTAssertEqual(retry.url.lastPathComponent, "clip.whisper.srt")
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "edited by user")
    }

    @MainActor
    func testDestinationAppearingAfterReservationRejectsPublication() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let reservation = fixture.reserve()
        defer { reservation.release() }
        try "external output".write(to: fixture.destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged, reservation: reservation, isCurrent: { true }
        )) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteFileExists) }
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "external output")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testOwnedDestinationChangedAfterReservationRejectsPublication() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let first = fixture.reserve()
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: first, isCurrent: { true })
        first.release()
        let retry = fixture.reserve()
        defer { retry.release() }
        try "external replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        try "retry output".write(to: fixture.staged, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged, reservation: retry, isCurrent: { true }
        )) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteFileExists) }
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "external replacement")
    }

    @MainActor
    func testDestinationChangedDuringMetadataPreparationRejectsPublication() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let first = fixture.reserve()
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: first, isCurrent: { true })
        first.release()
        let coordinator = SubtitleSRTNaming(persistOwnership: { _, _ in
            try? "external replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
            return false
        })
        let retry = fixture.reserve(coordinator: coordinator)
        defer { retry.release() }
        try "retry output".write(to: fixture.staged, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged, reservation: retry, isCurrent: { true }
        )) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteFileExists) }
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "external replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @MainActor
    func testReleasedReservationCannotPublishOrReleaseItsReplacement() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let old = fixture.reserve()
        old.release()
        let replacement = fixture.reserve()
        defer { replacement.release() }
        old.release()

        XCTAssertEqual(replacement.url, old.url)
        XCTAssertThrowsError(try SubtitleSRTPublication().publish(
            stagedURL: fixture.staged, reservation: old, isCurrent: { true }
        )) { XCTAssertTrue($0 is CancellationError) }
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: replacement, isCurrent: { true })
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "generated subtitle")
    }

    func testAbandonedReservationReleasesItsPath() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        var abandoned: SubtitleSRTReservation? = fixture.reserve()
        XCTAssertEqual(abandoned?.url, fixture.destination)
        abandoned = nil
        let replacement = fixture.reserve()
        defer { replacement.release() }
        XCTAssertEqual(replacement.url, fixture.destination)
    }

    @MainActor
    func testFilesystemWithoutOwnershipMetadataUsesFreshOutputOnRetry() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let first = fixture.reserve(coordinator: SubtitleSRTNaming(persistOwnership: { _, _ in false }))
        try SubtitleSRTPublication().publish(stagedURL: fixture.staged, reservation: first, isCurrent: { true })
        first.release()
        let retry = fixture.reserve(coordinator: SubtitleSRTNaming())
        defer { retry.release() }
        XCTAssertEqual(retry.url.lastPathComponent, "clip.whisper.srt")
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "generated subtitle")
    }

    func testDirectorySymlinkAliasesShareReservations() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        let first = fixture.reserve()
        let second = SubtitleSRTNaming.shared.reserve(directory: alias, sourceFile: fixture.source, method: .ocr)
        defer { first.release(); second.release() }
        XCTAssertEqual(first.url.lastPathComponent, "clip.srt")
        XCTAssertEqual(second.url.lastPathComponent, "clip.ocr.srt")
    }

    func testLongUnicodeBasenameReservesDistinctValidFilenames() throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        let source = fixture.directory.appendingPathComponent(String(repeating: "é", count: 125) + ".mov")
        let reservations = (0..<3).map { _ in
            SubtitleSRTNaming.shared.reserve(directory: fixture.directory, sourceFile: source, method: .whisper)
        }
        defer { reservations.forEach { $0.release() } }
        XCTAssertEqual(Set(reservations.map(\.url)).count, 3)
        XCTAssertTrue(reservations.allSatisfy { $0.url.lastPathComponent.utf8.count <= 255 })
    }

    @MainActor
    func testIndependentWhisperInstancesAndParakeetPublishConcurrentOutputs() async throws {
        let fixture = try PublicationFiles()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.staged)
        let runner = ConcurrentPublicationOutputRunner(expectedCount: 3)
        let model = PublicationModelProvider(path: fixture.directory.appendingPathComponent("model.bin"))
        let first = WhisperService(modelManager: model, subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let second = WhisperService(modelManager: model, subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let parakeet = ParakeetService(
            subprocessRunner: runner,
            parakeetPathProvider: { "/fixture/parakeet-mlx" },
            ffmpegPathProvider: { "/fixture/ffmpeg" },
            chunkDurationProvider: { AppConstants.defaultParakeetChunkDuration },
            overlapDurationProvider: { AppConstants.defaultParakeetOverlapDuration }
        )
        async let firstURL = first.generateSubtitlesOnly(
            inputFile: fixture.source, model: .base, language: "auto", operationID: UUID()
        ) { _ in }
        async let secondURL = second.generateSubtitlesOnly(
            inputFile: fixture.source, model: .base, language: "auto", operationID: UUID()
        ) { _ in }
        async let thirdURL = parakeet.generateSubtitlesOnly(
            inputFile: fixture.source, model: ParakeetModel.allModels[0], language: "en", operationID: UUID()
        ) { _ in }
        let outputs = try await [firstURL, secondURL, thirdURL]
        XCTAssertEqual(Set(outputs).count, 3)
        XCTAssertEqual(Set(try outputs.map { try String(contentsOf: $0, encoding: .utf8) }).count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count, 3)
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

    var source: URL { directory.appendingPathComponent("clip.mov") }

    func reserve(coordinator: SubtitleSRTNaming = .shared) -> SubtitleSRTReservation {
        coordinator.reserve(directory: directory, sourceFile: source, method: .whisper)
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
        let staged = try publicationStagedURL(for: request)
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

private func publicationStagedURL(for request: SubprocessRequest) throws -> URL {
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
    return staged
}

private actor ConcurrentPublicationOutputRunner: SubprocessRunning {
    let expectedCount: Int
    private var count = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) { self.expectedCount = expectedCount }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let staged = try publicationStagedURL(for: request)
        count += 1
        try "1\n00:00:00,000 --> 00:00:01,000\nResult \(count)\n".write(to: staged, atomically: true, encoding: .utf8)
        if count == expectedCount {
            waiting.forEach { $0.resume() }
            waiting.removeAll()
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1)
        )
    }
}
