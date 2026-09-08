import Combine
import XCTest
@testable import Aagedal_Media_Converter

final class MPVPreviewObservationTests: XCTestCase {
    @MainActor
    private func makeController() -> PreviewPlayerController {
        PreviewPlayerController(videoItem: VideoItem(
            url: URL(fileURLWithPath: "/private/observation-test.mov"),
            name: "Preview", size: 0, duration: "00:00:01",
            status: .waiting, progress: 0, eta: nil, outputURL: nil
        ))
    }

    @MainActor
    func testCurrentMPVPublishesTimeReadinessCompletionAndTrackRefresh() async {
        let controller = makeController()
        defer { controller.teardown() }
        let time = PassthroughSubject<Double, Never>()
        let loaded = PassthroughSubject<Bool, Never>()
        let ended = PassthroughSubject<Bool, Never>()
        let positionUpdated = expectation(description: "Current position")
        let becameReady = expectation(description: "Current readiness")
        let completed = expectation(description: "Current completion")
        let tracksRefreshed = expectation(description: "Current tracks")
        var observations = Set<AnyCancellable>()
        controller.$currentPlaybackTime.filter { $0 == 12 }.prefix(1)
            .sink { _ in positionUpdated.fulfill() }.store(in: &observations)
        controller.$isReady.filter { $0 }.prefix(1)
            .sink { _ in becameReady.fulfill() }.store(in: &observations)
        controller.playbackDidFinish = { completed.fulfill() }
        controller.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: ended.eraseToAnyPublisher(), refreshDelay: .zero
        ) { tracksRefreshed.fulfill() }
        time.send(12)
        loaded.send(false)
        loaded.send(true)
        ended.send(false)
        ended.send(true)
        ended.send(true) // Duplicate EOF notifications must not advance twice.
        await fulfillment(of: [positionUpdated, becameReady, completed, tracksRefreshed], timeout: 1)
        XCTAssertNil(controller.mpvTrackRefreshTask)
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testReplacementRejectsQueuedOldCallbacksAndCancelsRefresh() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        let time = PassthroughSubject<Double, Never>()
        let loaded = PassthroughSubject<Bool, Never>()
        let ended = PassthroughSubject<Bool, Never>()
        let staleEvent = expectation(description: "Retired callback")
        staleEvent.isInverted = true
        var observations = Set<AnyCancellable>()
        controller.$currentPlaybackTime.filter { $0 == 99 }
            .sink { _ in staleEvent.fulfill() }.store(in: &observations)
        controller.$isReady.filter { $0 }
            .sink { _ in staleEvent.fulfill() }.store(in: &observations)
        controller.playbackDidFinish = { staleEvent.fulfill() }
        controller.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: ended.eraseToAnyPublisher(), refreshDelay: .seconds(60)
        ) { staleEvent.fulfill() }
        let retiredRefresh = try XCTUnwrap(controller.mpvTrackRefreshTask)
        // All callbacks enqueue actor work, but replacement runs before we suspend.
        time.send(99)
        loaded.send(true)
        ended.send(true)
        controller.installMPVObservers(
            timePosition: Empty(completeImmediately: false).eraseToAnyPublisher(),
            fileLoaded: Empty(completeImmediately: false).eraseToAnyPublisher(),
            reachedEnd: Empty(completeImmediately: false).eraseToAnyPublisher(),
            refreshDelay: .seconds(60)
        ) {}
        let replacementID = controller.mpvObservationID
        let replacementRefresh = try XCTUnwrap(controller.mpvTrackRefreshTask)
        await retiredRefresh.value
        XCTAssertTrue(retiredRefresh.isCancelled)
        XCTAssertFalse(replacementRefresh.isCancelled)
        XCTAssertEqual(controller.mpvObservationID, replacementID)
        time.send(99)
        ended.send(false)
        ended.send(true)
        await fulfillment(of: [staleEvent], timeout: 0.1)
        XCTAssertEqual(controller.currentPlaybackTime, 0)
        XCTAssertFalse(controller.isReady)
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testTeardownCancelsAllMPVSubscriptionsAndPendingRefresh() async throws {
        let controller = makeController()
        let time = PassthroughSubject<Double, Never>()
        let loaded = PassthroughSubject<Bool, Never>()
        let ended = PassthroughSubject<Bool, Never>()
        let cancelled = expectation(description: "All subscriptions cancelled")
        cancelled.expectedFulfillmentCount = 3
        let staleRefresh = expectation(description: "Retired refresh")
        staleRefresh.isInverted = true
        controller.installMPVObservers(
            timePosition: time.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            fileLoaded: loaded.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            reachedEnd: ended.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            refreshDelay: .seconds(60)
        ) { staleRefresh.fulfill() }
        let refresh = try XCTUnwrap(controller.mpvTrackRefreshTask)
        controller.teardown()
        await refresh.value
        await fulfillment(of: [cancelled, staleRefresh], timeout: 0.1)
        XCTAssertTrue(refresh.isCancelled)
        XCTAssertNil(controller.mpvObservationID)
        XCTAssertNil(controller.mpvTrackRefreshTask)
        XCTAssertTrue(controller.mpvObservers.isEmpty)
    }

    @MainActor
    func testNonCompletingMPVPublishersDoNotRetainController() {
        let time = CurrentValueSubject<Double, Never>(0)
        let loaded = CurrentValueSubject<Bool, Never>(false)
        let ended = CurrentValueSubject<Bool, Never>(false)
        var controller: PreviewPlayerController? = makeController()
        weak var weakController = controller
        controller?.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: ended.eraseToAnyPublisher(), refreshDelay: .seconds(60)
        ) {}
        let refresh = controller?.mpvTrackRefreshTask
        defer { refresh?.cancel() }
        controller = nil
        XCTAssertNil(weakController)
    }
}
