import XCTest
import SwiftUI
@testable import Aagedal_Media_Converter

@MainActor
final class DownloadDetailsLifecycleTests: XCTestCase {
    func testCancellationDiscardsMetadataAndAutoEncodeAfterDownloadHasCompleted() async {
        let gate = DownloadDetailsGate()
        let started = expectation(description: "Details probe started")
        let manager = DownloadManager { _ in await gate.wait(started: started) }
        var items = [makeItem()]
        let itemID = items[0].id
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        var encodedItems: [UUID] = []
        manager.onAutoEncode = { encodedItems.append($0) }

        let task = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: items[0].url, autoEncode: true)
        await fulfillment(of: [started], timeout: 2)
        manager.cancelDownload(itemID: itemID)
        await task.value
        await gate.finish(size: 999)

        XCTAssertEqual(items[0].status, .cancelled)
        XCTAssertEqual(items[0].size, 0)
        XCTAssertFalse(items[0].detailsLoaded)
        XCTAssertTrue(encodedItems.isEmpty)
    }

    func testReplacementAtSameURLPublishesOnlyNewMetadataAndAutoEncode() async {
        let oldGate = DownloadDetailsGate()
        let newGate = DownloadDetailsGate()
        let oldStarted = expectation(description: "Old details probe started")
        let newStarted = expectation(description: "New details probe started")
        let sequencer = DownloadDetailsSequence(
            gates: [oldGate, newGate], expectations: [oldStarted, newStarted]
        )
        let manager = DownloadManager { _ in await sequencer.next() }
        var items = [makeItem()]
        let itemID = items[0].id
        let fileURL = items[0].url
        manager.videoItems = Binding(get: { items }, set: { items = $0 })
        var encodedItems: [UUID] = []
        manager.onAutoEncode = { encodedItems.append($0) }

        let oldTask = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: fileURL, autoEncode: true)
        await fulfillment(of: [oldStarted], timeout: 2)
        let newTask = manager.loadDownloadedFileDetails(itemID: itemID, fileURL: fileURL, autoEncode: true)
        await fulfillment(of: [newStarted], timeout: 2)
        await oldTask.value
        await oldGate.finish(size: 111)
        await newGate.finish(size: 222)
        await newTask.value

        XCTAssertEqual(items[0].size, 222)
        XCTAssertTrue(items[0].detailsLoaded)
        XCTAssertEqual(encodedItems, [itemID])
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/download.mov"), name: "download.mov", size: 0,
            duration: "", durationSeconds: 0, status: .waiting,
            progress: 0, eta: "", outputURL: nil
        )
    }
}

private actor DownloadDetailsSequence {
    let gates: [DownloadDetailsGate]
    let expectations: [XCTestExpectation]
    private var index = 0

    init(gates: [DownloadDetailsGate], expectations: [XCTestExpectation]) {
        self.gates = gates
        self.expectations = expectations
    }

    func next() async -> VideoFileUtils.VideoItemDetails {
        let nextIndex = index
        index += 1
        return await gates[nextIndex].wait(started: expectations[nextIndex])
    }
}

private actor DownloadDetailsGate {
    private var continuation: CheckedContinuation<VideoFileUtils.VideoItemDetails, Never>?

    func wait(started: XCTestExpectation) async -> VideoFileUtils.VideoItemDetails {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(size: Int64) {
        continuation?.resume(returning: VideoFileUtils.VideoItemDetails(
            size: size, duration: "00:00:01", durationSeconds: 1,
            thumbnailData: nil, outputURL: nil, hasVideoStream: true, metadata: nil
        ))
        continuation = nil
    }
}
