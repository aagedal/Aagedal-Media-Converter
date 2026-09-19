import Foundation
import SwiftUI
import os
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionQueueStateTests: XCTestCase {
    @MainActor
    func testTerminatingOldProgressSubscriptionPreservesReplacement() async {
        let manager = ConversionManager()
        let firstStream = await manager.progressUpdates()
        let firstSubscriber = Task {
            for await _ in firstStream { }
        }
        let replacementStream = await manager.progressUpdates()
        firstSubscriber.cancel()
        await firstSubscriber.value

        let received = expectation(description: "Replacement receives cancellation progress")
        let replacementSubscriber = Task {
            for await value in replacementStream {
                XCTAssertEqual(value, 0)
                received.fulfill()
                break
            }
        }
        await manager.cancelAllConversions()
        await fulfillment(of: [received], timeout: 2)
        replacementSubscriber.cancel()
        await replacementSubscriber.value
    }

    func testMergeCallbacksFollowSourcesAfterRowsAreRemovedAndReordered() {
        let first = item(status: .converting)
        let removed = item(status: .converting)
        let last = item(status: .converting)
        let unrelated = item(status: .converting)
        var items = [last, unrelated, first]

        ConversionQueueState.applyProgress(
            0.75, message: "00:00:05", isDuration: true,
            for: [first, removed, last], ownership: ConversionCallbackOwnership(), in: &items
        )

        XCTAssertEqual(ConversionQueueState.callbackIndices(for: [first, removed, last], in: items), [2, 0])
        XCTAssertEqual(items[0].progress, 0.75)
        XCTAssertEqual(items[2].eta, "00:00:05")
        XCTAssertNil(items[0].statusMessage)
        XCTAssertEqual(items[1], unrelated)
    }

    func testCallbacksDiscardReplacedCancelledAndFinishedSources() {
        let selected = item(status: .converting)
        var replaced = selected
        replaced.url = URL(fileURLWithPath: "/fixture/replacement.mov")
        var variants = [replaced]
        for status in [ConversionManager.ConversionStatus.waiting, .cancelled, .done, .failed] {
            var changed = selected
            changed.status = status
            variants.append(changed)
        }
        for variant in variants {
            var items = [variant]
            ConversionQueueState.applyProgress(
                0.9, message: "Muxing", isDuration: false,
                for: [selected], ownership: ConversionCallbackOwnership(), in: &items
            )
            XCTAssertEqual(items, [variant])
            XCTAssertTrue(ConversionQueueState.callbackIndices(for: [selected], in: items).isEmpty)
        }
    }

    func testOldBatchProgressCannotAffectRestartedItemWithSameIdentity() {
        let selected = item(status: .converting)
        let oldBatch = ConversionCallbackOwnership()
        oldBatch.invalidate()
        var items = [selected]
        ConversionQueueState.applyProgress(
            1, message: "Old completion", isDuration: false,
            for: [selected], ownership: oldBatch, in: &items
        )
        XCTAssertEqual(items, [selected])

        ConversionQueueState.applyProgress(
            0.1, message: "New encode", isDuration: false,
            for: [selected], ownership: ConversionCallbackOwnership(), in: &items
        )
        XCTAssertEqual(items[0].progress, 0.1)
        XCTAssertEqual(items[0].statusMessage, "New encode")
    }

    @MainActor
    func testCancellingItemDuringManagerPreparationDoesNotStartEncoding() async {
        let gate = ConversionPreparationDetailsGate()
        let started = expectation(description: "Conversion details started")
        let manager = ConversionManager(conversionDetailsLoader: { _, _, _ in
            await gate.wait(started: started)
        })
        let queue = ConversionPreparationQueue(items: [item(status: .waiting)])
        let selectedID = queue.items[0].id
        let binding = queue.binding
        let task = Task {
            await manager.startConversion(droppedFiles: binding, outputFolder: "/fixture", preset: .h264)
        }
        await fulfillment(of: [started], timeout: 2)
        await manager.cancelItem(with: selectedID)
        let cancelled = queue.items
        await gate.finish()
        await task.value

        XCTAssertEqual(queue.items, cancelled)
        XCTAssertEqual(queue.items[0].status, .cancelled)
        XCTAssertFalse(queue.items[0].detailsLoaded)
    }

    @MainActor
    func testLegacyCancellationWhileWaitingForApplicationJobDoesNotStartEncoding() async throws {
        let executionGate = ApplicationConversionExecutionGate()
        let applicationID = await executionGate.acquire()
        let manager = ConversionManager(
            executionGate: executionGate,
            conversionDetailsLoader: { _, _, _ in
                XCTFail("Cancelled legacy work reached conversion preparation")
                return VideoFileUtils.VideoItemDetails(
                    size: 1234, duration: "00:00:07", durationSeconds: 7,
                    thumbnailData: nil, outputURL: nil, hasVideoStream: true, metadata: nil
                )
            }
        )
        let queue = ConversionPreparationQueue(items: [item(status: .waiting)])
        let task = Task {
            await manager.startConversion(
                droppedFiles: queue.binding,
                outputFolder: "/fixture",
                preset: .h264
            )
        }
        for _ in 0..<100 {
            if await executionGate.waitingCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitingCount = await executionGate.waitingCount()
        XCTAssertEqual(waitingCount, 1)

        // The row remains waiting because this cancellation targets active work.
        // The queued request must still be fenced when its gate turn arrives.
        await manager.cancelConversion()
        await executionGate.release(applicationID)
        await task.value
        XCTAssertEqual(queue.items[0].status, .waiting)
        XCTAssertFalse(queue.items[0].detailsLoaded)
    }

    @MainActor
    func testCancellingLegacyGroupReleasesWaitingAgentJob() async throws {
        try await checkGroupAndAgentCancellation(cancelAgentFirst: false)
    }

    @MainActor
    func testCancellingWaitingAgentJobPreservesLegacyGroup() async throws {
        try await checkGroupAndAgentCancellation(cancelAgentFirst: true)
    }

    @MainActor
    private func checkGroupAndAgentCancellation(cancelAgentFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroupAgentCoexistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("agent.mov")
        try Data("fixture".utf8).write(to: source)
        let executionGate = ApplicationConversionExecutionGate()
        let detailsGate = ConversionPreparationDetailsGate()
        let preparing = expectation(description: "Legacy group owns execution during preparation")
        let manager = ConversionManager(
            executionGate: executionGate,
            conversionDetailsLoader: { _, _, _ in await detailsGate.wait(started: preparing) }
        )
        let queue = ConversionPreparationQueue(items: [item(status: .waiting)])
        let legacyTask = Task {
            await manager.convertGroup(
                items: queue.binding, outputFolder: directory.path, preset: .h264,
                concatEnabled: false, transcriptionEnabled: false,
                uploadEnabled: false, analyticsEnabled: false
            )
        }
        await fulfillment(of: [preparing], timeout: 2)
        let executed = expectation(description: "Agent executes after legacy cancellation")
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { _, plan, _ in
                    XCTAssertTrue(queue.items.allSatisfy { $0.status == .cancelled })
                    executed.fulfill()
                    return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
                },
                cancel: { _ in XCTFail("Queued agent cancellation must not signal an executor") }
            ),
            executionGate: executionGate
        )
        let plan = try await service.plan(ApplicationConversionRequest(
            origin: .localAgent, requesterID: "group-coexistence",
            sourceURLs: [source], destinationFolderURL: directory, presetID: .h264
        ))
        let accepted = try await service.submit(planID: plan.id)
        for _ in 0..<200 {
            if await executionGate.waitingCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await executionGate.waitingCount()
        XCTAssertEqual(waiting, 1)
        let queued = try await service.record(for: accepted.record.id)
        XCTAssertEqual(queued?.state, .queued)

        if cancelAgentFirst {
            let before = queue.items
            let cancelled = try await service.requestCancellation(accepted.record.id)
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(queue.items, before, "Agent cancellation must preserve legacy rows")
            let stillWaiting = await executionGate.waitingCount()
            XCTAssertEqual(stillWaiting, 1, "Agent cancellation must preserve legacy ownership")
        }
        await manager.cancelAllConversions()
        await detailsGate.finish()
        await legacyTask.value
        XCTAssertTrue(queue.items.allSatisfy { $0.status == .cancelled })
        XCTAssertFalse(queue.items[0].detailsLoaded, "Late preparation cannot revive cancelled rows")

        if cancelAgentFirst {
            // A subsequent job proves the cancelled gate waiter was drained and
            // did not stall the service or consume a later job's cancellation.
            let replacement = try await service.plan(ApplicationConversionRequest(
                origin: .localAgent, requesterID: "group-coexistence",
                sourceURLs: [source], destinationFolderURL: directory, presetID: .h264
            ))
            _ = try await service.submit(planID: replacement.id)
        }
        await fulfillment(of: [executed], timeout: 2)
        for _ in 0..<200 {
            let records = try await service.allRecords()
            if records.allSatisfy({ $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let records = try await service.allRecords()
        XCTAssertEqual(records.filter { $0.state == .succeeded }.count, 1)
        XCTAssertEqual(records.filter { $0.state == .cancelled }.count, cancelAgentFirst ? 1 : 0)
    }

    @MainActor
    func testLiveMergedEncodingCancellationDrainsBeforeWaitingAgentStarts() async throws {
        try await checkLiveEncodingCancellation(merge: true, cancelAgentFirst: false)
    }

    @MainActor
    func testLiveGroupEncodingCancellationDrainsBeforeWaitingAgentStarts() async throws {
        try await checkLiveEncodingCancellation(merge: false, cancelAgentFirst: false)
    }

    @MainActor
    func testCancellingWaitingAgentPreservesLiveMergedEncoding() async throws {
        try await checkLiveEncodingCancellation(merge: true, cancelAgentFirst: true)
    }

    @MainActor
    private func checkLiveEncodingCancellation(merge: Bool, cancelAgentFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncodingCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let first = directory.appendingPathComponent("first.mov")
        let second = directory.appendingPathComponent("second.mov")
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=64x48:rate=24:duration=20",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", first.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded)
        try FileManager.default.copyItem(at: first, to: second)
        let sourceBytes = try Data(contentsOf: first)
        let suite = "EncodingCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppConstants.exportStitchMarkersKey)
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        let settings = ConversionPreparationSettings(preset: .h264, defaults: defaults)
        let encoding = expectation(description: "Real FFmpeg emitted encoded frame progress")
        let terminated = expectation(description: "Cancelled FFmpeg terminated before runner drain")
        let runner = QueueLiveEncodingRunner(encoding: encoding, terminated: terminated)
        let executionGate = ApplicationConversionExecutionGate()
        let manager = ConversionManager(
            ffmpegConverter: FFMPEGConverter(subprocessRunner: runner),
            executionGate: executionGate,
            preparationSettingsProvider: { _ in settings }
        )
        let queue = ConversionPreparationQueue(items: [first, second].map { source in
            var value = item(status: .waiting, duration: 20, progress: 0)
            value.url = source
            value.name = source.lastPathComponent
            value.includeDateTag = false
            return value
        })
        let legacyTask = Task {
            await manager.convertGroup(
                items: queue.binding, outputFolder: directory.path, preset: .h264,
                concatEnabled: merge, groupName: "merged",
                transcriptionEnabled: false, uploadEnabled: false, analyticsEnabled: false
            )
        }
        await fulfillment(of: [encoding], timeout: 15)
        XCTAssertEqual(queue.items.filter { $0.status == .converting }.count, merge ? 2 : 1)
        let agentStarted = OSAllocatedUnfairLock(initialState: false)
        let adapter = ApplicationFFmpegJobExecutor(runner: .live())
        let executor = adapter.jobExecutor
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(execute: { jobID, plan, progress in
                agentStarted.withLock { $0 = true }
                XCTAssertTrue(queue.items.allSatisfy { $0.status == .cancelled })
                return await executor.execute(jobID, plan, progress)
            }, cancel: executor.cancel),
            executionGate: executionGate
        )
        let request = ApplicationConversionRequest(
            origin: .localAgent, requesterID: "encoding-coexistence",
            sourceURLs: [first], destinationFolderURL: directory, presetID: .streamCopy
        )
        let plan = try await service.plan(request)
        let accepted = try await service.submit(planID: plan.id)
        for _ in 0..<200 {
            if await executionGate.waitingCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await executionGate.waitingCount()
        XCTAssertEqual(waiting, 1)
        if cancelAgentFirst {
            let cancelled = try await service.requestCancellation(accepted.record.id)
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(queue.items.filter { $0.status == .converting }.count, merge ? 2 : 1)
            let stopped = await runner.didTerminate
            XCTAssertFalse(stopped, "Cancelling a waiting agent must not stop the legacy encoder")
        }
        let cancellation = Task { await manager.cancelAllConversions() }
        await fulfillment(of: [terminated], timeout: 5)
        let encoderWasCancelled = await runner.wasCancelled
        XCTAssertTrue(encoderWasCancelled, "The real child must terminate through cancellation")
        XCTAssertFalse(agentStarted.withLock { $0 }, "Execution ownership must survive subprocess drain")
        let cancelledRows = queue.items
        XCTAssertTrue(cancelledRows.allSatisfy { $0.status == .cancelled })
        await runner.releaseDrain()
        await cancellation.value
        await legacyTask.value
        XCTAssertEqual(queue.items, cancelledRows, "Late encoding completion must not revive cancelled rows")
        var expectedJobID = accepted.record.id
        if cancelAgentFirst {
            let replacement = try await service.plan(request)
            expectedJobID = try await service.submit(planID: replacement.id).record.id
        }
        for _ in 0..<1000 {
            if try await service.record(for: expectedJobID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let record = try await service.record(for: expectedJobID)
        XCTAssertEqual(record?.state, .succeeded)
        XCTAssertTrue(agentStarted.withLock { $0 })
        XCTAssertEqual(queue.items, cancelledRows)
        XCTAssertEqual(try Data(contentsOf: first), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: second), sourceBytes)
        let output = try XCTUnwrap(record?.outputURLs.first)
        let metadata = try await ApplicationMediaInspector.live.inspect(output)
        XCTAssertEqual(try XCTUnwrap(metadata.durationSeconds), 20, accuracy: 1.0 / 24)
    }

    @MainActor
    func testAgentConversionPreservesLegacyAnalyticsPostAction() async throws {
        try await checkAnalyticsAndAgentCoexistence(cancelAgent: false)
    }

    @MainActor
    func testAgentCancellationPreservesLegacyAnalyticsPostAction() async throws {
        try await checkAnalyticsAndAgentCoexistence(cancelAgent: true)
    }

    @MainActor
    private func checkAnalyticsAndAgentCoexistence(cancelAgent: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyticsAgentCoexistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let source = directory.appendingPathComponent("source.mov")
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=64x48:rate=24:duration=20",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded)
        let sourceBytes = try Data(contentsOf: source)
        let suite = "AnalyticsAgentCoexistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        let settings = ConversionPreparationSettings(preset: .h264, defaults: defaults)
        let analyticsStarted = expectation(description: "Legacy post-action ran real PSNR helper")
        let analyticsRunner = QueueAnalyticsCompletionRunner(started: analyticsStarted)
        let analyticsService = AnalyticsService(subprocessRunner: analyticsRunner)
        do {
            let executionGate = ApplicationConversionExecutionGate()
            let manager = ConversionManager(
                executionGate: executionGate,
                analyticsSettings: QueueAnalyticsSettings(),
                analyticsService: analyticsService,
                preparationSettingsProvider: { _ in settings }
            )
            var legacy = item(status: .waiting, duration: 20, progress: 0)
            legacy.url = source
            legacy.name = source.lastPathComponent
            legacy.includeDateTag = false
            let queue = ConversionPreparationQueue(items: [legacy])
            await manager.convertGroup(
                items: queue.binding, outputFolder: directory.path, preset: .h264,
                concatEnabled: false, transcriptionEnabled: false,
                uploadEnabled: false, analyticsEnabled: true
            )
            await fulfillment(of: [analyticsStarted], timeout: 15)
            XCTAssertEqual(queue.items[0].status, .done)
            XCTAssertTrue(queue.items[0].analyticsStatus.isInProgress)
            let legacyOutput = try XCTUnwrap(queue.items[0].outputURL)
            let legacyBytes = try Data(contentsOf: legacyOutput)
            let analyticsOperationID = try XCTUnwrap(queue.items[0].analyticsOperationID)
            let agentEncoding = cancelAgent ? expectation(description: "Agent encoder started") : nil
            let agentTerminated = cancelAgent ? expectation(description: "Agent encoder terminated") : nil
            let pacedRunner: QueueLiveEncodingRunner?
            let converter: FFMPEGConverter
            if let agentEncoding, let agentTerminated {
                let runner = QueueLiveEncodingRunner(encoding: agentEncoding, terminated: agentTerminated)
                pacedRunner = runner
                converter = FFMPEGConverter(subprocessRunner: runner)
            } else {
                pacedRunner = nil
                converter = FFMPEGConverter()
            }
            let adapter = ApplicationFFmpegJobExecutor(runner: .live(converter: converter))
            let service = ApplicationJobService(
                fileAccessAuthorizer: .unrestricted,
                executor: adapter.jobExecutor,
                executionGate: executionGate
            )
            var acceptedJobID: ApplicationJobID?
            do {
                let plan = try await service.plan(ApplicationConversionRequest(
                    origin: .localAgent, requesterID: "analytics-coexistence",
                    sourceURLs: [source], destinationFolderURL: directory, presetID: .streamCopy
                ))
                let accepted = try await service.submit(planID: plan.id)
                acceptedJobID = accepted.record.id
                if let agentEncoding, let agentTerminated, let pacedRunner {
                    await fulfillment(of: [agentEncoding], timeout: 15)
                    let cancellation = Task { try await service.requestCancellation(accepted.record.id) }
                    await fulfillment(of: [agentTerminated], timeout: 5)
                    await pacedRunner.releaseDrain()
                    _ = try await cancellation.value
                }
                for _ in 0..<1500 {
                    if try await service.record(for: accepted.record.id)?.state.isTerminal == true { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let record = try await service.record(for: accepted.record.id)
                XCTAssertEqual(record?.state, cancelAgent ? .cancelled : .succeeded)
                XCTAssertEqual(queue.items[0].status, .done)
                XCTAssertEqual(queue.items[0].analyticsOperationID, analyticsOperationID)
                XCTAssertTrue(queue.items[0].analyticsStatus.isInProgress)
                XCTAssertNil(queue.items[0].analyticsResults)
                let agentOutputBytes = try record?.outputURLs.first.map { try Data(contentsOf: $0) }

                // Complete the already-running legacy post-action after the agent reaches
                // its terminal state. Its delayed callback must still own only its row.
                await analyticsRunner.releaseCompletion()
                for _ in 0..<500 {
                    if !queue.items[0].analyticsStatus.isInProgress { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(queue.items[0].analyticsStatus, .completed)
                XCTAssertNil(queue.items[0].analyticsOperationID)
                let metric = try XCTUnwrap(queue.items[0].analyticsResults?.metrics.first)
                XCTAssertEqual(metric.metric, .psnr)
                XCTAssertTrue(metric.overallScore.isFinite)
                XCTAssertGreaterThan(metric.overallScore, 0)
                let finalRecord = try await service.record(for: accepted.record.id)
                XCTAssertEqual(finalRecord?.state, record?.state)
                XCTAssertEqual(finalRecord?.outputURLs, record?.outputURLs)
                XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
                XCTAssertEqual(try Data(contentsOf: legacyOutput), legacyBytes)
                if let agentOutput = record?.outputURLs.first {
                    XCTAssertEqual(try Data(contentsOf: agentOutput), agentOutputBytes)
                    let metadata = try await ApplicationMediaInspector.live.inspect(agentOutput)
                    XCTAssertEqual(try XCTUnwrap(metadata.durationSeconds), 20, accuracy: 1.0 / 24)
                }
                let analyticsWasCancelled = await analyticsRunner.wasCancelled
                XCTAssertFalse(analyticsWasCancelled)
            } catch {
                // Release the artificial drain before cancellation joins the encoder.
                await pacedRunner?.releaseDrain()
                if let acceptedJobID {
                    _ = try? await service.requestCancellation(acceptedJobID)
                }
                await converter.cancelConversion()
                throw error
            }
        } catch {
            // An unwrap or file read failure must not strand a metric completion.
            await analyticsRunner.releaseCompletion()
            await analyticsService.cancelAnalysis()
            throw error
        }
    }

    @MainActor
    func testRemovingItemDuringManagerPreparationFinishesEmptyQueue() async {
        let gate = ConversionPreparationDetailsGate()
        let started = expectation(description: "Conversion details started")
        let manager = ConversionManager(conversionDetailsLoader: { _, _, _ in
            await gate.wait(started: started)
        })
        let queue = ConversionPreparationQueue(items: [item(status: .waiting)])
        let binding = queue.binding
        let task = Task {
            await manager.startConversion(droppedFiles: binding, outputFolder: "/fixture", preset: .h264)
        }
        await fulfillment(of: [started], timeout: 2)
        queue.items = []
        await gate.finish()
        await task.value

        XCTAssertTrue(queue.items.isEmpty)
    }

    func testPreparedItemFollowsIdentityAfterQueueReordering() throws {
        let selected = item(status: .waiting)
        let other = item(status: .waiting)
        var items = [other, selected]

        let index = try XCTUnwrap(ConversionQueueState.beginPreparedItem(
            selected, details: preparedDetails(), in: &items
        ))

        XCTAssertEqual(index, 1)
        XCTAssertEqual(items[0], other)
        XCTAssertEqual(items[1].id, selected.id)
        XCTAssertEqual(items[1].status, .converting)
        XCTAssertEqual(items[1].size, 1234)
        XCTAssertEqual(items[1].durationSeconds, 7)
        XCTAssertTrue(items[1].detailsLoaded)
        XCTAssertEqual(items[1].comment, selected.comment)
    }

    func testPreparedItemDiscardsResultsForRemovedOrReplacedSources() {
        let selected = item(status: .waiting)
        var replacement = selected
        replacement.url = URL(fileURLWithPath: "/fixture/replacement.mov")
        for initial in [[], [item(status: .waiting)], [replacement]] {
            var items = initial
            XCTAssertNil(ConversionQueueState.beginPreparedItem(
                selected, details: preparedDetails(), in: &items
            ))
            XCTAssertEqual(items, initial)
        }
    }

    func testPreparedItemCannotReviveCancelledOrFinishedWork() {
        let selected = item(status: .waiting)
        for status in [ConversionManager.ConversionStatus.cancelled, .done, .failed, .converting] {
            var changed = selected
            changed.status = status
            var items = [changed]
            XCTAssertNil(ConversionQueueState.beginPreparedItem(
                selected, details: preparedDetails(), in: &items
            ))
            XCTAssertEqual(items, [changed])
        }
    }

    func testPreparedItemPreservesDetailsCompletedByConcurrentImport() throws {
        let selected = item(status: .waiting)
        var updated = selected
        updated.detailsLoaded = true
        updated.size = 9999
        updated.outputFileNameOverride = "chosen-name.mov"
        var items = [updated]

        XCTAssertNotNil(ConversionQueueState.beginPreparedItem(
            selected, details: preparedDetails(), in: &items
        ))
        updated.status = .converting
        XCTAssertEqual(items, [updated])
    }

    private func preparedDetails() -> VideoFileUtils.VideoItemDetails {
        VideoFileUtils.VideoItemDetails(
            size: 1234, duration: "00:00:07", durationSeconds: 7,
            thumbnailData: nil, outputURL: nil, hasVideoStream: true, metadata: nil
        )
    }

    func testNextItemPreservesQueueOrderAndRespectsBatchSelection() {
        let done = item(status: .done)
        let first = item(status: .waiting)
        let cancelled = item(status: .cancelled)
        let second = item(status: .waiting)
        let items = [done, first, cancelled, second]

        XCTAssertEqual(ConversionQueueState.nextItem(in: items, allowedItemIDs: nil)?.id, first.id)
        XCTAssertEqual(ConversionQueueState.nextItem(
            in: items, allowedItemIDs: [done.id, cancelled.id, second.id]
        )?.id, second.id)
        XCTAssertNil(ConversionQueueState.nextItem(in: items, allowedItemIDs: []))
        XCTAssertNil(ConversionQueueState.nextItem(in: [done, cancelled], allowedItemIDs: nil))
    }

    func testLegacyQueueDoesNotClaimCancelOrCountSharedApplicationJobs() {
        var shared = item(status: .converting, duration: 1_000, progress: 0.9)
        shared.applicationJobID = ApplicationJobID()
        shared.applicationJobOrigin = .localAgent
        let manual = item(status: .waiting, duration: 100, progress: 0)

        XCTAssertEqual(
            ConversionQueueState.nextItem(in: [shared, manual], allowedItemIDs: nil)?.id,
            manual.id
        )
        XCTAssertEqual(
            ConversionQueueState.overallProgress(for: [shared, manual]),
            0,
            accuracy: 0.000001
        )

        let originalShared = shared
        var items = [shared, manual]
        ConversionQueueState.cancel(&items, scope: .waitingAndConverting)
        XCTAssertEqual(items[0], originalShared)
        XCTAssertEqual(items[1].status, .cancelled)
    }

    func testProgressUsesTrimmedDurationsAndExcludesUnsuccessfulItems() {
        var completed = item(status: .done, duration: 100, progress: 0)
        completed.trimStart = 10
        completed.trimEnd = 30
        var converting = item(status: .converting, duration: 200, progress: 0.25)
        converting.trimStart = 20
        converting.trimEnd = 100
        let waiting = item(status: .waiting, duration: 100, progress: 1)

        XCTAssertEqual(ConversionQueueState.overallProgress(for: [
            completed, converting, waiting,
            item(status: .failed, duration: 1000, progress: 1),
            item(status: .cancelled, duration: 1000, progress: 1)
        ]), 0.2, accuracy: 0.000001)
    }

    func testProgressHandlesEmptyAndZeroDurationQueuesAndClampsOutOfRangeUpdates() {
        XCTAssertEqual(ConversionQueueState.overallProgress(for: []), 0)
        XCTAssertEqual(ConversionQueueState.overallProgress(for: [item(status: .done, duration: 0)]), 0)
        XCTAssertEqual(ConversionQueueState.overallProgress(for: [item(status: .failed)]), 0)
        XCTAssertEqual(ConversionQueueState.overallProgress(for: [item(status: .converting, progress: 2)]), 1)
        XCTAssertEqual(ConversionQueueState.overallProgress(for: [item(status: .converting, progress: -1)]), 0)
    }

    func testStoppingCurrentConversionLeavesWaitingAndTerminalItemsUnchanged() {
        var items = [item(status: .waiting), item(status: .converting), item(status: .done),
                     item(status: .failed), item(status: .cancelled)]
        let original = items
        ConversionQueueState.cancel(&items, scope: .converting)

        assertCancelled(items[1], preservingSettingsFrom: original[1])
        for index in [0, 2, 3, 4] {
            XCTAssertEqual(items[index], original[index])
        }
    }

    func testCancellingAllResetsPendingWorkAndPreservesTerminalItems() {
        var items = [item(status: .waiting), item(status: .converting), item(status: .done),
                     item(status: .failed), item(status: .cancelled)]
        let original = items
        ConversionQueueState.cancel(&items, scope: .waitingAndConverting)

        for index in [0, 1] {
            assertCancelled(items[index], preservingSettingsFrom: original[index])
        }
        for index in [2, 3, 4] {
            XCTAssertEqual(items[index], original[index])
        }
        let cancelled = items
        ConversionQueueState.cancel(&items, scope: .waitingAndConverting)
        XCTAssertEqual(items, cancelled)
    }

    private func item(
        status: ConversionManager.ConversionStatus,
        duration: Double = 100,
        progress: Double = 0.5
    ) -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/clip.mov"), name: "clip.mov", size: 0,
            duration: "00:01:40", durationSeconds: duration, status: status,
            progress: progress, eta: "00:00:50", outputURL: nil
        )
        item.statusMessage = "Encoding"
        item.comment = "Preserve this metadata"
        item.conversionError = "Previous diagnostic"
        return item
    }

    private func assertCancelled(
        _ item: VideoItem,
        preservingSettingsFrom original: VideoItem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expected = original
        expected.status = .cancelled
        expected.progress = 0
        expected.eta = nil
        expected.statusMessage = nil
        XCTAssertEqual(item, expected, file: file, line: line)
        XCTAssertNil(item.eta, file: file, line: line)
        XCTAssertNil(item.statusMessage, file: file, line: line)
        XCTAssertEqual(item.comment, original.comment, file: file, line: line)
        XCTAssertEqual(item.conversionError, original.conversionError, file: file, line: line)
    }
}

/// The manager is an actor and accesses queue bindings from its own executor.
/// Test bindings therefore use synchronized storage instead of MainActor closures.
private final class ConversionPreparationQueue: Sendable {
    private let storage: OSAllocatedUnfairLock<[VideoItem]>

    init(items: [VideoItem]) {
        storage = OSAllocatedUnfairLock(initialState: items)
    }

    var items: [VideoItem] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var binding: Binding<[VideoItem]> {
        Binding(get: { self.items }, set: { self.items = $0 })
    }
}

private actor ConversionPreparationDetailsGate {
    private var continuation: CheckedContinuation<VideoFileUtils.VideoItemDetails, Never>?

    func wait(started: XCTestExpectation) async -> VideoFileUtils.VideoItemDetails {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish() {
        continuation?.resume(returning: VideoFileUtils.VideoItemDetails(
            size: 1234, duration: "00:00:07", durationSeconds: 7,
            thumbnailData: nil, outputURL: nil, hasVideoStream: true, metadata: nil
        ))
        continuation = nil
    }
}

/// Runs the actual encoder at input speed, then holds cancellation drainage so
/// tests can inspect execution ownership before the converter acknowledges stop.
private actor QueueLiveEncodingRunner: SubprocessRunning {
    let encoding: XCTestExpectation
    let terminated: XCTestExpectation
    private(set) var didTerminate = false
    private(set) var wasCancelled = false
    private var drainReleased = false
    private var drainContinuation: CheckedContinuation<Void, Never>?

    init(encoding: XCTestExpectation, terminated: XCTestExpectation) {
        self.encoding = encoding
        self.terminated = terminated
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        var arguments = request.arguments
        if let input = arguments.firstIndex(of: "-i") {
            arguments.insert("-re", at: input)
        }
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
        let progress = OSAllocatedUnfairLock(initialState: (text: "", signalled: false))
        let encoding = self.encoding
        let result: Result<SubprocessResult, Error>
        do {
            result = .success(try await SubprocessRunner().run(paced) { chunk in
                outputHandler?(chunk)
                progress.withLock { state in
                    guard !state.signalled else { return }
                    state.text += String(decoding: chunk.data, as: UTF8.self)
                    if state.text.range(of: #"frame=\s*[1-9][0-9]*"#, options: .regularExpression) != nil {
                        state.signalled = true
                        encoding.fulfill()
                    }
                }
            })
        } catch {
            wasCancelled = error is CancellationError
            result = .failure(error)
        }
        didTerminate = true
        terminated.fulfill()
        if !drainReleased {
            await withCheckedContinuation { drainContinuation = $0 }
        }
        return try result.get()
    }

    func releaseDrain() {
        drainReleased = true
        drainContinuation?.resume()
        drainContinuation = nil
    }
}

private struct QueueAnalyticsSettings: AnalyticsSettingsProviding {
    func analyticsSnapshot() -> AnalyticsSettingsSnapshot {
        AnalyticsSettingsSnapshot(
            enabledMetrics: [.psnr], vmafModel: .vmaf_v0_6_1,
            ssimulacra2MaxFrames: 1,
            autoExport: AnalyticsAutoExportSettingsSnapshot(enabled: false, format: .json)
        )
    }
}

/// Runs the actual metric process, then holds its completion so a new agent
/// conversion can finish or cancel before the legacy post-action updates its row.
private actor QueueAnalyticsCompletionRunner: SubprocessRunning {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var wasCancelled = false

    init(started: XCTestExpectation) {
        self.started = started
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let result = try await SubprocessRunner().run(request, outputHandler: outputHandler)
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        wasCancelled = Task.isCancelled
        return result
    }

    func releaseCompletion() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
