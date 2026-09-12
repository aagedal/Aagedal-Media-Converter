// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CodecExportSettingsTests: XCTestCase {
    func testGeneratedVideoSnapshotRetainsAppearanceAndPresetResolutionAfterSettingsChange() throws {
        let suite = "GeneratedVideoSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TVResolutionLimit.r720.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(24.0, forKey: AppConstants.audioWaveformFrameRateKey)
        defaults.set("#123456", forKey: AppConstants.audioWaveformBackgroundColorKey)
        defaults.set("abcdef", forKey: AppConstants.audioWaveformForegroundColorKey)
        defaults.set(true, forKey: AppConstants.audioWaveformNormalizeKey)
        let settings = GeneratedVideoSettings(preset: .tvHEVC, defaults: defaults)
        defaults.set(TVResolutionLimit.r2160.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(60.0, forKey: AppConstants.audioWaveformFrameRateKey)
        defaults.set("000000", forKey: AppConstants.audioWaveformBackgroundColorKey)

        var audio = generatedVideoItem(hasVideo: false, waveform: true)
        let waveform = try XCTUnwrap(settings.requests(for: [audio]).waveform)
        XCTAssertEqual(waveform.width, 1280)
        XCTAssertEqual(waveform.height, 720)
        XCTAssertEqual(waveform.frameRate, 24)
        XCTAssertEqual(waveform.backgroundHex, "123456")
        XCTAssertEqual(waveform.foregroundHex, "ABCDEF")
        XCTAssertTrue(waveform.normalizeAudio)
        audio.waveformVideoEnabled = false
        let synthesized = try XCTUnwrap(settings.requests(for: [audio]).synthesized)
        XCTAssertEqual(synthesized.width, waveform.width)
        XCTAssertEqual(synthesized.height, waveform.height)
        XCTAssertEqual(synthesized.frameRate, waveform.frameRate)
        XCTAssertEqual(synthesized.backgroundHex, waveform.backgroundHex)
    }

    func testGeneratedVideoSettingsUseInjectedPresetResolutionOverrides() throws {
        let suite = "GeneratedVideoSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TVResolutionLimit.r2160.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(ProxyResolutionLimit.r480.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
        defaults.set(DCPResolution.twoKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(IMFResolution.hd1080.rawValue, forKey: AppConstants.imfResolutionKey)
        let cases: [(ExportPreset, Int, Int)] = [
            (.tvHEVC, 3840, 2160), (.tvAVCIntra, 3840, 2160), (.proxy, 854, 480),
            (.dcp, 2048, 1080), (.imfJ2K, 1920, 1080), (.imfProRes, 1920, 1080)
        ]
        for (preset, width, height) in cases {
            let request = try XCTUnwrap(GeneratedVideoSettings(preset: preset, defaults: defaults)
                .requests(for: [generatedVideoItem(hasVideo: false, waveform: true)]).waveform)
            XCTAssertEqual(request.width, width, "\(preset)")
            XCTAssertEqual(request.height, height, "\(preset)")
        }
    }

    func testGeneratedVideoRequestSelectionSharesSingleAndMergeRoutingPolicy() throws {
        let suite = "GeneratedVideoSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GeneratedVideoSettings(preset: .h264, defaults: defaults)
        let audio = generatedVideoItem(hasVideo: false, waveform: true)
        let video = generatedVideoItem(hasVideo: true, waveform: false)
        XCTAssertNil(settings.requests(for: []).waveform)
        XCTAssertNil(settings.requests(for: []).synthesized)
        XCTAssertNil(settings.requests(for: [video]).waveform)
        XCTAssertNil(settings.requests(for: [video]).synthesized)
        XCTAssertNotNil(settings.requests(for: [audio]).waveform)
        XCTAssertNotNil(settings.requests(for: [video, audio]).waveform)
        XCTAssertNil(settings.requests(for: [video, audio]).synthesized)

        var split = audio
        split.audioRoutingConfig = AudioRoutingConfig(inputTracks: [
            AudioTrackInfo(streamIndex: 0, channels: 2, channelLayout: "stereo", codec: "aac",
                           codecLongName: nil, sampleRate: 48000)
        ])
        split.audioRoutingConfig?.channelOperation = .splitToMono(trackIndex: 0)
        for items in [[split], [audio, split], [video, split]] {
            XCTAssertNil(settings.requests(for: items).waveform)
            XCTAssertNil(settings.requests(for: items).synthesized)
        }
        let audioOnly = GeneratedVideoSettings(preset: .audioOnly, defaults: defaults)
        XCTAssertNil(audioOnly.requests(for: [generatedVideoItem(hasVideo: false, waveform: false)]).synthesized)
        let streamCopy = GeneratedVideoSettings(preset: .streamCopy, defaults: defaults)
        XCTAssertNil(streamCopy.requests(for: [audio]).waveform)
    }

    func testWaveformFrameRateRejectsNonfinitePreferences() {
        for value in [Double.nan, Double.infinity, -Double.infinity, 0] {
            XCTAssertEqual(AudioWaveformPreferences.sanitizeFrameRate(value), AppConstants.defaultAudioWaveformFrameRate)
        }
        XCTAssertEqual(AudioWaveformPreferences.sanitizeFrameRate(5), 10)
        XCTAssertEqual(AudioWaveformPreferences.sanitizeFrameRate(200), 120)
        XCTAssertEqual(AudioWaveformPreferences.sanitizeFrameRate(23.976), 23.976)
    }

    private func generatedVideoItem(hasVideo: Bool, waveform: Bool) -> VideoItem {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/source/audio.wav"), name: "audio", size: 0,
            duration: "1", thumbnailData: nil, status: .waiting, progress: 0, eta: nil, outputURL: nil
        )
        item.hasVideoStream = hasVideo
        item.waveformVideoEnabled = waveform
        return item
    }

    func testGeneratedVideoRoutingOwnsAudioMapsAndPreservesDuplicateOrder() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceTracks = [0, 2].map {
            AudioTrackInfo(streamIndex: $0, channels: 2, channelLayout: "stereo", codec: "aac",
                           codecLongName: nil, sampleRate: 48000)
        }
        let cases: [(AudioRoutingConfig?, [String]?, Bool)] = [
            (AudioRoutingConfig(inputTracks: sourceTracks, outputTrackIndices: [2]), ["a:2"], false),
            (AudioRoutingConfig(inputTracks: sourceTracks, outputTrackIndices: [2, 0, 2]), ["a:2", "a:0", "a:2"], false),
            (AudioRoutingConfig(inputTracks: sourceTracks, outputTracks: []), [], true),
            (AudioRoutingConfig(inputTracks: [], outputTracks: []), nil, false),
            (nil, nil, false)
        ]
        for enabled in [true, false] {
            defaults.set("-c:v libx264 -c:a aac", forKey: AppConstants.customPresetCommandKey(for: 0))
            defaults.set(enabled, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: 0))
            let settings = try XCTUnwrap(CodecExportSettings(preset: .custom1, defaults: defaults))
            defaults.set(!enabled, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: 0))
            for (routing, expectedRoutes, silent) in cases {
                let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                    audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
                    outputFileURL: URL(fileURLWithPath: "/output/native.mp4"),
                    preset: .custom1, codecSettings: settings, width: 1280, height: 720,
                    frameRate: 24, audioRoutingConfig: routing, trimStart: nil, trimEnd: nil,
                    includeDateTag: false
                )
                let synthesized = await FFMPEGCommandBuilder.buildCommand(
                    inputURL: URL(fileURLWithPath: "/source/audio.wav"),
                    outputFileURL: URL(fileURLWithPath: "/output/synthesized.mp4"),
                    preset: .custom1, codecSettings: settings, comment: "", includeDateTag: false,
                    trimStart: nil, trimEnd: 1, audioRoutingConfig: routing,
                    synthesizedVideoRequest: .init(width: 1280, height: 720, backgroundHex: "000000", frameRate: 24, includeAudio: true)
                )
                let nativeAudio = enabled ? expectedRoutes?.map { "1:\($0)" } ?? ["1:a"] : ["1:a"]
                let synthesizedAudio = enabled ? expectedRoutes?.map { "0:\($0)" } ?? ["0:a?"] : ["0:a?"]
                XCTAssertEqual(mappedStreams(in: native.arguments), ["0:v"] + nativeAudio)
                XCTAssertEqual(mappedStreams(in: synthesized.arguments), ["[synth_v]"] + synthesizedAudio)
                XCTAssertEqual(native.arguments.contains("-an"), enabled && silent)
                XCTAssertEqual(synthesized.arguments.contains("-an"), enabled && silent)
            }
        }
    }

    func testGeneratedVideoAudioSuppressionDoesNotAddRoutedMapsOrFilters() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("-c:v libx264 -c:a aac", forKey: AppConstants.customPresetCommandKey(for: 0))
        defaults.set(true, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: 0))
        let settings = try XCTUnwrap(CodecExportSettings(preset: .custom1, defaults: defaults))
        let routing = AudioRoutingConfig(
            inputTracks: [.init(streamIndex: 0, channels: 6, channelLayout: "5.1", codec: "aac",
                                codecLongName: nil, sampleRate: 48000)],
            outputTracks: [OutputTrack(streamIndex: 0, downmixToStereo: true)]
        )
        let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
            outputFileURL: URL(fileURLWithPath: "/output/native.mp4"),
            preset: .custom1, codecSettings: settings, width: 1280, height: 720,
            frameRate: 24, audioRoutingConfig: routing, trimStart: nil, trimEnd: nil,
            isMuted: true, includeDateTag: false
        )
        XCTAssertEqual(mappedStreams(in: native.arguments), ["0:v"])
        XCTAssertTrue(native.arguments.contains("-an"))
        XCTAssertFalse(native.arguments.contains { $0.contains("aresample") })
        for (includeAudio, muted) in [(false, false), (true, true)] {
            let synthesized = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/synthesized.mp4"),
                preset: .custom1, codecSettings: settings, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: 1, audioRoutingConfig: routing,
                synthesizedVideoRequest: .init(width: 1280, height: 720, backgroundHex: "000000", frameRate: 24, includeAudio: includeAudio),
                isMuted: muted
            )
            XCTAssertEqual(mappedStreams(in: synthesized.arguments), ["[synth_v]"])
            XCTAssertTrue(synthesized.arguments.contains("-an"))
            XCTAssertFalse(synthesized.arguments.contains { $0.contains("aresample") })
            XCTAssertTrue(synthesized.arguments.contains { $0.contains("[synth_v]") && $0.contains("color=") })
        }
    }

    private func mappedStreams(in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == "-map", arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    func testStreamCopyCapturesContainerAndMetadataPolicy() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(StreamCopyContainer.mkv.rawValue, forKey: AppConstants.streamCopyContainerKey)
        defaults.set(false, forKey: AppConstants.preserveMetadataPreferenceKey)
        let captured = try XCTUnwrap(CodecExportSettings(preset: .streamCopy, defaults: defaults))
        await Task.yield()
        defaults.set(StreamCopyContainer.mov.rawValue, forKey: AppConstants.streamCopyContainerKey)
        defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/video.mov"),
            outputFileURL: URL(fileURLWithPath: "/output/video.\(captured.outputExtension(for: nil))"),
            preset: .streamCopy, codecSettings: captured, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil,
            customInputArguments: ["-framerate", "24", "-i", "/source/video.mov", "-i", "/source/audio.wav"]
        )
        XCTAssertEqual(command.arguments.last, "/output/video.mkv")
        XCTAssertTrue(command.arguments.contains("copy"))
        XCTAssertTrue(command.arguments.contains("-copy_unknown"))
        XCTAssertTrue(command.arguments.contains("-0:s?"))
        let metadataIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-map_metadata"))
        XCTAssertEqual(command.arguments[metadataIndex + 1], "-1")
        XCTAssertFalse(captured.appliesCrop)
        XCTAssertFalse(captured.appliesAudioRouting)
        XCTAssertEqual(CodecExportSettings(preset: .streamCopy, defaults: defaults)?.fileExtension, "mov")
    }

    func testStreamCopyKeepsSourceExtensionAndInvalidPreferenceWithoutRewriting() throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw in [StreamCopyContainer.keepCurrent.rawValue, "Invalid container"] {
            defaults.set(raw, forKey: AppConstants.streamCopyContainerKey)
            let captured = try XCTUnwrap(CodecExportSettings(preset: .streamCopy, defaults: defaults))
            defaults.set(StreamCopyContainer.mp4.rawValue, forKey: AppConstants.streamCopyContainerKey)
            XCTAssertEqual(captured.outputExtension(for: URL(fileURLWithPath: "/source/file.MXF")), "mxf")
            XCTAssertEqual(captured.outputExtension(for: URL(fileURLWithPath: "/source/file")), "mp4")
            XCTAssertEqual(captured.outputExtension(for: nil), "mp4")
            XCTAssertEqual(captured.streamCopyContainer, .keepCurrent)
            defaults.set(raw, forKey: AppConstants.streamCopyContainerKey)
            _ = CodecExportSettings(preset: .streamCopy, defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: AppConstants.streamCopyContainerKey), raw)
        }
    }

    func testAllCustomSlotsCaptureCommandsExtensionsAndRoutingSwitches() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in ExportPreset.allCases where preset.isCustom {
            let slot = try XCTUnwrap(preset.customSlotIndex)
            defaults.set(" .M K V \n", forKey: AppConstants.customPresetExtensionKey(for: slot))
            defaults.set("-c:v libx264 -metadata title=\"Custom slot \(slot)\"", forKey: AppConstants.customPresetCommandKey(for: slot))
            defaults.set(true, forKey: AppConstants.customPresetApplyCropKey(for: slot))
            defaults.set(true, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: slot))
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            await Task.yield()
            defaults.removePersistentDomain(forName: suite)
            XCTAssertEqual(captured.fileExtension, "mkv")
            XCTAssertEqual(captured.container, .mkv)
            XCTAssertTrue(captured.appliesCrop)
            XCTAssertTrue(captured.appliesAudioRouting)
            let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/video.mkv"),
                preset: preset, codecSettings: captured, width: 1280, height: 720,
                frameRate: 24, trimStart: nil, trimEnd: nil, includeDateTag: false
            )
            XCTAssertTrue(command.arguments.contains("libx264"))
            XCTAssertTrue(command.arguments.contains("title=Custom slot \(slot)"))
            defaults.set(" \n", forKey: AppConstants.customPresetCommandKey(for: slot))
            defaults.set(" . ", forKey: AppConstants.customPresetExtensionKey(for: slot))
            let fallback = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            XCTAssertEqual(fallback.fileExtension, AppConstants.defaultCustomPresetExtensions[slot])
            XCTAssertEqual(fallback.ffmpegArguments, ["-hide_banner"] + ExportPreset.parseCustomCommand(AppConstants.defaultCustomPresetCommands[slot]))
            XCTAssertFalse(fallback.appliesCrop)
            XCTAssertFalse(fallback.appliesAudioRouting)
        }
    }

    func testCustomCropAndAudioRoutingUseCapturedOptInsInCommands() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = VideoMetadata(
            duration: 1, formatName: "mov", containerLongName: nil, sizeBytes: nil,
            bitRate: nil, comment: nil, timecode: nil, timecodes: [], frameCount: nil,
            containerCreationDate: nil, containerModificationDate: nil, title: nil, artist: nil,
            gpsLatitude: nil, gpsLongitude: nil, gpsAltitude: nil, warnings: [],
            videoStreams: [.init(
                codec: "h264", codecLongName: nil, profile: nil, width: 1920, height: 1080,
                pixelFormat: "yuv420p", hasAlpha: false, pixelAspectRatio: .init(numerator: 1, denominator: 1),
                displayAspectRatio: nil, frameRate: .init(double: 24), bitDepth: 8, bitRate: nil,
                duration: 1, chromaSubsampling: "4:2:0", colorPrimaries: nil, colorTransfer: nil,
                colorSpace: nil, colorRange: nil, chromaLocation: nil, fieldOrder: nil,
                isInterlaced: false, title: nil, isDefault: true, isForced: false
            )], audioStreams: [], subtitleStreams: []
        )
        let routing = AudioRoutingConfig(
            inputTracks: [0, 2].map {
                AudioTrackInfo(
                    streamIndex: $0, channels: 2, channelLayout: "stereo", codec: "aac",
                    codecLongName: nil, sampleRate: 48000
                )
            },
            outputTracks: [OutputTrack(streamIndex: 2)]
        )
        for enabled in [true, false] {
            defaults.set("-c:v libx264 -c:a aac", forKey: AppConstants.customPresetCommandKey(for: 0))
            defaults.set(enabled, forKey: AppConstants.customPresetApplyCropKey(for: 0))
            defaults.set(enabled, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: 0))
            let captured = try XCTUnwrap(CodecExportSettings(preset: .custom1, defaults: defaults))
            defaults.set(!enabled, forKey: AppConstants.customPresetApplyCropKey(for: 0))
            defaults.set(!enabled, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: 0))
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/video.mp4"),
                preset: .custom1, codecSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil, audioRoutingConfig: routing,
                cropConfig: CropConfig(normalizedRect: CropRect(x: 0.25, y: 0, width: 0.5, height: 1)),
                sourceMetadata: metadata
            )
            XCTAssertEqual(command.arguments.contains { $0.contains("crop=960:1080:480:0") }, enabled)
            XCTAssertEqual(command.arguments.contains("0:a:2"), enabled)
            let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/video.mp4"),
                preset: .custom1, codecSettings: captured, width: 1280, height: 720,
                frameRate: 24, audioRoutingConfig: routing, trimStart: nil, trimEnd: nil,
                includeDateTag: false
            )
            XCTAssertEqual(native.arguments.contains("1:a:2"), enabled)
        }
    }

    func testStreamCopyAndCustomConverterUseCapturedExtensionForSourceProtection() async throws {
        let suite = "CodecExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for preset in [ExportPreset.streamCopy, .custom1] {
            defaults.set(StreamCopyContainer.keepCurrent.rawValue, forKey: AppConstants.streamCopyContainerKey)
            defaults.set("mkv", forKey: AppConstants.customPresetExtensionKey(for: 0))
            defaults.set("-c copy", forKey: AppConstants.customPresetCommandKey(for: 0))
            let captured = try XCTUnwrap(CodecExportSettings(preset: preset, defaults: defaults))
            defaults.set(StreamCopyContainer.mp4.rawValue, forKey: AppConstants.streamCopyContainerKey)
            defaults.set("mp4", forKey: AppConstants.customPresetExtensionKey(for: 0))
            defaults.set("-c:v libx265", forKey: AppConstants.customPresetCommandKey(for: 0))
            let source = directory.appendingPathComponent("source.mkv")
            try Data("source sentinel".utf8).write(to: source)
            let runner = CodecSettingsRecordingRunner()
            let finished = expectation(description: "\(preset) command captured")
            let request = ConversionRequest(
                inputURL: source, outputURL: source.deletingPathExtension(), preset: preset,
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
            let arguments = try XCTUnwrap(recorded).arguments
            XCTAssertEqual(arguments.last, directory.appendingPathComponent("source_encoded.mkv").path)
            XCTAssertTrue(arguments.contains("copy"))
            XCTAssertFalse(arguments.contains("libx265"))
            XCTAssertEqual(try Data(contentsOf: source), Data("source sentinel".utf8))
        }
    }

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
            mcaDefaults: captured.avcIntraMCADefaults ?? .none,
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

