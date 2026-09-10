// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class CommentSettingsTests: XCTestCase {
    func testOutputMetadataPoliciesPreserveOpaqueInputOptions() {
        let input = [
            "-timecode", "01:00:00:00", "-metadata", "comment=Input",
            "-metadata:s:v:0", "timecode=02:00:00:00", "-i", "source.mov"
        ]
        let output = [
            "-c:v", "copy", "-timecode", "03:00:00:00",
            "-metadata", "comment=Old", "-metadata", "timecode=04:00:00:00",
            "-metadata:s:v:0", "timecode=05:00:00:00", "-metadata", "title=Keep"
        ]
        for source in [SourceMetadataPlan.unchanged, .strip, .preserve(input: 0)] {
            for comment in [CommentMetadataPlan.source, .set("New")] {
                for timecode in [TimecodeMetadataPlan.clear, .set("10:00:00:00")] {
                    let plan = OutputMetadataPlan(source: source, comment: comment, timecode: timecode)
                    var arguments = input + output
                    plan.apply(to: &arguments, outputArgumentsStart: input.count)
                    XCTAssertEqual(Array(arguments.prefix(input.count)), input)
                    let rendered = Array(arguments.dropFirst(input.count))
                    XCTAssertFalse(rendered.contains("-timecode"))
                    XCTAssertFalse(rendered.contains("comment=Old"))
                    XCTAssertTrue(rendered.contains("title=Keep"))
                    XCTAssertEqual(Self.values(for: "-metadata:s:v:0", in: rendered).filter { $0.hasPrefix("timecode=") },
                                   [timecode == .clear ? "timecode=" : "timecode=10:00:00:00"])
                    XCTAssertEqual(rendered.contains("comment=New"), comment == .set("New"))
                    let once = arguments
                    plan.apply(to: &arguments, outputArgumentsStart: input.count)
                    XCTAssertEqual(arguments, once)
                }
            }
        }
    }

    func testSourceMetadataPlanOwnsOutputMappingAndKeepsInputFlags() {
        let inputArguments = ["-fflags", "+bitexact+genpts", "-i", "source.mov"]
        let outputArguments = [
            "-map_metadata:g", "0", "-map_metadata:s:a:0", "0:s:a:0", "-map_chapters", "0",
            "-fflags", "+genpts+bitexact", "-fflags", "-bitexact", "-metadata", "title=Authored",
            "-metadata:s:a:0", "language=nor"
        ]
        var arguments = inputArguments + outputArguments
        SourceMetadataPlan.strip.apply(to: &arguments, outputArgumentsStart: inputArguments.count)
        XCTAssertEqual(Array(arguments.prefix(inputArguments.count)), inputArguments)
        XCTAssertEqual(Self.values(for: "-map_metadata", in: arguments), ["-1"])
        XCTAssertEqual(Self.values(for: "-map_chapters", in: arguments), ["-1"])
        XCTAssertFalse(arguments.contains("-map_metadata:g"))
        XCTAssertFalse(arguments.contains("-map_metadata:s:a:0"))
        XCTAssertEqual(Self.values(for: "-fflags", in: arguments), ["+bitexact+genpts", "+genpts", "-bitexact", "+bitexact"])
        XCTAssertTrue(arguments.contains("title=Authored"))
        XCTAssertTrue(arguments.contains("language=nor"))
        let once = arguments
        SourceMetadataPlan.strip.apply(to: &arguments, outputArgumentsStart: inputArguments.count)
        XCTAssertEqual(arguments, once)

        arguments = outputArguments
        SourceMetadataPlan.unchanged.apply(to: &arguments)
        XCTAssertEqual(arguments, outputArguments)
        SourceMetadataPlan.preserve(input: nil).apply(to: &arguments)
        XCTAssertFalse(arguments.contains("-map_metadata:g"))
        XCTAssertFalse(arguments.contains("-map_metadata"))
        XCTAssertFalse(arguments.contains("-map_chapters"))
        // Stream-specific mappings remain available when preserving metadata.
        XCTAssertEqual(Self.values(for: "-map_metadata:s:a:0", in: arguments), ["0:s:a:0"])
    }

    func testCapturedSourceMetadataPolicyOwnsFinalArgumentsAcrossBranches() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = URL(fileURLWithPath: "/source/input.wav")
        for preserve in [false, true] {
            defaults.set(preserve, forKey: AppConstants.preserveMetadataPreferenceKey)
            let codec = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))
            let audio = AudioOnlySettings(defaults: defaults)
            defaults.set(!preserve, forKey: AppConstants.preserveMetadataPreferenceKey)
            let extra = ["-map_metadata:g", preserve ? "-1" : "0", "-map_chapters", preserve ? "-1" : "0",
                         "-fflags", "-bitexact", "-metadata", "title=Authored"]
            for branch in 0..<3 {
                let command = await FFMPEGCommandBuilder.buildCommand(
                    inputURL: input, outputFileURL: URL(fileURLWithPath: "/output/result.mp4"), preset: .h264,
                    codecSettings: codec, comment: "", includeDateTag: false, trimStart: nil, trimEnd: 1,
                    waveformRequest: branch == 1 ? Self.waveformRequest : nil,
                    synthesizedVideoRequest: branch == 2 ? SynthesizedVideoRequest(
                        width: 32, height: 32, backgroundHex: "000000", frameRate: 24, includeAudio: true
                    ) : nil,
                    additionalOutputArguments: extra
                )
                XCTAssertEqual(Self.values(for: "-map_metadata", in: command.arguments), [preserve ? "0" : "-1"])
                XCTAssertEqual(Self.values(for: "-map_chapters", in: command.arguments), [preserve ? "0" : "-1"])
                XCTAssertFalse(command.arguments.contains("-map_metadata:g"))
                XCTAssertTrue(command.arguments.contains("title=Authored"))
            }
            let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
                audioInputURL: input, outputFileURL: URL(fileURLWithPath: "/output/result.mp4"), preset: .h264,
                codecSettings: codec, width: 32, height: 32, frameRate: 24, trimStart: nil, trimEnd: 1,
                includeDateTag: false, additionalOutputArguments: extra
            )
            XCTAssertEqual(Self.values(for: "-map_metadata", in: native.arguments), [preserve ? "1" : "-1"])
            XCTAssertEqual(Self.values(for: "-map_chapters", in: native.arguments), [preserve ? "1" : "-1"])
            let audioCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: input, outputFileURL: URL(fileURLWithPath: "/output/result.wav"), preset: .audioOnly,
                audioOnlySettings: audio, comment: "", includeDateTag: false, trimStart: nil, trimEnd: 1,
                additionalOutputArguments: extra
            )
            XCTAssertEqual(Self.values(for: "-map_metadata", in: audioCommand.arguments), preserve ? [] : ["-1"])
        }
    }

    func testCustomPresetsKeepCapturedSourceMetadataMapping() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppConstants.preserveMetadataPreferenceKey)
        let slot = try XCTUnwrap(ExportPreset.custom1.customSlotIndex)
        defaults.set("-c:v libx264 -map_metadata 0 -map_chapters 0 -fflags +genpts", forKey: AppConstants.customPresetCommandKey(for: slot))
        let settings = try XCTUnwrap(CodecExportSettings(preset: .custom1, defaults: defaults))
        XCTAssertEqual(settings.sourceMetadataPlan, .unchanged)
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/input.mov"),
            outputFileURL: URL(fileURLWithPath: "/output/result.mov"), preset: .custom1,
            codecSettings: settings, comment: "", includeDateTag: false, trimStart: nil, trimEnd: 1,
            additionalOutputArguments: ["-map_metadata:s:a:0", "0:s:a:0", "-fflags", "-bitexact"]
        )
        XCTAssertEqual(Self.values(for: "-map_metadata", in: command.arguments), ["0"])
        XCTAssertEqual(Self.values(for: "-map_chapters", in: command.arguments), ["0"])
        XCTAssertEqual(Self.values(for: "-map_metadata:s:a:0", in: command.arguments), ["0:s:a:0"])
        XCTAssertEqual(Self.values(for: "-fflags", in: command.arguments), ["+genpts", "-bitexact"])
    }

    func testGeneratedTrimmedStreamCopyStripsSourceTagsAndChaptersAfterAdditionalOptions() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeTaggedSource(in: directory)
        for preserve in [true, false] {
            defaults.set(preserve, forKey: AppConstants.preserveMetadataPreferenceKey)
            let settings = try XCTUnwrap(CodecExportSettings(preset: .streamCopy, defaults: defaults))
            let output = directory.appendingPathComponent(preserve ? "preserved.mkv" : "stripped.mkv")
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: source, outputFileURL: output, preset: .streamCopy, codecSettings: settings,
                comment: "Authored comment", includeDateTag: false, trimStart: 0.1, trimEnd: 0.8,
                additionalOutputArguments: preserve
                    ? ["-map_metadata:g", "-1", "-map_chapters", "-1"]
                    : ["-map_metadata", "0", "-map_metadata:s", "0:s", "-map_chapters", "0", "-fflags", "-bitexact"]
            )
            try await runMetadataFFmpeg(command.arguments)
            let inspection = try await inspectMetadata(at: output)
            XCTAssertEqual(inspection.contains("Source title sentinel"), preserve, inspection)
            XCTAssertEqual(inspection.contains("Source video sentinel"), preserve, inspection)
            XCTAssertEqual(inspection.contains("Source audio sentinel"), preserve, inspection)
            XCTAssertEqual(inspection.contains("(nor)"), preserve, inspection)
            XCTAssertEqual(inspection.contains("Source chapter sentinel"), preserve, inspection)
            XCTAssertTrue(inspection.contains("Authored comment"), inspection)
            if !preserve {
                // Matroska keeps the deterministic "Lavf" writing-application
                // placeholder under bitexact, but omits versioned encoder tags.
                XCTAssertNil(inspection.range(of: "Lavf[0-9]", options: .regularExpression), inspection)
                XCTAssertFalse(inspection.contains("Lavc"), inspection)
            }
        }
    }

    func testGeneratedNativeWaveformPreservesMetadataFromAudioInput() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeTaggedSource(in: directory)
        let output = directory.appendingPathComponent("native.mkv")
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: source, outputFileURL: output, preset: .h264, codecSettings: settings,
            width: 32, height: 32, frameRate: 24, trimStart: nil, trimEnd: 1, includeDateTag: false
        )
        try await runMetadataFFmpeg(command.arguments, standardInput: Data(repeating: 0, count: 32 * 32 * 4 * 24))
        let inspection = try await inspectMetadata(at: output)
        XCTAssertTrue(inspection.contains("Source title sentinel"), inspection)
        XCTAssertTrue(inspection.contains("Source chapter sentinel"), inspection)
    }

    private static func values(for option: String, in arguments: [String]) -> [String] {
        arguments.indices.dropLast().compactMap { arguments[$0] == option ? arguments[$0 + 1] : nil }
    }

    private func makeTaggedSource(in directory: URL) async throws -> URL {
        let metadata = directory.appendingPathComponent("chapters.ffmetadata")
        try """
        ;FFMETADATA1
        title=Source title sentinel
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=Source chapter sentinel
        """.write(to: metadata, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("source.mkv")
        try await runMetadataFFmpeg([
            "-f", "lavfi", "-i", "color=c=black:s=32x32:r=24:d=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=1", "-i", metadata.path,
            "-map", "0:v", "-map", "1:a", "-map_metadata", "2", "-map_chapters", "2",
            "-metadata:s:v:0", "title=Source video sentinel", "-metadata:s:a:0", "title=Source audio sentinel",
            "-metadata:s:a:0", "language=nor", "-c:v", "libx264", "-c:a", "pcm_s16le", source.path
        ])
        return source
    }

    private var metadataFFmpegURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
    }

    private func runMetadataFFmpeg(_ arguments: [String], standardInput: Data? = nil) async throws {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: metadataFFmpegURL, arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments,
            standardInput: standardInput, timeout: .seconds(30), standardErrorCaptureLimit: 16_384
        ))
        guard result.succeeded else {
            throw NSError(domain: "CommentSettingsTests", code: Int(result.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: result.standardErrorText])
        }
    }

    private func inspectMetadata(at url: URL) async throws -> String {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: metadataFFmpegURL, arguments: ["-hide_banner", "-i", url.path],
            timeout: .seconds(30), standardErrorCaptureLimit: 16_384
        ))
        // An inspection with no destination reports the tags, then exits with status 1.
        return result.standardErrorText
    }

    func testCommentPlanResolvesOnceAndPreservesUnownedMetadata() throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("'captured date'", forKey: AppConstants.commentDateFormatKey)
        defaults.set("Created", forKey: AppConstants.dateTagPrefixKey)
        defaults.set(" - ", forKey: AppConstants.commentSeparatorKey)
        let plan = CommentMetadataPlan(comment: " Body ", includeDateTag: true, settings: CommentSettings(defaults: defaults))
        defaults.set("changed", forKey: AppConstants.commentDateFormatKey)
        let original = ["-map_metadata", "0", "-metadata", "comment=old", "-metadata", "title=Keep",
                        "-metadata:s:a:0", "comment=Track note", "-metadata", "comment=duplicate"]
        var arguments = original
        plan.apply(to: &arguments)
        XCTAssertEqual(arguments.filter { $0.hasPrefix("comment=") }, ["comment=Track note", "comment=Created: captured date - Body"])
        XCTAssertTrue(arguments.contains("title=Keep"))
        let once = arguments
        plan.apply(to: &arguments)
        XCTAssertEqual(arguments, once)
        CommentMetadataPlan.source.apply(to: &arguments)
        XCTAssertEqual(arguments, ["-map_metadata", "0", "-metadata", "title=Keep", "-metadata:s:a:0", "comment=Track note"])
        arguments = original
        CommentMetadataPlan.unchanged.apply(to: &arguments)
        XCTAssertEqual(arguments, original)
    }

    func testFinalMetadataPolicyOwnsAdditionalArgumentsAcrossVideoBranches() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CommentSettings(defaults: defaults)
        let codec = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))
        let input = URL(fileURLWithPath: "/source/input.wav")
        let output = URL(fileURLWithPath: "/output/result.mov")
        let extra = ["-metadata", "comment=stale", "-timecode", "01:00:00:00",
                     "-metadata", "timecode=02:00:00:00", "-metadata:s:v:0", "timecode=03:00:00:00",
                     "-metadata", "title=Keep"]
        for branch in 0..<3 {
            for config in [TimecodeConfig?.none, TimecodeConfig(mode: .manual("10:20:30:12"))] {
                let command = await FFMPEGCommandBuilder.buildCommand(
                    inputURL: input, outputFileURL: output, preset: .prores,
                    codecSettings: codec, commentSettings: settings,
                    comment: "Chosen", includeDateTag: false, trimStart: nil, trimEnd: 1,
                    timecodeConfig: config,
                    waveformRequest: branch == 1 ? Self.waveformRequest : nil,
                    synthesizedVideoRequest: branch == 2 ? SynthesizedVideoRequest(
                        width: 32, height: 32, backgroundHex: "000000", frameRate: 24, includeAudio: true
                    ) : nil,
                    additionalOutputArguments: extra
                )
                XCTAssertNil(command.preparationError)
                XCTAssertEqual(command.arguments.filter { $0.hasPrefix("comment=") }, ["comment=Chosen"])
                XCTAssertEqual(command.arguments.filter { $0.hasPrefix("timecode=") },
                               Array(repeating: config == nil ? "timecode=" : "timecode=10:20:30:12", count: 2))
                XCTAssertFalse(command.arguments.contains("-timecode"))
                XCTAssertTrue(command.arguments.contains("title=Keep"))
                XCTAssertEqual(command.arguments.last, output.path)
            }
        }
        let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: input, outputFileURL: output, preset: .prores,
            codecSettings: codec, commentSettings: settings, width: 32, height: 32, frameRate: 24,
            trimStart: nil, trimEnd: 1, comment: "Chosen", includeDateTag: false,
            additionalOutputArguments: ["-metadata", "comment=stale", "-metadata", "title=Keep"]
        )
        XCTAssertEqual(native.arguments.filter { $0.hasPrefix("comment=") }, ["comment=Chosen"])
        XCTAssertTrue(native.arguments.contains("title=Keep"))
    }

    func testGeneratedImageSequencesOmitContainerCommentMetadata() async throws {
        let suite = "CommentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ImageSequenceSettings(defaults: defaults)
        for branch in 0..<3 {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/input.wav"),
                outputFileURL: URL(fileURLWithPath: "/output/frame_%04d.png"), preset: .imageSequence,
                imageSequenceSettings: settings, comment: "Not a container", includeDateTag: true,
                trimStart: nil, trimEnd: 1,
                waveformRequest: branch == 1 ? Self.waveformRequest : nil,
                synthesizedVideoRequest: branch == 2 ? SynthesizedVideoRequest(
                    width: 32, height: 32, backgroundHex: "000000", frameRate: 24, includeAudio: false
                ) : nil
            )
            XCTAssertFalse(command.arguments.contains { $0.hasPrefix("comment=") })
        }
        let native = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: URL(fileURLWithPath: "/source/input.wav"),
            outputFileURL: URL(fileURLWithPath: "/output/frame_%04d.png"), preset: .imageSequence,
            imageSequenceSettings: settings, width: 32, height: 32, frameRate: 24,
            trimStart: nil, trimEnd: 1, comment: "Not a container", includeDateTag: true
        )
        XCTAssertFalse(native.arguments.contains { $0.hasPrefix("comment=") })
    }

    private static var waveformRequest: WaveformVideoRequest {
        WaveformVideoRequest(
            width: 32, height: 32, backgroundHex: "000000", foregroundHex: "FFFFFF",
            normalizeAudio: false, style: .linear, frameRate: 24, renderingEngine: .swift,
            swiftStyle: .capsules, bandCount: 16, frequencyDistribution: .logarithmic,
            foregroundGradientEnabled: false, foregroundGradientEndHex: "FFFFFF",
            backgroundGradientEnabled: false, backgroundGradientEndHex: "000000", waveformOpacity: 1
        )
    }

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
