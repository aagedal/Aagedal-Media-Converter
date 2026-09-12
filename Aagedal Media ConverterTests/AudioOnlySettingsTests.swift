import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AudioOnlySettingsTests: XCTestCase {
    func testAbsentAndInvalidPreferencesRetainFallbacksWithoutRewriting() throws {
        let suite = "AudioOnlySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AudioOnlySettings(defaults: defaults)
        XCTAssertEqual(initial.format.rawValue, AppConstants.defaultAudioOnlyFormat)
        XCTAssertEqual(initial.bitDepth.rawValue, AppConstants.defaultAudioOnlyBitDepth)
        XCTAssertEqual(initial.aacBitrate.rawValue, AppConstants.defaultAudioOnlyAACBitrate)
        XCTAssertEqual(initial.mp4Codec.rawValue, AppConstants.defaultAudioOnlyMP4Codec)
        XCTAssertEqual(initial.mp4Bitrate.rawValue, AppConstants.defaultAudioOnlyMP4Bitrate)
        XCTAssertFalse(initial.preserveMetadata)

        let keys = [AppConstants.audioOnlyFormatKey, AppConstants.audioOnlyBitDepthKey,
                    AppConstants.audioOnlyAACBitrateKey, AppConstants.audioOnlyMP4CodecKey,
                    AppConstants.audioOnlyMP4BitrateKey]
        for key in keys { defaults.set("removed-option", forKey: key) }
        let fallback = AudioOnlySettings(defaults: defaults)
        XCTAssertEqual(fallback.format, .wav)
        XCTAssertEqual(fallback.bitDepth, .pcm24)
        XCTAssertEqual(fallback.aacBitrate, .k192)
        XCTAssertEqual(fallback.mp4Codec, .aac)
        XCTAssertEqual(fallback.mp4Bitrate, .k192)
        for key in keys { XCTAssertEqual(defaults.string(forKey: key), "removed-option") }
    }

    func testCapturedMP4CommandKeepsPCMCodecAndMetadataAfterPreferencesChange() async throws {
        let suite = "AudioOnlySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        defaults.set(AudioOnlyMP4Codec.pcm32.rawValue, forKey: AppConstants.audioOnlyMP4CodecKey)
        defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
        let captured = AudioOnlySettings(defaults: defaults)
        await Task.yield()
        defaults.removePersistentDomain(forName: suite)
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/audio.mov"),
            outputFileURL: URL(fileURLWithPath: "/output/audio.\(captured.format.fileExtension)"),
            preset: .audioOnly, audioOnlySettings: captured, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil,
            customInputArguments: ["-framerate", "24", "-i", "/source/audio.mov", "-i", "/source/associated.wav"]
        )
        let codecIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-c:a"))
        XCTAssertEqual(command.arguments[codecIndex + 1], "pcm_s32le")
        XCTAssertFalse(command.arguments.contains("-b:a"))
        XCTAssertFalse(command.arguments.contains("-map_metadata"))
        XCTAssertEqual(command.arguments.last, "/output/audio.mp4")
        XCTAssertEqual(AudioOnlySettings(defaults: defaults).format, .wav)
    }

    func testWAVStreamMergeRetainsSnapshotWhileAudioProbeSuspends() async throws {
        let suite = "AudioOnlySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AudioOnlyBitDepth.pcm16.rawValue, forKey: AppConstants.audioOnlyBitDepthKey)
        let captured = AudioOnlySettings(defaults: defaults)
        var arguments = captured.ffmpegArguments
        await FFMPEGCommandBuilder.adjustArgumentsForInput(
            preset: .audioOnly, audioOnlySettings: captured,
            inputURL: URL(fileURLWithPath: "/source/audio.mov"), ffmpegArgs: &arguments,
            audioStreamProvider: { _ in
                await Task.yield()
                let changedDefaults = UserDefaults(suiteName: suite)!
                changedDefaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
                return [
                    .init(index: 0, channels: 2, channelLayout: "stereo", codecName: "aac"),
                    .init(index: 1, channels: 1, channelLayout: "mono", codecName: "aac")
                ]
            }
        )
        XCTAssertTrue(arguments.contains("[0:a:0][0:a:1]amerge=inputs=2[aout]"))
        XCTAssertTrue(arguments.contains("pcm_s16le"))
        XCTAssertFalse(arguments.contains("0:a"))
        let channelIndex = try XCTUnwrap(arguments.firstIndex(of: "-ac"))
        XCTAssertEqual(arguments[channelIndex + 1], "3")
        XCTAssertEqual(captured.format.fileExtension, "wav")
        XCTAssertEqual(AudioOnlySettings(defaults: defaults).format, .mp4)
    }

    func testConverterUsesCapturedContainerForSourceCollisionAndEncoding() async throws {
        let suite = "AudioOnlySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        defaults.set(AudioOnlyMP4Codec.pcm24.rawValue, forKey: AppConstants.audioOnlyMP4CodecKey)
        let captured = AudioOnlySettings(defaults: defaults)
        defaults.removePersistentDomain(forName: suite)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source sentinel".utf8).write(to: source)
        let runner = AudioOnlySettingsRecordingRunner()
        let finished = expectation(description: "Conversion completed")
        let request = ConversionRequest(
            inputURL: source, outputURL: source.deletingPathExtension(), preset: .audioOnly,
            includeDateTag: false, expectedDuration: 1,
            customInputArguments: ["-framerate", "24", "-i", source.path, "-i", source.path]
        )
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        await converter.convert(
            request: request, audioOnlySettings: captured,
            progressUpdate: { _, _ in }, completion: { _, _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 5)
        let recorded = await runner.request
        let args = try XCTUnwrap(recorded).arguments
        XCTAssertEqual(args.last, directory.appendingPathComponent("source_encoded.mp4").path)
        let codecIndex = try XCTUnwrap(args.firstIndex(of: "-c:a"))
        XCTAssertEqual(args[codecIndex + 1], "pcm_s24le")
        XCTAssertEqual(try Data(contentsOf: source), Data("source sentinel".utf8))
    }

    func testLossyBitratesAndFLACArgumentsFollowSelectedFormat() throws {
        let suite = "AudioOnlySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AudioBitrate.k96.rawValue, forKey: AppConstants.audioOnlyAACBitrateKey)
        defaults.set(AudioBitrate.k320.rawValue, forKey: AppConstants.audioOnlyMP4BitrateKey)
        let cases: [(AudioOnlyFormat, String, String?)] = [
            (.aac, "aac", "96k"), (.mp4, "aac", "320k"), (.flac, "flac", nil)
        ]
        for (format, codec, bitrate) in cases {
            defaults.set(format.rawValue, forKey: AppConstants.audioOnlyFormatKey)
            let args = AudioOnlySettings(defaults: defaults).ffmpegArguments
            let codecIndex = try XCTUnwrap(args.firstIndex(of: "-c:a"))
            XCTAssertEqual(args[codecIndex + 1], codec)
            if let bitrate {
                let bitrateIndex = try XCTUnwrap(args.firstIndex(of: "-b:a"))
                XCTAssertEqual(args[bitrateIndex + 1], bitrate)
            } else {
                XCTAssertFalse(args.contains("-b:a"))
            }
        }
    }
}

private actor AudioOnlySettingsRecordingRunner: SubprocessRunning {
    private(set) var request: SubprocessRequest?

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        self.request = request
        return SubprocessResult(
            terminationStatus: 1, termination: .exited,
            standardOutput: Data(), standardError: Data("Stopped after command capture".utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
