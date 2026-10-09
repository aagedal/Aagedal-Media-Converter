import Combine
import Libmpv
import XCTest
@testable import Aagedal_Media_Converter

final class MPVPreviewObservationTests: XCTestCase {
    @MainActor
    func testSilentDecoderTimesOutAndRejectsLateReadinessAndEOF() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        let loaded = PassthroughSubject<Bool, Never>()
        let ended = PassthroughSubject<Bool, Never>()
        controller.selectedAudioTrackOrderIndex = 2
        controller.playbackDidFinish = { XCTFail("Timed-out source must not complete") }
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(), reachedEnd: ended.eraseToAnyPublisher(),
            loadTimeout: .zero
        ) {}
        let deadline = try XCTUnwrap(controller.mpvLoadDeadlineTask)
        await deadline.value
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.mpvObservationID)
        XCTAssertNil(controller.mpvLoadDeadlineTask)
        XCTAssertEqual(controller.selectedAudioTrackOrderIndex, 2)
        loaded.send(true)
        ended.send(true)
        await Task.yield()
        XCTAssertFalse(controller.isReady)
    }

    @MainActor
    func testReadinessCancelsLoadDeadline() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        let loaded = PassthroughSubject<Bool, Never>()
        let ready = expectation(description: "Ready before deadline")
        let observation = controller.$isReady.filter { $0 }.prefix(1)
            .sink { _ in ready.fulfill() }
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(), reachedEnd: Empty().eraseToAnyPublisher(),
            loadTimeout: .seconds(60)
        ) {}
        let deadline = try XCTUnwrap(controller.mpvLoadDeadlineTask)
        loaded.send(true)
        await fulfillment(of: [ready], timeout: 1)
        await deadline.value
        XCTAssertTrue(deadline.isCancelled)
        XCTAssertNil(controller.mpvLoadDeadlineTask)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isReady)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testReplacementAndDismissalCancelPendingLoadDeadlines() async throws {
        let controller = makeController()
        for _ in 0..<2 {
            controller.installMPVObservers(
                timePosition: Empty().eraseToAnyPublisher(),
                fileLoaded: Empty().eraseToAnyPublisher(), reachedEnd: Empty().eraseToAnyPublisher(),
                loadTimeout: .zero
            ) {}
            let retiredDeadline = try XCTUnwrap(controller.mpvLoadDeadlineTask)
            controller.installMPVObservers(
                timePosition: Empty().eraseToAnyPublisher(),
                fileLoaded: Empty().eraseToAnyPublisher(), reachedEnd: Empty().eraseToAnyPublisher(),
                loadTimeout: .seconds(60)
            ) {}
            let replacementDeadline = try XCTUnwrap(controller.mpvLoadDeadlineTask)
            await retiredDeadline.value
            XCTAssertTrue(retiredDeadline.isCancelled)
            XCTAssertNil(controller.errorMessage)
            XCTAssertFalse(replacementDeadline.isCancelled)
            controller.teardown()
            await replacementDeadline.value
            XCTAssertTrue(replacementDeadline.isCancelled)
            XCTAssertNil(controller.errorMessage)
            XCTAssertNil(controller.mpvLoadDeadlineTask)
        }
    }

    @MainActor
    func testFailureRejectsQueuedReadinessTimeAndCompletion() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        let failure = PassthroughSubject<String?, Never>()
        let loaded = PassthroughSubject<Bool, Never>()
        let time = PassthroughSubject<Double, Never>()
        let ended = PassthroughSubject<Bool, Never>()
        let failed = expectation(description: "Failure shown")
        let observation = controller.$errorMessage.compactMap { $0 }.prefix(1)
            .sink { _ in failed.fulfill() }
        controller.isReady = true
        controller.isPreparing = true
        controller.selectedAudioTrackOrderIndex = 2
        controller.playbackDidFinish = { XCTFail("A failed clip must not complete") }
        controller.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(), fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: ended.eraseToAnyPublisher(), failure: failure.eraseToAnyPublisher(),
            refreshDelay: .seconds(60)
        ) { XCTFail("Failed decoder must not refresh tracks") }
        let refresh = try XCTUnwrap(controller.mpvTrackRefreshTask)
        failure.send("decoder failed")
        // Already enqueued actor callbacks must also be rejected after failure.
        loaded.send(true)
        time.send(99)
        ended.send(true)
        await fulfillment(of: [failed], timeout: 1)
        await refresh.value
        XCTAssertFalse(controller.isReady)
        XCTAssertFalse(controller.isPreparing)
        XCTAssertEqual(controller.currentPlaybackTime, 0)
        XCTAssertEqual(controller.selectedAudioTrackOrderIndex, 2)
        XCTAssertTrue(refresh.isCancelled)
        XCTAssertTrue(controller.mpvObservers.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testReplacementRejectsQueuedFailureAndRemainsPlayable() async {
        let controller = makeController()
        defer { controller.teardown() }
        let failure = PassthroughSubject<String?, Never>()
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(), fileLoaded: Empty().eraseToAnyPublisher(),
            reachedEnd: Empty().eraseToAnyPublisher(), failure: failure.eraseToAnyPublisher()
        ) {}
        failure.send("old source failed")
        let loaded = PassthroughSubject<Bool, Never>()
        let time = PassthroughSubject<Double, Never>()
        let ready = expectation(description: "Replacement ready")
        let moved = expectation(description: "Replacement clock")
        let completed = expectation(description: "Replacement EOF")
        var observations = Set<AnyCancellable>()
        controller.$isReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }.store(in: &observations)
        controller.$currentPlaybackTime.filter { $0 == 3 }.prefix(1)
            .sink { _ in moved.fulfill() }.store(in: &observations)
        let ended = PassthroughSubject<Bool, Never>()
        controller.playbackDidFinish = { completed.fulfill() }
        controller.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(), fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: ended.eraseToAnyPublisher()
        ) {}
        let replacementID = controller.mpvObservationID
        loaded.send(true)
        time.send(3)
        ended.send(true)
        await fulfillment(of: [ready, moved, completed], timeout: 1)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.mpvObservationID, replacementID)
        XCTAssertTrue(controller.isReady)
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testTeardownRejectsQueuedFailureAndClearsReadiness() async {
        let controller = makeController()
        let failure = PassthroughSubject<String?, Never>()
        let unexpected = expectation(description: "Retired failure")
        unexpected.isInverted = true
        let observation = controller.$errorMessage.compactMap { $0 }.sink { _ in unexpected.fulfill() }
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(), fileLoaded: Empty().eraseToAnyPublisher(),
            reachedEnd: Empty().eraseToAnyPublisher(), failure: failure.eraseToAnyPublisher()
        ) {}
        controller.isReady = true
        failure.send("retired source failed")
        controller.teardown()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.errorMessage)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testOnlyNaturalMPVEndCompletesClipAndNewLoadClearsFailure() {
        let player = MPVPlayer()
        for reason in [MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT] {
            player.reachedEnd = true
            player.isPlaying = true
            player.handleEndFile(reason: reason, errorCode: 0)
            XCTAssertFalse(player.reachedEnd)
            XCTAssertFalse(player.isPlaying)
            XCTAssertNil(player.error)
        }
        player.isFileLoaded = true
        player.handleEndFile(reason: MPV_END_FILE_REASON_ERROR, errorCode: MPV_ERROR_LOADING_FAILED.rawValue)
        XCTAssertNotNil(player.error)
        XCTAssertFalse(player.reachedEnd)
        XCTAssertFalse(player.isFileLoaded)
        player.handleEndFile(reason: MPV_END_FILE_REASON_EOF, errorCode: 0)
        XCTAssertFalse(player.reachedEnd, "A late EOF must not complete a failed source")
        // A pending load (before a view attaches) also starts a fresh error state.
        player.load(url: URL(fileURLWithPath: "/private/replacement.mkv"))
        XCTAssertNil(player.error)
        player.handleEndFile(reason: MPV_END_FILE_REASON_EOF, errorCode: 0)
        XCTAssertTrue(player.reachedEnd)
    }

    @MainActor
    func testMissingSourceReportsPreviewFailureWithoutCompletingClip() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        let failure = expectation(description: "Preview reports the real decoder failure")
        let completed = expectation(description: "A missing source is not a completed clip")
        completed.isInverted = true
        let observation = controller.$errorMessage.compactMap { $0 }.prefix(1)
            .sink { _ in failure.fulfill() }
        controller.playbackDidFinish = { completed.fulfill() }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mkv")
        controller.setupMPV(url: missingURL, startTime: 2)
        let mpv = try XCTUnwrap(controller.mpvPlayer)
        mpv.attachDrawable(MPVMetalLayer())
        await fulfillment(of: [failure], timeout: 10)
        await fulfillment(of: [completed], timeout: 0.1)
        XCTAssertNotNil(mpv.error, "Exercise a real libmpv load failure")
        XCTAssertFalse(controller.isReady)
        XCTAssertFalse(controller.isPreparing)
        XCTAssertNil(controller.mpvPlayer)
        XCTAssertNil(controller.mpvObservationID)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRapidSourceReplacementRejectsAllRetiredEventsAndReleasesTasks() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        var retiredTasks: [Task<Void, Never>] = []
        var cancellationCount = 0
        controller.playbackDidFinish = { XCTFail("Retired source must not advance playback") }
        for index in 0..<100 {
            let time = PassthroughSubject<Double, Never>()
            let loaded = PassthroughSubject<Bool, Never>()
            let ended = PassthroughSubject<Bool, Never>()
            let failure = PassthroughSubject<String?, Never>()
            controller.installMPVObservers(
                timePosition: time.handleEvents(receiveCancel: { cancellationCount += 1 }).eraseToAnyPublisher(),
                fileLoaded: loaded.eraseToAnyPublisher(), reachedEnd: ended.eraseToAnyPublisher(),
                failure: failure.eraseToAnyPublisher(), refreshDelay: .seconds(60),
                loadTimeout: .seconds(60)
            ) { XCTFail("Retired source must not refresh tracks") }
            retiredTasks.append(try XCTUnwrap(controller.mpvTrackRefreshTask))
            retiredTasks.append(try XCTUnwrap(controller.mpvLoadDeadlineTask))
            // Queue every kind of callback before replacement gets an actor turn.
            time.send(Double(index + 1))
            loaded.send(true)
            ended.send(true)
            failure.send("retired decoder failed")
        }
        let loaded = PassthroughSubject<Bool, Never>()
        let ready = expectation(description: "Final replacement ready")
        let observation = controller.$isReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(), fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: Empty().eraseToAnyPublisher(), refreshDelay: .seconds(60)
        ) {}
        loaded.send(true)
        await fulfillment(of: [ready], timeout: 3)
        for task in retiredTasks {
            await task.value
            XCTAssertTrue(task.isCancelled)
        }
        XCTAssertEqual(cancellationCount, 100)
        XCTAssertEqual(controller.currentPlaybackTime, 0)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isReady)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRepeatedRealDecoderFailureAndDismissalReleasePlayers() async throws {
        let controller = makeController()
        defer { controller.teardown() }
        for index in 0..<8 {
            let failure = expectation(description: "Decoder failure \(index)")
            let observation = controller.$errorMessage.compactMap { $0 }.prefix(1)
                .sink { _ in failure.fulfill() }
            controller.errorMessage = nil
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mkv")
            controller.setupMPV(url: missingURL, startTime: 0)
            weak var retiredPlayer = controller.mpvPlayer
            controller.mpvPlayer?.attachDrawable(MPVMetalLayer())
            await fulfillment(of: [failure], timeout: 10)
            controller.teardown()
            for _ in 0..<100 where retiredPlayer != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(retiredPlayer, "Failure/retry cycle must release its native player")
            XCTAssertNil(controller.mpvObservationID)
            XCTAssertNil(controller.mpvLoadDeadlineTask)
            XCTAssertNil(controller.mpvTrackRefreshTask)
            XCTAssertTrue(controller.mpvObservers.isEmpty)
            XCTAssertFalse(controller.isReady)
            controller.errorMessage = nil
            withExtendedLifetime(observation) {}
        }
    }

    @MainActor
    func testRepeatedCoreAudioPlaybackAndTeardown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-coreaudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.mkv")
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: ffmpeg)
        generator.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-c:a", "pcm_s16le", "-ac", "2", source.path,
        ]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)

        for cycle in 0..<4 {
            var player: MPVPlayer? = MPVPlayer()
            weak var retiredPlayer = player
            player?.attachDrawable(MPVMetalLayer())
            XCTAssertNil(player?.error, "MPV setup failed in cycle \(cycle)")
            player?.volume = 0
            player?.load(url: source, autostart: true)
            for _ in 0..<250 where !(player?.isFileLoaded == true && (player?.timePos ?? 0) > 0.1) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(player?.isFileLoaded == true, "Audio source did not load in cycle \(cycle)")
            XCTAssertGreaterThan(player?.timePos ?? 0, 0.1, "Audio clock did not advance in cycle \(cycle)")
            XCTAssertNil(player?.error, "Audio playback failed in cycle \(cycle)")
            guard let audioOutput = player?.currentAudioOutput else {
                throw XCTSkip("No system audio output was available to exercise CoreAudio")
            }
            XCTAssertEqual(audioOutput, "coreaudio", "Playback used an unexpected audio backend")
            player = nil
            for _ in 0..<100 where retiredPlayer != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(retiredPlayer, "CoreAudio player was retained after cycle \(cycle)")
        }
    }

    @MainActor
    func testSlowMPVLoadDefersTrackDiscoveryAndKeepsLoadingFeedback() async {
        let controller = makeController()
        defer { controller.teardown() }
        let loaded = PassthroughSubject<Bool, Never>()
        let refreshed = expectation(description: "Tracks discovered after readiness")
        var refreshCount = 0
        controller.isPreparing = true
        controller.installMPVObservers(
            timePosition: Empty().eraseToAnyPublisher(),
            fileLoaded: loaded.eraseToAnyPublisher(),
            reachedEnd: Empty().eraseToAnyPublisher(), refreshDelay: .zero
        ) {
            XCTAssertTrue(controller.isReady)
            refreshCount += 1
            refreshed.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(controller.isPreparing)
        XCTAssertFalse(controller.isReady)
        loaded.send(true)
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertFalse(controller.isPreparing)
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testMPVControlsBeforeReadinessDoNotReadThePlaybackCore() {
        let player = MPVPlayer()
        player.attachDrawable(MPVMetalLayer())
        player.rate = 2
        XCTAssertEqual(player.rate, 2)
        player.rate *= 2
        XCTAssertEqual(player.rate, 4)
        XCTAssertTrue(player.audioTrackNames.isEmpty)
        XCTAssertTrue(player.audioTrackIndexes.isEmpty)
        XCTAssertTrue(player.subtitleTrackNames.isEmpty)
        XCTAssertTrue(player.subtitleTrackIndexes.isEmpty)
        player.pause()
        player.volume = 25
        player.isMuted = true
    }

    @MainActor
    func testAsyncMPVLoadRejectsRepliesFromReplacedAndStoppedSources() {
        let player = MPVPlayer()
        player.load(url: URL(fileURLWithPath: "/private/first.mkv"))
        let firstGeneration = player.loadGeneration
        player.load(url: URL(fileURLWithPath: "/private/replacement.mkv"))
        let replacementGeneration = player.loadGeneration
        player.handleLoadCommandReply(generation: firstGeneration, errorCode: -1)
        XCTAssertNil(player.error)
        player.handleLoadCommandReply(generation: replacementGeneration, errorCode: 0)
        XCTAssertNil(player.error)
        player.handleLoadCommandReply(generation: replacementGeneration, errorCode: -1)
        XCTAssertNotNil(player.error)
        player.error = nil
        player.stop()
        player.handleLoadCommandReply(generation: replacementGeneration, errorCode: -1)
        XCTAssertNil(player.error)
    }

    @MainActor
    func testStoppingPendingMPVLoadDoesNotOpenItWhenDrawableArrives() async throws {
        let player = MPVPlayer()
        player.load(url: URL(fileURLWithPath: "/private/missing-\(UUID().uuidString).mkv"))
        player.stop()
        player.attachDrawable(MPVMetalLayer())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(player.error)
        XCTAssertFalse(player.isFileLoaded)
    }

    @MainActor
    func testRealMPVPausedScrubbingSettlesAtExactReleaseTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-scrubbing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone \"quoted\" \\slash.mkv")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath))
        generator.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=5",
            "-c:a", "pcm_s16le", source.path,
        ]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let player = MPVPlayer()
        player.attachDrawable(MPVMetalLayer())
        player.load(url: source, autostart: false)
        for _ in 0..<250 where !player.isFileLoaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.isFileLoaded)
        for index in 1...100 {
            player.seekForScrubbing(to: Double(index) / 30)
        }
        player.cancelPendingScrubSeeks()
        player.seek(to: 2.75)
        for _ in 0..<250 where abs(player.timePos - 2.75) > 0.03 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.timePos, 2.75, accuracy: 0.03)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.error)
    }

    @MainActor
    func testMPVScrubbingKeepsPointerPositionAndResumesClockUpdatesOnRelease() async {
        let controller = makeController()
        defer { controller.teardown() }
        let time = PassthroughSubject<Double, Never>()
        controller.installMPVObservers(
            timePosition: time.eraseToAnyPublisher(),
            fileLoaded: Empty().eraseToAnyPublisher(),
            reachedEnd: Empty().eraseToAnyPublisher()
        ) {}
        controller.beginScrubbing()
        controller.seekTo(20.75)
        time.send(18)
        // Let the queued observation execute during the gesture.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.currentPlaybackTime, 20.75)
        controller.endScrubbing()
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertEqual(controller.currentPlaybackTime, 20.75)
        time.send(21)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.currentPlaybackTime, 21)
        controller.beginScrubbing()
        controller.teardown()
        XCTAssertFalse(controller.isScrubbing)
    }

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
        let failure = PassthroughSubject<String?, Never>()
        cancelled.expectedFulfillmentCount = 4
        let staleRefresh = expectation(description: "Retired refresh")
        staleRefresh.isInverted = true
        controller.installMPVObservers(
            timePosition: time.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            fileLoaded: loaded.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            reachedEnd: ended.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
            failure: failure.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher(),
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

final class MPVWakeupContextTests: XCTestCase {
    private final class Owner: @unchecked Sendable {}

    @MainActor
    func testInitializedPlayerReleasesAfterLastOwnerDropsIt() async throws {
        var player: MPVPlayer? = MPVPlayer()
        weak var releasedPlayer = player
        player?.attachDrawable(MPVMetalLayer())
        XCTAssertNil(player?.error, "The regression must exercise successful MPV initialization")
        player = nil
        // Initial property notifications can briefly retain the player in queued
        // event work. Yield the main actor so those notifications can drain.
        for _ in 0..<100 where releasedPlayer != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(releasedPlayer, "The registered C callback must not retain its player")
    }

    func testCallbackContextDoesNotKeepWeakOwnerAlive() {
        let queue = DispatchQueue(label: "mpv-wakeup-ownership-test")
        var owner: Owner? = Owner()
        weak var weakOwner = owner
        let context = MPVWakeupContext(queue: queue) { [weak owner = owner] in
            XCTAssertNil(owner)
        }
        let rawContext = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<MPVWakeupContext>.fromOpaque(rawContext).release() }
        owner = nil
        XCTAssertNil(weakOwner)
        Unmanaged<MPVWakeupContext>.fromOpaque(rawContext).takeUnretainedValue().schedule()
        queue.sync {}
    }

    func testCallbackSchedulesWorkWithoutRunningInlineAndSurvivesContextRelease() {
        let queue = DispatchQueue(label: "mpv-wakeup-dispatch-test")
        let invoked = expectation(description: "Queued callback runs after context release")
        queue.suspend()
        var context: MPVWakeupContext? = MPVWakeupContext(queue: queue) {
            dispatchPrecondition(condition: .onQueue(queue))
            invoked.fulfill()
        }
        weak var weakContext = context
        // A synchronous callback here would fulfill while the event queue is suspended.
        context?.schedule()
        context = nil
        XCTAssertNil(weakContext)
        queue.resume()
        wait(for: [invoked], timeout: 1)
    }
}

