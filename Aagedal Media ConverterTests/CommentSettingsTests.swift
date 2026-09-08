// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CommentSettingsTests: XCTestCase {
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
