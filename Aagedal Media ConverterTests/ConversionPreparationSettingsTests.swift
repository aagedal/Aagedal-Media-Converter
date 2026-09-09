// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import os
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionPreparationSettingsTests: XCTestCase {
    func testDestinationDefaultsAndMalformedModePreservePreferences() throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = URL(fileURLWithPath: "/source/clip.mov")
        XCTAssertNil(OutputDestinationSettings(defaults: defaults).resolveFolder(
            for: source, defaultOutputFolder: nil, presetSuffix: "_custom"
        ))
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalSubfolderKey)
        defaults.set("removed-mode", forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
        let settings = OutputDestinationSettings(defaults: defaults)
        XCTAssertEqual(settings.resolveFolder(for: source, defaultOutputFolder: "/output", presetSuffix: "_custom"), "/source/Encoded")
        XCTAssertEqual(defaults.string(forKey: AppConstants.saveNextToOriginalSubfolderModeKey), "removed-mode")
        defaults.set("", forKey: AppConstants.saveNextToOriginalSubfolderNameKey)
        XCTAssertEqual(OutputDestinationSettings(defaults: defaults).resolveFolder(
            for: source, defaultOutputFolder: "/output", presetSuffix: "_custom"
        ), "/source")
    }

    func testAggregateSnapshotKeepsGeneratedGeometryEncodingAndDestinationTogether() throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TVResolutionLimit.r720.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalSubfolderKey)
        defaults.set("presetSuffix", forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        defaults.set("Original", forKey: AppConstants.commentPrefixKey)
        let settings = ConversionPreparationSettings(preset: .tvHEVC, defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        var audio = item(url: URL(fileURLWithPath: "/source/audio.wav"))
        audio.hasVideoStream = false
        audio.waveformVideoEnabled = true
        let generated = try XCTUnwrap(settings.generatedVideo.requests(for: [audio]).waveform)
        XCTAssertEqual(generated.width, 1280)
        XCTAssertEqual(generated.height, 720)
        XCTAssertEqual(settings.fileNameContext.resolution, "720p")
        XCTAssertTrue(try XCTUnwrap(settings.codec).ffmpegArguments.contains(where: { $0.contains("720") }))
        XCTAssertTrue(settings.subtitles.keepSubtitles)
        XCTAssertEqual(settings.comment.prefix, "Original")
        XCTAssertEqual(settings.outputDestination.resolveFolder(
            for: audio.url, defaultOutputFolder: "/output", presetSuffix: settings.fileNameContext.presetSuffix
        ), "/source/\(settings.fileNameContext.presetSuffix.dropFirst())")
    }

    func testImageSequenceContextUsesPreparedRateAndCapturedLabels() throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ImageSequenceFormat.jpeg.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        let settings = ConversionPreparationSettings(preset: .imageSequence, defaults: defaults)
        defaults.set(ImageSequenceFormat.png.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        let context = settings.namingContext(preset: .imageSequence, imageSequenceFrameRate: 23.976)
        XCTAssertEqual(context.framerate, "23.976")
        XCTAssertEqual(context.presetSuffix, settings.fileNameContext.presetSuffix)
        XCTAssertEqual(settings.imageSequence?.format, .jpeg)
        XCTAssertEqual(settings.namingContext(preset: .imageSequence, imageSequenceFrameRate: .infinity).framerate, "")
    }

    @MainActor
    func testManagerKeepsSettingsCapturedBeforeDetailsLoadingThroughCommandAndNaming() async throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("-c:v copy", forKey: AppConstants.customPresetCommandKey(for: 0))
        defaults.set("mov", forKey: AppConstants.customPresetExtensionKey(for: 0))
        defaults.set("_captured", forKey: AppConstants.customPresetSuffixKey(for: 0))
        defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalSubfolderKey)
        defaults.set("presetSuffix", forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
        defaults.set("Before", forKey: AppConstants.commentPrefixKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try Data("source sentinel".utf8).write(to: source)
        let captured = OSAllocatedUnfairLock(initialState: false)
        let gate = SettingsPreparationDetailsGate()
        let started = expectation(description: "Details loading suspended")
        let runner = SettingsPreparationRecordingRunner()
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let manager = ConversionManager(
            ffmpegConverter: converter,
            preparationSettingsProvider: { preset in
                captured.withLock { $0 = true }
                return ConversionPreparationSettings(preset: preset, defaults: UserDefaults(suiteName: suite)!)
            },
            conversionDetailsLoader: { _, _, _ in await gate.wait(started: started) }
        )
        let queue = SettingsPreparationQueue(items: [item(url: source)])
        let binding = queue.binding
        let task = Task {
            await manager.startConversion(droppedFiles: binding, outputFolder: directory.appendingPathComponent("elsewhere").path, preset: .custom1)
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(captured.withLock { $0 }, "Settings must be captured before the details loader suspends")
        defaults.set("-c:v libx264", forKey: AppConstants.customPresetCommandKey(for: 0))
        defaults.set("mp4", forKey: AppConstants.customPresetExtensionKey(for: 0))
        defaults.set("_changed", forKey: AppConstants.customPresetSuffixKey(for: 0))
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set("After", forKey: AppConstants.commentPrefixKey)
        await gate.finish()
        await task.value
        let requests = await runner.requests
        let command = try XCTUnwrap(requests.last).arguments
        XCTAssertEqual(command.last, directory.appendingPathComponent("captured/source_captured.mov").path)
        XCTAssertEqual(command[try XCTUnwrap(command.firstIndex(of: "-c:v")) + 1], "copy")
        XCTAssertTrue(command.contains(where: { $0.contains("Before") }))
        XCTAssertFalse(command.contains(where: { $0.contains("After") }))
        XCTAssertEqual(try Data(contentsOf: source), Data("source sentinel".utf8))
    }

    func testImportDefaultsAndTimecodeModesDoNotRewriteMalformedPreferences() throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Named suites still see the app's registration domain, which enables
        // waveform video. Set explicit fixture values instead of assuming absence.
        defaults.set(false, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set(false, forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)
        let initial = VideoImportSettings(defaults: defaults)
        XCTAssertFalse(initial.includeDateTag)
        XCTAssertFalse(initial.waveformVideoEnabled)
        XCTAssertEqual(initial.timecode, TimecodeConfig(mode: .preserveSource))
        defaults.set("disabled", forKey: AppConstants.defaultTimecodeModeKey)
        XCTAssertNil(VideoImportSettings(defaults: defaults).timecode)
        defaults.set("preserveSource", forKey: AppConstants.defaultTimecodeModeKey)
        XCTAssertEqual(VideoImportSettings(defaults: defaults).timecode, TimecodeConfig(mode: .preserveSource))
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        XCTAssertEqual(VideoImportSettings(defaults: defaults).timecode,
                       TimecodeConfig(mode: .manual(AppConstants.defaultTimecodeValue)))
        defaults.set("removed-mode", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("invalid timecode", forKey: AppConstants.defaultTimecodeValueKey)
        XCTAssertNil(VideoImportSettings(defaults: defaults).timecode)
        XCTAssertEqual(defaults.string(forKey: AppConstants.defaultTimecodeModeKey), "removed-mode")
        XCTAssertEqual(defaults.string(forKey: AppConstants.defaultTimecodeValueKey), "invalid timecode")
    }

    @MainActor
    func testSequenceImportAndResetReuseCapturedDefaultsWithExistingResetPolicy() throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set(true, forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("01:02:03:04", forKey: AppConstants.defaultTimecodeValueKey)
        let settings = VideoImportSettings(defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        let config = ImageSequenceConfig(
            pattern: "frame_%04d.png", directory: URL(fileURLWithPath: "/fixture/frames"),
            startNumber: 1, endNumber: 24, frameRate: 24, imageFormat: .png
        )
        var imported = VideoFileUtils.makePlaceholderItem(
            fromImageSequence: config, settings: settings, reserveCounter: { nil }
        )
        XCTAssertTrue(imported.includeDateTag)
        XCTAssertFalse(imported.waveformVideoEnabled, "Image sequences retain their own picture input")
        XCTAssertEqual(imported.timecodeConfig, TimecodeConfig(mode: .manual("01:02:03:04")))
        imported.includeDateTag = false
        imported.clearUserSettings(settings: settings)
        XCTAssertTrue(imported.includeDateTag)
        XCTAssertNil(imported.timecodeConfig, "Reset continues clearing explicit timecode")
    }

    @MainActor
    func testAsyncImportKeepsCapturedDefaultsWhileMetadataLoadingSuspends() async throws {
        let suite = "ConversionPreparationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set(true, forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("10:00:00:00", forKey: AppConstants.defaultTimecodeValueKey)
        let settings = VideoImportSettings(defaults: defaults)
        let gate = SettingsPreparationDetailsGate()
        let started = expectation(description: "Import details suspended")
        let task = Task {
            await VideoFileUtils.createVideoItem(
                from: URL(fileURLWithPath: "/fixture/audio.wav"), settings: settings,
                reserveCounter: { nil }, detailsLoader: { _, _, _, _, _ in await gate.wait(started: started) }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        defaults.set(false, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set(false, forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)
        defaults.set("disabled", forKey: AppConstants.defaultTimecodeModeKey)
        await gate.finish()
        let result = await task.value
        let imported = try XCTUnwrap(result)
        XCTAssertTrue(imported.detailsLoaded)
        XCTAssertTrue(imported.includeDateTag)
        XCTAssertTrue(imported.waveformVideoEnabled)
        XCTAssertEqual(imported.timecodeConfig, TimecodeConfig(mode: .manual("10:00:00:00")))
        XCTAssertEqual(imported.size, 15)
        XCTAssertFalse(VideoImportSettings(defaults: defaults).includeDateTag)
    }

    @MainActor
    func testImportPreviewKeepsNamingDestinationAndContainerSnapshot() async throws {
        let suite = "ImportPreviewSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("before_{sourceName}_{counter}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(2, forKey: AppConstants.customFileNameCounterPaddingKey)
        defaults.set(false, forKey: AppConstants.fileNameIncludePresetSuffixKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalSubfolderKey)
        defaults.set("custom", forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
        defaults.set("captured", forKey: AppConstants.saveNextToOriginalSubfolderNameKey)
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        let naming = VideoImportNamingSettings(preset: .h264, defaults: defaults)
        let gate = SettingsPreparationDetailsGate()
        let started = expectation(description: "Naming suspended")
        let task = Task {
            await VideoFileUtils.createVideoItem(
                from: URL(fileURLWithPath: "/fixture/clip.mp4"), preset: .h264,
                namingSettings: naming, reserveCounter: { 7 },
                detailsLoader: { url, folder, preset, counter, captured in
                    let details = await gate.wait(started: started)
                    return VideoFileUtils.VideoItemDetails(
                        size: details.size, duration: details.duration, durationSeconds: details.durationSeconds,
                        thumbnailData: nil,
                        outputURL: VideoFileUtils.makeOutputURL(
                            for: url, outputFolder: folder, preset: preset, counter: counter, namingSettings: captured
                        ), hasVideoStream: true, metadata: nil
                    )
                }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        defaults.set("after", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(CodecContainer.mp4.rawValue, forKey: AppConstants.h264ContainerKey)
        await gate.finish()
        let imported = await task.value
        XCTAssertEqual(imported?.outputURL?.path, "/fixture/captured/before_clip_07.mov")
        XCTAssertEqual(imported?.customCounterValue, 7)
    }

    func testImportImageSequenceFrameRateUsesMetadataWithCapturedTemplate() throws {
        let suite = "ImportPreviewSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{framerate}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(false, forKey: AppConstants.fileNameIncludePresetSuffixKey)
        defaults.set(false, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(ImageSequenceFormat.png.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        let naming = VideoImportNamingSettings(preset: .imageSequence, defaults: defaults)
        defaults.set("after", forKey: AppConstants.customFileNameTemplateKey)
        let output = VideoFileUtils.makeOutputURL(
            for: URL(fileURLWithPath: "/fixture/clip.mov"), outputFolder: "/output", preset: .imageSequence,
            imageSequenceFrameRate: 24, namingSettings: naming
        )
        XCTAssertEqual(output?.path, "/output/clip_24.png")
    }

    private func item(url: URL) -> VideoItem {
        VideoItem(url: url, name: url.lastPathComponent, size: 0, duration: "1", durationSeconds: 1,
                  status: .waiting, progress: 0, eta: nil, outputURL: nil, includeDateTag: false)
    }
}

private final class SettingsPreparationQueue: Sendable {
    private let storage: OSAllocatedUnfairLock<[VideoItem]>
    init(items: [VideoItem]) { storage = OSAllocatedUnfairLock(initialState: items) }
    var binding: Binding<[VideoItem]> {
        Binding(get: { self.storage.withLock { $0 } }, set: { items in self.storage.withLock { $0 = items } })
    }
}

private actor SettingsPreparationDetailsGate {
    private var continuation: CheckedContinuation<VideoFileUtils.VideoItemDetails, Never>?
    func wait(started: XCTestExpectation) async -> VideoFileUtils.VideoItemDetails {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish() {
        continuation?.resume(returning: VideoFileUtils.VideoItemDetails(
            size: 15, duration: "1", durationSeconds: 1, thumbnailData: nil,
            outputURL: nil, hasVideoStream: true, metadata: nil
        ))
        continuation = nil
    }
}

private actor SettingsPreparationRecordingRunner: SubprocessRunning {
    private(set) var requests: [SubprocessRequest] = []
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        requests.append(request)
        return SubprocessResult(
            terminationStatus: 1, termination: .exited, standardOutput: Data(),
            standardError: Data("Stopped after command capture".utf8), discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