final class MPVSeekSchedulerTests: XCTestCase {
    func testDragWaitsForDecodedFrameAndKeepsOnlyLatestTarget() throws {
        var scheduler = MPVSeekScheduler()
        let first = try XCTUnwrap(scheduler.request(.init(time: 10, exact: false)))
        for time in 11...100 {
            XCTAssertNil(scheduler.request(.init(time: Double(time), exact: false)))
        }
        XCTAssertNil(scheduler.commandReplied(id: first.id, succeeded: true))
        // Command acceptance and unrelated startup restart cannot unblock it.
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertEqual(scheduler.inFlight, first)
        scheduler.seekStarted()
        let next = try XCTUnwrap(scheduler.playbackRestarted())
        XCTAssertEqual(next.request, .init(time: 100, exact: false))
        XCTAssertNil(scheduler.pending)
    }

    func testReleaseReplacesPendingPreviewWithPreciseTarget() throws {
        var scheduler = MPVSeekScheduler()
        let first = try XCTUnwrap(scheduler.request(.init(time: 10, exact: false)))
        XCTAssertNil(scheduler.request(.init(time: 20, exact: false)))
        scheduler.cancelPendingPreview()
        XCTAssertNil(scheduler.request(.init(time: 20.75, exact: true)))
        // Cancelling further preview work must preserve the final exact seek.
        scheduler.cancelPendingPreview()
        scheduler.seekStarted()
        XCTAssertNil(scheduler.commandReplied(id: first.id, succeeded: true))
        let final = try XCTUnwrap(scheduler.playbackRestarted())
        XCTAssertEqual(final.request, .init(time: 20.75, exact: true))
        scheduler.seekStarted()
        XCTAssertNil(scheduler.commandReplied(id: final.id, succeeded: true))
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertNil(scheduler.inFlight)
        XCTAssertNil(scheduler.pending)
    }

