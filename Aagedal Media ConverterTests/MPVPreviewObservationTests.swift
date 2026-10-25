import Combine
import Libmpv
import XCTest
@testable import Aagedal_Media_Converter

final class MPVPreviewObservationTests: XCTestCase {
    func testGroupedAudioGraphPreservesIDsRolesAndGain() throws {
        let stereo = try XCTUnwrap(MPVPlayer.audioPresentationGraph(.stereo(left: 1, right: 0), trackIDs: [4, 9]))
        XCTAssertTrue(stereo.contains("[aid9]pan=stereo|FL=c0|FR=0*c0"))
        XCTAssertTrue(stereo.contains("[aid4]pan=stereo|FL=0*c0|FR=c0"))
        XCTAssertTrue(stereo.hasSuffix("amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[ao]"))
        let surround = try XCTUnwrap(MPVPlayer.audioPresentationGraph(.surround51([5, 4, 3, 2, 1, 0]), trackIDs: [1, 2, 3, 4, 5, 6]))
        XCTAssertTrue(surround.contains("[aid3]pan=5.1(side)|FL=0*c0|FR=0*c0|FC=0*c0|LFE=c0|SL=0*c0|SR=0*c0"))
        XCTAssertEqual(MPVPlayer.audioPresentationGraph(.track(0), trackIDs: [4]), "")
        XCTAssertNil(MPVPlayer.audioPresentationGraph(.stereo(left: 0, right: 0), trackIDs: [4]))
        XCTAssertNil(MPVPlayer.audioPresentationGraph(.track(1), trackIDs: [4]))
        XCTAssertNil(MPVPlayer.audioPresentationGraph(.surround51([0, 1]), trackIDs: [4, 9]))
    }

