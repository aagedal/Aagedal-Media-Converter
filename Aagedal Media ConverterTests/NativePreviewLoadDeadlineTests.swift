import AVFoundation
import XCTest
@testable import Aagedal_Media_Converter

final class NativePreviewLoadDeadlineTests: XCTestCase {
    @MainActor
    func testSilentNativeLoadRetiresPlayerBeforeFallbackAndPreservesSelection() async throws {
        let (controller, item) = makeController()
        defer { controller.teardown() }
        let observerID = UUID()
        controller.playerItemStatusObserverID = observerID
        controller.selectedAudioTrackOrderIndex = 2
        var fallbackCount = 0
        controller.beginPlayerItemLoadDeadline(for: item, observerID: observerID, timeout: .zero) {
            fallbackCount += 1
            XCTAssertNil(controller.player)
            XCTAssertNil(controller.playerItemStatusObserverID)
            XCTAssertNil(controller.playerItemLoadDeadlineTask)
            XCTAssertFalse(controller.isReady)
            XCTAssertEqual(controller.selectedAudioTrackOrderIndex, 2)
        }
        let deadline = try XCTUnwrap(controller.playerItemLoadDeadlineTask)
        await deadline.value
        XCTAssertEqual(fallbackCount, 1)
    }

    @MainActor
    func testNativeReadinessCancelsLoadDeadline() async throws {
        let (controller, item) = makeController()
        defer { controller.teardown() }
        let observerID = UUID()
        controller.playerItemStatusObserverID = observerID
        controller.beginPlayerItemLoadDeadline(for: item, observerID: observerID, timeout: .seconds(30)) {
            XCTFail("Ready native player must not fall back")
        }
        let deadline = try XCTUnwrap(controller.playerItemLoadDeadlineTask)
        controller.prepareReadyPlayerItem(item, startTime: 0, verify: { true }, seek: { true })
        let preparation = try XCTUnwrap(controller.playerItemStatusTask)
        await deadline.value
        await preparation.value
        XCTAssertNil(controller.playerItemLoadDeadlineTask)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.player?.currentItem === item)
    }

    @MainActor
    func testReplacementAndDismissalCancelNativeDeadline() async throws {
        let (controller, item) = makeController()
        defer { controller.teardown() }
        let observerID = UUID()
        controller.playerItemStatusObserverID = observerID
        controller.beginPlayerItemLoadDeadline(for: item, observerID: observerID, timeout: .seconds(30)) {
            XCTFail("Retired native player must not fall back")
        }
        let deadline = try XCTUnwrap(controller.playerItemLoadDeadlineTask)
        controller.removePlayerItemStatusObserver()
        let replacement = AVPlayer()
        controller.player = replacement
        await deadline.value
        XCTAssertTrue(controller.player === replacement)
        XCTAssertNil(controller.playerItemLoadDeadlineTask)
        controller.playerItemStatusObserverID = UUID()
        controller.beginPlayerItemLoadDeadline(for: item, observerID: controller.playerItemStatusObserverID!, timeout: .seconds(30)) {
            XCTFail("Dismissed native player must not fall back")
        }
        let dismissedDeadline = try XCTUnwrap(controller.playerItemLoadDeadlineTask)
        controller.teardown()
        await dismissedDeadline.value
        XCTAssertNil(controller.playerItemLoadDeadlineTask)
    }

    @MainActor
    func testStaleNativeDeadlineCannotRetireReplacement() async throws {
        let (controller, item) = makeController()
        defer { controller.teardown() }
        let observerID = UUID()
        controller.playerItemStatusObserverID = observerID
        controller.beginPlayerItemLoadDeadline(for: item, observerID: observerID, timeout: .zero) {
            XCTFail("Stale deadline must not fall back")
        }
        let deadline = try XCTUnwrap(controller.playerItemLoadDeadlineTask)
        controller.playerItemStatusObserverID = UUID()
        let replacement = AVPlayer()
        controller.player = replacement
        controller.isReady = true
        await deadline.value
        XCTAssertTrue(controller.player === replacement)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    private func makeController() -> (PreviewPlayerController, AVPlayerItem) {
        let url = URL(fileURLWithPath: "/private/native-load-deadline.mov")
        let video = VideoItem(url: url, name: "Preview", size: 0, duration: "00:00:01",
                              status: .waiting, progress: 0, eta: nil, outputURL: nil)
        let controller = PreviewPlayerController(videoItem: video)
        let item = AVPlayerItem(url: url)
        controller.player = AVPlayer(playerItem: item)
        return (controller, item)
    }
}
