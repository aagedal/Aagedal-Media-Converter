import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionUploadFollowUpTests: XCTestCase {
    func testIndividualUploadRequiresSuccessAndOptIn() {
        let enabled = item(uploadEnabled: true)
        let disabled = item(uploadEnabled: false)
        XCTAssertEqual(ConversionUploadFollowUp.itemID(afterSuccess: true, item: enabled), enabled.id)
        XCTAssertNil(ConversionUploadFollowUp.itemID(afterSuccess: false, item: enabled))
        XCTAssertNil(ConversionUploadFollowUp.itemID(afterSuccess: true, item: disabled))
        XCTAssertNil(ConversionUploadFollowUp.itemID(afterSuccess: false, item: disabled))
    }

    func testMergeUsesFirstEnabledItemInMergeOrder() {
        let items = [item(uploadEnabled: true), item(uploadEnabled: false), item(uploadEnabled: true)]
        XCTAssertEqual(ConversionUploadFollowUp.itemID(
            afterSuccess: true, mergedIndices: [1, 2, 0], items: items
        ), items[2].id)
    }

    func testMergeExcludesOptedInItemsOutsideSelection() {
        let items = [item(uploadEnabled: true), item(uploadEnabled: false)]
        XCTAssertNil(ConversionUploadFollowUp.itemID(
            afterSuccess: true, mergedIndices: [1], items: items
        ))
    }

    func testFailedOrEmptyMergeDoesNotUpload() {
        let items = [item(uploadEnabled: true)]
        XCTAssertNil(ConversionUploadFollowUp.itemID(
            afterSuccess: false, mergedIndices: [0], items: items
        ))
        XCTAssertNil(ConversionUploadFollowUp.itemID(
            afterSuccess: true, mergedIndices: [], items: items
        ))
        XCTAssertNil(ConversionUploadFollowUp.itemID(
            afterSuccess: true, mergedIndices: [0], items: []
        ))
    }

    func testMergeSkipsIndicesThatNoLongerExist() {
        let items = [item(uploadEnabled: false), item(uploadEnabled: true)]
        XCTAssertEqual(ConversionUploadFollowUp.itemID(
            afterSuccess: true, mergedIndices: [-1, 5, 0, 1], items: items
        ), items[1].id)
    }

    private func item(uploadEnabled: Bool) -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/clip.mov"), name: "clip.mov", size: 0,
            duration: "00:01:40", durationSeconds: 100, status: .done,
            progress: 1, eta: nil, outputURL: URL(fileURLWithPath: "/fixture/output.mp4")
        )
        item.uploadEnabled = uploadEnabled
        return item
    }
}
