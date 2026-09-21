import Foundation
import AppKit
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

final class WhisperAgentCoexistenceTests: XCTestCase {
    @MainActor
    func testWhisperCancellationPreservesRunningAgentExport() async throws {
        try await checkCoexistence(cancelAgent: false)
    }

    @MainActor
    func testAgentCancellationPreservesRunningWhisperPublication() async throws {
        try await checkCoexistence(cancelAgent: true)
    }

    @MainActor
    private func checkCoexistence(cancelAgent: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperAgentCoexistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let existingSRT = directory.appendingPathComponent("source.srt")
        let existingBytes = Data("Existing subtitles".utf8)
        try existingBytes.write(to: existingSRT)
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=64x48:rate=24:duration=2",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded)
        let sourceBytes = try Data(contentsOf: source)
        let whisperStarted = expectation(description: "Whisper transcription is outstanding")
        let whisperCancelled = expectation(description: "Whisper runner received cancellation")
        whisperCancelled.isInverted = cancelAgent
        let transcriptionRunner = CoexistenceWhisperRunner(started: whisperStarted, cancelled: whisperCancelled)
        let whisper = WhisperService(
            modelManager: CoexistenceWhisperModel(path: directory.appendingPathComponent("model.bin")),
            subprocessRunner: transcriptionRunner, ffmpegPathProvider: { ffmpeg }
        )
        let operationID = UUID()
        let transcription = Task {
            try await whisper.generateSubtitlesOnly(
                inputFile: source, model: .base, language: "auto", operationID: operationID
            ) { _ in }
        }
        await fulfillment(of: [whisperStarted], timeout: 3)
        let agentStarted = expectation(description: "Real agent FFmpeg reported progress")
        let runner = CoexistenceLiveAgentRunner(started: agentStarted)
        let adapter = ApplicationFFmpegJobExecutor(runner: .live(converter: FFMPEGConverter(subprocessRunner: runner)))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor)
        var jobID: ApplicationJobID?
        do {
            let plan = try await service.plan(ApplicationConversionRequest(
                origin: .localAgent, requesterID: "whisper-coexistence", sourceURLs: [source],
                destinationFolderURL: directory, presetID: .streamCopy
            ))
            let accepted = try await service.submit(planID: plan.id)
            jobID = accepted.record.id
            await fulfillment(of: [agentStarted], timeout: 15)
            let running = await runner.isRunning
            XCTAssertTrue(running)
            if cancelAgent {
                _ = try await service.requestCancellation(accepted.record.id)
            } else {
                await whisper.cancelGeneration(operationID: operationID)
                await fulfillment(of: [whisperCancelled], timeout: 3)
                // Deliberately return successful SRT output after cancellation.
                await transcriptionRunner.finish()
                do {
                    _ = try await transcription.value
                    XCTFail("Cancelled Whisper must reject late successful output")
                } catch let error as WhisperServiceError {
                    guard case .cancelled = error else { throw error }
                }
                let stillRunning = await runner.isRunning
                XCTAssertTrue(stillRunning)
            }
            for _ in 0..<1500 {
                if try await service.record(for: accepted.record.id)?.state.isTerminal == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let record = try await service.record(for: accepted.record.id)
            XCTAssertEqual(record?.state, cancelAgent ? .cancelled : .succeeded)
            let drained = await runner.isRunning
            let wasCancelled = await runner.wasCancelled
            XCTAssertFalse(drained)
            XCTAssertEqual(wasCancelled, cancelAgent)
            var subtitleOutputs: [URL] = []
            if cancelAgent {
                XCTAssertEqual(record?.outputURLs, [])
                let transcriptionActive = await transcriptionRunner.isRunning
                XCTAssertTrue(transcriptionActive)
                await transcriptionRunner.finish()
                let output = try await transcription.value
                subtitleOutputs = [output]
                XCTAssertEqual(output.lastPathComponent, "source.whisper.srt")
                XCTAssertEqual(try Data(contentsOf: output), CoexistenceWhisperRunner.subtitleBytes)
                await fulfillment(of: [whisperCancelled], timeout: 0.1)
            } else {
                let output = try XCTUnwrap(record?.outputURLs.first)
                let metadata = try await ApplicationMediaInspector.live.inspect(output)
                XCTAssertEqual(try XCTUnwrap(metadata.durationSeconds), 2, accuracy: 1.0 / 24)
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: existingSRT), existingBytes)
            let expectedFiles = [source, existingSRT] + subtitleOutputs + (record?.outputURLs ?? [])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                           Set(expectedFiles.map(\.lastPathComponent)))
            let finalRecord = try await service.record(for: accepted.record.id)
            XCTAssertEqual(finalRecord?.state, record?.state)
            XCTAssertEqual(finalRecord?.outputURLs, record?.outputURLs)
        } catch {
            if let jobID { _ = try? await service.requestCancellation(jobID) }
            await whisper.cancelGeneration(operationID: operationID)
            await transcriptionRunner.finish()
            _ = await transcription.result
            throw error
        }
    }
}

