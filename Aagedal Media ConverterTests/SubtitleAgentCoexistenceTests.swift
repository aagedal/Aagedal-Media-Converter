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
    func testActiveSubtitleMuxCancellationPreservesConcurrentAgentExport() async throws {
        try await checkCoexistence(cancelEmbedding: true, cancelActiveMux: true)
    }

    @MainActor
    func testSubtitleCancellationWhileBothProcessesRunPreservesAgentExport() async throws {
        try await checkCoexistence(cancelEmbedding: true, cancelActiveMux: true, cancelDuringAgentExport: true)
    }

    @MainActor
    func testAgentCancellationWhileBothProcessesRunPreservesSubtitlePublication() async throws {
        try await checkCoexistence(
            cancelEmbedding: false, cancelActiveMux: true,
            cancelDuringAgentExport: true, cancelAgent: true
        )
    }

    @MainActor
    private func checkCoexistence(
        cancelEmbedding: Bool,
        cancelActiveMux: Bool = false,
        cancelDuringAgentExport: Bool = false,
        cancelAgent: Bool = false
    ) async throws {
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
        let muxReady = expectation(description: cancelActiveMux
            ? "Real subtitle mux reported active progress"
            : "Real subtitle mux reached publication boundary")
        let subtitleRunner = CoexistenceSubtitleRunner(
            completed: muxReady, throttleMux: cancelActiveMux,
            readRate: cancelAgent ? "0.25" : "0.01"
        )
        let gate = ApplicationConversionExecutionGate()
        let manager = ConversionManager(subprocessRunner: subtitleRunner, executionGate: gate)
        let itemID = UUID()
        let embedding = Task {
            await manager.embedSubtitlesForAttachedFile(
                srtURL: subtitles, videoURL: legacyOutput, itemID: itemID
            )
        }
        let agentStarted = expectation(description: "Agent acquired execution while subtitle work is outstanding")
        let agentGate = CoexistenceAgentGate(started: agentStarted)
        let agentProgress = XCTestExpectation(description: "Real agent FFmpeg reported active progress")
        let agentRunner = CoexistenceLiveAgentRunner(started: agentProgress)
        let converter = cancelDuringAgentExport
            ? FFMPEGConverter(subprocessRunner: agentRunner)
            : FFMPEGConverter()
        let adapter = ApplicationFFmpegJobExecutor(runner: .live(converter: converter))
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
            await fulfillment(of: [muxReady], timeout: 15)
            XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            let plan = try await service.plan(ApplicationConversionRequest(
                origin: .localAgent, requesterID: "subtitle-coexistence",
                sourceURLs: [source], destinationFolderURL: directory, presetID: .streamCopy
            ))
            let accepted = try await service.submit(planID: plan.id)
            acceptedJobID = accepted.record.id
            await fulfillment(of: [agentStarted], timeout: 15)
            if cancelEmbedding && !cancelActiveMux {
                await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
                await subtitleRunner.release()
                await embedding.value
                XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            }
            await agentGate.release()
            if cancelDuringAgentExport {
                await fulfillment(of: [agentProgress], timeout: 15)
                let muxRunning = await subtitleRunner.isRunning
                let agentRunning = await agentRunner.isRunning
                XCTAssertTrue(muxRunning, "Subtitle FFmpeg must be active at cancellation")
                XCTAssertTrue(agentRunning, "Agent FFmpeg must be active at cancellation")
                if cancelAgent {
                    _ = try await service.requestCancellation(accepted.record.id)
                    for _ in 0..<1500 {
                        if try await service.record(for: accepted.record.id)?.state.isTerminal == true { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let cancelledRecord = try await service.record(for: accepted.record.id)
                    XCTAssertEqual(cancelledRecord?.state, .cancelled)
                    XCTAssertEqual(cancelledRecord?.outputURLs, [])
                    let agentDrained = await agentRunner.isRunning
                    let agentCancelled = await agentRunner.wasCancelled
                    let subtitleStillRunning = await subtitleRunner.isRunning
                    XCTAssertFalse(agentDrained)
                    XCTAssertTrue(agentCancelled)
                    XCTAssertTrue(subtitleStillRunning, "Agent cancellation must leave the subtitle subprocess running")
                    XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
                    await embedding.value
                    let subtitleCancelled = await subtitleRunner.wasCancelled
                    let subtitleProcessCancelled = await subtitleRunner.processWasCancelled
                    let subtitleRunning = await subtitleRunner.isRunning
                    XCTAssertFalse(subtitleCancelled)
                    XCTAssertFalse(subtitleProcessCancelled)
                    XCTAssertFalse(subtitleRunning)
                    let metadata = try await ApplicationMediaInspector.live.inspect(legacyOutput)
                    XCTAssertEqual(metadata.subtitleStreams.count, 1)
                    XCTAssertEqual(try XCTUnwrap(metadata.durationSeconds), 2, accuracy: 1.0 / 24)
                    XCTAssertNotEqual(try Data(contentsOf: legacyOutput), originalBytes)
                    XCTAssertEqual(try Data(contentsOf: source), originalBytes)
                    XCTAssertEqual(try Data(contentsOf: subtitles), subtitleBytes)
                    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    XCTAssertEqual(Set(remainingFiles), Set([source.lastPathComponent, legacyOutput.lastPathComponent, subtitles.lastPathComponent]))
                    let finalRecord = try await service.record(for: accepted.record.id)
                    XCTAssertEqual(finalRecord?.state, .cancelled)
                    XCTAssertEqual(finalRecord?.outputURLs, [])
                    return
                }
                await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
                await embedding.value
                let muxDrained = await subtitleRunner.isRunning
                let muxCancelled = await subtitleRunner.processWasCancelled
                let agentStillRunning = await agentRunner.isRunning
                let activeRecord = try await service.record(for: accepted.record.id)
                XCTAssertFalse(muxDrained)
                XCTAssertTrue(muxCancelled)
                XCTAssertTrue(agentStillRunning, "Subtitle cancellation must leave the agent subprocess running")
                XCTAssertEqual(activeRecord?.state, .running)
                XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            }
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
            if cancelDuringAgentExport {
                let agentDrained = await agentRunner.isRunning
                let agentCancelled = await agentRunner.wasCancelled
                XCTAssertFalse(agentDrained)
                XCTAssertFalse(agentCancelled)
            }
            if cancelActiveMux && !cancelDuringAgentExport {
                let stillMuxing = await subtitleRunner.isRunning
                XCTAssertTrue(stillMuxing, "The real mux must remain active throughout the agent export")
                await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
                await embedding.value
                let drained = await subtitleRunner.isRunning
                let cancelledProcess = await subtitleRunner.processWasCancelled
                XCTAssertFalse(drained)
                XCTAssertTrue(cancelledProcess, "Cancellation must reach the running subprocess")
                XCTAssertEqual(try Data(contentsOf: legacyOutput), originalBytes)
            }
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

/// Media is produced by the bundled FFmpeg; tests control completion or input read rate.
private actor CoexistenceSubtitleRunner: SubprocessRunning {
    let completed: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var wasCancelled = false
    private(set) var isRunning = false
    private(set) var processWasCancelled = false
    private let throttleMux: Bool
    private let readRate: String

    init(completed: XCTestExpectation, throttleMux: Bool, readRate: String = "0.01") {
        self.completed = completed
        self.throttleMux = throttleMux
        self.readRate = readRate
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        if throttleMux {
            // Keep the real mux active long enough to finish the concurrent agent job.
            // Signal readiness from FFmpeg progress, not merely from launching the task.
            let readiness = MuxProgressReadiness(expectation: completed)
            let throttled = SubprocessRequest(
                executableURL: request.executableURL,
                arguments: ["-readrate", readRate, "-progress", "pipe:1", "-stats_period", "0.05"] + request.arguments,
                timeout: .seconds(45),
                sensitiveValues: request.sensitiveValues
            )
            isRunning = true
            defer {
                isRunning = false
                wasCancelled = Task.isCancelled
            }
            do {
                return try await SubprocessRunner().run(throttled) { chunk in
                    readiness.receive(chunk)
                    outputHandler?(chunk)
                }
            } catch is CancellationError {
                processWasCancelled = true
                throw CancellationError()
            }
        }
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

/// Pipe chunks can split lines; retain a bounded tail and signal exactly once.
private final class MuxProgressReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private let stream: SubprocessOutputStream
    private var buffer = ""
    private var signalled = false

    init(expectation: XCTestExpectation, stream: SubprocessOutputStream = .standardOutput) {
        self.expectation = expectation
        self.stream = stream
    }

    func receive(_ chunk: SubprocessOutputChunk) {
        guard chunk.stream == stream else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !signalled else { return }
        buffer += String(decoding: chunk.data, as: UTF8.self)
        if buffer.contains("progress=continue") {
            signalled = true
            expectation.fulfill()
        }
        buffer = String(buffer.suffix(4096))
    }
}

/// Pace the real agent export so cancellation is observed while both children run.
private actor CoexistenceLiveAgentRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var isRunning = false
    private(set) var wasCancelled = false

    init(started: XCTestExpectation) { self.started = started }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        var arguments = request.arguments
        if let input = arguments.firstIndex(of: "-i") {
            arguments.insert(contentsOf: ["-readrate", "0.25"], at: input)
        }
        arguments.insert(contentsOf: ["-stats_period", "0.05"], at: 0)
        let paced = SubprocessRequest(
            executableURL: request.executableURL, arguments: arguments,
            environment: request.environment, currentDirectoryURL: request.currentDirectoryURL,
            standardInput: request.standardInput, timeout: .seconds(30),
            terminationGracePeriod: request.terminationGracePeriod,
            standardOutputCaptureLimit: request.standardOutputCaptureLimit,
            standardErrorCaptureLimit: request.standardErrorCaptureLimit,
            sensitiveArgumentNames: request.sensitiveArgumentNames,
            sensitiveValues: request.sensitiveValues, redactURLs: request.redactURLs
        )
        // Production commands send their progress protocol to stderr (pipe:2).
        let readiness = MuxProgressReadiness(expectation: started, stream: .standardError)
        isRunning = true
        defer { isRunning = false }
        do {
            return try await SubprocessRunner().run(paced) { chunk in
                readiness.receive(chunk)
                outputHandler?(chunk)
            }
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}
