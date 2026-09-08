// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CodecExportSettingsTests: XCTestCase {
    func testProResAndVideoLoopCommandsRetainCapturedPreferences() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in [ExportPreset.prores, .videoLoop, .videoLoopWithSound] {
            defaults.set(ProResProfile.hq.rawValue, forKey: AppConstants.proResProfileKey)
            defaults.set(false, forKey: AppConstants.preserveMetadataPreferenceKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            await Task.yield()
            defaults.set(ProResProfile.proxy.rawValue, forKey: AppConstants.proResProfileKey)
            defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
            let output = URL(fileURLWithPath: "/output/video.\(captured.container.fileExtension)")
            let standard = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"), outputFileURL: output,
                preset: preset, codecSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil,
                customInputArguments: ["-framerate", "24", "-i", "/source/video.mov", "-i", "/source/audio.wav"]
            )
            let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: URL(fileURLWithPath: "/source/audio.wav"), outputFileURL: output,
                preset: preset, codecSettings: captured, width: 1280, height: 720,
                frameRate: 24, trimStart: nil, trimEnd: nil, includeDateTag: false
            )
            for command in [standard, native] {
                let metadataIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-map_metadata"))
                XCTAssertEqual(command.arguments[metadataIndex + 1], "-1")
                XCTAssertEqual(command.arguments.last, output.path)
                if preset == .prores {
                    let profileIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-profile:v"))
                    XCTAssertEqual(command.arguments[profileIndex + 1], "hq")
                    XCTAssertTrue(command.arguments.contains("prores_videotoolbox"))
                } else {
                    XCTAssertTrue(command.arguments.contains("libx264"))
                    XCTAssertEqual(captured.resolutionLimit, .r1080)
                }
            }
        }
    }

    func testInvalidProResProfileFallsBackWithoutRewritingPreferences() throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Unknown profile", forKey: AppConstants.proResProfileKey)
        let captured = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))
        XCTAssertEqual(captured.container, .mov)
        XCTAssertEqual(captured.resolutionLimit, .unlimited)
        let index = try XCTUnwrap(captured.ffmpegArguments.firstIndex(of: "-profile:v"))
        XCTAssertEqual(captured.ffmpegArguments[index + 1], "standard")
        XCTAssertEqual(defaults.string(forKey: AppConstants.proResProfileKey), "Unknown profile")
    }

    func testAllCodecCommandsRetainCapturedContainerEncoderAndAudio() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cases: [(ExportPreset, String, String, String)] = [
            (.h264, AppConstants.h264ContainerKey, AppConstants.h264AudioFormatKey, "libx264"),
            (.h265, AppConstants.h265ContainerKey, AppConstants.h265AudioFormatKey, "libx265"),
            (.av1, AppConstants.av1ContainerKey, AppConstants.av1AudioFormatKey, "libsvtav1")
        ]
        for (preset, containerKey, audioKey, encoder) in cases {
            defaults.set(CodecContainer.mkv.rawValue, forKey: containerKey)
            defaults.set(CodecAudioFormat.opus.rawValue, forKey: audioKey)
            defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
            defaults.set(H265Encoder.software.rawValue, forKey: AppConstants.h265EncoderKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            await Task.yield()
            defaults.set(CodecContainer.mp4.rawValue, forKey: containerKey)
            defaults.set(CodecAudioFormat.aac.rawValue, forKey: audioKey)
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/video.\(captured.container.fileExtension)"),
                preset: preset, codecSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil,
                customInputArguments: [
                    "-framerate", "24", "-i", "/source/video.mov", "-i", "/source/audio.wav"
                ]
            )
            XCTAssertTrue(command.arguments.contains(encoder), "\(preset): standard command lost captured video encoder")
            XCTAssertTrue(command.arguments.contains("libopus"), "\(preset): standard command lost captured Opus audio")
            XCTAssertFalse(command.arguments.contains("+faststart"))
            XCTAssertEqual(command.arguments.last, "/output/video.mkv")
            XCTAssertEqual(CodecExportSettings(preset: preset, defaults: defaults)?.container, .mp4)
            let nativeCommand = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/native.mkv"),
                preset: preset, codecSettings: captured, width: 1280, height: 720,
                frameRate: 24, trimStart: nil, trimEnd: nil, includeDateTag: false
            )
            XCTAssertTrue(nativeCommand.arguments.contains(encoder), "\(preset): native waveform lost captured video encoder")
            XCTAssertTrue(nativeCommand.arguments.contains("libopus"), "\(preset): native waveform lost captured Opus audio")
            XCTAssertFalse(nativeCommand.arguments.contains("+faststart"))
        }
    }

    func testOpusFallbackAndHardwareEncodingUseInjectedPreferences() throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(CodecAudioFormat.opus.rawValue, forKey: AppConstants.h264AudioFormatKey)
        defaults.set(H264Encoder.hardware.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set("17M", forKey: AppConstants.h264BitrateKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.h264ResolutionLimitKey)
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))
        XCTAssertEqual(settings.container, .mov)
        XCTAssertEqual(settings.resolutionLimit, .r720)
        XCTAssertTrue(settings.ffmpegArguments.contains("h264_videotoolbox"))
        XCTAssertTrue(settings.ffmpegArguments.contains("17M"))
        XCTAssertTrue(settings.ffmpegArguments.contains("aac"))
        XCTAssertFalse(settings.ffmpegArguments.contains("libopus"))
        XCTAssertTrue(settings.ffmpegArguments.contains("+faststart"))
        XCTAssertNil(CodecExportSettings(preset: .audioOnly, defaults: defaults))
    }

    func testConverterUsesCapturedContainerForSourceCollisionAndEncoding() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h265ContainerKey)
        defaults.set(H265Encoder.hardware.rawValue, forKey: AppConstants.h265EncoderKey)
        let captured = try XCTUnwrap(CodecExportSettings(preset: .h265, defaults: defaults))
        defaults.removePersistentDomain(forName: suite)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try Data("source sentinel".utf8).write(to: source)
        let runner = CodecSettingsRecordingRunner()
        let finished = expectation(description: "Conversion completed")
        let request = ConversionRequest(
            inputURL: source, outputURL: source.deletingPathExtension(), preset: .h265,
            includeDateTag: false, expectedDuration: 1,
            customInputArguments: ["-framerate", "24", "-i", source.path, "-i", source.path]
        )
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        await converter.convert(
            request: request, codecSettings: captured,
            progressUpdate: { _, _ in }, completion: { _, _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 5)
        let recorded = await runner.request
        let args = try XCTUnwrap(recorded).arguments
        XCTAssertEqual(args.last, directory.appendingPathComponent("source_encoded.mov").path)
        let codecIndex = try XCTUnwrap(args.firstIndex(of: "-c:v"))
        XCTAssertEqual(args[codecIndex + 1], "hevc_videotoolbox")
        XCTAssertEqual(try Data(contentsOf: source), Data("source sentinel".utf8))
    }

}

private actor CodecSettingsRecordingRunner: SubprocessRunning {
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