private struct CoexistenceWhisperModel: WhisperModelProviding {
    let path: URL
    func modelPath(for model: WhisperModel) -> URL { path }
    func isModelDownloaded(_ model: WhisperModel) -> Bool { true }
}

/// Holds the inference boundary and deliberately succeeds after cancellation.
private actor CoexistenceWhisperRunner: SubprocessRunning {
    static let subtitleBytes = Data("1\n00:00:00,000 --> 00:00:01,000\nTranscription result\n".utf8)
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isRunning = false

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let index = try XCTUnwrap(request.arguments.firstIndex(of: "-af"))
        let filter = request.arguments[index + 1]
        let start = try XCTUnwrap(filter.range(of: "destination=")?.upperBound)
        let end = try XCTUnwrap(filter.range(of: ":use_gpu=true", range: start..<filter.endIndex)?.lowerBound)
        let staged = URL(fileURLWithPath: String(filter[start..<end]))
        isRunning = true
        defer { isRunning = false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { self.continuation = continuation }
                if !released { started.fulfill() }
            }
        } onCancel: {
            self.cancelled.fulfill()
        }
        try Self.subtitleBytes.write(to: staged)
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1)
        )
    }

    func finish() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class OCRAgentCoexistenceTests: XCTestCase {
    @MainActor
    func testOCRCancellationPreservesRunningAgentExport() async throws {
        try await checkCoexistence(cancelAgent: false)
    }

    @MainActor
    func testAgentCancellationPreservesRunningOCRPublication() async throws {
        try await checkCoexistence(cancelAgent: true)
    }

    @MainActor
    func testActiveExtractionCancellationPreservesRunningAgentExport() async throws {
        try await checkCoexistence(cancelAgent: false, cancelDuringExtraction: true)
    }

    @MainActor
    func testAgentCancellationPreservesActiveExtractionAndOCRPublication() async throws {
        try await checkCoexistence(cancelAgent: true, cancelDuringExtraction: true)
    }

    @MainActor
    func testActiveDVDExtractionCancellationPreservesRunningAgentExport() async throws {
        try await checkCoexistence(cancelAgent: false, cancelDuringExtraction: true, useDVD: true)
    }

    @MainActor
    func testAgentCancellationPreservesActiveDVDExtractionAndOCRPublication() async throws {
        try await checkCoexistence(cancelAgent: true, cancelDuringExtraction: true, useDVD: true)
    }

    @MainActor
    func testAgentCancellationPreservesRealTesseractOCRPublication() async throws {
        try await checkCoexistence(cancelAgent: true, useRealTesseract: true)
    }

    @MainActor
    func testAllOCRFramesFailWithoutPublishingOrStoppingAgentExport() async throws {
        try await checkCoexistence(cancelAgent: false, failOCR: true)
    }

    @MainActor
    private func checkCoexistence(
        cancelAgent: Bool, cancelDuringExtraction: Bool = false, useRealTesseract: Bool = false,
        failOCR: Bool = false, useDVD: Bool = false
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRAgentCoexistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let fixtureDirectory = directory.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let subtitleFixture: URL
        if useDVD {
            subtitleFixture = try CoexistenceDVDFixture.writeFixture(
                packet: CoexistenceDVDFixture.fixture(padding: 4096), directory: fixtureDirectory
            )
            let header = try String(contentsOf: subtitleFixture, encoding: .utf8)
            let sub = fixtureDirectory.appendingPathComponent("fixture.sub")
            let packet = try Data(contentsOf: sub)
            try (packet + packet + packet).write(to: sub)
            let additionalTimestamps = [200, 400].enumerated().map { index, milliseconds in
                String(format: "\ntimestamp: 00:00:00:%03d, filepos: %09X", milliseconds,
                       packet.count * (index + 1))
            }.joined()
            try (header.replacingOccurrences(of: "00:00:02:000", with: "00:00:00:000")
                 + additionalTimestamps).write(to: subtitleFixture, atomically: true, encoding: .utf8)
        } else {
            subtitleFixture = fixtureDirectory.appendingPathComponent("fixture.sup")
            try (useRealTesseract ? CoexistencePGSFixture.readableData() : CoexistencePGSFixture.data)
                .write(to: subtitleFixture)
        }
        let existingSRT = directory.appendingPathComponent("source.srt")
        let existingBytes = Data("Existing subtitles".utf8)
        try existingBytes.write(to: existingSRT)
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=64x48:rate=24:duration=2",
                        "-i", subtitleFixture.path, "-map", "0:v:0", "-map", "1:s:0",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "copy", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        try FileManager.default.removeItem(at: fixtureDirectory)
        let sourceBytes = try Data(contentsOf: source)
        let ocrStarted = expectation(description: "OCR recognition is outstanding")
        let ocrCancelled = expectation(description: "OCR engine received cancellation")
        ocrCancelled.isInverted = cancelAgent || cancelDuringExtraction || failOCR
        ocrStarted.isInverted = cancelDuringExtraction && !cancelAgent
        let extractionStarted = cancelDuringExtraction
            ? expectation(description: "Real subtitle extraction reported FFmpeg progress") : nil
        let recognizer = CoexistenceOCREngine(started: ocrStarted, cancelled: ocrCancelled,
                                               useRealTesseract: useRealTesseract, failOCR: failOCR)
        let extractor = CoexistenceLiveBitmapSubtitleRunner(started: extractionStarted, paceVideo: useDVD)
        let ocr = TesseractService(subprocessRunner: extractor, ocrEngine: recognizer)
        let operationID = UUID()
        let recognition = Task {
            try await ocr.generateSubtitlesOnly(
                sourceFile: source, operationID: operationID, subtitleStreamIndex: 0,
                codec: useDVD ? "dvd_subtitle" : "hdmv_pgs_subtitle", language: "eng", engineKind: .appleVision
            ) { _ in }
        }
        if let extractionStarted {
            await fulfillment(of: [extractionStarted], timeout: 15)
        } else {
            await fulfillment(of: [ocrStarted], timeout: 15)
        }
        let agentStarted = expectation(description: "Real agent FFmpeg reported progress")
        let runner = CoexistenceLiveAgentRunner(started: agentStarted)
        let adapter = ApplicationFFmpegJobExecutor(runner: .live(converter: FFMPEGConverter(subprocessRunner: runner)))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor)
        var jobID: ApplicationJobID?
        do {
            let plan = try await service.plan(ApplicationConversionRequest(
                origin: .localAgent, requesterID: "ocr-coexistence", sourceURLs: [source],
                destinationFolderURL: directory, presetID: .streamCopy
            ))
            let accepted = try await service.submit(planID: plan.id)
            jobID = accepted.record.id
            await fulfillment(of: [agentStarted], timeout: 15)
            let running = await runner.isRunning
            XCTAssertTrue(running)
            if cancelDuringExtraction {
                let extracting = await extractor.isRunning
                let recognizing = await recognizer.isRunning
                XCTAssertTrue(extracting, "Both real FFmpeg processes must be active at cancellation")
                XCTAssertFalse(recognizing)
            }
            if cancelAgent {
                _ = try await service.requestCancellation(accepted.record.id)
            } else if failOCR {
                await recognizer.finish()
                do {
                    _ = try await recognition.value
                    XCTFail("An entirely failed OCR run must not publish an empty SRT")
                } catch let error as TesseractServiceError {
                    guard case .ocrFailed(let message) = error else { throw error }
                    XCTAssertEqual(message, "Recognition fixture failure")
                }
                await fulfillment(of: [ocrCancelled], timeout: 0.1)
                let stillRunning = await runner.isRunning
                XCTAssertTrue(stillRunning)
            } else {
                await ocr.cancelGeneration(operationID: operationID)
                if !cancelDuringExtraction {
                    await fulfillment(of: [ocrCancelled], timeout: 3)
                }
                // Release any recognition wait; recognition-stage tests return late success.
                await recognizer.finish()
                do {
                    _ = try await recognition.value
                    XCTFail("Cancelled OCR must reject late successful output")
                } catch let error as TesseractServiceError {
                    guard case .cancelled = error else { throw error }
                }
                let stillRunning = await runner.isRunning
                XCTAssertTrue(stillRunning)
            }
            for _ in 0..<1500 {
                if try await service.record(for: accepted.record.id)?.state.isTerminal == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let record = try await service.record(for: accepted.record.id)
            XCTAssertEqual(record?.state, cancelAgent ? .cancelled : .succeeded)
            let drained = await runner.isRunning
            let wasCancelled = await runner.wasCancelled
            XCTAssertFalse(drained)
            XCTAssertEqual(wasCancelled, cancelAgent)
            var subtitleOutputs: [URL] = []
            if cancelAgent {
                XCTAssertEqual(record?.outputURLs, [])
                if cancelDuringExtraction {
                    // Extraction may finish naturally while the agent drains. It must
                    // reach recognition without receiving the agent's cancellation.
                    await fulfillment(of: [ocrStarted], timeout: 20)
                }
                let recognitionActive = await recognizer.isRunning
                XCTAssertTrue(recognitionActive)
                await recognizer.finish()
                let output = try await recognition.value
                subtitleOutputs = [output]
                XCTAssertEqual(output.lastPathComponent, "source.ocr.srt")
                let expectedText = useRealTesseract ? "Media subtitle" : "OCR result"
                let expectedIntervals = useDVD
                    ? ["00:00:00,512 --> 00:00:01,536", "00:00:00,712 --> 00:00:01,736",
                       "00:00:00,912 --> 00:00:01,936"]
                    : ["00:00:00,000 --> 00:00:01,000"]
                let expectedSRT = expectedIntervals.enumerated().map { index, interval in
                    "\(index + 1)\n\(interval)\n\(expectedText)\n"
                }.joined(separator: "\n")
                XCTAssertEqual(try Data(contentsOf: output), Data(expectedSRT.utf8))
                await fulfillment(of: [ocrCancelled], timeout: 0.1)
            } else {
                let output = try XCTUnwrap(record?.outputURLs.first)
                let metadata = try await ApplicationMediaInspector.live.inspect(output)
                XCTAssertEqual(try XCTUnwrap(metadata.durationSeconds), 2, accuracy: 1.0 / 24)
            }
            if cancelDuringExtraction && !cancelAgent {
                await fulfillment(of: [ocrStarted, ocrCancelled], timeout: 0.1)
            }
            let extractionRunning = await extractor.isRunning
            let extractionCancelled = await extractor.wasCancelled
            XCTAssertFalse(extractionRunning)
            XCTAssertEqual(extractionCancelled, cancelDuringExtraction && !cancelAgent)
            let extractedURL = await extractor.outputURL()
            let scratch = try XCTUnwrap(extractedURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.deletingLastPathComponent().path))
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: existingSRT), existingBytes)
            let expectedFiles = [source, existingSRT] + subtitleOutputs + (record?.outputURLs ?? [])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                           Set(expectedFiles.map(\.lastPathComponent)))
            let finalRecord = try await service.record(for: accepted.record.id)
            XCTAssertEqual(finalRecord?.state, record?.state)
            XCTAssertEqual(finalRecord?.outputURLs, record?.outputURLs)
        } catch {
            if let jobID { _ = try? await service.requestCancellation(jobID) }
            await ocr.cancelGeneration(operationID: operationID)
            await recognizer.finish()
            _ = await recognition.result
            throw error
        }
    }
}

