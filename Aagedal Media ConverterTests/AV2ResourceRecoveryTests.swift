import Foundation
import XCTest
import os
@testable import Aagedal_Media_Converter

final class AV2ResourceRecoveryTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    func testMemoryBudgetAccountsForGeometryDepthAndPressure() {
        let normal = AV2MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib, pressure: .normal)
        let hd = normal.workerLimit(width: 1920, height: 1080, bitDepth: 8, planned: 16, running: 0)
        let uhd = normal.workerLimit(width: 3840, height: 2160, bitDepth: 10, planned: 16, running: 0)
        XCTAssertGreaterThan(hd, uhd)
        XCTAssertLessThan(uhd, 16)
        XCTAssertGreaterThan(AV2MemorySnapshot.estimatedWorkerBytes(width: 1920, height: 1080, bitDepth: 10),
                             AV2MemorySnapshot.estimatedWorkerBytes(width: 1920, height: 1080, bitDepth: 8))
        XCTAssertEqual(AV2MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib, pressure: .warning)
            .workerLimit(width: 128, height: 128, bitDepth: 8, planned: 8, running: 4), 1)
        XCTAssertEqual(AV2MemorySnapshot(physicalBytes: 16 * gib, availableBytes: 12 * gib, pressure: .critical)
            .workerLimit(width: 128, height: 128, bitDepth: 8, planned: 8, running: 0), 0)
        XCTAssertEqual(AV2MemorySnapshot(physicalBytes: 8 * gib, availableBytes: 0, pressure: .normal)
            .workerLimit(width: 3840, height: 2160, bitDepth: 10, planned: 8, running: 0), 1)
        XCTAssertGreaterThan(AV2MemoryMonitor.shared.snapshot().physicalBytes, 0)
    }

    func testRecoveryValidatesContentsAndSerializesLeases() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let plan = fixture.plan()
        try FileManager.default.createDirectory(at: plan.segmentDirectory, withIntermediateDirectories: true)
        try resourceIVF().write(to: plan.segments[0].outputURL)
        var store: AV2RecoveryStore? = try fixture.open(plan)
        let directory = try XCTUnwrap(store?.directory)
        try store?.store(plan.segments[0])
        XCTAssertNil(try fixture.open(plan), "Another writer must not adopt the same checkpoint")
        store = nil
        let retry = fixture.plan()
        try FileManager.default.createDirectory(at: retry.segmentDirectory, withIntermediateDirectories: true)
        store = try fixture.open(retry)
        XCTAssertEqual(store?.directory, directory, "Random scratch paths must not change recovery identity")
        XCTAssertTrue(try XCTUnwrap(store).restore(retry.segments[0]))
        XCTAssertEqual(try Data(contentsOf: retry.segments[0].outputURL), resourceIVF())
        try FileManager.default.removeItem(at: retry.segments[0].outputURL)
        var corrupt = resourceIVF()
        corrupt[44] ^= 1 // Structurally valid IVF, different payload: SHA-256 must reject it.
        try corrupt.write(to: directory.appendingPathComponent("chunk_0.ivf"))
        XCTAssertFalse(try XCTUnwrap(store).restore(retry.segments[0]))
        try resourceIVF().write(to: directory.appendingPathComponent("chunk_1.ivf"))
        XCTAssertFalse(try XCTUnwrap(store).restore(retry.segments[1]), "Uncommitted chunks must never be reused")
        try Data("modified source".utf8).write(to: fixture.source)
        XCTAssertThrowsError(try XCTUnwrap(store).validateSource())
        XCTAssertThrowsError(try XCTUnwrap(store).restore(retry.segments[0]))
        store = nil
    }

    func testRecoveryIdentityChangesWithSourceSettingsAndToolBuild() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        var store: AV2RecoveryStore? = try fixture.open(fixture.plan())
        let first = try XCTUnwrap(store?.directory)
        store = nil
        let changed = fixture.plan(quality: 40)
        store = try fixture.open(changed)
        XCTAssertNotEqual(store?.directory, first)
        store = nil
        try Data("different encoder build".utf8).write(to: fixture.encoder)
        store = try fixture.open(fixture.plan())
        XCTAssertNotEqual(store?.directory, first)
        let toolChanged = store?.directory
        store = nil
        try Data("different source content".utf8).write(to: fixture.source)
        store = try fixture.open(fixture.plan())
        XCTAssertNotEqual(store?.directory, toolChanged)
        store = nil
    }

    func testRetryReusesOnlyCompletedChunksAfterWorkerFailure() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let firstRunner = ResourceRunner(failIndex: 1)
        let first = await fixture.converter(runner: firstRunner).runAV2ChunkedConversion(
            plan: fixture.plan(), outputFileURL: fixture.directory.appendingPathComponent("first.ivf"),
            ffmpegPath: fixture.ffmpeg.path, avmencPath: fixture.encoder.path, progressUpdate: { _, _ in })
        XCTAssertFalse(first.success)
        let firstLaunched = await firstRunner.launched
        XCTAssertEqual(firstLaunched, [0, 1])
        let runner = ResourceRunner()
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let retry = await fixture.converter(runner: runner).runAV2ChunkedConversion(
            plan: fixture.plan(), outputFileURL: fixture.directory.appendingPathComponent("retry.ivf"),
            ffmpegPath: fixture.ffmpeg.path, avmencPath: fixture.encoder.path,
            progressUpdate: { _, status in if status?.contains("Resumed 1") == true { resumed.withLock { $0 = true } } })
        XCTAssertTrue(retry.success, retry.errorReason ?? "")
        let launched = await runner.launched
        XCTAssertEqual(launched, [1, 2, 3])
        XCTAssertTrue(resumed.withLock { $0 })
        XCTAssertEqual(IVFHeaderParser.parse(url: fixture.directory.appendingPathComponent("retry.ivf"))?.frameCount, 8)
        let checkpoint = try XCTUnwrap(retry.recoveryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
        AV2RecoveryStore.discard(checkpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testCancellationRetainsCompletedChunksForRetry() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let held = expectation(description: "Second chunk running")
        let runner = ResourceRunner(holdIndices: [1], started: [1: held])
        let converter = fixture.converter(runner: runner)
        let run = Task { await converter.runAV2ChunkedConversion(
            plan: fixture.plan(), outputFileURL: fixture.directory.appendingPathComponent("cancelled.ivf"),
            ffmpegPath: fixture.ffmpeg.path, avmencPath: fixture.encoder.path, progressUpdate: { _, _ in }) }
        await fulfillment(of: [held], timeout: 5)
        await converter.cancelConversion()
        let cancelled = await run.value
        XCTAssertFalse(cancelled.success)
        let retryRunner = ResourceRunner()
        let retry = await fixture.converter(runner: retryRunner).runAV2ChunkedConversion(
            plan: fixture.plan(), outputFileURL: fixture.directory.appendingPathComponent("retry.ivf"),
            ffmpegPath: fixture.ffmpeg.path, avmencPath: fixture.encoder.path, progressUpdate: { _, _ in })
        XCTAssertTrue(retry.success, retry.errorReason ?? "")
        let launched = await retryRunner.launched
        XCTAssertEqual(launched, [1, 2, 3])
    }

    func testCriticalPressureWaitCanBeStoppedWithoutLaunchingAWorker() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let waiting = expectation(description: "Waiting for memory")
        waiting.assertForOverFulfill = false
        let runner = ResourceRunner()
        let converter = FFMPEGConverter(subprocessRunner: runner,
            av2MemorySnapshot: { AV2MemorySnapshot(physicalBytes: 8 * 1024 * 1024 * 1024,
                availableBytes: 8 * 1024 * 1024 * 1024, pressure: .critical) }, av2RecoveryRoot: { fixture.cache })
        let plan = fixture.plan()
        let run = Task { await converter.runAV2ChunkedConversion(plan: plan,
            outputFileURL: fixture.directory.appendingPathComponent("critical.ivf"), ffmpegPath: fixture.ffmpeg.path,
            avmencPath: fixture.encoder.path, progressUpdate: { _, status in
                if status?.contains("Waiting for memory") == true { waiting.fulfill() }
            }) }
        await fulfillment(of: [waiting], timeout: 5)
        await converter.cancelConversion()
        let result = await run.value
        XCTAssertFalse(result.success)
        let launched = await runner.launched
        XCTAssertTrue(launched.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.segmentDirectory.path))
    }

    func testWorkerPoolRespondsToPressureBetweenCompletedChunks() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let starts = (0..<4).map { expectation(description: "Chunk \($0) started") }
        let waiting = expectation(description: "Critical memory pause")
        waiting.assertForOverFulfill = false
        let pressure = OSAllocatedUnfairLock(initialState: AV2MemorySnapshot.Pressure.normal)
        let runner = ResourceRunner(holdIndices: Set(0..<4), started: Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($0.offset, $0.element) }))
        let converter = FFMPEGConverter(subprocessRunner: runner,
            av2MemorySnapshot: { AV2MemorySnapshot(physicalBytes: 5 * 1024 * 1024 * 1024 / 2,
                availableBytes: 5 * 1024 * 1024 * 1024 / 2, pressure: pressure.withLock { $0 }) },
            av2RecoveryRoot: { fixture.cache })
        let run = Task { await converter.runAV2ChunkedConversion(plan: fixture.plan(),
            outputFileURL: fixture.directory.appendingPathComponent("pressure.ivf"), ffmpegPath: fixture.ffmpeg.path,
            avmencPath: fixture.encoder.path, progressUpdate: { _, status in
                if status?.contains("Waiting for memory") == true { waiting.fulfill() }
            }) }
        await fulfillment(of: [starts[0], starts[1]], timeout: 5)
        pressure.withLock { $0 = .warning }
        await runner.release(0)
        try await Task.sleep(for: .milliseconds(50))
        let afterFirst = await runner.launched
        XCTAssertEqual(afterFirst.count, 2, "Warning pressure must let existing workers drain before admitting another")
        await runner.release(1)
        await fulfillment(of: [starts[2]], timeout: 5)
        pressure.withLock { $0 = .critical }
        await runner.release(2)
        await fulfillment(of: [waiting], timeout: 5)
        let paused = await runner.launched
        XCTAssertEqual(paused.count, 3)
        pressure.withLock { $0 = .normal }
        await fulfillment(of: [starts[3]], timeout: 5)
        await runner.release(3)
        let result = await run.value
        XCTAssertTrue(result.success, result.errorReason ?? "")
        let maximum = await runner.maximumActive
        XCTAssertEqual(maximum, 2)
    }

    func testBundledAV2RetrySkipsSavedEncodeAndStreamsDecodableMatroska() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let encoder = try XCTUnwrap(BinaryPathResolver.avmencPath)
        let decoder = try XCTUnwrap(BinaryPathResolver.avmdecPath)
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let source = fixture.directory.appendingPathComponent("real-source.mkv")
        let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-nostdin", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=2:d=1", "-c:v", "ffv1", source.path], timeout: .seconds(30)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        func plan() -> AV2CommandBuilder.AV2SegmentPlan {
            let scratch = fixture.directory.appendingPathComponent(UUID().uuidString)
            return .init(segments: (0..<2).map { index in
                let output = scratch.appendingPathComponent("seg_\(index).ivf")
                return .init(index: index,
                    ffmpegArguments: ["-nostdin", "-ss", String(Double(index) / 2), "-i", source.path,
                        "-frames:v", "1", "-an", "-pix_fmt", "yuv420p", "-f", "yuv4mpegpipe", "-strict", "-1", "pipe:1"],
                    avmencArguments: ["--ivf", "-w", "128", "-h", "128", "-b", "8", "--input-bit-depth=8", "--i420", "--fps=2/1",
                        "--end-usage=q", "--qp=110", "--cpu-used=9", "-t", "1", "--lag-in-frames=0", "--limit=1", "-o", output.path, "-"],
                    outputURL: output, frameCount: 1)
            }, segmentDirectory: scratch, outputWidth: 128, outputHeight: 128, bitDepth: 8,
               totalFrames: 2, effectiveDuration: 1, frameRate: 2, recoverySourceURL: source)
        }
        func converter(_ runner: RealResourceRunner) -> FFMPEGConverter {
            FFMPEGConverter(subprocessRunner: runner, av2MemorySnapshot: {
                AV2MemorySnapshot(physicalBytes: 8 * 1024 * 1024 * 1024, availableBytes: 8 * 1024 * 1024 * 1024, pressure: .warning)
            }, av2RecoveryRoot: { fixture.cache })
        }
        let firstRunner = RealResourceRunner(encoder: encoder, failSecond: true)
        let first = await converter(firstRunner).runAV2ChunkedConversion(plan: plan(),
            outputFileURL: fixture.directory.appendingPathComponent("failed.ivf"), ffmpegPath: ffmpeg,
            avmencPath: encoder, progressUpdate: { _, _ in })
        XCTAssertFalse(first.success)
        let retryRunner = RealResourceRunner(encoder: encoder, failSecond: false)
        let output = fixture.directory.appendingPathComponent("recovered.ivf")
        let retry = await converter(retryRunner).runAV2ChunkedConversion(plan: plan(), outputFileURL: output,
            ffmpegPath: ffmpeg, avmencPath: encoder, progressUpdate: { _, _ in })
        XCTAssertTrue(retry.success, retry.errorReason ?? "")
        XCTAssertEqual(retryRunner.consumers.withLock { $0 }, ["seg_1.ivf"])
        XCTAssertEqual(try IVFConcatenator.frameRecords(in: output).count, 2)
        let mkv = fixture.directory.appendingPathComponent("recovered.mkv")
        try MatroskaMuxer.write(to: mkv, video: .init(codecPrivate: nil, width: 128, height: 128, fpsNumerator: 2, fpsDenominator: 1),
            videoIVFURL: output, keyframeIndices: retry.keyframeIndices, audioTracks: [])
        let decoded = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: decoder),
            arguments: [mkv.path, "-o", fixture.directory.appendingPathComponent("decoded.y4m").path], timeout: .seconds(30)))
        XCTAssertTrue(decoded.succeeded, decoded.standardErrorText)
        let counted = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-nostdin", "-i", fixture.directory.appendingPathComponent("decoded.y4m").path,
                        "-map", "0:v:0", "-f", "framemd5", "-"], timeout: .seconds(30)))
        XCTAssertTrue(counted.succeeded, counted.standardErrorText)
        XCTAssertEqual(counted.standardOutputText.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.count, 2)
    }

    func testPruningNeverRemovesLeasedCheckpoint() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        var store: AV2RecoveryStore? = try fixture.open(fixture.plan())
        let directory = try XCTUnwrap(store?.directory)
        AV2RecoveryStore.prune(root: fixture.cache, now: .distantFuture, maximumBytes: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        store = nil
        AV2RecoveryStore.prune(root: fixture.cache, now: .distantFuture, maximumBytes: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStreamingMuxMatchesArrayMuxAndPreservesDestinationOnInvalidInput() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanup() }
        let ivf = fixture.directory.appendingPathComponent("video.ivf")
        try resourceIVF().write(to: ivf)
        let video = MatroskaMuxer.VideoTrackInfo(codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1)
        let audio = MatroskaMuxer.AudioTrack(info: .init(codecID: "A_OPUS", codecPrivate: nil,
            sampleRate: 48_000, channels: 1, codecDelayNs: 6_500_000),
            frames: [.init(data: Data([7]), durationSamples: 960, presentationTimestampMilliseconds: -7),
                     .init(data: Data([8]), durationSamples: 960, presentationTimestampMilliseconds: 13,
                           discardPaddingNanoseconds: 1_000_000)])
        let array = fixture.directory.appendingPathComponent("array.mkv")
        let streamed = fixture.directory.appendingPathComponent("streamed.mkv")
        try MatroskaMuxer.write(to: array, video: video, videoFrames: [
            .init(data: Data([1, 2]), isKeyframe: true), .init(data: Data([3, 4]), isKeyframe: false)], audioTracks: [audio])
        try MatroskaMuxer.write(to: streamed, video: video, videoIVFURL: ivf, keyframeIndices: [0], audioTracks: [audio])
        XCTAssertEqual(try Data(contentsOf: array), try Data(contentsOf: streamed))
        let original = try Data(contentsOf: streamed)
        try Data(resourceIVF().dropLast()).write(to: ivf)
        XCTAssertThrowsError(try MatroskaMuxer.write(to: streamed, video: video, videoIVFURL: ivf,
                                                   keyframeIndices: [0], audioTracks: []))
        XCTAssertEqual(try Data(contentsOf: streamed), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasSuffix(".partial") })
    }
}

