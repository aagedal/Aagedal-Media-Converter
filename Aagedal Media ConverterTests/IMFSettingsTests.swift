import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class IMFSettingsTests: XCTestCase {
    func testExperimentalIMFExportsCreatePackages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IMFEndToEnd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: ffmpeg)
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                               "testsrc2=size=64x64:rate=24:duration=0.25", "-f", "lavfi", "-i",
                               "sine=frequency=440:duration=0.25", "-c:v", "prores_ks", "-profile:v", "3",
                               "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le", "-shortest", source.path]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)

        let completed = expectation(description: "experimental ProRes IMF export")
        let converter = FFMPEGConverter()
        await converter.convert(
            request: ConversionRequest(inputURL: source,
                                       outputURL: directory.appendingPathComponent("export"),
                                       preset: .imfProRes),
            progressUpdate: { _, _ in },
            completion: { success, reason in
                XCTAssertTrue(success, reason ?? "Unknown conversion failure")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 120)
        let xmlFiles = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        XCTAssertTrue(xmlFiles.contains { $0.hasSuffix("ASSETMAP.xml") })
        XCTAssertTrue(xmlFiles.contains { $0.contains("CPL_") && $0.hasSuffix(".xml") })
        XCTAssertTrue(xmlFiles.contains { $0.contains("PKL_") && $0.hasSuffix(".xml") })
        let proResMap = try XCTUnwrap(xmlFiles.first { $0.hasSuffix("ASSETMAP.xml") })
        let proResPackage = directory.appendingPathComponent(proResMap).deletingLastPathComponent()
        XCTAssertEqual(try IMFPackageParser.parsePackage(folder: proResPackage).essences.map(\.kind),
                       [.mainImage, .mainAudio])

        let j2kCompleted = expectation(description: "experimental JPEG 2000 IMF export")
        let j2kConverter = FFMPEGConverter()
        await j2kConverter.convert(
            request: ConversionRequest(inputURL: source,
                                       outputURL: directory.appendingPathComponent("export_j2k"),
                                       preset: .imfJ2K),
            progressUpdate: { _, _ in },
            completion: { success, reason in
                XCTAssertTrue(success, reason ?? "Unknown conversion failure")
                j2kCompleted.fulfill()
            }
        )
        await fulfillment(of: [j2kCompleted], timeout: 120)
        let j2kFiles = try FileManager.default.subpathsOfDirectory(
            atPath: directory.appendingPathComponent("export_j2k").path
        )
        XCTAssertTrue(j2kFiles.contains { $0.hasSuffix("ASSETMAP.xml") })
        let j2kMap = try XCTUnwrap(j2kFiles.first { $0.hasSuffix("ASSETMAP.xml") })
        let j2kPackage = directory.appendingPathComponent("export_j2k")
            .appendingPathComponent(j2kMap).deletingLastPathComponent()
        XCTAssertEqual(try IMFPackageParser.parsePackage(folder: j2kPackage).essences.map(\.kind),
                       [.mainImage, .mainAudio])
    }

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
