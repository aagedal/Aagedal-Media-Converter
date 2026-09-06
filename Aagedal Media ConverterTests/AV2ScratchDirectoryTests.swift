import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AV2ScratchDirectoryTests: XCTestCase {
    func testAbandonedSegmentPlansDoNotCreateScratchDirectories() async throws {
        let suite = "AV2ScratchDirectoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: AppConstants.av2ParallelChunksKey)
        defaults.set(AV2RateControlMode.constantQuality.rawValue, forKey: AppConstants.av2RateControlModeKey)
        let settings = AV2Settings(defaults: defaults)

        for _ in 0..<2 {
            let built = await AV2CommandBuilder.buildSegments(
                inputURL: URL(fileURLWithPath: "/nonexistent/source.mov"),
                trimStart: nil, trimEnd: nil, cropConfig: nil,
                metadataSource: .resolved(videoMetadata(timecode: nil, frameRate: 24)),
                settings: settings
            )
            let plan = try XCTUnwrap(built)
            XCTAssertGreaterThan(plan.segments.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.segmentDirectory.path))
        }
    }

    func testCapturedSettingsGovernSingleChunkedAndMuxBitDepthAfterPreferencesChange() async throws {
        let suite = "AV2SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: AppConstants.av2ParallelChunksKey)
        defaults.set(AV2BitDepthOption.ten.rawValue, forKey: AppConstants.av2BitDepthKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.av2ResolutionLimitKey)
        defaults.set(42, forKey: AppConstants.av2QualityKey)
        defaults.set(3, forKey: AppConstants.av2SpeedKey)
        let settings = AV2Settings(defaults: defaults)
        defaults.set(1, forKey: AppConstants.av2ParallelChunksKey)
        defaults.set(AV2BitDepthOption.eight.rawValue, forKey: AppConstants.av2BitDepthKey)
        defaults.set(CodecResolutionLimit.unlimited.rawValue, forKey: AppConstants.av2ResolutionLimitKey)
        defaults.set(100, forKey: AppConstants.av2QualityKey)
        defaults.set(9, forKey: AppConstants.av2SpeedKey)

        let input = URL(fileURLWithPath: "/nonexistent/source.mov")
        let metadata = videoMetadata(timecode: nil, frameRate: 24)
        let built = await AV2CommandBuilder.build(
            inputURL: input, outputURL: input.appendingPathExtension("ivf"),
            trimStart: nil, trimEnd: nil, cropConfig: nil,
            metadataSource: .resolved(metadata), settings: settings
        )
        let command = try XCTUnwrap(built)
        XCTAssertEqual(command.outputWidth, 1280)
        XCTAssertEqual(command.outputHeight, 720)
        XCTAssertTrue(command.avmencArguments.contains("--input-bit-depth=10"))
        XCTAssertTrue(command.avmencArguments.contains("--qp=42"))
        XCTAssertTrue(command.avmencArguments.contains("--cpu-used=3"))
        let planned = await AV2CommandBuilder.buildSegments(
            inputURL: input, trimStart: nil, trimEnd: nil, cropConfig: nil,
            metadataSource: .resolved(metadata), settings: settings
        )
        let plan = try XCTUnwrap(planned)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.outputWidth, command.outputWidth)
        XCTAssertEqual(plan.outputHeight, command.outputHeight)
        XCTAssertEqual(plan.bitDepth, 10)
        XCTAssertTrue(plan.segments.allSatisfy { $0.avmencArguments.contains("--qp=42") })
        let muxBitDepth = await AV2CommandBuilder.resolvedBitDepth(
            inputURL: input, trimStart: nil, trimEnd: nil, cropConfig: nil,
            metadataSource: .resolved(metadata), settings: settings
        )
        XCTAssertEqual(muxBitDepth, plan.bitDepth)
        let nextSettings = AV2Settings(defaults: defaults)
        let nextPlan = await AV2CommandBuilder.buildSegments(
            inputURL: input, trimStart: nil, trimEnd: nil, cropConfig: nil,
            metadataSource: .resolved(metadata), settings: nextSettings
        )
        XCTAssertNil(nextPlan)
        let nextBitDepth = await AV2CommandBuilder.resolvedBitDepth(
            inputURL: input, trimStart: nil, trimEnd: nil, cropConfig: nil,
            metadataSource: .resolved(metadata), settings: nextSettings
        )
        XCTAssertEqual(nextBitDepth, 8)
    }

    func testConflictingScratchFileFailsBeforeLaunchingAndPreservesFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sentinel = Data("existing user data".utf8)
        try sentinel.write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorReason?.contains("Could not create temporary storage for AV2 chunks") == true)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try Data(contentsOf: directory), sentinel)
    }

    func testExistingScratchDirectoryIsNotAdoptedOrRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinelURL = directory.appendingPathComponent("keep.txt")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: sentinelURL)
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
    }

    func testMissingScratchParentFailsBeforeLaunching() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("chunks")
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWorkerFailureCleansOwnedScratchDirectory() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertGreaterThan(runner.launchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func execute(directory: URL, runner: ScratchRecordingRunner) async -> FFMPEGConverter.AV2EncodeResult {
        let plan = AV2CommandBuilder.AV2SegmentPlan(
            segments: [.init(index: 0, ffmpegArguments: [], avmencArguments: [],
                             outputURL: directory.appendingPathComponent("segment.ivf"), frameCount: 24)],
            segmentDirectory: directory, outputWidth: 32, outputHeight: 32,
            bitDepth: 8, totalFrames: 24, effectiveDuration: 1, frameRate: 24
        )
        return await FFMPEGConverter(subprocessRunner: runner).runAV2ChunkedConversion(
            plan: plan, outputFileURL: directory.appendingPathComponent("output.ivf"),
            ffmpegPath: "/nonexistent/ffmpeg", avmencPath: "/nonexistent/avmenc",
            progressUpdate: { _, _ in }
        )
    }
    private func videoMetadata(
        timecode: String?,
        frameRate: Double,
        duration: Double? = 60
    ) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
            formatName: "mov",
            containerLongName: "QuickTime / MOV",
            sizeBytes: nil,
            bitRate: nil,
            comment: nil,
            timecode: timecode,
            timecodes: [],
            frameCount: nil,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [
                VideoMetadata.VideoStream(
                    codec: "h264",
                    codecLongName: nil,
                    profile: nil,
                    width: 1920,
                    height: 1080,
                    pixelFormat: "yuv420p",
                    hasAlpha: false,
                    pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: frameRate),
                    bitDepth: 8,
                    bitRate: nil,
                    duration: 60,
                    chromaSubsampling: "4:2:0",
                    colorPrimaries: nil,
                    colorTransfer: nil,
                    colorSpace: nil,
                    colorRange: nil,
                    chromaLocation: nil,
                    fieldOrder: nil,
                    isInterlaced: false,
                    title: nil,
                    isDefault: true,
                    isForced: false
                )
            ],
            audioStreams: [],
            subtitleStreams: []
        )
    }

}