    func testRestartBeforeCommandReplyStillFinishesExactlyOnce() throws {
        var scheduler = MPVSeekScheduler()
        let first = try XCTUnwrap(scheduler.request(.init(time: 10, exact: false)))
        XCTAssertNil(scheduler.request(.init(time: 20, exact: false)))
        scheduler.seekStarted()
        XCTAssertNil(scheduler.playbackRestarted())
        let next = try XCTUnwrap(scheduler.commandReplied(id: first.id, succeeded: true))
        XCTAssertEqual(next.request.time, 20)
        XCTAssertNil(scheduler.commandReplied(id: first.id, succeeded: true))
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertEqual(scheduler.inFlight, next)
    }

    func testFailedCommandAllowsLatestRequestAndResetRejectsOldReplies() throws {
        var scheduler = MPVSeekScheduler()
        let first = try XCTUnwrap(scheduler.request(.init(time: 10, exact: false)))
        XCTAssertNil(scheduler.request(.init(time: 20, exact: true)))
        let next = try XCTUnwrap(scheduler.commandReplied(id: first.id, succeeded: false))
        XCTAssertTrue(next.request.exact)
        scheduler.reset()
        XCTAssertNil(scheduler.pending)
        XCTAssertNil(scheduler.inFlight)
        let replacement = try XCTUnwrap(scheduler.request(.init(time: 30, exact: false)))
        XCTAssertNotEqual(replacement.id, next.id)
        XCTAssertNil(scheduler.commandReplied(id: next.id, succeeded: false))
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertEqual(scheduler.inFlight, replacement)
    }

    func testCancellationDropsWaitingPreviewAndInvalidTargetsAreIgnored() throws {
        var scheduler = MPVSeekScheduler()
        let first = try XCTUnwrap(scheduler.request(.init(time: 10, exact: false)))
        XCTAssertNil(scheduler.request(.init(time: 20, exact: false)))
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(scheduler.request(.init(time: time, exact: true)))
        }
        XCTAssertEqual(scheduler.pending?.time, 20)
        scheduler.cancelPendingPreview()
        scheduler.seekStarted()
        XCTAssertNil(scheduler.commandReplied(id: first.id, succeeded: true))
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertNil(scheduler.inFlight)
    }
}
