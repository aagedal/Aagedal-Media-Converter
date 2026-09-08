import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionFollowUpTests: XCTestCase {
    func testCompletedOutputRemainsEligibleWhenUnrelatedBatchEnds() {
        let item = completedItem()
        let ownership = ConversionCallbackOwnership()
        let followUp = ConversionFollowUp(item: item, ownership: ownership)
        let unrelatedBatch = ConversionCallbackOwnership()
        unrelatedBatch.invalidate()

        XCTAssertEqual(followUp.index(in: [item]), 0)
    }

    func testRetryCannotPublishOldResultsEvenWhenOutputPathIsReused() {
        var item = completedItem()
        let ownership = ConversionCallbackOwnership()
        let followUp = ConversionFollowUp(item: item, ownership: ownership)
        item.resetConversionState()
        XCTAssertNil(followUp.index(in: [item]))
        ownership.invalidate() // Starting this item's replacement conversion.
        item.status = .done
        XCTAssertNil(followUp.index(in: [item]))
    }

    func testRemovedReplacedAndRelocatedOutputsRejectFollowUp() {
        let item = completedItem()
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        XCTAssertNil(followUp.index(in: []))
        var changed = item
        changed.url = URL(fileURLWithPath: "/fixture/replacement.mov")
        XCTAssertNil(followUp.index(in: [changed]))
        changed = item
        changed.outputURL = URL(fileURLWithPath: "/fixture/new-output.mp4")
        XCTAssertNil(followUp.index(in: [changed]))
        XCTAssertEqual(followUp.index(in: [completedItem(), item]), 1)
    }

    func testRetainedOwnershipIdentifiesSubtitleRunAfterRowTokenIsCleared() {
        let item = completedItem()
        let ownership = ConversionCallbackOwnership()
        let followUp = ConversionFollowUp(item: item, ownership: ownership)
        var items = [item]
        followUp.reserveSubtitles(in: &items)
        let serviceOperationID = items[0].subtitleOperationID
        items[0].subtitleOperationID = nil
        items[0].resetConversionState()

        XCTAssertEqual(ownership.id, serviceOperationID)
        XCTAssertEqual(followUp.subtitleOperationID, serviceOperationID)
        XCTAssertFalse(followUp.canBeginSubtitles(in: items))
    }

    func testImmediateSubtitleCancellationPreventsDeferredRestart() {
        let item = completedItem()
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveSubtitles(in: &items)
        XCTAssertTrue(followUp.canBeginSubtitles(in: items))
        items[0].subtitleOperationID = nil
        items[0].subtitleStatus = .notQueued
        XCTAssertFalse(followUp.canBeginSubtitles(in: items))
    }

    func testNewSubtitleOperationCannotBeOverwrittenByDeferredOldOperation() {
        let item = completedItem()
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveSubtitles(in: &items)
        let replacement = UUID()
        items[0].subtitleOperationID = replacement
        XCTAssertFalse(followUp.canBeginSubtitles(in: items))
        XCTAssertEqual(items[0].subtitleOperationID, replacement)
    }

    func testCancelledAnalyticsCannotRestartOrPublishAndExportResults() {
        let item = completedItem()
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveAnalytics(in: &items)
        XCTAssertEqual(followUp.analyticsIndex(in: items), 0)
        items[0].analyticsStatus = .notQueued
        XCTAssertNil(followUp.analyticsIndex(in: items))
    }

    func testRetriedConversionRejectsInProgressAnalyticsCallbacks() {
        let item = completedItem()
        let ownership = ConversionCallbackOwnership()
        let followUp = ConversionFollowUp(item: item, ownership: ownership)
        var items = [item]
        followUp.reserveAnalytics(in: &items)
        ownership.invalidate()
        XCTAssertNil(followUp.analyticsIndex(in: items))
    }

    func testManualAnalyticsRetryRejectsOldProgressCompletionAndExport() {
        let item = completedItem()
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveAnalytics(in: &items)
        let replacementOperationID = UUID()
        items[0].analyticsOperationID = replacementOperationID
        items[0].analyticsStatus = .pending

        XCTAssertNil(followUp.analyticsIndex(in: items))
        XCTAssertEqual(items[0].analyticsOperationID, replacementOperationID)
    }

    func testAutomaticReservationPreservesRunningManualAnalytics() {
        var item = completedItem()
        let manualOperationID = UUID()
        item.analyticsOperationID = manualOperationID
        item.analyticsStatus = .pending
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveAnalytics(in: &items)

        XCTAssertEqual(items[0].analyticsOperationID, manualOperationID)
        XCTAssertNil(followUp.analyticsIndex(in: items))
    }

    func testFailedConversionCannotReservePostConversionWork() {
        var item = completedItem()
        item.status = .failed
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        var items = [item]
        followUp.reserveSubtitles(in: &items)
        followUp.reserveAnalytics(in: &items)
        XCTAssertNil(items[0].subtitleOperationID)
        XCTAssertFalse(items[0].analyticsStatus.isInProgress)
    }

    private func completedItem() -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/clip.mov"), name: "clip.mov", size: 0,
            duration: "00:00:10", durationSeconds: 10, status: .done,
            progress: 1, eta: nil, outputURL: URL(fileURLWithPath: "/fixture/output.mp4")
        )
        item.subtitleEnabled = true
        item.analyticsEnabled = true
        return item
    }
}
