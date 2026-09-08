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

}
