import XCTest
@testable import Aagedal_Media_Converter

final class YTDLPEngineRouterTests: XCTestCase {
    // MARK: - Hosts

    func testSupportedHostsMatchSubdomainsOnLabelBoundaries() {
        let supported = [
            "https://www.youtube.com/watch?v=jNQXAC9IVRw": "youtube",
            "https://youtube.com/shorts/abc": "youtube",
            "https://m.youtube.com/watch?v=abc": "youtube",
            "https://music.youtube.com/watch?v=abc": "youtube",
            "https://youtu.be/abc": "youtube",
            "https://www.youtube-nocookie.com/embed/abc": "youtube",
            "HTTPS://WWW.YOUTUBE.COM./watch?v=abc": "youtube",
            "https://www.instagram.com/reel/abc/": "instagram",
            "https://vm.tiktok.com/abc/": "tiktok",
            "https://x.com/user/status/1": "twitter",
            "https://mobile.twitter.com/user/status/1": "twitter",
            "https://t.co/abc": "twitter",
            "https://m.facebook.com/watch/?v=1": "facebook",
            "https://fb.watch/abc/": "facebook",
            "https://old.reddit.com/r/videos/comments/1/x/": "reddit",
            "https://redd.it/abc": "reddit",
            "https://player.vimeo.com/video/1": "vimeo",
            "https://clips.twitch.tv/abc": "twitch",
            "https://bsky.app/profile/a/post/b": "bluesky",
            "https://soundcloud.com/forss/flickermood": "soundcloud",
            "https://artist.bandcamp.com/track/song": "bandcamp",
            "https://www.dailymotion.com/video/x7tgad0": "dailymotion",
            "https://dai.ly/x7tgad0": "dailymotion",
        ]
        for (url, site) in supported {
            XCTAssertEqual(YTDLPEngineRouter.site(for: url)?.id, site, url)
        }

        let unsupported = [
            "https://notyoutube.com/watch?v=abc",
            "https://youtube.com.evil.example/watch?v=abc",
            "https://v.redd.it/abc",
            "https://example.com/video.mp4",
            "ftp://youtube.com/video",
            "not a url",
        ]
        for url in unsupported {
            XCTAssertNil(YTDLPEngineRouter.site(for: url), url)
        }
    }

    // MARK: - Operations and options

    func testRoutingByOperationAndOptions() {
        func engine(_ url: String, _ operation: YTDLPEngineOperation,
                    available: Bool = true, skipped: Bool = false) -> YTDLPEngine {
            YTDLPEngineRouter.decide(url: url, operation: operation,
                                     rsAvailable: available, rsSkippedForSite: skipped).engine
        }
        let youtube = "https://www.youtube.com/watch?v=abc"
        XCTAssertEqual(engine(youtube, .metadata), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .metadata, available: false), .ytdlp)
        XCTAssertEqual(engine(youtube, .metadata, skipped: true), .ytdlp)
        XCTAssertEqual(engine("https://example.com/a.mp4", .metadata), .ytdlp)
        XCTAssertEqual(engine("https://www.dailymotion.com/video/x1", .download(.init())), .ytdlpRS)

        XCTAssertEqual(engine("https://www.youtube.com/playlist?list=PL1", .playlistListing), .ytdlpRS)
        XCTAssertEqual(engine("https://www.twitch.tv/name/videos", .playlistListing), .ytdlpRS)
        XCTAssertEqual(engine("https://vimeo.com/showcase/1", .playlistListing), .ytdlp)
        XCTAssertEqual(engine("https://soundcloud.com/a/sets/b", .playlistListing), .ytdlp)

