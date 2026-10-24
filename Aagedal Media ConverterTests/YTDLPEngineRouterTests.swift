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
        ]
        for (url, site) in supported {
            XCTAssertEqual(YTDLPEngineRouter.site(for: url)?.id, site, url)
        }

        let unsupported = [
            "https://notyoutube.com/watch?v=abc",
            "https://youtube.com.evil.example/watch?v=abc",
            "https://www.dailymotion.com/video/x7tgad0",
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
        XCTAssertEqual(engine("https://www.dailymotion.com/video/x1", .download(.init())), .ytdlp)

        XCTAssertEqual(engine("https://www.youtube.com/playlist?list=PL1", .playlistListing), .ytdlpRS)
        XCTAssertEqual(engine("https://www.twitch.tv/name/videos", .playlistListing), .ytdlpRS)
        XCTAssertEqual(engine("https://vimeo.com/showcase/1", .playlistListing), .ytdlp)
        XCTAssertEqual(engine("https://soundcloud.com/a/sets/b", .playlistListing), .ytdlp)

        XCTAssertEqual(engine("https://x.com/a/status/1", .postListing), .ytdlpRS)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/", .postListing), .ytdlp)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/?img_index=2", .metadata), .ytdlp)
        XCTAssertEqual(engine("https://www.instagram.com/p/abc/", .download(.init())), .ytdlp)
        XCTAssertEqual(engine("https://www.instagram.com/reel/abc/", .download(.init())), .ytdlpRS)

        XCTAssertEqual(engine(youtube, .download(.init())), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(section: true))), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(liveFromStart: true))), .ytdlp)
        XCTAssertEqual(engine(youtube, .download(.init(hasFFmpeg: false))), .ytdlp)
        XCTAssertEqual(engine(youtube, .download(.init(audioOnly: true, hasFFprobe: false))), .ytdlp)
        XCTAssertEqual(engine(youtube, .download(.init(audioOnly: true, hasFFprobe: true))), .ytdlpRS)
        XCTAssertEqual(engine(youtube, .download(.init(audioOnly: false, hasFFprobe: false))), .ytdlpRS)
    }

    func testFallbackSkipsUserStopsAndConfigurationErrors() {
        let noFallback: [Error] = [
            YTDLPError.cancelled, YTDLPError.liveRecordingStopped,
            YTDLPError.fileAlreadyExists(path: "/a", title: "a"),
            CancellationError(), CookieError.message("bad profile"),
        ]
        for error in noFallback {
            XCTAssertFalse(YTDLPEngineRouter.shouldFallBack(after: error), "\(error)")
        }
        let fallback: [Error] = [
            YTDLPError.metadataFetchFailed("Unsupported URL: x"),
            YTDLPError.downloadFailed("Requested format is not available"),
            YTDLPError.outputNotFound, YTDLPError.stalled, YTDLPError.binaryNotFound,
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
        _ = try await service.fetchMetadata(url: "https://www.dailymotion.com/video/x1")
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

    func resolveYTDLPPath() async -> String? { Self.ytdlpPath }
    func resolveYTDLPRSPath() async -> String? { Self.rsPath }
    func ensureDenoInstalled() async -> String? { nil }
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