private struct ResourceFixture: Sendable {
    let directory: URL
    var source: URL { directory.appendingPathComponent("source.mov") }
    var encoder: URL { directory.appendingPathComponent("avmenc") }
    var ffmpeg: URL { directory.appendingPathComponent("ffmpeg") }
    var cache: URL { directory.appendingPathComponent("recovery") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["source.mov", "avmenc", "ffmpeg"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func plan(quality: Int = 100) -> AV2CommandBuilder.AV2SegmentPlan {
        let scratch = directory.appendingPathComponent(UUID().uuidString)
        return .init(segments: (0..<4).map { index in
            let output = scratch.appendingPathComponent("seg_\(index).ivf")
            return .init(index: index, ffmpegArguments: ["-i", source.path],
                avmencArguments: ["--qp=\(quality)", "--limit=2", "-o", output.path, "-"], outputURL: output, frameCount: 2)
        }, segmentDirectory: scratch, outputWidth: 16, outputHeight: 16, bitDepth: 8,
           totalFrames: 8, effectiveDuration: 1.0 / 3, frameRate: 24, recoverySourceURL: source)
    }
    func open(_ plan: AV2CommandBuilder.AV2SegmentPlan) throws -> AV2RecoveryStore? {
        try AV2RecoveryStore.open(plan: plan, ffmpeg: ffmpeg, encoder: encoder, root: cache)
    }
    func converter(runner: ResourceRunner) -> FFMPEGConverter {
        FFMPEGConverter(subprocessRunner: runner,
            av2MemorySnapshot: { AV2MemorySnapshot(physicalBytes: 16 * 1024 * 1024 * 1024,
                availableBytes: 12 * 1024 * 1024 * 1024, pressure: .warning) }, av2RecoveryRoot: { cache })
    }
}

private actor ResourceRunner: SubprocessRunning {
    let failIndex: Int?
    let holdIndices: Set<Int>
    let started: [Int: XCTestExpectation]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var launched: [Int] = []
    private(set) var maximumActive = 0
    private var active = 0

    init(failIndex: Int? = nil, holdIndices: Set<Int> = [], started: [Int: XCTestExpectation] = [:]) {
        self.failIndex = failIndex
        self.holdIndices = holdIndices
        self.started = started
    }
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        guard request.executableURL.lastPathComponent == "avmenc" else { return resourceProcessResult() }
        let argument = try XCTUnwrap(request.arguments.firstIndex(of: "-o"))
        let url = URL(fileURLWithPath: request.arguments[argument + 1])
        let index = Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "seg_", with: ""))!
        launched.append(index)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdIndices.contains(index) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    continuations[index] = continuation
                    started[index]?.fulfill()
                }
            } onCancel: { Task { await self.release(index) } }
        } else { started[index]?.fulfill() }
        try Task.checkCancellation()
        if failIndex == index { return resourceProcessResult(status: 1) }
        try resourceIVF().write(to: url)
        return resourceProcessResult()
    }
    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
}

