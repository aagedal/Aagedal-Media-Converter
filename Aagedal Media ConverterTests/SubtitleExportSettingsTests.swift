// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class SubtitleExportSettingsTests: XCTestCase {
    func testPlanKeepsMapAndCodecTogetherForSupportedContainers() {
        XCTAssertEqual(SubtitleMappingPlan(keepSubtitles: true, outputExtension: "MKV"), .copy)
        for ext in ["mov", "MP4"] {
            XCTAssertEqual(SubtitleMappingPlan(keepSubtitles: true, outputExtension: ext), .quickTimeText)
        }
        for ext in ["mxf", "png", "ivf", "wav", ""] {
            XCTAssertEqual(SubtitleMappingPlan(keepSubtitles: true, outputExtension: ext).arguments, [])
        }
        XCTAssertEqual(SubtitleMappingPlan(keepSubtitles: false, outputExtension: "mkv"), .omit)
        XCTAssertEqual(SubtitleMappingPlan.copy.arguments, ["-map", "0:s?", "-c:s", "copy"])
        XCTAssertEqual(SubtitleMappingPlan.quickTimeText.arguments, ["-map", "0:s?", "-c:s", "mov_text"])
    }

    func testSettingsDefaultAndCapturedCommandsRemainIndependentOfLaterEdits() async throws {
        let suite = "SubtitleExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SubtitleExportSettings(defaults: defaults).keepSubtitles)
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        let captured = SubtitleExportSettings(defaults: defaults)
        defaults.set(false, forKey: AppConstants.keepSubtitlesKey)
        for (preset, ext, codec) in [(ExportPreset.h264, "mp4", "mov_text"), (.h265, "mkv", "copy"), (.streamCopy, "mov", "")] {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/video.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/video.\(ext)"),
                preset: preset, subtitleSettings: captured,
                comment: "", includeDateTag: false, trimStart: nil, trimEnd: nil,
                customInputArguments: ["-framerate", "24", "-i", "/source/video.mov", "-i", "/source/audio.wav"]
            )
            if codec.isEmpty {
                XCTAssertFalse(command.arguments.contains("-c:s"))
            } else {
                let index = try XCTUnwrap(command.arguments.firstIndex(of: "-c:s"))
                XCTAssertEqual(command.arguments[index + 1], codec)
                XCTAssertEqual(command.arguments.filter { $0 == "0:s?" }.count, 1)
            }
        }
        XCTAssertFalse(SubtitleExportSettings(defaults: defaults).keepSubtitles)
    }

    func testConverterPassesCapturedSubtitlePolicyToCommand() async throws {
        let suite = "SubtitleExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        let settings = SubtitleExportSettings(defaults: defaults)
        defaults.set(false, forKey: AppConstants.keepSubtitlesKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.mov")
        try Data("sentinel".utf8).write(to: source)
        let runner = SubtitleSettingsRunner()
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let finished = expectation(description: "Conversion completed")
        await converter.convert(
            request: ConversionRequest(
                inputURL: source, outputURL: directory.appendingPathComponent("output"), preset: .h264,
                includeDateTag: false, expectedDuration: 1,
                customInputArguments: ["-framerate", "24", "-i", source.path, "-i", source.path]
            ),
            subtitleSettings: settings,
            progressUpdate: { _, _ in }, completion: { _, _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 5)
        let recorded = await runner.request
        let args = try XCTUnwrap(recorded).arguments
        XCTAssertTrue(args.contains("0:s?"))
        XCTAssertTrue(args.contains("-c:s"))
    }
}

private actor SubtitleSettingsRunner: SubprocessRunning {
    private(set) var request: SubprocessRequest?

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        self.request = request
        return SubprocessResult(
            terminationStatus: 1, termination: .exited, standardOutput: Data(),
            standardError: Data("Stopped after command capture".utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
