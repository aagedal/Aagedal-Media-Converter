import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class SubtitleAgentCoexistenceTests: XCTestCase {
    @MainActor
    func testLateSubtitlePublicationPreservesCompletedAgentExport() async throws {
        try await checkCoexistence(cancelEmbedding: false)
    }

    @MainActor
    func testSubtitleCancellationWhileAgentRunsPreservesBothOutputs() async throws {
        try await checkCoexistence(cancelEmbedding: true)
    }

    @MainActor
    private func checkCoexistence(cancelEmbedding: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleAgentCoexistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let source = directory.appendingPathComponent("source.mp4")
        let legacyOutput = directory.appendingPathComponent("legacy.mp4")
        let subtitles = directory.appendingPathComponent("captions.eng.srt")
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=64x48:rate=24:duration=2",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded)
        try FileManager.default.copyItem(at: source, to: legacyOutput)
        let originalBytes = try Data(contentsOf: source)
        let subtitleBytes = Data("1\n00:00:00,000 --> 00:00:01,500\nCoexistence fixture\n".utf8)
        try subtitleBytes.write(to: subtitles)
        let muxFinished = expectation(description: "Real subtitle mux reached publication boundary")
        let subtitleRunner = CoexistenceSubtitleRunner(completed: muxFinished)
        let gate = ApplicationConversionExecutionGate()
        let manager = ConversionManager(subprocessRunner: subtitleRunner, executionGate: gate)
        let itemID = UUID()
        let embedding = Task {
            await manager.embedSubtitlesForAttachedFile(
                srtURL: subtitles, videoURL: legacyOutput, itemID: itemID
            )
        }
        let agentStarted = expectation(description: "Agent acquired execution while subtitle publication waits")
        let agentGate = CoexistenceAgentGate(started: agentStarted)
        let adapter = ApplicationFFmpegJobExecutor(runner: .live())
        let liveExecutor = adapter.jobExecutor
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(execute: { jobID, plan, progress in
                await agentGate.wait()
                return await liveExecutor.execute(jobID, plan, progress)
            }, cancel: liveExecutor.cancel),
            executionGate: gate
        )
        var acceptedJobID: ApplicationJobID?
        do {
            await fulfillment(of: [muxFinished], timeout: 15)
            XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            let plan = try await service.plan(ApplicationConversionRequest(
                origin: .localAgent, requesterID: "subtitle-coexistence",
                sourceURLs: [source], destinationFolderURL: directory, presetID: .streamCopy
            ))
            let accepted = try await service.submit(planID: plan.id)
            acceptedJobID = accepted.record.id
            await fulfillment(of: [agentStarted], timeout: 15)
            if cancelEmbedding {
                await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
                await subtitleRunner.release()
                await embedding.value
                XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            }
            await agentGate.release()
            for _ in 0..<1500 {
                if try await service.record(for: accepted.record.id)?.state.isTerminal == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let completedRecord = try await service.record(for: accepted.record.id)
            let record = try XCTUnwrap(completedRecord)
            XCTAssertEqual(record.state, .succeeded)
            let agentOutput = try XCTUnwrap(record.outputURLs.first)
            XCTAssertNotEqual(agentOutput, source)
            XCTAssertNotEqual(agentOutput, legacyOutput)
            let agentBytes = try Data(contentsOf: agentOutput)
            if !cancelEmbedding {
                await subtitleRunner.release()
                await embedding.value
                XCTAssertNotEqual(try Data(contentsOf: legacyOutput), originalBytes)
            }
            let legacyMetadata = try await ApplicationMediaInspector.live.inspect(legacyOutput)
            XCTAssertEqual(legacyMetadata.subtitleStreams.count, cancelEmbedding ? 0 : 1)
            let agentMetadata = try await ApplicationMediaInspector.live.inspect(agentOutput)
            XCTAssertEqual(agentMetadata.subtitleStreams.count, 0)
            XCTAssertEqual(try XCTUnwrap(agentMetadata.durationSeconds), 2, accuracy: 1.0 / 24)
            XCTAssertEqual(try Data(contentsOf: agentOutput), agentBytes)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertEqual(try Data(contentsOf: subtitles), subtitleBytes)
            let finalRecord = try await service.record(for: accepted.record.id)
            XCTAssertEqual(finalRecord?.state, .succeeded)
            XCTAssertEqual(finalRecord?.outputURLs, record.outputURLs)
            let cancelled = await subtitleRunner.wasCancelled
            XCTAssertEqual(cancelled, cancelEmbedding)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".subtitle-embed-") }
            XCTAssertTrue(leftovers.isEmpty)
        } catch {
            await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
            await subtitleRunner.release()
            await embedding.value
            await agentGate.release()
            if let acceptedJobID { _ = try? await service.requestCancellation(acceptedJobID) }
            throw error
        }
    }
}

/// Only completion is controlled; media is produced by the bundled FFmpeg.
private actor CoexistenceSubtitleRunner: SubprocessRunning {
    let completed: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var wasCancelled = false

    init(completed: XCTestExpectation) { self.completed = completed }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let result = try await SubprocessRunner().run(request, outputHandler: outputHandler)
        if !released {
            await withCheckedContinuation {
                continuation = $0
                completed.fulfill()
            }
        }
        wasCancelled = Task.isCancelled
        return result
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CoexistenceAgentGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
