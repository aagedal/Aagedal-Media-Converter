import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class DCPSettingsTests: XCTestCase {
    func testAbsentPreferencesPreserveDefaults() throws {
        let suite = "DCPSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = DCPSettings(defaults: defaults)
        XCTAssertEqual(settings.resolution.rawValue, AppConstants.defaultDCPResolution)
        XCTAssertEqual(settings.frameRate.rawValue, AppConstants.defaultDCPFrameRate)
        XCTAssertEqual(settings.bitrate.rawValue, AppConstants.defaultDCPBitrate)
        XCTAssertEqual(settings.scalingMode.rawValue, AppConstants.defaultDCPScalingMode)
        XCTAssertFalse(settings.keepJP2Images)
    }

    func testInvalidPreferencesKeepFallbacksWithoutRewritingSavedValues() throws {
        let suite = "DCPSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [AppConstants.dcpResolutionKey, AppConstants.dcpFrameRateKey,
                    AppConstants.dcpBitrateKey, AppConstants.dcpScalingModeKey]
        for key in keys { defaults.set("removed-option", forKey: key) }

        let settings = DCPSettings(defaults: defaults)
        XCTAssertEqual(settings.resolution, .twoKFull)
        XCTAssertEqual(settings.frameRate, .fps24)
        XCTAssertEqual(settings.bitrate, .high)
        XCTAssertEqual(settings.scalingMode, .fill)
        for key in keys { XCTAssertEqual(defaults.string(forKey: key), "removed-option") }
    }

    func testCommandAndPackageSettingsRetainInjectedSnapshotAfterPreferencesChange() async throws {
        let suite = "DCPSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DCPResolution.fourKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(DCPFrameRate.fps24.rawValue, forKey: AppConstants.dcpFrameRateKey)
        defaults.set(DCPBitrate.max.rawValue, forKey: AppConstants.dcpBitrateKey)
        defaults.set(DCPScalingMode.fit.rawValue, forKey: AppConstants.dcpScalingModeKey)
        defaults.set(true, forKey: AppConstants.dcpKeepJP2ImagesKey)
        let captured = DCPSettings(defaults: defaults)

        await Task.yield()
        defaults.set(DCPResolution.twoKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(DCPFrameRate.fps25.rawValue, forKey: AppConstants.dcpFrameRateKey)
        defaults.set(DCPBitrate.low.rawValue, forKey: AppConstants.dcpBitrateKey)
        defaults.set(DCPScalingMode.fill.rawValue, forKey: AppConstants.dcpScalingModeKey)
        defaults.set(false, forKey: AppConstants.dcpKeepJP2ImagesKey)

        // A custom sequence input avoids probing an actual media file in this command regression.
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/frames"),
            outputFileURL: URL(fileURLWithPath: "/output/frame_%06d.jp2"),
            preset: .dcp, dcpSettings: captured, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil,
            customInputArguments: ["-framerate", "24", "-i", "/source/frame_%06d.png"]
        )
        func value(after option: String) throws -> String {
            let index = try XCTUnwrap(command.arguments.firstIndex(of: option))
            return command.arguments[index + 1]
        }
        XCTAssertEqual(try value(after: "-c:v"), "libopenjpeg")
        XCTAssertEqual(try value(after: "-profile"), "cinema4k")
        XCTAssertEqual(try value(after: "-cinema_mode"), "4k_24")
        XCTAssertEqual(try value(after: "-b:v"), "250M")
        XCTAssertEqual(try value(after: "-r"), "24")
        XCTAssertTrue(try value(after: "-vf").contains("pad=4096:2160:-1:-1:color=black"))
        XCTAssertEqual(captured.resolution, .fourKFull)
        XCTAssertEqual(captured.frameRate, .fps24)
        XCTAssertTrue(captured.keepJP2Images)

        let next = DCPSettings(defaults: defaults)
        XCTAssertEqual(next.resolution, .twoKFull)
        XCTAssertEqual(next.frameRate, .fps25)
        XCTAssertEqual(next.bitrate, .low)
        XCTAssertEqual(next.scalingMode, .fill)
        XCTAssertFalse(next.keepJP2Images)
    }
}
