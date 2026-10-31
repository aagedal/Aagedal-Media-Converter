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

    func testAttachmentPlanCopiesFontsAlongsideMatroskaSubtitles() {
        XCTAssertEqual(
            SubtitleAttachmentPlan(subtitlePlan: .copy, stripsStreamMetadata: false, attachmentCount: nil).arguments,
            ["-map", "0:t?", "-c:t", "copy"]
        )
        XCTAssertEqual(
            SubtitleAttachmentPlan(subtitlePlan: .copy, stripsStreamMetadata: true, attachmentCount: 2).arguments,
            ["-map", "0:t:0", "-map", "0:t:1", "-c:t", "copy",
             "-map_metadata:s:t:0", "0:s:t:0", "-map_metadata:s:t:1", "0:s:t:1"]
        )
        // Without a known count, untagged attachments would make the Matroska muxer fail.
        for count in [nil, 0] {
            XCTAssertEqual(SubtitleAttachmentPlan(subtitlePlan: .copy, stripsStreamMetadata: true, attachmentCount: count), .omit)
        }
        for plan in [SubtitleMappingPlan.omit, .quickTimeText] {
            XCTAssertEqual(SubtitleAttachmentPlan(subtitlePlan: plan, stripsStreamMetadata: false, attachmentCount: 3), .omit)
        }
        // FFmpeg demuxes cover art as an attached-picture video stream, so `0:t:N` must skip it.
        XCTAssertEqual(
            SubtitleAttachmentPlan.ffmpegAttachmentStreamCount(
                mimeTypes: ["image/jpeg", "application/x-truetype-font", "image/png", "font/otf", "application/vnd.ms-opentype"]
            ),
            3
        )
        XCTAssertEqual(SubtitleAttachmentPlan.ffmpegAttachmentStreamCount(mimeTypes: ["image/jpeg"]), 0)
        XCTAssertTrue(SubtitleAttachmentPlan.stripsStreamMetadata(["-c:v", "libx265", "-map_metadata", "-1"]))
        XCTAssertTrue(SubtitleAttachmentPlan.stripsStreamMetadata(["-map_metadata:s", "-1"]))
        XCTAssertFalse(SubtitleAttachmentPlan.stripsStreamMetadata(["-map_metadata", "0", "-map_metadata:g", "-1"]))
    }

    func testStrippedMatroskaCommandRestoresAttachmentTagsAfterMetadataPolicy() async throws {
        let suite = "SubtitleExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        defaults.set(false, forKey: AppConstants.preserveMetadataPreferenceKey(for: .h265))
        var metadata = VideoMetadata(
            duration: 1, formatName: "matroska", containerLongName: nil, sizeBytes: nil,
            bitRate: nil, comment: nil, timecode: nil, timecodes: [], frameCount: nil,
            containerCreationDate: nil, containerModificationDate: nil, title: nil, artist: nil,
            gpsLatitude: nil, gpsLongitude: nil, gpsAltitude: nil, warnings: [],
            videoStreams: [], audioStreams: [], subtitleStreams: []
        )
        metadata.attachmentCount = 1
        metadata.attachmentStreamCount = 1
        let codecSettings = try XCTUnwrap(CodecExportSettings(preset: .h265, defaults: defaults))
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/episode.mkv"),
            outputFileURL: URL(fileURLWithPath: "/output/episode.mkv"),
            preset: .h265,
            codecSettings: codecSettings,
            subtitleSettings: SubtitleExportSettings(defaults: defaults),
            comment: "", includeDateTag: false, trimStart: nil, trimEnd: nil,
            sourceMetadata: metadata
        )
        let args = command.arguments
        let strip = try XCTUnwrap(args.firstIndex(of: "-map_metadata"))
        XCTAssertEqual(args[strip + 1], "-1")
        let restore = try XCTUnwrap(args.firstIndex(of: "-map_metadata:s:t:0"))
        XCTAssertGreaterThan(restore, strip)
        XCTAssertEqual(args[restore + 1], "0:s:t:0")
        XCTAssertTrue(args.contains("0:t:0"))
        XCTAssertFalse(args.contains("0:t:1"))
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