/// Records scratch output while extracting the real MKV track with bundled FFmpeg.
private actor CoexistenceLiveBitmapSubtitleRunner: SubprocessRunning {
    private var output: URL?
    private let started: XCTestExpectation?
    private let paceVideo: Bool
    private(set) var isRunning = false
    private(set) var wasCancelled = false

    init(started: XCTestExpectation? = nil, paceVideo: Bool = false) {
        self.started = started
        self.paceVideo = paceVideo
    }

    func outputURL() -> URL? { output }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let destination = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
        output = destination
        var paced = request
        let readiness = started.map { MuxProgressReadiness(expectation: $0) }
        if readiness != nil {
            // Slow actual demuxing so the agent starts while extraction is still active.
            // Subtitle-only DVD extraction does not honor read-rate pacing here.
            // A discarded video output keeps the same demuxer alive at the test rate.
            let pacingOutput = paceVideo ? ["-map", "0:v:0", "-c:v", "copy", "-f", "null", "-"] : []
            paced = SubprocessRequest(
                executableURL: request.executableURL,
                arguments: ["-readrate", "0.1", "-readrate_initial_burst", paceVideo ? "0.001" : "0",
                            "-progress", "pipe:1", "-stats_period", "0.05"] + request.arguments + pacingOutput,
                timeout: .seconds(30),
                standardOutputCaptureLimit: request.standardOutputCaptureLimit,
                standardErrorCaptureLimit: request.standardErrorCaptureLimit,
                sensitiveValues: request.sensitiveValues
            )
        }
        isRunning = true
        defer { isRunning = false }
        do {
            return try await SubprocessRunner().run(paced) { chunk in
                readiness?.receive(chunk)
                outputHandler?(chunk)
            }
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

/// Generated PGS display sets, muxed into the source before extraction.
private enum CoexistencePGSFixture {
    /// Generates actual readable pixels, then encodes them as a PGS bitmap.
    @MainActor
    static func readableData() throws -> Data {
        let width = 640
        let height = 100
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        ("Media subtitle" as NSString).draw(at: NSPoint(x: 40, y: 25), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()

        func word(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 255), UInt8(value & 255)] }
        func segment(_ type: UInt8, pts: UInt32 = 0, _ payload: [UInt8]) -> Data {
            Data([0x50, 0x47, UInt8((pts >> 24) & 255), UInt8((pts >> 16) & 255),
                  UInt8((pts >> 8) & 255), UInt8(pts & 255), 0, 0, 0, 0, type]
                 + word(payload.count) + payload)
        }
        var rle: [UInt8] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                func color(at x: Int) -> UInt8 {
                    (bitmap.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5 ? 2 : 1
                }
                let paletteIndex = color(at: x)
                var count = 1
                while x + count < width && color(at: x + count) == paletteIndex { count += 1 }
                rle += [0, 0xC0 | UInt8(count >> 8), UInt8(count & 255), paletteIndex]
                x += count
            }
            rle += [0, 0]
        }
        let dimensions = word(width) + word(height)
        var data = segment(0x16, dimensions + [0x10, 0, 0, 0x80, 0, 0, 1,
                                             0, 0, 0, 0, 0, 0, 0, 0])
        data += segment(0x14, [0, 0, 1, 16, 128, 128, 255, 2, 235, 128, 128, 255])
        let length = rle.count + 4
        data += segment(0x15, [0, 0, 0, 0xC0, UInt8(length >> 16)]
                        + word(length) + dimensions + rle)
        data += segment(0x80, [])
        data += segment(0x16, pts: 90_000, dimensions + [0x10, 0, 1, 0, 0, 0, 0])
        data += segment(0x80, pts: 90_000, [])
        return data
    }

    static var data: Data {
        func segment(_ type: UInt8, pts: UInt32 = 0, payload: [UInt8]) -> Data {
            Data([0x50, 0x47, UInt8((pts >> 24) & 255), UInt8((pts >> 16) & 255),
                  UInt8((pts >> 8) & 255), UInt8(pts & 255), 0, 0, 0, 0, type,
                  UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload)
        }
        var data = segment(0x16, payload: [0, 2, 0, 1, 0x10, 0, 0, 0x80, 0, 0, 1,
                                          0, 0, 0, 0, 0, 0, 0, 0])
        data += segment(0x14, payload: [0, 0, 1, 235, 128, 128, 255])
        data += segment(0x15, payload: [0, 0, 0, 0xC0, 0, 0, 8, 0, 2, 0, 1, 1, 1, 0, 0])
        data += segment(0x80, payload: [])
        data += segment(0x16, pts: 90_000, payload: [0, 2, 0, 1, 0x10, 0, 1, 0, 0, 0, 0])
        data += segment(0x80, pts: 90_000, payload: [])
        return data
    }
}

/// Holds recognition after PNG rendering, then returns controlled text or invokes bundled Tesseract.
private actor CoexistenceOCREngine: BitmapSubtitleOCREngine {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isRunning = false

    private let useRealTesseract: Bool
    private let failOCR: Bool

    init(started: XCTestExpectation, cancelled: XCTestExpectation,
         useRealTesseract: Bool = false, failOCR: Bool = false) {
        self.started = started
        self.cancelled = cancelled
        self.useRealTesseract = useRealTesseract
        self.failOCR = failOCR
    }

    func recognize(pngURL: URL, language: String) async throws -> String {
        let bytes = try Data(contentsOf: pngURL)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(language, "eng")
        isRunning = true
        defer { isRunning = false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { self.continuation = continuation }
                if !released { started.fulfill() }
            }
        } onCancel: {
            self.cancelled.fulfill()
        }
        if failOCR {
            throw NSError(domain: "OCRFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recognition fixture failure"])
        }
        if useRealTesseract {
            let engine = TesseractOCREngine(
                tesseractPath: try XCTUnwrap(BinaryPathResolver.tesseractPath),
                tessdataPrefix: BinaryPathResolver.tessdataDirectory
            )
            return try await engine.recognize(pngURL: pngURL, language: language)
        }
        return "OCR result"
    }

    func finish() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class VOBSUBParserTests: XCTestCase {
    func testProgramStreamTimestampsRemainContinuousAcrossClockWrap() throws {
        let period: UInt64 = 1 << 33
        let timestamps = [period - 180_000, period - 90_000, period, period + 90_000]
        let frames = try parseProgramStream(timestamps: timestamps.map { $0 % period })
        XCTAssertEqual(frames.count, timestamps.count)
        for (frame, ticks) in zip(frames, timestamps) {
            XCTAssertEqual(frame.startTime, Double(ticks / 90) / 1000 + 0.512, accuracy: 0.0001)
            XCTAssertEqual(frame.endTime, Double(ticks / 90) / 1000 + 1.536, accuracy: 0.0001)
        }
    }

    func testProgramStreamPreservesSmallBackwardAndRepeatedTimestamps() throws {
        let timestamps: [UInt64] = [900_000, 900_000, 810_000, 990_000]
        let frames = try parseProgramStream(timestamps: timestamps)
        XCTAssertEqual(frames.count, timestamps.count)
        for (frame, ticks) in zip(frames, timestamps) {
            XCTAssertEqual(frame.startTime, Double(ticks / 90) / 1000 + 0.512, accuracy: 0.0001)
        }
    }

    func testProgramStreamHandlesReorderedTimestampAcrossWrap() throws {
        let period: UInt64 = 1 << 33
        let timestamps = [period - 180_000, period + 90_000, period - 90_000, period + 180_000]
        let frames = try parseProgramStream(timestamps: timestamps.map { $0 % period })
        XCTAssertEqual(frames.count, timestamps.count)
        for (frame, ticks) in zip(frames, timestamps) {
            XCTAssertEqual(frame.startTime, Double(ticks / 90) / 1000 + 0.512, accuracy: 0.0001)
        }
    }

    private func parseProgramStream(timestamps: [UInt64]) throws -> [SubtitleFrame] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DVDTimestamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packet = CoexistenceDVDFixture.fixture()
        let palette = try CoexistenceDVDFixture.writeFixture(packet: packet, directory: directory)
        var bytes: [UInt8] = []
        for ticks in timestamps {
            let pts: [UInt8] = [
                0x21 | UInt8((ticks >> 29) & 0x0E), UInt8((ticks >> 22) & 0xFF),
                UInt8((ticks >> 14) & 0xFE) | 1, UInt8((ticks >> 7) & 0xFF),
                UInt8((ticks << 1) & 0xFE) | 1
            ]
            // Split each SPU across a timestamped PES and an untimestamped continuation.
            bytes += [0, 0, 1, 0xBD] + CoexistenceDVDFixture.word(16)
                + [0x80, 0x80, 5] + pts + [0x20] + Array(packet.prefix(7))
            bytes += [0, 0, 1, 0xBD] + CoexistenceDVDFixture.word(packet.count - 7 + 4)
                + [0x80, 0, 0, 0x20] + Array(packet.dropFirst(7))
        }
        let stream = directory.appendingPathComponent("timestamps.vob")
        try Data(bytes).write(to: stream)
        return try VOBSUBParser.parse(programStreamURL: stream, paletteURL: palette)
    }

    func testDVDControlChainTimingPaletteAndVariableLengthRuns() throws {
        let frames = try parse(packet: CoexistenceDVDFixture.fixture())
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frame.startTime, 2.512, accuracy: 0.0001)
        XCTAssertEqual(frame.endTime, 3.536, accuracy: 0.0001)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.imageData))
        XCTAssertEqual(bitmap.pixelsWide, 300)
        XCTAssertEqual(bitmap.pixelsHigh, 2)
        for (x, expected) in [(0, [255, 0, 0, 255]), (1, [0, 255, 0, 255]),
                              (3, [0, 255, 0, 255]), (4, [0, 0, 255, 255]),
                              (15, [0, 0, 255, 255]), (16, [255, 255, 255, 255]),
                              (85, [255, 255, 255, 255]), (86, [255, 0, 0, 255]),
                              (299, [255, 0, 0, 255])] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: x, y: 0)
            XCTAssertEqual(pixel, expected, "x=\(x)")
        }
        var oddField = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&oddField, atX: 299, y: 1)
        XCTAssertEqual(oddField, [0, 255, 0, 255])
    }

    func testPreservesPaletteAlpha() throws {
        var packet = CoexistenceDVDFixture.fixture()
        packet[21] = 0xF8 // White opaque, blue 8/15 alpha.
        packet[22] = 0x40 // Green 4/15 alpha, red transparent.
        let frame = try XCTUnwrap(try parse(packet: packet).first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.imageData))
        for (x, expectedAlpha) in [(0, 0), (1, 68), (4, 136), (16, 255)] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: x, y: 0)
            XCTAssertEqual(pixel[3], expectedAlpha, "x=\(x)")
        }
    }

    func testRejectsBackwardControlLinkAndTruncatedPacket() throws {
        var packet = CoexistenceDVDFixture.fixture()
        packet[14] = 0
        packet[15] = 4 // First block points backward into pixel data.
        XCTAssertTrue(try parse(packet: packet).isEmpty)
        XCTAssertTrue(try parse(packet: Array(CoexistenceDVDFixture.fixture().dropLast())).isEmpty)
    }

    func testAlphaBeforePaletteMatchesPaletteBeforeAlpha() throws {
        var packet = CoexistenceDVDFixture.fixture()
        packet[21] = 0xF8
        packet[22] = 0x40
        let expected = try XCTUnwrap(try parse(packet: packet).first)
        // The same color/contrast state must produce the same bitmap in either order.
        packet.replaceSubrange(17..<23, with: [0x04, 0xF8, 0x40, 0x03, 0x32, 0x10])
        let actual = try XCTUnwrap(try parse(packet: packet).first)
        XCTAssertEqual(actual.startTime, expected.startTime)
        XCTAssertEqual(actual.endTime, expected.endTime)
        let expectedBitmap = try XCTUnwrap(NSBitmapImageRep(data: expected.imageData))
        let actualBitmap = try XCTUnwrap(NSBitmapImageRep(data: actual.imageData))
        for y in 0..<2 {
            for x in 0..<300 {
                var expectedPixel = [Int](repeating: 0, count: 4)
                var actualPixel = [Int](repeating: 0, count: 4)
                expectedBitmap.getPixel(&expectedPixel, atX: x, y: y)
                actualBitmap.getPixel(&actualPixel, atX: x, y: y)
                XCTAssertEqual(actualPixel, expectedPixel, "x=\(x), y=\(y)")
            }
        }
    }

    func testLaterPaletteCommandPreservesContrast() throws {
        var packet = CoexistenceDVDFixture.fixture()
        packet[21] = 0xF8
        packet[22] = 0x40
        // A later control block changes colors without changing contrast.
        packet.insert(contentsOf: [0x03, 0x32, 0x01], at: packet.count - 2)
        packet.replaceSubrange(0..<2, with: CoexistenceDVDFixture.word(packet.count))
        let frame = try XCTUnwrap(try parse(packet: packet).first)
        XCTAssertEqual(frame.startTime, 2.512, accuracy: 0.0001)
        XCTAssertEqual(frame.endTime, 3.536, accuracy: 0.0001)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.imageData))
        for (x, alpha) in [(0, 0), (1, 68), (4, 136), (16, 255)] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: x, y: 0)
            XCTAssertEqual(pixel[3], alpha, "x=\(x)")
            if x == 1 {
                XCTAssertGreaterThan(pixel[0], 0)
                XCTAssertEqual(pixel[1], 0)
                XCTAssertEqual(pixel[2], 0)
            }
        }
    }

    func testRejectsRunBeyondRowAndTruncatedPixelData() throws {
        var packet = CoexistenceDVDFixture.fixture()
        // A run of 255 pixels followed by another 255 exceeds the 300-pixel row.
        packet.replaceSubrange(4..<8, with: [0x03, 0xFC, 0x03, 0xFC])
        XCTAssertTrue(try parse(packet: packet).isEmpty)
        packet = CoexistenceDVDFixture.fixture()
        packet[33] = 0
        packet[34] = 11 // Odd field starts with only one byte before the controls.
        XCTAssertTrue(try parse(packet: packet).isEmpty)
    }

    func testSelectedDVDTrackExtractionAndSRTPublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DVDExtraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first", isDirectory: true)
        let second = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstIDX = try CoexistenceDVDFixture.writeFixture(packet: CoexistenceDVDFixture.fixture(), directory: first)
        // Force FFmpeg to fragment the selected SPU across several PES packets.
        let secondIDX = try CoexistenceDVDFixture.writeFixture(packet: CoexistenceDVDFixture.fixture(padding: 4096), directory: second)
        let originalHeader = try String(contentsOf: secondIDX, encoding: .utf8)
        try originalHeader.replacingOccurrences(of: "00:00:02:000", with: "00:00:07:000")
            .replacingOccurrences(of: "ff0000, 00ff00", with: "ffff00, 00ff00")
            .write(to: secondIDX, atomically: true, encoding: .utf8)
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let source = directory.appendingPathComponent("source.mkv")
        let mux = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-i", firstIDX.path, "-i", secondIDX.path,
                        "-map", "0:s:0", "-map", "1:s:0", "-c", "copy", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(mux.succeeded, mux.standardErrorText)
        let originalSource = try Data(contentsOf: source)
        let programStream = directory.appendingPathComponent("selected.vob")
        let palette = directory.appendingPathComponent("palette.txt")
        try await TesseractSubtitleStreamExtractor().extract(
            source: source.path, streamIndex: 1, outputPath: programStream.path,
            palettePath: palette.path, ffmpegPath: ffmpeg
        )
        let frames = try VOBSUBParser.parse(programStreamURL: programStream, paletteURL: palette)
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.startTime, 7.512, accuracy: 0.001)
        XCTAssertEqual(frame.endTime, 8.536, accuracy: 0.001)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.imageData))
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: 0, y: 0)
        XCTAssertEqual(pixel, [255, 255, 0, 255])

        let existing = directory.appendingPathComponent("source.ocr.srt")
        try "Preserve existing subtitles".write(to: existing, atomically: true, encoding: .utf8)
        let service = TesseractService(ocrEngine: DVDExtractionOCREngine())
        let output = try await service.generateSubtitles(
            sourceFile: source, outputDirectory: directory, operationID: UUID(),
            subtitleStreamIndex: 1, codec: "dvd_subtitle", language: "eng"
        ) { _ in }
        XCTAssertNotEqual(output, existing)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8),
                       "1\n00:00:07,512 --> 00:00:08,536\nSelected DVD track\n")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Preserve existing subtitles")
        XCTAssertEqual(try Data(contentsOf: source), originalSource)
    }

    private func parse(packet: [UInt8]) throws -> [SubtitleFrame] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VOBSUBParser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let idx = try CoexistenceDVDFixture.writeFixture(packet: packet, directory: directory)
        return try VOBSUBParser.parse(idxURL: idx, subURL: directory.appendingPathComponent("fixture.sub"))
    }
}