        XCTAssertEqual(engine("https://x.com/a/status/1", .postListing), .ytdlpRS)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/", .postListing), .ytdlpRS)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/?img_index=2", .metadata), .ytdlpRS)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/", .download(.init())), .ytdlpRS)
        XCTAssertEqual(engine("https://www.instagram.com/reel/abc/", .download(.init())), .ytdlpRS)
        XCTAssertEqual(engine("https://vimeo.com/1", .postListing), .ytdlp)
        XCTAssertEqual(engine(youtube, .upcomingStreamInfo), .ytdlpRS)
        XCTAssertEqual(engine("https://example.com/live", .upcomingStreamInfo), .ytdlp)

        XCTAssertEqual(engine(youtube, .download(.init())), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(section: true))), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(liveFromStart: true))), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(hasFFmpeg: false))), .ytdlp)
        XCTAssertEqual(engine(youtube, .download(.init(audioOnly: true, hasFFprobe: true))), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(audioOnly: false, hasFFprobe: false))), .ytdlpRS)
    }

    func testDailymotionNeedsAVersionWithItsTopVariants() {
        func engine(version: String?) -> YTDLPEngine {
            YTDLPEngineRouter.decide(url: "https://www.dailymotion.com/video/x1", operation: .metadata,
                                     rsAvailable: true, rsVersion: version).engine
        }
        XCTAssertEqual(engine(version: AppConstants.bundledYTDLPRSVersion), .ytdlpRS)
        XCTAssertEqual(engine(version: "0.9.0-beta.1"), .ytdlpRS)
        XCTAssertEqual(engine(version: "0.8.0-beta.1"), .ytdlp)
        XCTAssertEqual(engine(version: nil), .ytdlp)
        // Other sites still use an older yt-dlp-rs.
        XCTAssertEqual(YTDLPEngineRouter.decide(url: "https://www.youtube.com/watch?v=abc", operation: .metadata,
                                                rsAvailable: true, rsVersion: "0.8.0-beta.1").engine, .ytdlpRS)
    }

    /// Instagram photo slides and scheduled streams were re-checked on 1.0.0-rc.1 against
    /// yt-dlp 2026.10.26 on 2026-11-13: identical listings, metadata and downloads.
    func testIgnoreNoFormatsRoutesNeedRC1() {
        func engine(_ url: String, _ operation: YTDLPEngineOperation, version: String?) -> YTDLPEngine {
            YTDLPEngineRouter.decide(url: url, operation: operation, rsAvailable: true, rsVersion: version).engine
        }
        let post = "https://www.instagram.com/p/abc/"
        let upcoming = "https://www.youtube.com/watch?v=abc"
        for operation: YTDLPEngineOperation in [.postListing, .metadata, .download(.init())] {
            XCTAssertEqual(engine(post, operation, version: "1.0.0-rc.1"), .ytdlpRS)
            XCTAssertEqual(engine(post, operation, version: "1.0.0"), .ytdlpRS)
            XCTAssertEqual(engine(post, operation, version: "0.10.0-beta.1"), .ytdlp)
            XCTAssertEqual(engine(post, operation, version: nil), .ytdlp)
        }
        XCTAssertEqual(engine(upcoming, .upcomingStreamInfo, version: "1.0.0-rc.1"), .ytdlpRS)
        XCTAssertEqual(engine(upcoming, .upcomingStreamInfo, version: "0.9.0-beta.1"), .ytdlp)
        // Instagram reels never needed it.
        XCTAssertEqual(engine("https://www.instagram.com/reel/abc/", .download(.init()), version: "0.9.0-beta.1"), .ytdlpRS)
    }

    func testAudioWithoutFFprobeNeedsRC2() {
        func engine(version: String?, hasFFprobe: Bool = false) -> YTDLPEngine {
            YTDLPEngineRouter.decide(url: "https://www.youtube.com/watch?v=abc",
                                     operation: .download(.init(audioOnly: true, hasFFprobe: hasFFprobe)),
                                     rsAvailable: true, rsVersion: version).engine
        }
        XCTAssertEqual(engine(version: "1.0.0-rc.2"), .ytdlpRS)
        XCTAssertEqual(engine(version: "1.0.0"), .ytdlpRS)
        XCTAssertEqual(engine(version: "1.0.0-rc.1"), .ytdlp)
        XCTAssertEqual(engine(version: nil), .ytdlp)
        XCTAssertEqual(engine(version: "0.9.0-beta.1", hasFFprobe: true), .ytdlpRS)
    }

    func testLiveFromStartNeedsLiveRecordingVersion() {
        func engine(version: String?) -> YTDLPEngine {
            YTDLPEngineRouter.decide(url: "https://www.youtube.com/watch?v=abc",
                                     operation: .download(.init(liveFromStart: true)),
                                     rsAvailable: true, rsVersion: version).engine
        }
        XCTAssertEqual(engine(version: "0.6.0-beta.1"), .ytdlpRS)
        XCTAssertEqual(engine(version: "0.6.1"), .ytdlpRS)
        XCTAssertEqual(engine(version: "0.5.0-beta.1"), .ytdlp)
        XCTAssertEqual(engine(version: "0.6.0-alpha.1"), .ytdlp)
        XCTAssertEqual(engine(version: nil), .ytdlp)
        XCTAssertEqual(engine(version: "garbage"), .ytdlp)
        XCTAssertTrue(YTDLPEngineRouter.supportsLiveRecording(version: AppConstants.bundledYTDLPRSVersion))
        // Other downloads still use an older yt-dlp-rs.
        XCTAssertEqual(YTDLPEngineRouter.decide(url: "https://www.youtube.com/watch?v=abc",
                                                operation: .download(.init()), rsAvailable: true,
                                                rsVersion: "0.4.0-beta.1").engine, .ytdlpRS)
    }

    func testGrowingFileProgressParsing() throws {
        let line = "[download]   24.79MiB at  122.26KiB/s (00:03:27), recorded 00:03:40"
        let parsed = try XCTUnwrap(YTDLPProgressParser.parseGrowingFileProgress(line))
        XCTAssertEqual(parsed.time, 220)
        XCTAssertEqual(parsed.bytes, Int64(24.79 * 1024 * 1024))
        XCTAssertEqual(YTDLPProgressParser.parseGrowingFileProgress(
            "[download]  696.52KiB at  436.85KiB/s (00:00:01), recorded 01:00:05")?.time, 3605)
        XCTAssertNil(YTDLPProgressParser.parseGrowingFileProgress("[download]    1.63MiB at  999.04KiB/s (00:00:01)"))
        XCTAssertNil(YTDLPProgressParser.parseGrowingFileProgress("[download] Destination: recorded 00:00:01"))
        // The line still counts as download activity.
        XCTAssertNotNil(YTDLPProgressParser.parse(line))
    }

    /// Lines captured 2026-11-02 from yt-dlp-rs 0.8.0-beta.1 and yt-dlp 2026.10.21 (both
    /// print the same) downloading a local MP4 with `downloadProgressTemplate`.
    func testDownloadStatusParsing() throws {
        let prefix = YTDLPProgressParser.downloadStatusPrefix
        let downloading = try XCTUnwrap(YTDLPProgressParser.parseDownloadStatus(
            prefix + #"{"status": "downloading", "downloaded_bytes": 7168, "total_bytes": 7897258, "eta": 4, "speed": 1861113.375765749, "filename": "clip.mp4", "tmpfilename": "clip.mp4.part"}"#
        ))
        XCTAssertFalse(downloading.isFinished)
        XCTAssertEqual(downloading.filename, "clip.mp4")
        XCTAssertEqual(try XCTUnwrap(downloading.fraction), 7168.0 / 7897258.0, accuracy: 1e-9)
        XCTAssertEqual(downloading.speedText, "1.77MiB/s")

        let finished = try XCTUnwrap(YTDLPProgressParser.parseDownloadStatus(
            prefix + #"{"status": "finished", "downloaded_bytes": 7897258, "total_bytes": 7897258, "speed": 2092169.295093156, "filename": "clip.mp4"}"#
        ))
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.fraction, 1)

        // HLS/DASH: the estimate stands in for the total; fragments without sizes.
        let estimate = try XCTUnwrap(YTDLPProgressParser.parseDownloadStatus(
            prefix + #"{"status": "downloading", "downloaded_bytes": 250, "total_bytes_estimate": 1000.0, "fragment_index": 1, "fragment_count": 8}"#
        ))
        XCTAssertEqual(estimate.fraction, 0.25)
        let fragments = try XCTUnwrap(YTDLPProgressParser.parseDownloadStatus(
            prefix + #"{"status": "downloading", "fragment_index": 3, "fragment_count": 4}"#
        ))
        XCTAssertEqual(fragments.fraction, 0.75)

        // A live stream has no size or fragment count; a growing file reports its recorded time.
        let live = try XCTUnwrap(YTDLPProgressParser.parseDownloadStatus(
            prefix + #"{"status": "downloading", "downloaded_bytes": 1593835, "speed": 512, "filename": "Live.mov", "tmpfilename": "Live.mov", "recorded_seconds": 15}"#
        ))
        XCTAssertNil(live.fraction)
        XCTAssertEqual(live.recordedSeconds, 15)
        XCTAssertEqual(live.speedText, "512.00B/s")

        XCTAssertNil(YTDLPProgressParser.parseDownloadStatus(prefix + "NA"))
        XCTAssertNil(YTDLPProgressParser.parseDownloadStatus(prefix + #"{"downloaded_bytes": 1}"#))
        XCTAssertNil(YTDLPProgressParser.parseDownloadStatus(#"{"status": "downloading"}"#))
    }

    func testDownloadUsesProgressTemplateAndIgnoresHeuristicsAfterIt() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefix = YTDLPProgressParser.downloadStatusPrefix
        let runner = EngineScriptedRunner { _, output in
            func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
            func err(_ text: String) { output?(SubprocessOutputChunk(stream: .standardError, data: Data((text + "\n").utf8))) }
            err("[youtube] abc: Downloading webpage")
            out(prefix + #"{"status": "downloading", "downloaded_bytes": 400, "total_bytes": 1000, "speed": 2048, "filename": "Clip.f137.mp4", "tmpfilename": "Clip.f137.mp4.part"}"#)
            out(prefix + #"{"status": "finished", "downloaded_bytes": 1000, "total_bytes": 1000, "filename": "Clip.f137.mp4"}"#)
            // Between the formats of a merge: a setup line must not move progress back.
            err("[hlsnative] Downloading m3u8 manifest")
            out(prefix + #"{"status": "downloading", "downloaded_bytes": 50, "total_bytes": 100, "filename": "Clip.f140.m4a", "tmpfilename": "Clip.f140.m4a.part"}"#)
            let final = folder.appendingPathComponent("Clip.mp4")
            try Data("video".utf8).write(to: final)
            out(final.path)
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let reports = LockedProgress()
        let result = try await service.download(
            url: "https://www.youtube.com/watch?v=abc", outputFolder: folder,
            progress: { value, speed, _ in reports.append(value, speed) }
        )
        XCTAssertEqual(result.outputURL.lastPathComponent, "Clip.mp4")
        let arguments = try XCTUnwrap(runner.requests.last?.arguments)
        let template = try XCTUnwrap(arguments.firstIndex(of: "--progress-template"))
        XCTAssertEqual(arguments[template + 1], YTDLPProgressParser.downloadProgressTemplate)
        // The setup line before the first status still shows activity; after it only
        // the statuses count, and `finished` leaves the bar to the next status.
        XCTAssertEqual(reports.values.map(\.value), [0.05, 0.4, 0.5, 1.0])
        XCTAssertEqual(reports.values[1].speed, "2.00KiB/s")
    }

    /// `--growing-file` adds `recorded_seconds` to the JSON status (yt-dlp-rs 0.8+).
    func testGrowingRecordingReportsRecordedTimeFromDownloadStatus() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Live.mov")
        let prefix = YTDLPProgressParser.downloadStatusPrefix
        let runner = EngineScriptedRunner { _, output in
            func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
            out("\(YTDLPProgressParser.liveStatusPrefix)is_live")
            try Data("growing".utf8).write(to: file)
            out(prefix + #"{"status": "downloading", "downloaded_bytes": 2048, "speed": 512, "filename": "Live.mov", "tmpfilename": "Live.mov", "recorded_seconds": 15.5}"#)
            out(file.path)
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let updates = LockedUpdates()
        _ = try await service.download(
            url: "https://www.youtube.com/watch?v=x", outputFolder: folder, growingFile: true,
            progress: { _, _, _ in }, liveUpdate: { updates.append($0) }
        )
        XCTAssertEqual(updates.values, [.growingFile(file), .recording(duration: 15.5, bytes: 2048)])
    }

    func testGrowingRecordingTagSetsClearsAndSweeps() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Live.mov")
        try Data("mov".utf8).write(to: file)
        let saved = UserDefaults.standard.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey)
        defer { UserDefaults.standard.set(saved, forKey: AppConstants.pendingGrowingRecordingPathsKey) }
        UserDefaults.standard.removeObject(forKey: AppConstants.pendingGrowingRecordingPathsKey)

        XCTAssertNil(GrowingRecordingTag.set(at: file.path))
        XCTAssertTrue(GrowingRecordingTag.isSet(at: file.path))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey), [file.path])
        GrowingRecordingTag.sweepStale()
        XCTAssertFalse(GrowingRecordingTag.isSet(at: file.path))
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey))

        GrowingRecordingTag.set(at: file.path)
        XCTAssertNil(GrowingRecordingTag.clear(at: file.path))
        XCTAssertNil(GrowingRecordingTag.clear(at: file.path), "An untagged or missing file is not an error")
        XCTAssertFalse(GrowingRecordingTag.isSet(at: file.path))
    }

    func testFallbackSkipsUserStopsAndConfigurationErrors() {
        let noFallback: [Error] = [
            YTDLPError.cancelled, YTDLPError.liveRecordingStopped,
            YTDLPError.fileAlreadyExists(path: "/a", title: "a"),
            YTDLPError.streamNotStarted("This live event will begin in 44 hours."),
            CancellationError(), CookieError.message("bad profile"),
        ]
        for error in noFallback {
            XCTAssertFalse(YTDLPEngineRouter.shouldFallBack(after: error), "\(error)")
        }
        let fallback: [Error] = [
            YTDLPError.metadataFetchFailed("Unsupported URL: x"),
            YTDLPError.downloadFailed("Requested format is not available"),
            YTDLPError.outputNotFound, YTDLPError.stalled, YTDLPError.binaryNotFound,
            YTDLPError.invalidArguments("yt-dlp-rs: error: no such option: --x"),
            URLError(.badServerResponse),
        ]
        for error in fallback {
            XCTAssertTrue(YTDLPEngineRouter.shouldFallBack(after: error), "\(error)")
        }
    }

    func testFailureMemorySkipsSiteAfterLimit() async {
        let memory = YTDLPEngineFailureMemory(limit: 2)
        let first = "https://www.youtube.com/watch?v=a"
        let sameSite = "https://youtu.be/b"
        var skipped = await memory.isSkipped(url: sameSite)
        XCTAssertFalse(skipped)
        await memory.recordFailure(url: first)
        skipped = await memory.isSkipped(url: sameSite)
        XCTAssertFalse(skipped)
        await memory.recordFailure(url: sameSite)
        skipped = await memory.isSkipped(url: first)
        XCTAssertTrue(skipped)
        skipped = await memory.isSkipped(url: "https://www.tiktok.com/@a/video/1")
        XCTAssertFalse(skipped)
    }

    // MARK: - Cleanup

    func testCleanupStemsAndRemovesOnlyNewFilesOfTheReportedDownload() throws {
        XCTAssertEqual(YTDLPAttemptCleanup.stem(of: "Title.f137.mp4.part"), "Title")
        XCTAssertEqual(YTDLPAttemptCleanup.stem(of: "Title.mp4"), "Title")
        XCTAssertEqual(YTDLPAttemptCleanup.stem(of: "A.B (clip 1s-2s).webm"), "A.B (clip 1s-2s)")

        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("Title.mp4"))
        let preexisting = YTDLPAttemptCleanup.snapshot(of: folder)
        for name in ["Title.f137.mp4.part", "Title.f140.m4a", "Other.mp4.part"] {
            try Data("new".utf8).write(to: folder.appendingPathComponent(name))
        }

        let removed = YTDLPAttemptCleanup.removeLeftovers(
            in: folder,
            reportedPaths: [folder.appendingPathComponent("Title.f137.mp4").path, "/elsewhere/Other.mp4"],
            preexisting: preexisting
        )

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["Title.f137.mp4.part", "Title.f140.m4a"])
        XCTAssertEqual(Set(YTDLPAttemptCleanup.snapshot(of: folder)), ["Title.mp4", "Other.mp4.part"])
    }

    // MARK: - Service fallback

    func testMetadataFallsBackToYTDLPAfterRSFailure() async throws {
        let runner = EngineScriptedRunner { request, _ in
            if request.executableURL.path == EngineStubUpdater.rsPath {
                return .result(status: 1, stderr: "ERROR: Unsupported URL: https://www.youtube.com/watch?v=x\n")
            }
            return .result(stdout: #"{"title":"From yt-dlp","duration":12,"formats":[{"url":"https://example.invalid/a"}]}"#)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())

        let metadata = try await service.fetchMetadata(url: "https://www.youtube.com/watch?v=x")

        XCTAssertEqual(metadata.title, "From yt-dlp")
        XCTAssertEqual(runner.executables, [EngineStubUpdater.rsPath, EngineStubUpdater.ytdlpPath])
        let rsArguments = try XCTUnwrap(runner.requests.first?.arguments)
        XCTAssertEqual(rsArguments.first, "--ignore-config")
        XCTAssertFalse(rsArguments.contains("--remote-components"))
        XCTAssertTrue(try XCTUnwrap(runner.requests.last?.arguments).contains("--remote-components"))
    }

    func testRSResultWithoutFormatsFallsBack() async throws {
        let runner = EngineScriptedRunner { request, _ in
            request.executableURL.path == EngineStubUpdater.rsPath
                ? .result(stdout: #"{"title":"Empty"}"#)
                : .result(stdout: #"{"title":"Full","formats":[{"url":"https://example.invalid/a"}]}"#)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let metadata = try await service.fetchMetadata(url: "https://www.tiktok.com/@a/video/1")
        XCTAssertEqual(metadata.title, "Full")
    }

    func testUnsupportedSiteGoesStraightToYTDLP() async throws {
        let runner = EngineScriptedRunner { _, _ in
            .result(stdout: #"{"title":"Direct","formats":[{"url":"https://example.invalid/a"}]}"#)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        _ = try await service.fetchMetadata(url: "https://example.com/video.mp4")
        XCTAssertEqual(runner.executables, [EngineStubUpdater.ytdlpPath])
    }

    func testRepeatedRSFailuresSkipTheSiteForTheSession() async throws {
        let runner = EngineScriptedRunner { request, _ in
            request.executableURL.path == EngineStubUpdater.rsPath
                ? .result(status: 1, stderr: "ERROR: boom\n")
                : .result(stdout: #"{"title":"ok","formats":[{"url":"https://example.invalid/a"}]}"#)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory(limit: 2))
        for id in ["a", "b", "c"] {
            _ = try await service.fetchMetadata(url: "https://www.youtube.com/watch?v=\(id)")
        }
        XCTAssertEqual(runner.executables, [
            EngineStubUpdater.rsPath, EngineStubUpdater.ytdlpPath,
            EngineStubUpdater.rsPath, EngineStubUpdater.ytdlpPath,
            EngineStubUpdater.ytdlpPath,
        ])
    }

    func testDownloadFallbackRemovesRSPartialFilesAndRecordsEngine() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("Clip.description"))
        let final = folder.appendingPathComponent("Clip.mp4")
        let runner = EngineScriptedRunner { request, output in
            if request.executableURL.path == EngineStubUpdater.rsPath {
                let partial = folder.appendingPathComponent("Clip.f137.mp4.part")
                try Data("partial".utf8).write(to: partial)
                output?(SubprocessOutputChunk(stream: .standardOutput,
                                              data: Data("[download] Destination: \(folder.path)/Clip.f137.mp4\n".utf8)))
                output?(SubprocessOutputChunk(stream: .standardError, data: Data("ERROR: fragment 3 not found\n".utf8)))
                return .result(status: 1)
            }
            try Data("video".utf8).write(to: final)
            output?(SubprocessOutputChunk(stream: .standardOutput, data: Data("\(final.path)\n".utf8)))
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())

        let result = try await service.download(
            url: "https://www.youtube.com/watch?v=x", outputFolder: folder, progress: { _, _, _ in }
        )

        XCTAssertEqual(result.engine, .ytdlp)
        XCTAssertNotNil(result.engineFallbackReason)
        XCTAssertEqual(result.outputURL.lastPathComponent, "Clip.mp4")
        XCTAssertEqual(runner.executables, [EngineStubUpdater.rsPath, EngineStubUpdater.ytdlpPath])
        XCTAssertEqual(Set(YTDLPAttemptCleanup.snapshot(of: folder)), ["Clip.description", "Clip.mp4"])
        let rsArguments = try XCTUnwrap(runner.requests.first?.arguments)
        XCTAssertTrue(rsArguments.contains("--ffmpeg-location"))
        XCTAssertTrue(rsArguments.contains("--ignore-config"))
    }

    func testCancellingRSDownloadDoesNotFallBack() async throws {
        let runner = EngineScriptedRunner { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let control = YTDLPDownloadControl()
        let task = Task {
            try await service.download(url: "https://www.youtube.com/watch?v=x",
                                       outputFolder: FileManager.default.temporaryDirectory,
                                       control: control, progress: { _, _, _ in })
        }
        await runner.waitUntilStarted()
        _ = control.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as YTDLPError {
            guard case .cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        XCTAssertEqual(runner.executables, [EngineStubUpdater.rsPath])
    }

    /// Exit 2 is a usage error; captured from v0.8.0-beta.1 given an unknown option.
    func testUsageErrorFallsBackAndTurnsRSOffForTheSession() async throws {
        let runner = EngineScriptedRunner { request, _ in
            request.executableURL.path == EngineStubUpdater.rsPath
                ? .result(status: 2, stderr: "\nUsage: yt-dlp-rs [OPTIONS] URL [URL...]\n\nyt-dlp-rs: error: no such option: --keep-partial-on-stop\n")
                : .result(stdout: #"{"title":"ok","formats":[{"url":"https://example.invalid/a"}]}"#)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory(limit: 2))
        _ = try await service.fetchMetadata(url: "https://www.youtube.com/watch?v=a")
        _ = try await service.fetchMetadata(url: "https://www.tiktok.com/@a/video/1")
        XCTAssertEqual(runner.executables, [
            EngineStubUpdater.rsPath, EngineStubUpdater.ytdlpPath, EngineStubUpdater.ytdlpPath,
        ])
    }

    // MARK: - Stop and cancel

    func testKeepPartialOnStopIsPassedOnlyToCapableRSOutsideLiveFromStart() async throws {
        func request(rsVersion: String? = AppConstants.bundledYTDLPRSVersion, liveFromStart: Bool = false,
                     url: String = "https://www.youtube.com/watch?v=x") async throws -> SubprocessRequest {
            let folder = try makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let runner = EngineScriptedRunner { _, output in
                let final = folder.appendingPathComponent("Clip.mp4")
                try Data("video".utf8).write(to: final)
                output?(SubprocessOutputChunk(stream: .standardOutput, data: Data("\(final.path)\n".utf8)))
                return .result()
            }
            let service = YTDLPService(updateService: EngineStubUpdater(rsVersion: rsVersion), subprocessRunner: runner,
                                       engineFailures: YTDLPEngineFailureMemory())
            _ = try await service.download(url: url, outputFolder: folder, liveFromStart: liveFromStart,
                                           progress: { _, _, _ in })
            return try XCTUnwrap(runner.requests.last)
        }
        let rs = try await request()
        XCTAssertTrue(rs.arguments.contains("--keep-partial-on-stop"))
        XCTAssertEqual(rs.terminationGracePeriod, .seconds(10))
        let liveFromStart = try await request(liveFromStart: true)
        XCTAssertFalse(liveFromStart.arguments.contains("--keep-partial-on-stop"))
        // yt-dlp-rs merges a --live-from-start recording on Cancel's SIGTERM too.
        XCTAssertEqual(liveFromStart.terminationGracePeriod, .seconds(10))
        let oldRS = try await request(rsVersion: "0.7.0-beta.1")
        XCTAssertFalse(oldRS.arguments.contains("--keep-partial-on-stop"))
        let ytdlp = try await request(url: "https://example.com/video.mp4")
        XCTAssertFalse(ytdlp.arguments.contains("--keep-partial-on-stop"))
        XCTAssertEqual(ytdlp.terminationGracePeriod, .seconds(2))
        let ytdlpLiveFromStart = try await request(liveFromStart: true, url: "https://example.com/video.mp4")
        XCTAssertEqual(ytdlpLiveFromStart.terminationGracePeriod, .seconds(2))
    }

    /// v0.8.0-beta.1 with --keep-partial-on-stop, stopped with SIGINT during a YouTube
    /// merge, 2026-11-03 (trimmed): the kept file is the after_move path, exit 1.
    func testStoppedRSDownloadKeepsTheMergedFile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let final = folder.appendingPathComponent("Clip.mp4")
        let signals = LockedSignals()
        let prefix = YTDLPProgressParser.downloadStatusPrefix
        let runner = EngineScriptedRunner { request, output in
            func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
            func err(_ text: String) { output?(SubprocessOutputChunk(stream: .standardError, data: Data((text + "\n").utf8))) }
            out("\(YTDLPProgressParser.liveStatusPrefix)not_live")
            out(prefix + #"{"status": "finished", "downloaded_bytes": 300, "total_bytes": 300, "filename": "Clip.f258.m4a"}"#)
            out(prefix + #"{"status": "downloading", "downloaded_bytes": 200, "total_bytes": 700, "filename": "Clip.f401.mp4", "tmpfilename": "Clip.f401.mp4.part"}"#)
            request.signalHandle?.attach { signals.append($0); return true }
            signals.markAttached()
            while !signals.values.contains(SIGINT) { try await Task.sleep(for: .milliseconds(10)) }
            err("[Merger] Merging formats into \"Clip.mp4\"")
            try Data("merged".utf8).write(to: final)
            out(final.path)
            err("[download] Download stopped; keeping the partial file")
            err("")
            err("ERROR: Interrupted by user")
            return .result(status: 1)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let control = YTDLPDownloadControl()
        let task = Task {
            try await service.download(url: "https://www.youtube.com/watch?v=x", outputFolder: folder,
                                       control: control, progress: { _, _, _ in })
        }
        // Stopping before the process runs would force-stop it instead of sending SIGINT.
        while !signals.attached { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(control.stopLiveRecording())
        do {
            _ = try await task.value
            XCTFail("Expected liveRecordingStopped")
        } catch YTDLPError.liveRecordingStopped {
        }
        XCTAssertEqual(signals.values, [SIGINT])
        XCTAssertEqual(runner.executables, [EngineStubUpdater.rsPath])
        // DownloadManager adopts this file as the finished download.
        XCTAssertEqual(control.partialFile(in: folder)?.lastPathComponent, final.lastPathComponent)
    }

    func testCancelRemovesTheDownloadsNewFilesButKeepsLiveFootage() async throws {
        func cancelledDownload(liveStatus: String) async throws -> Set<String> {
            let folder = try makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            for name in ["Clip.description", "Other.mp4.part"] {
                try Data("old".utf8).write(to: folder.appendingPathComponent(name))
            }
            let prefix = YTDLPProgressParser.downloadStatusPrefix
            let runner = EngineScriptedRunner { _, output in
                func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
                out("\(YTDLPProgressParser.liveStatusPrefix)\(liveStatus)")
                for name in ["Clip.f401.mp4.part", "Clip.mp4.part-Frag6.part", "Clip.mp4.ytdl"] {
                    try Data("new".utf8).write(to: folder.appendingPathComponent(name))
                }
                out(prefix + #"{"status": "downloading", "downloaded_bytes": 1, "filename": "Clip.f401.mp4", "tmpfilename": "Clip.f401.mp4.part"}"#)
                try await Task.sleep(for: .seconds(30))
                return .result()
            }
            let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                       engineFailures: YTDLPEngineFailureMemory())
            let control = YTDLPDownloadControl()
            let task = Task {
                try await service.download(url: "https://www.youtube.com/watch?v=x", outputFolder: folder,
                                           control: control, progress: { _, _, _ in })
            }
            while control.reportedFiles(in: folder).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            _ = control.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch YTDLPError.cancelled {
            }
            return Set(YTDLPAttemptCleanup.snapshot(of: folder))
        }
        let vod = try await cancelledDownload(liveStatus: "not_live")
        XCTAssertEqual(vod, ["Clip.description", "Other.mp4.part"])
        let live = try await cancelledDownload(liveStatus: "is_live")
        XCTAssertTrue(live.contains("Clip.f401.mp4.part"))
    }

    func testFrequentDownloadStatusesAreThrottled() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefix = YTDLPProgressParser.downloadStatusPrefix
        let runner = EngineScriptedRunner { _, output in
            func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
            for bytes in 1...100 {
                out(prefix + #"{"status": "downloading", "downloaded_bytes": \#(bytes), "total_bytes": 100000, "filename": "Clip.mp4", "tmpfilename": "Clip.mp4.part"}"#)
            }
            let final = folder.appendingPathComponent("Clip.mp4")
            try Data("video".utf8).write(to: final)
            out(final.path)
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let reports = LockedProgress()
        _ = try await service.download(url: "https://www.youtube.com/watch?v=x", outputFolder: folder,
                                       progress: { value, speed, _ in reports.append(value, speed) })
        // The first status, maybe one after the interval, and the final 100%.
        XCTAssertLessThanOrEqual(reports.values.count, 4)
        XCTAssertEqual(reports.values.last?.value, 1.0)
    }

    // MARK: - Growing files

    func testGrowingFileIsPassedOnlyToCapableRSForWholeVideoDownloads() async throws {
        func arguments(rsVersion: String? = AppConstants.bundledYTDLPRSVersion,
                       audioOnly: Bool = false, section: DownloadSection? = nil,
                       url: String = "https://www.youtube.com/watch?v=x") async throws -> [String] {
            let folder = try makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let runner = EngineScriptedRunner { _, output in
                let final = folder.appendingPathComponent("Clip.mp4")
                try Data("video".utf8).write(to: final)
                output?(SubprocessOutputChunk(stream: .standardOutput, data: Data("\(final.path)\n".utf8)))
                return .result()
            }
            let service = YTDLPService(updateService: EngineStubUpdater(rsVersion: rsVersion), subprocessRunner: runner,
                                       engineFailures: YTDLPEngineFailureMemory())
            _ = try await service.download(url: url, outputFolder: folder, growingFile: true,
                                           audioOnly: audioOnly, section: section, progress: { _, _, _ in })
            return try XCTUnwrap(runner.requests.last?.arguments)
        }
        let growing = try await arguments()
        XCTAssertTrue(growing.contains("--growing-file"))
        XCTAssertTrue(growing.contains("--embed-metadata"))
        let oldRS = try await arguments(rsVersion: "0.5.0-beta.1")
        XCTAssertFalse(oldRS.contains("--growing-file"))
        let audio = try await arguments(audioOnly: true)
        XCTAssertFalse(audio.contains("--growing-file"))
        let clip = try await arguments(section: DownloadSection(start: 1, end: 5))
        XCTAssertFalse(clip.contains("--growing-file"))
        let ytdlp = try await arguments(url: "https://example.com/video.mp4")
        XCTAssertFalse(ytdlp.contains("--growing-file"))
    }

    /// Output captured 2026-10-28 from v0.6.0-beta.1 recording a YouTube live stream with
    /// `--growing-file` and stopped with SIGINT (trimmed).
    func testGrowingRecordingReportsFileAndRecordedTime() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Live 2026-10-28 23_16.mov")
        let runner = EngineScriptedRunner { _, output in
            func out(_ text: String) { output?(SubprocessOutputChunk(stream: .standardOutput, data: Data((text + "\n").utf8))) }
            func err(_ text: String) { output?(SubprocessOutputChunk(stream: .standardError, data: Data((text + "\n").utf8))) }
            out("\(YTDLPProgressParser.liveStatusPrefix)is_live")
            out("\(YTDLPProgressParser.sourceDurationPrefix)NA")
            err("[download] Destination: \(file.lastPathComponent)")
            try Data("growing".utf8).write(to: file)
            out("[download]    1.52MiB at  834.25KiB/s (00:00:01), recorded 00:00:15")
            err("frame=  450 fps= 32 q=-1.0 size=    1556KiB time=00:00:15.00 bitrate= 850.1kbits/s speed=1.06x")
            err("[ffmpeg] Interrupted by user")
            out("[download] 100% of    4.29MiB in 00:00:31 at 141.20KiB/s")
            err("[Metadata] Adding metadata to \"\(file.lastPathComponent)\"")
            out(file.path)
            return .result()
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        let updates = LockedUpdates()
        let result = try await service.download(
            url: "https://www.youtube.com/watch?v=x", outputFolder: folder, growingFile: true,
            progress: { _, _, _ in }, liveUpdate: { updates.append($0) }
        )
        XCTAssertEqual(result.outputURL.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(result.engine, .ytdlpRS)
        XCTAssertEqual(updates.values, [
            .growingFile(file), .recording(duration: 15, bytes: Int64(1.52 * 1024 * 1024)),
        ])
    }

    func testFailedGrowingRecordingKeepsItsFileWithoutFallingBack() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Live.mov")
        let runner = EngineScriptedRunner { _, output in
            func line(_ text: String) { output?(SubprocessOutputChunk(stream: .standardError, data: Data((text + "\n").utf8))) }
            line("[download] Destination: Live.mov")
            try Data("growing".utf8).write(to: file)
            GrowingRecordingTag.set(at: file.path)
            line("[download]    1.52MiB at  834.25KiB/s (00:00:01), recorded 00:00:15")
            line("ERROR: ffmpeg exited with code 1")
            return .result(status: 1)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())
        do {
            _ = try await service.download(url: "https://www.youtube.com/watch?v=x", outputFolder: folder,
                                           growingFile: true, progress: { _, _, _ in })
            XCTFail("Expected liveRecordingStopped")
        } catch YTDLPError.liveRecordingStopped {
        }
        XCTAssertEqual(runner.executables, [EngineStubUpdater.rsPath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(GrowingRecordingTag.isSet(at: file.path), "The left-behind recording tag is removed")
    }

    // MARK: - Live yt-dlp-rs output (captured 2026-10-24 with v0.3.0-beta.1, trimmed)

    func testAppDecodesCapturedRSMetadataAndListings() async throws {
        let youtube = #"{"id": "jNQXAC9IVRw", "title": "Me at the zoo", "duration": 19, "thumbnail": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg?sqp=-oaymwEmCOADEOgC8quKqQMa8AEB-AG-AoAC8AGKAgwIABABGFUgWShlMA8=&rs=AOn4CLA9eLBatYv9WbkD4BbZ2Im-biSPTw&usqp=CBQ", "uploader": "jawed", "live_status": "not_live", "webpage_url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "extractor_key": "Youtube", "description": "Microplastics are accumulating in human brains at an alarmin", "formats": [{"format_id": "395", "ext": "mp4", "url": "https://example.invalid/media"}]}"#
        let soundcloud = #"{"id": "293", "title": "Flickermood", "duration": 213.886, "thumbnail": "https://i1.sndcdn.com/artworks-000067273316-smsiqx-original.jpg", "uploader": "Forss", "webpage_url": "https://soundcloud.com/forss/flickermood", "extractor_key": "Soundcloud", "description": "From the Soulhack album,&nbsp;recently f", "formats": [{"format_id": "hls_aac_160k", "ext": "m4a", "url": "https://example.invalid/media"}]}"#
        let channel = #"{"_type": "playlist", "id": "UC4QobU6STFB0P71PMvOGN5A", "title": "jawed - Videos", "webpage_url": "https://www.youtube.com/@jawed/videos", "entries": [{"_type": "url", "ie_key": "Youtube", "id": "jNQXAC9IVRw", "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "title": "Me at the zoo", "duration": 19, "thumbnails": [{"url": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg", "height": 270, "width": 480}]}]}"#
        let runner = EngineScriptedRunner { request, _ in
            XCTAssertEqual(request.executableURL.path, EngineStubUpdater.rsPath)
            let url = request.arguments.last ?? ""
            if url.contains("soundcloud") { return .result(stdout: soundcloud) }
            return .result(stdout: url.contains("@jawed") ? channel : youtube)
        }
        let service = YTDLPService(updateService: EngineStubUpdater(), subprocessRunner: runner,
                                   engineFailures: YTDLPEngineFailureMemory())

        let video = try await service.fetchMetadata(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw")
        XCTAssertEqual(video.title, "Me at the zoo")
        XCTAssertEqual(video.duration, 19)
        XCTAssertEqual(video.uploader, "jawed")
        XCTAssertNotNil(video.thumbnailURL)

        let track = try await service.fetchMetadata(url: "https://soundcloud.com/forss/flickermood")
        XCTAssertEqual(track.title, "Flickermood")
        XCTAssertEqual(try XCTUnwrap(track.duration), 213.886, accuracy: 0.001)

        let entries = try await service.fetchPlaylistEntries(url: "https://www.youtube.com/@jawed/videos")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url, "https://www.youtube.com/watch?v=jNQXAC9IVRw")
        XCTAssertEqual(entries.first?.duration, 19)
        XCTAssertNotNil(entries.first?.thumbnailURL)
        XCTAssertTrue(entries.first?.isAvailable ?? false)
        XCTAssertEqual(runner.executables.count, 3)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("amc-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct EngineStubUpdater: YTDLPUpdating {
    static let rsPath = "/fixture/yt-dlp-rs"
    static let ytdlpPath = "/fixture/yt-dlp"
    var rsVersion: String? = AppConstants.bundledYTDLPRSVersion

    func resolveYTDLPPath() async -> String? { Self.ytdlpPath }
    func resolveYTDLPRSPath() async -> String? { Self.rsPath }
    func getCurrentYTDLPRSVersion() async -> String? { rsVersion }
    func ensureDenoInstalled() async -> String? { nil }
}

private final class LockedUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [YTDLPLiveUpdate] = []
    var values: [YTDLPLiveUpdate] { lock.withLock { recorded } }
    func append(_ update: YTDLPLiveUpdate) { lock.withLock { recorded.append(update) } }
}

private final class LockedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    private var isAttached = false
    var values: [Int32] { lock.withLock { recorded } }
    var attached: Bool { lock.withLock { isAttached } }
    func append(_ signal: Int32) { lock.withLock { recorded.append(signal) } }
    func markAttached() { lock.withLock { isAttached = true } }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(value: Double, speed: String?)] = []
    var values: [(value: Double, speed: String?)] { lock.withLock { recorded } }
    func append(_ value: Double, _ speed: String?) { lock.withLock { recorded.append((value, speed)) } }
}

private final class EngineScriptedRunner: SubprocessRunning, @unchecked Sendable {
    typealias Script = @Sendable (
        SubprocessRequest, (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult

    private let lock = NSLock()
    private let script: Script
    private var recorded: [SubprocessRequest] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(script: @escaping Script) {
        self.script = script
    }

    var requests: [SubprocessRequest] { lock.withLock { recorded } }
    var executables: [String] { requests.map(\.executableURL.path) }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock { () -> Bool in
                if !recorded.isEmpty { return true }
                startWaiters.append(continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            recorded.append(request)
            defer { startWaiters.removeAll() }
            return startWaiters
        }
        waiters.forEach { $0.resume() }
        return try await script(request, outputHandler)
    }
}

private extension SubprocessResult {
    static func result(status: Int32 = 0, stdout: String = "", stderr: String = "") -> SubprocessResult {
        SubprocessResult(
            terminationStatus: status, termination: .exited,
            standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
