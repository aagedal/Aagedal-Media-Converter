import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionQueueStateTests: XCTestCase {
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