private final class ScratchRecordingRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var launchCount: Int { lock.withLock { count } }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        lock.withLock { count += 1 }
        throw SubprocessRunnerError.failedToStart(command: request.executableURL.path, underlying: "Injected launch failure")
    }
}

final class AV2SettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "AV2SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testAbsentPreferencesPreserveExistingDefaults() {
        withDefaults { defaults in
            let settings = AV2Settings(defaults: defaults)
            XCTAssertEqual(settings.quality, AppConstants.defaultAV2Quality)
            XCTAssertEqual(settings.targetBitrate, AppConstants.defaultAV2TargetBitrate)
            XCTAssertEqual(settings.speed, AppConstants.defaultAV2Speed)
            XCTAssertEqual(settings.threads, AppConstants.defaultAV2Threads)
            XCTAssertEqual(settings.tileColumns, AppConstants.defaultAV2TileColumns)
            XCTAssertEqual(settings.tileRows, AppConstants.defaultAV2TileRows)
            XCTAssertEqual(settings.parallelChunks, AppConstants.defaultAV2ParallelChunks)
            XCTAssertEqual(settings.resolutionLimit.rawValue, AppConstants.defaultAV2ResolutionLimit)
            XCTAssertEqual(settings.bitDepth.rawValue, AppConstants.defaultAV2BitDepth)
            XCTAssertEqual(settings.rateControlMode.rawValue, AppConstants.defaultAV2RateControlMode)
        }
    }

    func testExplicitZeroPreferencesAreNotReplacedByDefaults() {
        withDefaults { defaults in
            defaults.set(0, forKey: AppConstants.av2QualityKey)
            defaults.set(0, forKey: AppConstants.av2SpeedKey)
            let settings = AV2Settings(defaults: defaults)
            XCTAssertEqual(settings.quality, 0)
            XCTAssertEqual(settings.speed, 0)
        }
    }

    func testInvalidEnumsRetainFallbacksWithoutRewritingPreferences() {
        withDefaults { defaults in
            for key in [AppConstants.av2ResolutionLimitKey, AppConstants.av2BitDepthKey,
                        AppConstants.av2RateControlModeKey] {
                defaults.set("removed-option", forKey: key)
            }
            let settings = AV2Settings(defaults: defaults)
            XCTAssertEqual(settings.resolutionLimit, .unlimited)
            XCTAssertEqual(settings.bitDepth, .auto)
            XCTAssertEqual(settings.rateControlMode, .constantQuality)
            XCTAssertEqual(defaults.string(forKey: AppConstants.av2BitDepthKey), "removed-option")
        }
    }
}
