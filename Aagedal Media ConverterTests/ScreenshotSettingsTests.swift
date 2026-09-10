import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ScreenshotSettingsTests: XCTestCase {
    func testFormatSnapshotRetainsEachBitDepthPreferenceAfterEdits() throws {
        let suite = "ScreenshotSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ScreenshotFormat.jpeg.rawValue, forKey: AppConstants.screenshot8BitFormatKey)
        defaults.set(ScreenshotFormat.avif.rawValue, forKey: AppConstants.screenshot10BitFormatKey)
        defaults.set(ScreenshotFormat.tiff.rawValue, forKey: AppConstants.screenshotHighBitFormatKey)
        let captured = ScreenshotSettings(defaults: defaults)
        for key in formatKeys {
            defaults.set(ScreenshotFormat.png.rawValue, forKey: key)
        }
        XCTAssertEqual(captured.format(bitDepth: 8, hasAlpha: false), .jpeg)
        XCTAssertEqual(captured.format(bitDepth: 10, hasAlpha: false), .avif)
        XCTAssertEqual(captured.format(bitDepth: 12, hasAlpha: false), .tiff)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).format(bitDepth: 10, hasAlpha: false), .png)
    }

    func testMissingAndMalformedPreferencesFallBackWithoutRewritingStorage() throws {
        let suite = "ScreenshotSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = ScreenshotSettings(defaults: defaults)
        for bitDepth in [8, 10, 16] {
            XCTAssertEqual(initial.format(bitDepth: bitDepth, hasAlpha: true), .jpegXL)
        }
        for key in formatKeys {
            defaults.set(["unsupported"], forKey: key)
        }
        defaults.set("unknown", forKey: AppConstants.screenshotAlphaHandlingKey)
        let malformed = ScreenshotSettings(defaults: defaults)
        XCTAssertEqual(malformed.alphaHandling, .auto)
        for bitDepth in [8, 10, 16] {
            XCTAssertEqual(malformed.format(bitDepth: bitDepth, hasAlpha: true), .jpegXL)
        }
        for key in formatKeys {
            XCTAssertEqual(defaults.stringArray(forKey: key), ["unsupported"])
        }
        XCTAssertEqual(defaults.string(forKey: AppConstants.screenshotAlphaHandlingKey), "unknown")
    }

    func testMalformedAlphaPolicyPreservesTransparencyForOpaqueFormats() throws {
        let suite = "ScreenshotSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: AppConstants.screenshotAlphaHandlingKey)
        for format in ScreenshotFormat.allCases {
            for key in formatKeys {
                defaults.set(format.rawValue, forKey: key)
            }
            let settings = ScreenshotSettings(defaults: defaults)
            for bitDepth in [8, 10, 16] {
                XCTAssertEqual(settings.format(bitDepth: bitDepth, hasAlpha: true), format.supportsAlpha ? format : .png)
                XCTAssertEqual(settings.format(bitDepth: bitDepth, hasAlpha: false), format)
            }
        }
    }

    func testExplicitDiscardAlphaPolicyRemainsCaptured() throws {
        let suite = "ScreenshotSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ScreenshotFormat.jpeg.rawValue, forKey: AppConstants.screenshot8BitFormatKey)
        defaults.set(ScreenshotAlphaHandling.useSelectedFormat.rawValue, forKey: AppConstants.screenshotAlphaHandlingKey)
        let settings = ScreenshotSettings(defaults: defaults)
        defaults.set(ScreenshotAlphaHandling.auto.rawValue, forKey: AppConstants.screenshotAlphaHandlingKey)
        XCTAssertEqual(settings.format(bitDepth: 8, hasAlpha: true), .jpeg)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).format(bitDepth: 8, hasAlpha: true), .png)
    }

    @MainActor
    func testControllerScreenshotParametersUseCapturedDepthAndAlphaPolicy() async throws {
        let suite = "ScreenshotSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ScreenshotFormat.tiff.rawValue, forKey: AppConstants.screenshot8BitFormatKey)
        defaults.set(ScreenshotFormat.jpeg.rawValue, forKey: AppConstants.screenshot10BitFormatKey)
        defaults.set(ScreenshotAlphaHandling.auto.rawValue, forKey: AppConstants.screenshotAlphaHandlingKey)
        let preserveAlpha = ScreenshotSettings(defaults: defaults)
        defaults.set(ScreenshotAlphaHandling.useSelectedFormat.rawValue, forKey: AppConstants.screenshotAlphaHandlingKey)
        let discardAlpha = ScreenshotSettings(defaults: defaults)
        for key in formatKeys {
            defaults.set(ScreenshotFormat.jpegXL.rawValue, forKey: key)
        }

        let video = VideoItem(
            url: URL(fileURLWithPath: "/private/screenshot-settings.mov"), name: "Screenshot",
            size: 0, duration: "00:00:01", status: .waiting, progress: 0, eta: nil, outputURL: nil
        )
        let controller = PreviewPlayerController(videoItem: video)
        defer { controller.teardown() }
        let stream = VideoMetadata.VideoStream(
            codec: "prores", codecLongName: nil, profile: nil, width: 1920, height: 1080,
            pixelFormat: "yuva444p10le", hasAlpha: true, pixelAspectRatio: nil,
            displayAspectRatio: nil, frameRate: nil, bitDepth: 10, bitRate: nil, duration: 1,
            chromaSubsampling: "4:4:4", colorPrimaries: nil, colorTransfer: nil,
            colorSpace: nil, colorRange: nil, chromaLocation: nil, fieldOrder: nil,
            isInterlaced: false, title: nil, isDefault: true, isForced: false
        )

        let preserved = controller.screenshotParameters(for: stream, settings: preserveAlpha)
        XCTAssertEqual(preserved.fileExtension, "png")
        XCTAssertEqual(preserved.codecArguments, ["-c:v", "png", "-compression_level", "1"])
        XCTAssertEqual(preserved.pixelFormat, "rgba64be")

        let discarded = controller.screenshotParameters(for: stream, settings: discardAlpha)
        XCTAssertEqual(discarded.fileExtension, "jpg")
        XCTAssertEqual(discarded.codecArguments, ["-c:v", "mjpeg", "-q:v", "1"])
        XCTAssertEqual(discarded.pixelFormat, "yuvj444p")

        let missingMetadata = controller.screenshotParameters(for: nil, settings: preserveAlpha)
        XCTAssertEqual(missingMetadata.fileExtension, "tiff")
        XCTAssertEqual(missingMetadata.codecArguments, ["-c:v", "tiff"])
        XCTAssertEqual(missingMetadata.pixelFormat, "rgb24")
    }

    private var formatKeys: [String] {
        [AppConstants.screenshot8BitFormatKey, AppConstants.screenshot10BitFormatKey, AppConstants.screenshotHighBitFormatKey]
    }
}
