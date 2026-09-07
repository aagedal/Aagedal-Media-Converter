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
}
