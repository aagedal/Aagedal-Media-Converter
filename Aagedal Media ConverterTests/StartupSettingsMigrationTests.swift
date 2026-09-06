import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class StartupSettingsMigrationTests: XCTestCase {
    private func withStore(_ body: (UserDefaults, StartupSettingsMigration) -> Void) {
        let suite = "StartupSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, StartupSettingsMigration(defaults: defaults))
    }

    func testCaptureSelectionMigratesLegacyDisplayAndDoesNotRestoreClearedSelection() {
        withStore { defaults, migration in
            defaults.register(defaults: [AppConstants.captureDisplayIDsKey: ""])
            defaults.set(42, forKey: AppConstants.captureDisplayIDKey)
            migration.migrateCaptureDisplaySelection()
            XCTAssertEqual(defaults.string(forKey: AppConstants.captureDisplayIDsKey), "42")
            XCTAssertTrue(defaults.bool(forKey: AppConstants.captureDisplayIDsMigratedKey))
            defaults.set("", forKey: AppConstants.captureDisplayIDsKey)
            migration.migrateCaptureDisplaySelection()
            XCTAssertEqual(defaults.string(forKey: AppConstants.captureDisplayIDsKey), "")
        }
    }

    func testCaptureMigrationPreservesMultiDisplaySelectionAndAutomaticDefault() {
        withStore { defaults, migration in
            defaults.register(defaults: [AppConstants.captureDisplayIDsKey: ""])
            migration.migrateCaptureDisplaySelection()
            XCTAssertEqual(defaults.string(forKey: AppConstants.captureDisplayIDsKey), "")
        }
        withStore { defaults, migration in
            defaults.set(42, forKey: AppConstants.captureDisplayIDKey)
            defaults.set("7,8", forKey: AppConstants.captureDisplayIDsKey)
            migration.migrateCaptureDisplaySelection()
            XCTAssertEqual(defaults.string(forKey: AppConstants.captureDisplayIDsKey), "7,8")
        }
    }

    func testEveryLegacyAudioPresetPreservesItsFormat() {
        for (legacy, format) in [
            ("Audio only WAV (all channels)", AudioOnlyFormat.wav),
            ("Audio only AAC (stereo downmix)", .aac),
            ("Audio only MP4 (all tracks)", .mp4)
        ] {
            withStore { defaults, migration in
                defaults.set(legacy, forKey: AppConstants.defaultPresetKey)
                migration.migrateAudioPresets()
                XCTAssertEqual(defaults.string(forKey: AppConstants.defaultPresetKey), ExportPreset.audioOnly.rawValue)
                XCTAssertEqual(defaults.string(forKey: AppConstants.audioOnlyFormatKey), format.rawValue)
            }
        }
    }

    func testAudioVisibilityCombinesLegacyChoicesAndDefaultsMissingChoicesToVisible() {
        for mask in 0..<8 {
            withStore { defaults, migration in
                for (index, key) in [AppConstants.audioWAVVisibleKey, AppConstants.audioAACVisibleKey, AppConstants.audioMP4VisibleKey].enumerated() {
                    defaults.set(mask & (1 << index) != 0, forKey: key)
                }
                migration.migrateAudioPresets()
                XCTAssertEqual(defaults.bool(forKey: AppConstants.audioOnlyVisibleKey), mask != 0)
            }
        }
        withStore { defaults, migration in
            defaults.set(false, forKey: AppConstants.audioWAVVisibleKey)
            migration.migrateAudioPresets()
            XCTAssertTrue(defaults.bool(forKey: AppConstants.audioOnlyVisibleKey))
        }
    }

    func testExplicitModernAudioChoicesWinAndMigrationIsIdempotent() {
        withStore { defaults, migration in
            defaults.set("Audio only WAV (all channels)", forKey: AppConstants.defaultPresetKey)
            defaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
            defaults.set(false, forKey: AppConstants.audioOnlyVisibleKey)
            migration.migrateAudioPresets()
            XCTAssertEqual(defaults.string(forKey: AppConstants.audioOnlyFormatKey), AudioOnlyFormat.mp4.rawValue)
            XCTAssertFalse(defaults.bool(forKey: AppConstants.audioOnlyVisibleKey))
            defaults.set("custom-preset", forKey: AppConstants.defaultPresetKey)
            let before = defaults.dictionaryRepresentation()
            migration.migrateAudioPresets()
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
        }
    }

    func testUnrelatedDefaultPresetAndFormatArePreserved() {
        withStore { defaults, migration in
            defaults.set("custom-preset", forKey: AppConstants.defaultPresetKey)
            migration.migrateAudioPresets()
            XCTAssertEqual(defaults.string(forKey: AppConstants.defaultPresetKey), "custom-preset")
            XCTAssertNil(defaults.object(forKey: AppConstants.audioOnlyFormatKey))
        }
    }
}
