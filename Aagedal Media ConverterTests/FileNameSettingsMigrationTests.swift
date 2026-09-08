import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class FileNameSettingsMigrationTests: XCTestCase {
    private func withSettings(_ body: (UserDefaults, FileNameSettings) -> Void) {
        let suite = "FileNameSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, FileNameSettings(defaults: defaults))
    }

    func testLegacyBooleanPreservesBothPriorBehaviors() {
        withSettings { defaults, settings in
            defaults.set(true, forKey: AppConstants.fileNameRemoveSpecialCharsKey)
            XCTAssertEqual(settings.specialCharacterRemovalMode, .strict)
            defaults.set(false, forKey: AppConstants.fileNameRemoveSpecialCharsKey)
            XCTAssertEqual(settings.specialCharacterRemovalMode, .off)
        }
    }

    func testExplicitNewModeWinsOverEveryLegacyValue() {
        withSettings { defaults, settings in
            for legacy in [false, true] {
                defaults.set(legacy, forKey: AppConstants.fileNameRemoveSpecialCharsKey)
                for mode in SpecialCharacterRemovalMode.allCases {
                    defaults.set(mode.rawValue, forKey: AppConstants.fileNameSpecialCharRemovalModeKey)
                    XCTAssertEqual(settings.specialCharacterRemovalMode, mode)
                    XCTAssertEqual(defaults.string(forKey: AppConstants.fileNameSpecialCharRemovalModeKey), mode.rawValue)
                }
            }
        }
    }

    func testMissingAndInvalidModesUseExistingFallbacks() {
        withSettings { defaults, settings in
            let fallback = SpecialCharacterRemovalMode(rawValue: AppConstants.defaultFileNameSpecialCharRemovalMode)
            XCTAssertEqual(settings.specialCharacterRemovalMode, fallback)
            defaults.set("removed-mode", forKey: AppConstants.fileNameSpecialCharRemovalModeKey)
            XCTAssertEqual(settings.specialCharacterRemovalMode, fallback)
            defaults.set(true, forKey: AppConstants.fileNameRemoveSpecialCharsKey)
            XCTAssertEqual(settings.specialCharacterRemovalMode, .strict)
        }
    }

    func testRepeatedResolutionDoesNotRewritePreferencesAndHonorsLaterExplicitMode() {
        withSettings { defaults, settings in
            defaults.set(true, forKey: AppConstants.fileNameRemoveSpecialCharsKey)
            for _ in 0..<3 {
                XCTAssertEqual(settings.specialCharacterRemovalMode, .strict)
                XCTAssertNil(defaults.object(forKey: AppConstants.fileNameSpecialCharRemovalModeKey))
                XCTAssertTrue(defaults.bool(forKey: AppConstants.fileNameRemoveSpecialCharsKey))
            }
            defaults.set(SpecialCharacterRemovalMode.loose.rawValue, forKey: AppConstants.fileNameSpecialCharRemovalModeKey)
            for _ in 0..<3 {
                XCTAssertEqual(settings.specialCharacterRemovalMode, .loose)
                XCTAssertEqual(defaults.string(forKey: AppConstants.fileNameSpecialCharRemovalModeKey), "loose")
                XCTAssertTrue(defaults.bool(forKey: AppConstants.fileNameRemoveSpecialCharsKey))
            }
        }
    }

    func testCapturedPreferencesKeepTemplateSanitizationAndSuffixTogether() {
        withSettings { defaults, settings in
            defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set("{sourceName}_{resolution}_{framerate}{presetSuffix}_{counter}", forKey: AppConstants.customFileNameTemplateKey)
            defaults.set(true, forKey: AppConstants.fileNameReplaceSpacesKey)
            defaults.set(true, forKey: AppConstants.fileNameReplaceScandinavianCharsKey)
            defaults.set("loose", forKey: AppConstants.fileNameSpecialCharRemovalModeKey)
            defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
            defaults.set(3, forKey: AppConstants.customFileNameCounterPaddingKey)
            let captured = settings.snapshot
            defaults.set(false, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set(false, forKey: AppConstants.fileNameReplaceSpacesKey)
            defaults.set("changed", forKey: AppConstants.customFileNameTemplateKey)
            let actual = FileNameProcessor.outputBaseName(
                inputURL: URL(fileURLWithPath: "/tmp/Sømmer Video.mov"), counter: 7, preset: .h264,
                settings: captured,
                context: FileNameTemplateContext(presetSuffix: "_h264", resolution: "1080p", framerate: "25")
            )
            XCTAssertEqual(actual, "Sommer_Video_1080p_25_h264_007")
            XCTAssertTrue(captured.customTemplateUsesCounter)
            XCTAssertTrue(captured.customTemplateUsesPresetSuffix)
        }
    }

    func testFilenameOverridesAndAutomaticSuffixShareTheSameRules() {
        withSettings { defaults, settings in
            defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
            defaults.set(true, forKey: AppConstants.fileNameReplaceSpacesKey)
            defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set("{sourceName}_{counter}", forKey: AppConstants.customFileNameTemplateKey)
            defaults.set(2, forKey: AppConstants.customFileNameCounterPaddingKey)
            let preferences = settings.snapshot
            let context = FileNameTemplateContext(presetSuffix: "_h264")
            let input = URL(fileURLWithPath: "/tmp/My Video.mov")
            XCTAssertEqual(FileNameProcessor.outputBaseName(inputURL: input, counter: 2, preset: .h264,
                settings: preferences, context: context), "My_Video_02_h264")
            XCTAssertEqual(FileNameProcessor.outputBaseName(inputURL: input, override: " My Edit.mp4 ",
                counter: 2, preset: .h264, settings: preferences, context: context), "My_Edit")
            let parts = FileNameProcessor.outputNameParts(inputURL: input, counter: 2, preset: .h264,
                settings: preferences, context: context)
            let output = FileSafetyUtils.safeOutputURL(inputURL: input, outputFolder: input.deletingLastPathComponent(),
                baseName: parts.baseName, suffix: parts.suffix, fileExtension: "mov")
            XCTAssertEqual(output.lastPathComponent, "My_Video_02_h264.mov")
        }
    }

    func testCounterFormattingPreservesFullWidthAndBoundsInvalidPadding() {
        withSettings { defaults, settings in
            defaults.set(false, forKey: AppConstants.enableFileNameProcessingKey)
            defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set("{counter}", forKey: AppConstants.customFileNameTemplateKey)
            defaults.set(Int.max, forKey: AppConstants.customFileNameCounterPaddingKey)
            XCTAssertEqual(settings.snapshot.counterPadding, 6)
            for value in [Int.max, Int.min, 4_294_967_297] {
                XCTAssertEqual(FileNameProcessor.applyCustomTemplate(sourceName: "unused", counter: value,
                    settings: settings.snapshot), String(value))
            }
            XCTAssertEqual(FileNameProcessor.applyCustomTemplate(sourceName: "unused", counter: -7,
                settings: settings.snapshot), "-00007")
            defaults.set(-1, forKey: AppConstants.customFileNameCounterPaddingKey)
            XCTAssertEqual(settings.snapshot.counterPadding, 1)
            XCTAssertEqual(defaults.integer(forKey: AppConstants.customFileNameCounterPaddingKey), -1)
        }
    }

    @MainActor
    func testCounterReservationHandlesIntegerLimitWithoutOverflow() {
        let suite = "FileNameSettingsMigrationTests.limit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FileNameSettings(defaults: defaults)
        defaults.set(Int.max - 1, forKey: AppConstants.customFileNameCounterValueKey)
        XCTAssertEqual(settings.nextCounterValue(), Int.max - 1)
        XCTAssertEqual(settings.nextCounterValue(), Int.max)
        XCTAssertEqual(settings.nextCounterValue(), Int.max)
        XCTAssertEqual(defaults.object(forKey: AppConstants.customFileNameCounterValueKey) as? Int, Int.max)
    }

    @MainActor
    func testConcurrentCounterReservationsDoNotLoseIncrements() async {
        let suite = "FileNameSettingsMigrationTests.concurrent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: AppConstants.customFileNameCounterValueKey)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await MainActor.run {
                        _ = FileNameSettings(defaults: UserDefaults(suiteName: suite)!).nextCounterValue()
                    }
                }
            }
        }
        XCTAssertEqual(defaults.integer(forKey: AppConstants.customFileNameCounterValueKey), 101)
    }

    func testCapturedTemplateUsesInjectedDateAndDisabledProcessing() {
        withSettings { defaults, settings in
            defaults.set(false, forKey: AppConstants.enableFileNameProcessingKey)
            defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set("{sourceName}_{date}", forKey: AppConstants.customFileNameTemplateKey)
            defaults.set("yyyy", forKey: AppConstants.customFileNameDateFormatKey)
            let captured = settings.snapshot
            defaults.set("MM", forKey: AppConstants.customFileNameDateFormatKey)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            XCTAssertEqual(FileNameProcessor.applyCustomTemplate(sourceName: "Sømmer Video", settings: captured,
                date: date), "Sømmer Video_2023")
        }
    }


    func testTemplatedSuffixDoesNotAddSpuriousSourceProtectionSuffix() {
        withSettings { defaults, settings in
            defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
            defaults.set("{sourceName}{presetSuffix}", forKey: AppConstants.customFileNameTemplateKey)
            defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
            let input = URL(fileURLWithPath: "/tmp/source.mov")
            let parts = FileNameProcessor.outputNameParts(inputURL: input, preset: .prores,
                settings: settings.snapshot, context: FileNameTemplateContext(presetSuffix: "_prores"))
            let actual = FileSafetyUtils.safeOutputURL(inputURL: input, outputFolder: input.deletingLastPathComponent(),
                baseName: parts.baseName, suffix: parts.suffix, fileExtension: "mov")
            XCTAssertEqual(parts.suffix, "")
            XCTAssertEqual(actual.lastPathComponent, "source_prores.mov")
            XCTAssertEqual(parts.baseName + parts.suffix, actual.deletingPathExtension().lastPathComponent)
        }
    }

    func testSourceProtectionUsesCompleteFilenameAndConservativeCaseComparison() {
        let input = URL(fileURLWithPath: "/tmp/source.mov")
        for (name, suffix, ext, expected) in [
            ("source", "", "mov", "source_encoded.mov"),
            ("SOURCE", "", "MOV", "SOURCE_encoded.MOV"),
            ("sou", "rce", "mov", "sou_encodedrce.mov"),
            ("renamed", "", "mov", "renamed.mov"),
            ("source", "_prores", "mov", "source_prores.mov"),
            ("source", "", "mp4", "source.mp4")
        ] {
            XCTAssertEqual(FileSafetyUtils.safeOutputURL(inputURL: input, outputFolder: input.deletingLastPathComponent(),
                baseName: name, suffix: suffix, fileExtension: ext).lastPathComponent, expected)
        }
    }

    func testBroadcastFilenameAndCommandKeepTheSameCapturedLabels() async throws {
        let suite = "FileNameSettingsMigrationTests.broadcast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{resolution}_{framerate}{presetSuffix}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(TVResolutionLimit.r720.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(TVFramerateMode.p25.rawValue, forKey: AppConstants.tvFramerateModeKey)
        let preferences = FileNameSettings(defaults: defaults).snapshot
        let codec = try XCTUnwrap(CodecExportSettings(preset: .tvHEVC, defaults: defaults))
        await Task.yield()
        defaults.set("changed", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(TVResolutionLimit.r2160.rawValue, forKey: AppConstants.tvResolutionLimitKey)
        defaults.set(TVFramerateMode.p50.rawValue, forKey: AppConstants.tvFramerateModeKey)
        let input = URL(fileURLWithPath: "/source/video.mov")
        let outputName = FileNameProcessor.outputBaseName(
            inputURL: input, preset: .tvHEVC, settings: preferences, context: codec.fileNameContext
        )
        XCTAssertEqual(outputName, "video_720p_25p_tv")
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: input, outputFileURL: URL(fileURLWithPath: "/output/\(outputName).mov"),
            preset: .tvHEVC, codecSettings: codec, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil,
            customInputArguments: ["-framerate", "24", "-i", input.path]
        )
        let rateIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-r"))
        XCTAssertEqual(command.arguments[rateIndex + 1], "25")
        let filterIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-vf"))
        XCTAssertTrue(command.arguments[filterIndex + 1].contains("720"))
    }

    func testCapturedAnimatedStillAndCustomSuffixesUseInjectedDefaults() throws {
        let suite = "FileNameSettingsMigrationTests.suffix.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AnimatedStillFormat.gif.rawValue, forKey: AppConstants.animatedStillFormatKey)
        defaults.set(" delivery ", forKey: AppConstants.customPresetSuffixKey(for: 0))
        let animated = try XCTUnwrap(CodecExportSettings(preset: .animatedStill, defaults: defaults))
        let custom = try XCTUnwrap(CodecExportSettings(preset: .custom1, defaults: defaults))
        defaults.set(AnimatedStillFormat.avif.rawValue, forKey: AppConstants.animatedStillFormatKey)
        defaults.set("changed", forKey: AppConstants.customPresetSuffixKey(for: 0))
        XCTAssertEqual(animated.fileNameContext.presetSuffix, "_gif")
        XCTAssertEqual(animated.fileExtension, "gif")
        XCTAssertEqual(custom.fileNameContext.presetSuffix, "_delivery")
        XCTAssertEqual(FileNameTemplateContext(preset: .custom1, defaults: defaults).presetSuffix, "_changed")
    }

    func testAV2FilenameResolutionUsesTheEncodingSnapshot() {
        withSettings { defaults, _ in
            defaults.set(CodecResolutionLimit.r1080.rawValue, forKey: AppConstants.av2ResolutionLimitKey)
            let captured = AV2Settings(defaults: defaults)
            defaults.set(CodecResolutionLimit.r2160.rawValue, forKey: AppConstants.av2ResolutionLimitKey)
            let context = FileNameTemplateContext(preset: .av2, defaults: defaults, av2Settings: captured)
            XCTAssertEqual(context.resolution, "1080p")
            XCTAssertEqual(context.presetSuffix, "_av2")
            XCTAssertEqual(FileNameTemplateContext(preset: .av2, defaults: defaults).resolution, "2160p")
        }
    }

    func testDCPFilenameUsesCapturedPackagingResolutionAndRate() throws {
        let suite = "FileNameSettingsMigrationTests.dcp.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{resolution}_{framerate}{presetSuffix}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(DCPResolution.fourKScope.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(DCPFrameRate.fps48.rawValue, forKey: AppConstants.dcpFrameRateKey)
        let captured = DCPSettings(defaults: defaults)
        defaults.set(DCPResolution.twoKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(DCPFrameRate.fps24.rawValue, forKey: AppConstants.dcpFrameRateKey)
        let context = FileNameTemplateContext(preset: .dcp, defaults: defaults, dcpSettings: captured)
        XCTAssertEqual(FileNameProcessor.outputBaseName(
            inputURL: URL(fileURLWithPath: "/source/video.mov"), preset: .dcp,
            settings: FileNameSettings(defaults: defaults).snapshot, context: context
        ), "video_4K_48_dcp")
        let rateIndex = try XCTUnwrap(captured.ffmpegArguments.firstIndex(of: "-r"))
        XCTAssertEqual(captured.ffmpegArguments[rateIndex + 1], context.framerate)
        XCTAssertEqual(FileNameTemplateContext(preset: .dcp, defaults: defaults).resolution, "2K")
    }

    func testIMFFilenameUsesCapturedPackagingResolutionAndFractionalRateTag() throws {
        let suite = "FileNameSettingsMigrationTests.imf.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in [ExportPreset.imfJ2K, .imfProRes] {
            defaults.set(IMFResolution.uhd2160.rawValue, forKey: AppConstants.imfResolutionKey)
            defaults.set(IMFFrameRate.fps59_94.rawValue, forKey: AppConstants.imfFrameRateKey)
            let captured = IMFSettings(defaults: defaults)
            defaults.set(IMFResolution.hd1080.rawValue, forKey: AppConstants.imfResolutionKey)
            defaults.set(IMFFrameRate.fps24.rawValue, forKey: AppConstants.imfFrameRateKey)
            let context = FileNameTemplateContext(preset: preset, defaults: defaults, imfSettings: captured)
            XCTAssertEqual(context.resolution, "4K")
            XCTAssertEqual(context.framerate, "60")
            XCTAssertEqual(context.presetSuffix, preset == .imfJ2K ? "_imf2e" : "_imf5")
            let arguments = captured.ffmpegArguments(application: preset == .imfJ2K ? .app2e : .app5)
            let rateIndex = try XCTUnwrap(arguments.firstIndex(of: "-r"))
            XCTAssertEqual(arguments[rateIndex + 1], "60000/1001")
            XCTAssertEqual(FileNameTemplateContext(preset: preset, defaults: defaults).resolution, "2K")
        }
    }

    func testMalformedImageSequenceFramerateLabelsFallBackWithoutTrapping() {
        withSettings { defaults, _ in
            let fallback = FileNameTemplateContext(preset: .imageSequence, defaults: defaults).framerate
            for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), 0, -24] {
                defaults.set(value, forKey: AppConstants.imageSequenceFrameRateKey)
                XCTAssertEqual(FileNameTemplateContext(preset: .imageSequence, defaults: defaults).framerate, fallback)
            }
            for (value, expected) in [(24.0, "24"), (23.976, "23.976"), (59.94, "59.94")] {
                defaults.set(value, forKey: AppConstants.imageSequenceFrameRateKey)
                XCTAssertEqual(FileNameTemplateContext(preset: .imageSequence, defaults: defaults).framerate, expected)
            }
        }
    }

}
