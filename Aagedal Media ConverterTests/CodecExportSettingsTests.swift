// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CodecExportSettingsTests: XCTestCase {
    func testBroadcastCommandsRetainCapturedFramerateResolutionAndClass() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in [ExportPreset.tvHEVC, .tvAVCIntra] {
            defaults.set(TVFramerateMode.p25.rawValue, forKey: AppConstants.tvFramerateModeKey)
            defaults.set(TVResolutionLimit.r720.rawValue, forKey: AppConstants.tvResolutionLimitKey)
            defaults.set(AVCIntraClass.class50.rawValue, forKey: AppConstants.avcIntraClassKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            defaults.set(TVFramerateMode.p50.rawValue, forKey: AppConstants.tvFramerateModeKey)
            defaults.set(TVResolutionLimit.r2160.rawValue, forKey: AppConstants.tvResolutionLimitKey)
            defaults.set(AVCIntraClass.class200.rawValue, forKey: AppConstants.avcIntraClassKey)
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/video.\(captured.fileExtension)"),
                preset: preset, codecSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil,
                customInputArguments: ["-framerate", "24", "-i", "/source/video.mov"]
            )
            let rateIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-r"))
            XCTAssertEqual(command.arguments[rateIndex + 1], "25")
            let bitrateIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-b:v"))
            XCTAssertEqual(command.arguments[bitrateIndex + 1], preset == .tvHEVC ? "8M" : "50M")
            let filterIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-vf"))
            XCTAssertTrue(command.arguments[filterIndex + 1].contains("1280"))
            XCTAssertTrue(command.arguments[filterIndex + 1].contains("720"))
            XCTAssertEqual(captured.fileExtension, preset == .tvHEVC ? "mov" : "mxf")
        }
    }

    func testAVCIntraAudioUsesCapturedChannelCountAcrossStreamProbe() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AVCIntraAudioChannels.ch4.rawValue, forKey: AppConstants.avcIntraAudioChannelsKey)
        let captured = try XCTUnwrap(CodecExportSettings(preset: .tvAVCIntra, defaults: defaults))
        var arguments = captured.ffmpegArguments
        await FFMPEGCommandBuilder.adjustArgumentsForInput(
            preset: .tvAVCIntra, codecSettings: captured,
            inputURL: URL(fileURLWithPath: "/source/video.mov"), ffmpegArgs: &arguments,
            trimStart: 0, trimEnd: 2,
            audioStreamProvider: { _ in
                // Use a fresh store handle so this Sendable closure captures only the suite name.
                UserDefaults(suiteName: suite)?.set(
                    AVCIntraAudioChannels.ch16.rawValue, forKey: AppConstants.avcIntraAudioChannelsKey
                )
                await Task.yield()
                return []
            }
        )
        let filterIndex = try XCTUnwrap(arguments.firstIndex(of: "-filter_complex"))
        XCTAssertTrue(arguments[filterIndex + 1].contains("asplit=4"))
        XCTAssertFalse(arguments[filterIndex + 1].contains("asplit=16"))
        XCTAssertEqual(arguments.filter { $0.hasPrefix("[silent") }.count, 4)
        XCTAssertEqual(CodecExportSettings(preset: .tvAVCIntra, defaults: defaults)?.avcIntraAudioChannels, .ch16)
    }

    func testAVCIntraLabelsRetainCapturedTrackCountAcrossProbe() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AVCIntraAudioChannels.ch4.rawValue, forKey: AppConstants.avcIntraAudioChannelsKey)
        let captured = try XCTUnwrap(CodecExportSettings(preset: .tvAVCIntra, defaults: defaults))
        let labelsURL = await FFMPEGConverter.prepareAVCIntraMCALabelsFile(
            inputURL: URL(fileURLWithPath: "/source/video.mov"),
            audioRoutingConfig: AudioRoutingConfig(inputTracks: [], outputTracks: (0..<3).map {
                OutputTrack(streamIndex: $0, mcaOverride: MCALabelOverride(soundfield: .stereo))
            }),
            targetChannelCount: try XCTUnwrap(captured.avcIntraAudioChannels).count,
            audioStreamProvider: { _ in
                UserDefaults(suiteName: suite)?.set(
                    AVCIntraAudioChannels.ch16.rawValue, forKey: AppConstants.avcIntraAudioChannelsKey
                )
                await Task.yield()
                return (0..<3).map {
                    .init(index: $0, channels: 2, channelLayout: "stereo", codecName: "pcm_s24le")
                }
            }
        )
        let url = try XCTUnwrap(labelsURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let labels = try String(contentsOf: url, encoding: .utf8)
        let labeledTrackIndices = labels.split(separator: "\n").compactMap { Int($0) }
        XCTAssertEqual(labeledTrackIndices, [0, 1, 2, 3])
        XCTAssertEqual(CodecExportSettings(preset: .tvAVCIntra, defaults: defaults)?.avcIntraAudioChannels, .ch16)
    }

    func testAnimatedFormatsAndProxyCodecsCaptureMatchingOutputExtensions() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for format in AnimatedStillFormat.allCases {
            defaults.set(format.rawValue, forKey: AppConstants.animatedStillFormatKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: .animatedStill, defaults: defaults))
            defaults.set("Invalid format", forKey: AppConstants.animatedStillFormatKey)
            XCTAssertEqual(captured.fileExtension, format.fileExtension)
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/video.\(captured.fileExtension)"),
                preset: .animatedStill, codecSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil,
                customInputArguments: ["-framerate", "24", "-i", "/source/video.mov"]
            )
            switch format {
            case .avif: XCTAssertTrue(command.arguments.contains("libsvtav1"))
            case .gif: XCTAssertTrue(command.arguments.contains { $0.contains("palettegen") })
            case .apng: XCTAssertTrue(command.arguments.contains("-plays"))
            case .jpegXL: XCTAssertTrue(command.arguments.contains("libjxl_anim"))
            case .webp: XCTAssertTrue(command.arguments.contains("libwebp"))
            }
            XCTAssertTrue(captured.ffmpegArguments.contains("-an"))
        }
        for (codec, encoder) in [(ProxyCodec.hevc, "hevc_videotoolbox"), (.prores, "prores_videotoolbox"), (.dnxhd, "dnxhd")] {
            defaults.set(codec.rawValue, forKey: AppConstants.proxyCodecKey)
            defaults.set(ProxyResolutionLimit.r480.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: .proxy, defaults: defaults))
            defaults.set("Invalid codec", forKey: AppConstants.proxyCodecKey)
            defaults.set(ProxyResolutionLimit.source.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
            XCTAssertEqual(captured.fileExtension, codec.fileExtension)
            XCTAssertTrue(captured.ffmpegArguments.contains(encoder))
            let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/proxy.\(captured.fileExtension)"),
                preset: .proxy, codecSettings: captured, width: 1280, height: 720,
                frameRate: 24, trimStart: nil, trimEnd: nil, includeDateTag: false
            )
            XCTAssertTrue(command.arguments.contains(encoder))
            let filterIndex = try XCTUnwrap(captured.ffmpegArguments.firstIndex(of: "-vf"))
            XCTAssertTrue(captured.ffmpegArguments[filterIndex + 1].contains("480"))
        }
        let fallbackProxy = try XCTUnwrap(CodecExportSettings(preset: .proxy, defaults: defaults))
        let fallbackStill = try XCTUnwrap(CodecExportSettings(preset: .animatedStill, defaults: defaults))
        XCTAssertEqual(fallbackProxy.fileExtension, "mov")
        XCTAssertTrue(fallbackProxy.ffmpegArguments.contains("hevc_videotoolbox"))
        XCTAssertEqual(fallbackStill.fileExtension, "avif")
        XCTAssertEqual(defaults.string(forKey: AppConstants.proxyCodecKey), "Invalid codec")
        XCTAssertEqual(defaults.string(forKey: AppConstants.animatedStillFormatKey), "Invalid format")
    }

    func testConverterUsesCapturedMXFProxyAndWebPFormatAfterPreferencesChange() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (preset, encoder, extensionName) in [(ExportPreset.proxy, "dnxhd", "mxf"), (.animatedStill, "libwebp", "webp")] {
            defaults.set(ProxyCodec.dnxhd.rawValue, forKey: AppConstants.proxyCodecKey)
            defaults.set(AnimatedStillFormat.webp.rawValue, forKey: AppConstants.animatedStillFormatKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            defaults.set(ProxyCodec.hevc.rawValue, forKey: AppConstants.proxyCodecKey)
            defaults.set(AnimatedStillFormat.gif.rawValue, forKey: AppConstants.animatedStillFormatKey)
            let source = directory.appendingPathComponent("source.\(extensionName)")
            try Data("source sentinel".utf8).write(to: source)
            let runner = CodecSettingsRecordingRunner()
            let finished = expectation(description: "\(preset) conversion completed")
            let request = ConversionRequest(
                inputURL: source, outputURL: source.deletingPathExtension(), preset: preset,
                includeDateTag: false, expectedDuration: 1,
                customInputArguments: ["-framerate", "24", "-i", source.path]
            )
            let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
            await converter.convert(
                request: request, codecSettings: captured,
                progressUpdate: { _, _ in }, completion: { _, _ in finished.fulfill() }
            )
            await fulfillment(of: [finished], timeout: 5)
            let recorded = await runner.request
            let args = try XCTUnwrap(recorded).arguments
            XCTAssertEqual(args.last, directory.appendingPathComponent("source_encoded.\(extensionName)").path)
            XCTAssertTrue(args.contains(encoder))
            XCTAssertEqual(try Data(contentsOf: source), Data("source sentinel".utf8))
        }
    }

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
            let output = URL(fileURLWithPath: "/output/video.\(captured.fileExtension)")
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
                outputFileURL: URL(fileURLWithPath: "/output/video.\(captured.fileExtension)"),
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