    @MainActor
    func testPackagedMPVGroupedAudioAuditionAndSingleTrackRestoration() async throws {
        XCTAssertTrue(MPVPlayer.supportsGroupedAudioPresentation)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-group-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8",
                        "-f", "lavfi", "-i", "aevalsrc=0.25*sin(2*PI*880*t):s=48000:d=8",
                        "-map", "0:a", "-map", "1:a", "-c:a", "flac", source.path], timeout: .seconds(20)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop() }
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }
        let grouped = await player.selectAudioPresentation(.stereo(left: 1, right: 0))
        XCTAssertTrue(grouped)
        XCTAssertTrue(player.audioPresentationFilterGraph?.contains("normalize=0") == true)
        player.play()
        try await waitForMeterCondition { player.isPlaying && player.timePos > 0.2 }
        player.setPlaybackMeterEnabled(true)
        try await waitForMeterCondition { player.playbackMeterSample?.peaks.count == 2 }
        let sample = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertEqual(try XCTUnwrap(sample.peaks[0]), -12.04, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(sample.peaks[1]), -18.06, accuracy: 0.1)
        let single = await player.selectAudioPresentation(.track(0))
        XCTAssertTrue(single)
        XCTAssertEqual(player.audioPresentationFilterGraph, "")
        XCTAssertEqual(player.currentAudioTrackIndex, try XCTUnwrap(player.audioTrackIndexes.first))
        let invalid = await player.selectAudioPresentation(.stereo(left: 0, right: 99))
        XCTAssertFalse(invalid)
        XCTAssertEqual(player.audioPresentationFilterGraph, "")
        XCTAssertLessThanOrEqual(player.currentAudioTrackIndex, 0)
        let regrouped = await player.selectAudioPresentation(.stereo(left: 0, right: 1))
        XCTAssertTrue(regrouped)
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }
        XCTAssertEqual(player.audioPresentationFilterGraph, "")
        XCTAssertGreaterThan(player.currentAudioTrackIndex, 0, "Loading another source must restore normal audio selection")
        withExtendedLifetime(layer) {}
    }

    @MainActor
    func testAudioRegroupingPreservesNearEOFPositionAndRejectsCancelledSelection() async throws {
        let source = try await makeGroupedVideoFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.stop() }
        player.load(url: source, autostart: true)
        try await waitForMeterCondition { player.isFileLoaded && player.reachedEnd && !player.isPlaying }
        let position = player.timePos
        XCTAssertGreaterThan(position, 0.97)
        let ready = await player.selectAudioPresentation(.stereo(left: 0, right: 1))
        XCTAssertTrue(ready)
        try await waitForMeterCondition { !player.isPlaying && abs(player.timePos - position) < 0.02 }
        XCTAssertEqual(player.timePos, position, accuracy: 0.02,
                       "Refreshing the paused last frame must not rewind by the navigation EOF margin")
        let graph = player.audioPresentationFilterGraph
        let cancelled = Task { await player.selectAudioPresentation(.track(0)) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(player.audioPresentationFilterGraph, graph)
        withExtendedLifetime(layer) {}
    }

    @MainActor
    func testAudioRefreshWaitersDrainAcrossReplacementAndStop() async throws {
        let source = try await makeGroupedVideoFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.stop() }
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }
        let replaced = Task { await player.selectAudioPresentation(.stereo(left: 0, right: 1)) }
        await Task.yield()
        player.load(url: source)
        _ = try await NonJoiningTaskDeadline.run(timeout: .seconds(2)) { await replaced.value }
        try await waitForMeterCondition { player.isFileLoaded }
        XCTAssertEqual(player.audioPresentationFilterGraph, "", "An old readiness waiter cannot restore a replaced audio graph")
        player.seek(to: 0.625)
        let grouped = await player.selectAudioPresentation(.stereo(left: 0, right: 1))
        XCTAssertTrue(grouped)
        try await waitForMeterCondition { abs(player.timePos - 0.625) < 0.02 }
        let changing = Task { await player.selectAudioPresentation(.track(0)) }
        await Task.yield()
        player.seek(to: 0.375)
        let changed = await changing.value
        XCTAssertTrue(changed)
        try await waitForMeterCondition { abs(player.timePos - 0.375) < 0.02 }
        XCTAssertFalse(player.isPlaying)
        let stopped = Task { await player.selectAudioPresentation(.stereo(left: 1, right: 0)) }
        await Task.yield()
        player.stop()
        _ = try await NonJoiningTaskDeadline.run(timeout: .seconds(2)) { await stopped.value }
        XCTAssertEqual(player.audioPresentationFilterGraph, "")
        withExtendedLifetime(layer) {}
    }

    /// Regrouping redraws the paused frame with an exact seek. With sparse
    /// keyframes (every 10 s, x264's default at 25 fps) the playhead must stay
    /// put rather than land on the next keyframe. 5 s is a frame boundary.
    @MainActor
    func testAudioRegroupingKeepsPausedPositionBetweenSparseKeyframes() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-sparse-gop-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                         "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=30"]
        var maps = ["-map", "0:v"]
        for index in 0..<7 {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=\(440 + index * 100):sample_rate=48000:duration=30"]
            maps += ["-map", "\(index + 1):a"]
        }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: arguments + maps + ["-c:v", "libx264", "-preset", "ultrafast", "-g", "250",
                                           "-pix_fmt", "yuv420p", "-c:a", "flac", source.path],
            timeout: .seconds(60)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.stop() }
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }

        // The view opens on the first track; switching `aid` used to land on
        // the next keyframe after readiness had already been reported.
        func settledPosition() async throws -> Double {
            try await Task.sleep(for: .milliseconds(500))
            return player.timePos
        }
        let initial = await player.selectAudioPresentation(.track(1))
        XCTAssertTrue(initial)
        let opened = try await settledPosition()
        XCTAssertEqual(opened, 0, accuracy: 0.05, "Opening must not move to the next keyframe")

        player.seek(to: 5)
        try await waitForMeterCondition { abs(player.timePos - 5) < 0.05 }
        let presentations: [LoudnessPresentation] = [
            .track(0), .stereo(left: 0, right: 1), .track(2), .surround51([0, 1, 2, 3, 4, 5]),
            .track(1), .track(3),
        ]
        for (round, presentation) in (presentations + presentations).enumerated() {
            let ready = await player.selectAudioPresentation(presentation)
            XCTAssertTrue(ready, "Round \(round): \(presentation)")
            XCTAssertFalse(player.isPlaying)
            let position = try await settledPosition()
            XCTAssertEqual(position, 5, accuracy: 0.05, "Round \(round): \(presentation)")
        }
        withExtendedLifetime(layer) {}
    }

    @MainActor
    private func makeGroupedVideoFixture() async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-group-video-\(UUID().uuidString).mkv")
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc2=s=128x128:r=60:d=1",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=1",
                        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-g", "60", "-c:a", "flac", file.path],
            timeout: .seconds(20)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        return file
    }

    @MainActor
    func testTimestampHistoryMeasuresStartupAndResumeWithoutDecoderReadAheadGap() async throws {
        guard ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_HISTORY"] == "1" else {
            throw XCTSkip("Requires the isolated timestamp-history dependency and diagnostic opt-in")
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-history-resume-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=8",
                "-f", "lavfi", "-i", "aevalsrc=0.25*sin(2*PI*440*t):s=48000:d=8",
                "-c:v", "mpeg4", "-c:a", "aac", source.path], timeout: .seconds(30)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop(); withExtendedLifetime(layer) {} }
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }
        player.setPlaybackMeterEnabled(true)
        player.play()
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        XCTAssertLessThan(try XCTUnwrap(player.playbackMeterSample).seconds, 0.6,
                          "Startup must measure decoded audio before the existing output buffer ends")
        player.pause()
        try await waitForMeterCondition { !player.isPlaying && player.playbackMeterSample == nil }
        // Resume without a user seek: the output buffer must also be refreshed.
        let pausedPosition = player.timePos
        player.play()
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        let resumed = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertLessThan(resumed.seconds - pausedPosition, 0.6)
        XCTAssertNil(resumed.shortTermLUFS, "Pausing starts a fresh loudness history")
        player.pause()
        try await waitForMeterCondition { !player.isPlaying && player.playbackMeterSample == nil }
        player.seek(to: 3)
        try await waitForMeterCondition { abs(player.timePos - 3) < 0.03 }
        player.play()
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        let sought = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertGreaterThanOrEqual(sought.seconds, 3)
        XCTAssertLessThan(sought.seconds, 3.6)
        XCTAssertNil(sought.shortTermLUFS)
        XCTAssertTrue(player.playbackMeterHasTimestampHistory)
    }

    @MainActor
    func testTimestampHistorySurvivesRepeatedShuttleSpeedChanges() async throws {
        guard ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_HISTORY"] == "1" else {
            throw XCTSkip("Requires the isolated timestamp-history dependency and diagnostic opt-in")
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-history-speed-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=40",
                "-f", "lavfi", "-i", "aevalsrc=0.25*sin(2*PI*440*t):s=48000:d=40",
                "-c:v", "mpeg4", "-c:a", "aac", source.path], timeout: .seconds(30)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop(); withExtendedLifetime(layer) {} }
        player.load(url: source)
        try await waitForMeterCondition { player.isFileLoaded }
        player.setPlaybackMeterEnabled(true)
        player.play()
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        // J/K/L shuttle presses can change speed several times per second.
        try await waitForMeterCondition { player.playbackMeterSample?.shortTermLUFS != nil }
        for rate: Float in [2, 4, 8, 1, 2, 4, 1, 2, 1] {
            player.rate = rate
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(player.playbackMeterUnavailable, "Speed changes must not disable the meter")
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        let sample = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertLessThan(abs(sample.seconds - player.timePos), 0.6, "Readings must resume near the playhead")
        XCTAssertEqual(try XCTUnwrap(sample.peaks[0]), -12.04, accuracy: 0.5)
        XCTAssertTrue(player.playbackMeterHasTimestampHistory)
        // The filter measures decoded samples ahead of MPV's tempo stage, so
        // speed changes are not discontinuities and loudness keeps its history.
        XCTAssertEqual(try XCTUnwrap(sample.shortTermLUFS, "Speed changes must not reset loudness"), -15.7, accuracy: 0.5)
    }

    @MainActor
    func testTimestampHistoryDoesNotPublishDelayedAudioBeforeMeasuredInterval() async throws {
        guard ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_HISTORY"] == "1" else {
            throw XCTSkip("Requires the isolated timestamp-history dependency and diagnostic opt-in")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-delayed-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("delayed.mkv")
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=18",
                "-itsoffset", "12", "-f", "lavfi", "-i", "aevalsrc=0.5*sin(2*PI*1000*t):s=48000:d=6",
                "-c:v", "mpeg4", "-c:a", "flac", source.path], timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop(); withExtendedLifetime(layer) {} }
        player.load(url: source, autostart: false)
        try await waitForMeterCondition { player.isFileLoaded }
        player.setPlaybackMeterEnabled(true)
        player.play()
        let deadline = ContinuousClock.now + .seconds(20)
        var observedSilence = false
        while player.timePos < 12, ContinuousClock.now < deadline {
            observedSilence = true
            XCTAssertNil(player.playbackMeterSample, "Decoder lookahead must not publish audio from twelve seconds in the future")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(observedSilence)
        XCTAssertGreaterThanOrEqual(player.timePos, 12)
        try await waitForMeterCondition { player.playbackMeterHasTimestampHistory }
        let sample = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertGreaterThanOrEqual(sample.seconds, 12.09999)
        XCTAssertEqual(try XCTUnwrap(sample.peaks.first.flatMap { $0 }), -6.0206, accuracy: 0.05)
        XCTAssertNil(sample.shortTermLUFS, "Loudness warm-up is measured audio, not twelve seconds of video-only time")
        XCTAssertFalse(player.playbackMeterUnavailable)
    }

    @MainActor
    func testPackagedMPVCompressedMonoMeter() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-aac-meter-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=320x180:rate=24:duration=15", "-f", "lavfi", "-i",
                        "sine=frequency=440:sample_rate=48000:duration=15", "-c:v", "mpeg4", "-c:a", "aac", source.path],
            timeout: .seconds(20)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop() }
        player.load(url: source, autostart: true)
        try await waitForMeterCondition { player.isPlaying && player.isFileLoaded }
        player.setPlaybackMeterEnabled(true)
        try await waitForMeterCondition { player.playbackMeterSample?.shortTermLUFS != nil }
        let sample = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertEqual(try XCTUnwrap(sample.peaks[0]), -18.06, accuracy: 0.6)
        XCTAssertEqual(try XCTUnwrap(sample.rms[0]), -21.07, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(sample.momentaryLUFS), -21.8, accuracy: 0.3)
        withExtendedLifetime(layer) {}
    }

    @MainActor
    func testPackagedMPVPlaybackMeterSignalAndLifecycle() async throws {
        XCTAssertTrue(MPVPlayer.supportsPlaybackMeter, "Pinned libavfilter must provide astats and ebur128")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-meter-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "aevalsrc=0.5*sin(2*PI*1000*t)|0.25*sin(2*PI*1000*t):s=48000:d=14:c=stereo",
                        "-f", "lavfi", "-i",
                        "aevalsrc=0.125*sin(2*PI*500*t)|0.0625*sin(2*PI*500*t):s=48000:d=14:c=stereo",
                        "-map", "0:a", "-map", "1:a", "-c:a", "flac", source.path], timeout: .seconds(20)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let sourceWindow = try await PlaybackAudioMeterDecoder.decode(
            SourceAudioMeterRequest(url: source, track: 0, channels: 2, window: 0))
        let referenceLUFS = try XCTUnwrap(sourceWindow.sample(at: 4)?.momentaryLUFS)
        let player = MPVPlayer()
        player.attachDrawable(MPVMetalLayer())
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop() }
        player.load(url: source, autostart: true)
        try await waitForMeterCondition { player.isFileLoaded && player.isPlaying }
        XCTAssertNil(player.playbackMeterSample, "Normal playback must not install the meter")
        player.setPlaybackMeterEnabled(true)
        try await waitForMeterCondition { player.playbackMeterSample?.shortTermLUFS != nil }
        let sample = try XCTUnwrap(player.playbackMeterSample)
        XCTAssertEqual(sample.peaks.count, 2)
        XCTAssertEqual(try XCTUnwrap(sample.peaks[0]), -6.0206, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(sample.peaks[1]), -12.0412, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(sample.rms[0]), -9.0309, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(sample.rms[1]), -15.0515, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(sample.momentaryLUFS), referenceLUFS, accuracy: 0.2)
        player.volume = 10
        player.pause()
        try await waitForMeterCondition { !player.isPlaying && player.playbackMeterSample == nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(player.playbackMeterSample, "Old replies cannot revive paused readings")
        player.seek(to: 7)
        player.play()
        try await waitForMeterCondition { (player.playbackMeterSample?.seconds ?? 0) >= 7 }
        XCTAssertNil(player.playbackMeterSample?.shortTermLUFS, "Seek must restart loudness warm-up")
        XCTAssertEqual(try XCTUnwrap(player.playbackMeterSample?.peaks[0]), -6.0206, accuracy: 0.05)
        let tracks = player.audioTrackIndexes
        XCTAssertEqual(tracks.count, 2)
        player.currentAudioTrackIndex = try XCTUnwrap(tracks.last)
        try await waitForMeterCondition { (player.playbackMeterSample?.peaks.first.flatMap { $0 } ?? 0) < -17 }
        XCTAssertEqual(try XCTUnwrap(player.playbackMeterSample?.peaks[0]), -18.0618, accuracy: 0.05)
        XCTAssertNil(player.playbackMeterSample?.shortTermLUFS, "Track changes reset loudness history")
        player.setPlaybackMeterEnabled(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(player.playbackMeterSample)
        player.setPlaybackMeterEnabled(true)
        try await waitForMeterCondition { player.playbackMeterSample != nil }
        player.load(url: source, autostart: true)
        try await waitForMeterCondition { (player.playbackMeterSample?.seconds ?? 100) < 2 }
        XCTAssertNil(player.playbackMeterSample?.shortTermLUFS, "Replacement sources reset history")
        player.seek(to: 13.8)
        try await waitForMeterCondition { player.reachedEnd }
        XCTAssertNil(player.playbackMeterSample, "EOF must clear decoded readings")
        player.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(player.playbackMeterSample, "Stopping rejects late metadata")
    }

    @MainActor
    private func waitForMeterCondition(file: StaticString = #filePath, line: UInt = #line,
                                       _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for packaged MPV meter", file: file, line: line)
    }

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
    func testScrubReleaseKeepsLastPointerTargetWhenBackendClockMoves() {
        let controller = makeController()
        defer { controller.teardown() }
        controller.beginScrubbing()
        controller.seekTo(20.75)
        // Native playback can still publish a clock position during a drag.
        controller.currentPlaybackTime = 18
        controller.beginScrubbing() // Repeated stitching updates keep the target.
        controller.endScrubbing()
        XCTAssertEqual(controller.currentPlaybackTime, 20.75)
        controller.beginScrubbing()
        controller.seekTo(22)
        controller.endScrubbing(at: 22.5)
        XCTAssertEqual(controller.currentPlaybackTime, 22.5)
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
    func testCompletionStatusRequiresDecodedRestartAndResetsWithSource() throws {
        var scheduler = MPVSeekScheduler()
        let submission = try XCTUnwrap(scheduler.request(.init(time: 1.25, exact: true)))
        XCTAssertNil(scheduler.lastCompletionSucceeded)
        XCTAssertNil(scheduler.commandReplied(id: submission.id, succeeded: true))
        XCTAssertNil(scheduler.lastCompletionSucceeded, "Command acceptance does not certify a visible frame")
        scheduler.seekStarted()
        XCTAssertNil(scheduler.playbackRestarted())
        XCTAssertEqual(scheduler.lastCompletionSucceeded, true)
        scheduler.reset()
        XCTAssertNil(scheduler.lastCompletionSucceeded)
        let failed = try XCTUnwrap(scheduler.request(.init(time: 2.25, exact: true)))
        XCTAssertNil(scheduler.commandReplied(id: failed.id, succeeded: false))
        XCTAssertEqual(scheduler.lastCompletionSucceeded, false)
    }

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
