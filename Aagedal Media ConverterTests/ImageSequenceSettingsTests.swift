import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ImageSequenceSettingsTests: XCTestCase {
    func testDefaultsAndInvalidPreferencesDoNotRewriteStoredValues() throws {
        let suite = "ImageSequenceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = ImageSequenceSettings(defaults: defaults)
        XCTAssertEqual(initial.format, .png)
        XCTAssertEqual(initial.jpegQuality, AppConstants.defaultImageSequenceExportQuality)
        XCTAssertEqual(initial.numberingPadding, AppConstants.defaultImageSequenceNumberingPadding)
        XCTAssertEqual(initial.metadataSidecarEnabled, AppConstants.defaultImageSequenceMetadataSidecarEnabled)
        XCTAssertEqual(initial.metadataSidecarFormat.rawValue, AppConstants.defaultImageSequenceMetadataSidecarFormat)

        defaults.set("removed-format", forKey: AppConstants.imageSequenceExportFormatKey)
        defaults.set("removed-sidecar", forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)
        defaults.set(false, forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
        for invalid in [-1, 0, Int.max] {
            defaults.set(invalid, forKey: AppConstants.imageSequenceExportQualityKey)
            defaults.set(invalid, forKey: AppConstants.imageSequenceNumberingPaddingKey)
            let settings = ImageSequenceSettings(defaults: defaults)
            XCTAssertEqual(settings.format, .png)
            XCTAssertEqual(settings.metadataSidecarFormat, .markdown)
            XCTAssertFalse(settings.metadataSidecarEnabled)
            XCTAssertEqual(settings.jpegQuality, AppConstants.defaultImageSequenceExportQuality)
            XCTAssertEqual(settings.numberingPadding, AppConstants.defaultImageSequenceNumberingPadding)
            XCTAssertEqual(defaults.integer(forKey: AppConstants.imageSequenceExportQualityKey), invalid)
            XCTAssertEqual(defaults.integer(forKey: AppConstants.imageSequenceNumberingPaddingKey), invalid)
        }
        XCTAssertEqual(defaults.string(forKey: AppConstants.imageSequenceExportFormatKey), "removed-format")
    }

    func testCapturedSettingsKeepFrameNamingEncodingAndSidecarConsistent() async throws {
        let suite = "ImageSequenceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ImageSequenceFormat.jpeg.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        defaults.set(5, forKey: AppConstants.imageSequenceExportQualityKey)
        defaults.set(8, forKey: AppConstants.imageSequenceNumberingPaddingKey)
        defaults.set(true, forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
        defaults.set(MetadataSidecarGenerator.SidecarFormat.json.rawValue, forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)
        let captured = ImageSequenceSettings(defaults: defaults)
        await Task.yield()
        defaults.removePersistentDomain(forName: suite)
        let output = URL(fileURLWithPath: "/output/\(captured.outputPattern(baseName: "frame"))")
        let ordinary = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/frames"), outputFileURL: output,
            preset: .imageSequence, imageSequenceSettings: captured, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil,
            customInputArguments: ["-framerate", "24", "-i", "/source/frame_%06d.png"]
        )
        let waveform = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: URL(fileURLWithPath: "/source/audio.wav"), outputFileURL: output,
            preset: .imageSequence, imageSequenceSettings: captured,
            width: 1920, height: 1080, frameRate: 24, trimStart: nil, trimEnd: nil
        )
        for command in [ordinary, waveform] {
            let codec = try XCTUnwrap(command.arguments.firstIndex(of: "-c:v"))
            let quality = try XCTUnwrap(command.arguments.firstIndex(of: "-q:v"))
            XCTAssertEqual(command.arguments[codec + 1], "mjpeg")
            XCTAssertEqual(command.arguments[quality + 1], "5")
            XCTAssertEqual(command.arguments.last, "/output/frame_%08d.jpg")
            XCTAssertTrue(command.arguments.contains("-an"))
        }
        XCTAssertTrue(captured.metadataSidecarEnabled)
        XCTAssertEqual(captured.metadataSidecarFormat, .json)
        XCTAssertEqual(ImageSequenceSettings(defaults: defaults).outputPattern(baseName: "frame"), "frame_%06d.png")
    }

    func testGeneratedMediaExportUsesCapturedJPEGFramesAndJSONSidecar() async throws {
        let suite = "ImageSequenceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ImageSequenceFormat.jpeg.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        defaults.set(1, forKey: AppConstants.imageSequenceExportQualityKey)
        defaults.set(4, forKey: AppConstants.imageSequenceNumberingPaddingKey)
        defaults.set(true, forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
        defaults.set(MetadataSidecarGenerator.SidecarFormat.json.rawValue, forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)
        let captured = ImageSequenceSettings(defaults: defaults)
        defaults.set(ImageSequenceFormat.png.rawValue, forKey: AppConstants.imageSequenceExportFormatKey)
        defaults.set(8, forKey: AppConstants.imageSequenceNumberingPaddingKey)
        defaults.set(false, forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
        defaults.set(MetadataSidecarGenerator.SidecarFormat.markdown.rawValue, forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageSequenceSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBinary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
        let ffmpeg = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) ?? sourceBinary
        let source = directory.appendingPathComponent("source.mkv")
        let generated = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "color=c=red:s=32x32:r=1:d=1", "-c:v", "ffv1", source.path],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let metadata = try await VideoMetadataService.shared.metadata(for: source)
        let outputFolder = directory.appendingPathComponent("frames", isDirectory: true)
        let finished = expectation(description: "Image sequence export completed")
        let converter = FFMPEGConverter(ffmpegPathProvider: { ffmpeg.path })
        await converter.convert(
            request: ConversionRequest(
                inputURL: source, outputURL: outputFolder, preset: .imageSequence,
                includeDateTag: false, sourceMetadata: metadata, expectedDuration: 1
            ),
            imageSequenceSettings: captured,
            progressUpdate: { _, _ in },
            completion: { success, reason in
                XCTAssertTrue(success, reason ?? "Conversion failed")
                finished.fulfill()
            }
        )
        await fulfillment(of: [finished], timeout: 30)
        let outputFiles = try FileManager.default.contentsOfDirectory(atPath: outputFolder.path)
        XCTAssertEqual(Set(outputFiles), ["frames_0001.jpg", "SourceMetadata_source.json"])
        let sidecar = try Data(contentsOf: outputFolder.appendingPathComponent("SourceMetadata_source.json"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        let decoded = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-i",
                        outputFolder.appendingPathComponent("frames_0001.jpg").path,
                        "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"],
            timeout: .seconds(15)
        ))
        XCTAssertTrue(decoded.succeeded, decoded.standardErrorText)
        let pixels = decoded.standardOutput
        XCTAssertEqual(pixels.count, 32 * 32 * 3)
        guard pixels.count == 32 * 32 * 3 else { return }
        let center = ((16 * 32) + 16) * 3
        XCTAssertGreaterThan(pixels[center], 220)
        XCTAssertLessThan(pixels[center + 1], 30)
        XCTAssertLessThan(pixels[center + 2], 30)
    }

}