final class SilentSynthesizedVideoTests: XCTestCase {
    func testSilentDurationUsesRemainingSourceAndRejectsUnknownOrExhaustedSources() async throws {
        for (sourceDuration, trimStart, expected) in [(Optional(8.0), Optional(3.0), Optional(5.0)), (nil, nil, nil), (Optional(Double.infinity), nil, nil), (Optional(2.0), Optional(3.0), nil)] {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/silent.mp4"),
                preset: .videoLoop, comment: "", includeDateTag: false,
                trimStart: trimStart, trimEnd: nil,
                synthesizedVideoRequest: .init(width: 64, height: 48, backgroundHex: "000000", frameRate: 24, includeAudio: false),
                durationProvider: { _ in sourceDuration }
            )
            XCTAssertEqual(command.effectiveDuration, expected)
            if let expected {
                XCTAssertNil(command.preparationError)
                let index = try XCTUnwrap(command.arguments.lastIndex(of: "-t"))
                XCTAssertEqual(Double(command.arguments[index + 1]), expected)
            } else {
                XCTAssertNotNil(command.preparationError)
                XCTAssertTrue(command.arguments.isEmpty)
            }
        }
    }

    func testExplicitTrimAndPreparedDurationDoNotProbeOrDoubleTrim() async throws {
        for (trimStart, trimEnd, hint, expected) in [(Optional(3.0), Optional(5.0), Optional(9.0), 2.0), (Optional(3.0), nil, Optional(2.0), 2.0)] {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/audio.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/silent.mp4"),
                preset: .videoLoop, comment: "", includeDateTag: false,
                trimStart: trimStart, trimEnd: trimEnd,
                synthesizedVideoRequest: .init(width: 64, height: 48, backgroundHex: "000000", frameRate: 24, includeAudio: true),
                synthesizedVideoDuration: hint, isMuted: true,
                durationProvider: { _ in XCTFail("A known duration must not be probed again"); return nil }
            )
            XCTAssertNil(command.preparationError)
            XCTAssertEqual(command.effectiveDuration, expected)
            let index = try XCTUnwrap(command.arguments.lastIndex(of: "-t"))
            XCTAssertEqual(Double(command.arguments[index + 1]), expected)
        }
    }

    func testConverterRejectsUnknownSilentDurationBeforeLaunchingEncoder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("unknown.wav")
        try Data("invalid audio fixture".utf8).write(to: source)
        let runner = CodecSettingsRecordingRunner()
        let finished = expectation(description: "Unknown duration rejected")
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let request = ConversionRequest(
            inputURL: source, outputURL: directory.appendingPathComponent("silent"), preset: .videoLoop,
            includeDateTag: false, isMuted: true,
            synthesizedVideoRequest: .init(width: 64, height: 48, backgroundHex: "000000", frameRate: 24, includeAudio: true)
        )
        await converter.convert(request: request, progressUpdate: { _, _ in }, completion: { success, reason in
            XCTAssertFalse(success)
            XCTAssertTrue(reason?.contains("duration") == true)
            finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 2)
        let recorded = await runner.request
        XCTAssertNil(recorded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("silent.mp4").path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(directory.appendingPathComponent("silent.mp4")))

        var retry = request
        retry.trimEnd = 1
        let retried = expectation(description: "Retry reaches encoder")
        await converter.convert(request: retry, progressUpdate: { _, _ in }, completion: { _, _ in retried.fulfill() })
        await fulfillment(of: [retried], timeout: 2)
        let retryRequest = await runner.request
        XCTAssertEqual(retryRequest?.arguments.last, directory.appendingPathComponent("silent.mp4").path)
    }

    func testRealSilentSynthesizedVideoFinishesWithTrimmedDuration() async throws {
        let executable = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let output = directory.appendingPathComponent("silent.mp4")
        let runner = SubprocessRunner()
        let fixture = try await runner.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", source.path],
            timeout: .seconds(15)
        ), outputHandler: nil)
        XCTAssertTrue(fixture.succeeded, fixture.standardErrorText)
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: source, outputFileURL: output, preset: .videoLoop,
            comment: "", includeDateTag: false, trimStart: 0.25, trimEnd: nil,
            synthesizedVideoRequest: .init(width: 64, height: 48, backgroundHex: "000000", frameRate: 24, includeAudio: true),
            isMuted: true
        )
        XCTAssertNil(command.preparationError)
        let result = try await runner.run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: executable), arguments: command.arguments, timeout: .seconds(15)
        ), outputHandler: nil)
        XCTAssertTrue(result.succeeded, result.standardErrorText)
        let duration = await FFMPEGProbeService.getVideoDuration(for: output)
        XCTAssertEqual(try XCTUnwrap(duration), 0.75, accuracy: 0.05)
        let streams = await FFMPEGProbeService.fetchAudioStreams(for: output)
        XCTAssertTrue(try XCTUnwrap(streams).isEmpty)
    }
}