private enum CoexistenceDVDFixture {
    static func fixture(padding: Int = 0) -> [UInt8] {
        // Even row: 1 red, 3 green, 12 blue, 70 white, then red to end-of-line.
        // Odd row: green to end-of-line. Exercises all four RLE code lengths.
        let pixels: [UInt8] = [0x4D, 0x32, 0x01, 0x1B, 0, 0, 0, 1]
            + [UInt8](repeating: 0, count: padding)
        let firstControl = 4 + pixels.count
        let stopControl = firstControl + 24
        let size = stopControl + 6
        return word(size) + word(firstControl) + pixels
            + word(45) + word(stopControl)
            + [0x01, 0x03, 0x32, 0x10, 0x04, 0xFF, 0xFF,
               0x05, 0, 0x01, 0x2B, 0, 0, 1,
               0x06, 0, 4, 0, 10, 0xFF]
            + word(135) + word(stopControl) + [0x02, 0xFF]
    }

    static func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

    static func writeFixture(packet: [UInt8], directory: URL) throws -> URL {
        let idx = directory.appendingPathComponent("fixture.idx")
        let sub = directory.appendingPathComponent("fixture.sub")
        try """
        # VobSub index file, v7 (do not modify this line!)
        size: 720x480
        palette: ff0000, 00ff00, 0000ff, ffffff, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000
        id: en, index: 0
        timestamp: 00:00:02:000, filepos: 000000000
        """.write(to: idx, atomically: true, encoding: .utf8)
        // A DVD pack followed by two PES packets carrying one fragmented subtitle.
        var ps: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8]
        for chunk in [Array(packet.prefix(7)), Array(packet.dropFirst(7))] {
            ps += [0, 0, 1, 0xBD] + word(chunk.count + 4) + [0x80, 0, 0, 0x20] + chunk
        }
        try Data(ps).write(to: sub)
        return idx
    }
}

private struct DVDExtractionOCREngine: BitmapSubtitleOCREngine {
    func recognize(pngURL: URL, language: String) async throws -> String {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: pngURL)))
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: 0, y: 0)
        XCTAssertEqual(pixel, [255, 255, 0, 255])
        return "Selected DVD track"
    }
}