private func resourceProcessResult(status: Int32 = 0) -> SubprocessResult {
    .init(terminationStatus: status, termination: .exited, standardOutput: Data(), standardError: Data(),
          discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1))
}
private func resourceIVF() -> Data {
    var data = Data("DKIF".utf8)
    func append(_ value: UInt64, _ count: Int) { for i in 0..<count { data.append(UInt8((value >> (i * 8)) & 255)) } }
    append(0, 2); append(32, 2); data.append(Data("AV02".utf8))
    append(16, 2); append(16, 2); append(24, 4); append(1, 4); append(2, 4); append(0, 4)
    for i in 0..<2 { append(2, 4); append(UInt64(i), 8); data.append(contentsOf: [UInt8(i * 2 + 1), UInt8(i * 2 + 2)]) }
    return data
}

private final class RealResourceRunner: SubprocessRunning, Sendable {
    let consumers = OSAllocatedUnfairLock(initialState: [String]())
    private let encoder: String
    private let failSecond: Bool
    private let runner = SubprocessRunner()

    init(encoder: String, failSecond: Bool) { self.encoder = encoder; self.failSecond = failSecond }
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        try await runner.run(request, outputHandler: outputHandler)
    }
    func runWithStreamingStandardInput(_ request: SubprocessRequest, inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        if request.executableURL.path == encoder, let argument = request.arguments.firstIndex(of: "-o") {
            let name = URL(fileURLWithPath: request.arguments[argument + 1]).lastPathComponent
            consumers.withLock { $0.append(name) }
            if failSecond && name == "seg_1.ivf" { return resourceProcessResult(status: 1) }
        }
        return try await runner.runWithStreamingStandardInput(request, inputProducer: inputProducer, outputHandler: outputHandler)
    }
}
