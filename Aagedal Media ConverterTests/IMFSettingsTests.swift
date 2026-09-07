import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class IMFSettingsTests: XCTestCase {
    func testAbsentAndInvalidPreferencesPreserveFallbacksWithoutRewritingValues() throws {
        let suite = "IMFSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = IMFSettings(defaults: defaults)
        XCTAssertEqual(initial.resolution.rawValue, AppConstants.defaultIMFResolution)
        XCTAssertEqual(initial.frameRate.rawValue, AppConstants.defaultIMFFrameRate)
        XCTAssertEqual(initial.bitrate.rawValue, AppConstants.defaultIMFJ2KBitrate)
        XCTAssertEqual(initial.scalingMode.rawValue, AppConstants.defaultIMFScalingMode)
        XCTAssertEqual(initial.color.rawValue, AppConstants.defaultIMFJ2KColorEncoding)
        XCTAssertEqual(initial.proResProfile.rawValue, AppConstants.defaultIMFProResProfile)
        XCTAssertFalse(initial.keepIntermediates)

        let keys = [AppConstants.imfResolutionKey, AppConstants.imfFrameRateKey,
                    AppConstants.imfJ2KBitrateKey, AppConstants.imfScalingModeKey,
                    AppConstants.imfJ2KColorEncodingKey, AppConstants.imfProResProfileKey]
        for key in keys { defaults.set("removed-option", forKey: key) }
        let fallback = IMFSettings(defaults: defaults)
        XCTAssertEqual(fallback.resolution, .hd1080)
        XCTAssertEqual(fallback.frameRate, .fps24)
        XCTAssertEqual(fallback.bitrate, .high)
        XCTAssertEqual(fallback.scalingMode, .fit)
        XCTAssertEqual(fallback.color, .rec709)
        XCTAssertEqual(fallback.proResProfile, .proRes422HQ)
        for key in keys { XCTAssertEqual(defaults.string(forKey: key), "removed-option") }
    }

    func testBothApplicationsKeepCommandAndPackagePreferencesAfterSuspension() async throws {
        let suite = "IMFSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(IMFResolution.uhd2160.rawValue, forKey: AppConstants.imfResolutionKey)
        defaults.set(IMFFrameRate.fps23_976.rawValue, forKey: AppConstants.imfFrameRateKey)
        defaults.set(DCPBitrate.max.rawValue, forKey: AppConstants.imfJ2KBitrateKey)
        defaults.set(IMFScalingMode.fill.rawValue, forKey: AppConstants.imfScalingModeKey)
        defaults.set(IMFColorEncoding.rec2020PQ.rawValue, forKey: AppConstants.imfJ2KColorEncodingKey)
        defaults.set(IMFProResProfile.proRes4444XQ.rawValue, forKey: AppConstants.imfProResProfileKey)
        defaults.set(true, forKey: AppConstants.imfKeepIntermediatesKey)
        let captured = IMFSettings(defaults: defaults)
        await Task.yield()
        defaults.removePersistentDomain(forName: suite)

        for preset in [ExportPreset.imfJ2K, .imfProRes] {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: URL(fileURLWithPath: "/source/frames"),
                outputFileURL: URL(fileURLWithPath: "/output/essence"),
                preset: preset, imfSettings: captured, comment: "", includeDateTag: false,
                trimStart: nil, trimEnd: nil,
                customInputArguments: ["-framerate", "24", "-i", "/source/frame_%06d.png"]
            )
            func value(after option: String) throws -> String {
                let index = try XCTUnwrap(command.arguments.firstIndex(of: option))
                return command.arguments[index + 1]
            }
            XCTAssertEqual(try value(after: "-r"), "24000/1001")
            XCTAssertEqual(try value(after: "-color_primaries"), "bt2020")
            XCTAssertEqual(try value(after: "-color_trc"), "smpte2084")
            XCTAssertTrue(try value(after: "-vf").contains("crop=3840:2160"))
            if preset == .imfJ2K {
                XCTAssertEqual(try value(after: "-c:v"), "libopenjpeg")
                XCTAssertEqual(try value(after: "-b:v"), "250M")
                XCTAssertFalse(command.arguments.contains("-cinema_mode"))
            } else {
                XCTAssertEqual(try value(after: "-c:v"), "prores_ks")
                XCTAssertEqual(try value(after: "-profile:v"), "5")
                XCTAssertEqual(try value(after: "-pix_fmt"), "yuva444p10le")
            }
        }
        // Wrapping and manifests consume these same captured values, including the exact edit rate.
        XCTAssertEqual(captured.frameRate.editRateNumerator, 24000)
        XCTAssertEqual(captured.frameRate.editRateDenominator, 1001)
        XCTAssertEqual(captured.resolution, .uhd2160)
        XCTAssertEqual(captured.color.bmxFlags.transferCharacteristic, "st2084")
        XCTAssertTrue(captured.keepIntermediates)
        let next = IMFSettings(defaults: defaults)
        XCTAssertEqual(next.resolution, .hd1080)
        XCTAssertEqual(next.frameRate, .fps24)
        XCTAssertFalse(next.keepIntermediates)
    }
}
