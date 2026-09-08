// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CommentSettingsTests: XCTestCase {
    func testConfiguredTimecodePlanSeparatesProbeFailureFromExplicitRemoval() async {
        let url = URL(fileURLWithPath: "/missing/source.mov")
        let failedPreservation = await FFMPEGCommandBuilder.configuredTimecodePlan(
            preset: .streamCopy, inputURL: url, timecodeConfig: TimecodeConfig(mode: .preserveSource),
            trimStart: nil, metadataProvider: { _ in nil }
        )
        XCTAssertEqual(failedPreservation, .unchanged)
        for (preset, config, expected) in [
            (ExportPreset.streamCopy, nil, TimecodeMetadataPlan.clear),
            (.streamCopy, TimecodeConfig(mode: .manual("")), .clear),
            (.streamCopy, TimecodeConfig(mode: .manual("10:20:30:12")), .set("10:20:30:12")),
            (.audioOnly, TimecodeConfig(mode: .preserveSource), .unchanged)
        ] {
            let plan = await FFMPEGCommandBuilder.configuredTimecodePlan(
                preset: preset, inputURL: url, timecodeConfig: config, trimStart: nil,
                metadataProvider: { _ in
                    XCTFail("This timecode policy must not probe its input")
                    return nil
                }
            )
            XCTAssertEqual(plan, expected)
        }
    }

    func testTimecodePlanOwnsBothTagsAndRemovesConflictingShortcut() {
        let original = [
            "-c:v", "copy", "-timecode", "01:00:00:00",
            "-metadata", "timecode=02:00:00:00",
            "-metadata:s:v:0", "timecode=03:00:00:00",
            "-metadata", "title=Keep", "-metadata:s:a:0", "language=nor"
        ]
        var arguments = original
        TimecodeMetadataPlan.unchanged.apply(to: &arguments)
        XCTAssertEqual(arguments, original)
        for plan in [TimecodeMetadataPlan.set("10:20:30:12"), .clear] {
            arguments = original
            plan.apply(to: &arguments)
            let value = plan == .clear ? "" : "10:20:30:12"
            XCTAssertEqual(arguments, [
                "-c:v", "copy", "-metadata", "title=Keep", "-metadata:s:a:0", "language=nor",
                "-metadata", "timecode=\(value)", "-metadata:s:v:0", "timecode=\(value)"
            ])
            let once = arguments
            plan.apply(to: &arguments)
            XCTAssertEqual(arguments, once)
        }
        XCTAssertEqual(TimecodeMetadataPlan(resolvedValue: nil), .clear)
        XCTAssertEqual(TimecodeMetadataPlan(resolvedValue: ""), .clear)
    }

    func testTimecodeOffsetsRejectNonfiniteAndOverflowingValues() {
        let original = "01:02:03:04"
        for rate in [Double.nan, .infinity, -.infinity, Double(Int.max), 0, -24, 0.25] {
            XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode(original, bySeconds: 1, frameRate: rate), original)
        }
        for offset in [Double.nan, .infinity, -.infinity, Double(Int.max), Double.greatestFiniteMagnitude] {
            XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode(original, bySeconds: offset, frameRate: 24), original)
        }
        for label in ["\(Int.max):00:00:00", "01:60:00:00", "01:00:60:00", "01:00:00:24", "-1:00:00:00"] {
            XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode(label, bySeconds: 1, frameRate: 24), label)
        }
        // Individually representable operands must also be safe when added together.
        let largeLabel = "100000000000000:00:00:00"
        XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode(largeLabel, bySeconds: 1e17, frameRate: 24), largeLabel)
    }

    func testTimecodeOffsetsWrapAtMidnightAndClampBeforeZero() {
        XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode("23:59:59:23", bySeconds: 1.0 / 24, frameRate: 24), "00:00:00:00")
        XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode("00:00:00:01", bySeconds: -1, frameRate: 24), "00:00:00:00")
        XCTAssertEqual(FFMPEGCommandBuilder.offsetTimecode("23:59:59;29", bySeconds: 1001.0 / 30000, frameRate: 30000.0 / 1001), "00:00:00;00")
    }

    func testDefaultsAndEmptyDatePrefixPreserveFormattingPolicy() throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CommentSettings(defaults: defaults)
        XCTAssertEqual(settings.separator, AppConstants.defaultCommentSeparator)
        XCTAssertEqual(settings.dateFormat, AppConstants.defaultCommentDateFormat)
        XCTAssertNil(FFMPEGCommandBuilder.commentMetadataValue(comment: " \n", includeDateTag: false, settings: settings))
        defaults.set("", forKey: AppConstants.dateTagPrefixKey)
        defaults.set("'fixed date'", forKey: AppConstants.commentDateFormatKey)
        XCTAssertEqual(FFMPEGCommandBuilder.commentMetadataValue(
            comment: "", includeDateTag: true, settings: CommentSettings(defaults: defaults)
        ), "\(AppConstants.defaultDateTagPrefix): fixed date")
        XCTAssertEqual(defaults.string(forKey: AppConstants.dateTagPrefixKey), "")
    }

    func testStandardSynthesizedAndNativeCommandsRetainCapturedFormatting() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("  Prefix \n", forKey: AppConstants.commentPrefixKey)
        defaults.set(" Suffix ", forKey: AppConstants.commentSuffixKey)
        defaults.set(" | ", forKey: AppConstants.commentSeparatorKey)
        defaults.set("'fixed date'", forKey: AppConstants.commentDateFormatKey)
        defaults.set("Created", forKey: AppConstants.dateTagPrefixKey)
        let settings = CommentSettings(defaults: defaults)
        let codec = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))
        await Task.yield()
        for key in [AppConstants.commentPrefixKey, AppConstants.commentSuffixKey,
                    AppConstants.commentSeparatorKey, AppConstants.commentDateFormatKey,
                    AppConstants.dateTagPrefixKey] {
            defaults.set("changed", forKey: key)
        }
        for synthesized in [false, true] {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/input.mov"),
                outputFileURL: URL(fileURLWithPath: "/output/result.mov"),
                preset: .prores, codecSettings: codec, commentSettings: settings,
                comment: " Body ", includeDateTag: true, trimStart: nil, trimEnd: nil,
                synthesizedVideoRequest: synthesized ? SynthesizedVideoRequest(
                    width: 640, height: 360, backgroundHex: "000000", frameRate: 24, includeAudio: true
                ) : nil
            )
            XCTAssertTrue(command.arguments.contains("comment=Created: fixed date | Prefix | Body | Suffix"))
        }
        let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: URL(fileURLWithPath: "/source/input.wav"),
            outputFileURL: URL(fileURLWithPath: "/output/result.mov"),
            preset: .prores, codecSettings: codec, commentSettings: settings,
            width: 640, height: 360, frameRate: 24, trimStart: nil, trimEnd: nil,
            comment: "Body", includeDateTag: true
        )
        XCTAssertTrue(native.arguments.contains("comment=Created: fixed date | Prefix | Body | Suffix"))
        var arguments = ["-metadata", "comment=old", "-metadata", "title=Keep"]
        FFMPEGCommandBuilder.applyCommentMetadata(
            to: &arguments, comment: "Body", includeDateTag: false, settings: settings
        )
        XCTAssertEqual(arguments, ["-metadata", "title=Keep", "-metadata", "comment=Prefix | Body | Suffix"])
    }
    func testConverterPassesCapturedCommentFormattingToCommand() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Captured", forKey: AppConstants.commentPrefixKey)
        let settings = CommentSettings(defaults: defaults)
        defaults.set("Changed", forKey: AppConstants.commentPrefixKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.mov")
        try Data("sentinel".utf8).write(to: source)
        let runner = CommentSettingsRunner()
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let finished = expectation(description: "Conversion completed")
        await converter.convert(
            request: ConversionRequest(
                inputURL: source, outputURL: directory.appendingPathComponent("output"), preset: .prores,
                includeDateTag: false, expectedDuration: 1,
                customInputArguments: ["-framerate", "24", "-i", source.path, "-i", source.path]
            ),
            commentSettings: settings,
            progressUpdate: { _, _ in }, completion: { _, _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 5)
        let recorded = await runner.request
        XCTAssertTrue(try XCTUnwrap(recorded).arguments.contains("comment=Captured"))
    }

}


private actor CommentSettingsRunner: SubprocessRunning {
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
