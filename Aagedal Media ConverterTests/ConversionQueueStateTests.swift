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
