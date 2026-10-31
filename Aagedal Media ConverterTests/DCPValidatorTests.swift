import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class DCPValidatorTests: XCTestCase {
    // MARK: - Colour conversion

    func testWhiteMapsBelowZClipWithDCINormalization() {
        let white = DCPColorConversion.xyzPrime(red: 1, green: 1, blue: 1)
        // DCP-o-matic reference values for D65 white with the 48/52.37 normalisation.
        XCTAssertEqual(white.x, 0.9483, accuracy: 0.0005)
        XCTAssertEqual(white.y, 0.9670, accuracy: 0.0005)
        XCTAssertEqual(white.z, 0.9992, accuracy: 0.0005)
        XCTAssertLessThan(white.z, 1, "Z must not clip for reference white")

        let black = DCPColorConversion.xyzPrime(red: 0, green: 0, blue: 0)
        XCTAssertEqual(black.x, 0)
        XCTAssertEqual(black.y, 0)
        XCTAssertEqual(black.z, 0)
    }

    func testCubeHasExpectedEntryCount() {
        let text = String(decoding: DCPColorConversion.cubeData(size: 5), as: UTF8.self)
        let rows = text.split(separator: "\n").filter { $0.first?.isNumber == true }
        XCTAssertEqual(rows.count, 125)
        XCTAssertTrue(text.contains("LUT_3D_SIZE 5"))
    }

    // MARK: - Rate control

    func testRatePlanHonoursBitrateWithinDCILimit() throws {
        let twoK24 = DCPJ2KRatePlan(resolution: .twoKFlat, frameRate: .fps24, bitrate: .max)
        XCTAssertEqual(twoK24.cinemaMode, "2k_24")
        XCTAssertEqual(twoK24.maxFrameBytes, 1_302_083)
        XCTAssertEqual(twoK24.peakMegabitsPerSecond, 250)

        let twoK25 = DCPJ2KRatePlan(resolution: .twoKFlat, frameRate: .fps25, bitrate: .max)
        XCTAssertEqual(twoK25.maxFrameBytes, 1_250_000, "250 Mbit/s at 25 fps, not the 24 fps cap")

        let medium = DCPJ2KRatePlan(resolution: .twoKScope, frameRate: .fps24, bitrate: .medium)
        XCTAssertEqual(medium.peakMegabitsPerSecond, 150)

        let fourK30 = DCPJ2KRatePlan(resolution: .fourKFlat, frameRate: .fps30, bitrate: .max)
        XCTAssertEqual(fourK30.cinemaMode, "4k_24")
        XCTAssertEqual(fourK30.maxFrameBytes, 1_041_666)

        let suite = "DCPValidatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DCPFrameRate.fps25.rawValue, forKey: AppConstants.dcpFrameRateKey)
        defaults.set(DCPBitrate.max.rawValue, forKey: AppConstants.dcpBitrateKey)
        let arguments = DCPSettings(defaults: defaults).ffmpegArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "-max_cs_size"))
        XCTAssertEqual(arguments[index + 1], "1250000")
    }

    func testFourKHighFrameRateIsRejected() throws {
        let suite = "DCPValidatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DCPResolution.fourKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        defaults.set(DCPFrameRate.fps48.rawValue, forKey: AppConstants.dcpFrameRateKey)
        XCTAssertNotNil(DCPSettings(defaults: defaults).configurationError)

        defaults.set(DCPResolution.twoKFull.rawValue, forKey: AppConstants.dcpResolutionKey)
        XCTAssertNil(DCPSettings(defaults: defaults).configurationError)
    }

    // MARK: - ISDCF naming

    func testISDCFNameFollowsConvention() {
        let date = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC
        let name = DCPService.isdcfName(
            title: "Blåbær Øy", contentKind: .feature, frameRate: .fps24, resolution: .twoKFlat,
            audioLanguage: "nb", audioCode: "51", date: date
        )
        XCTAssertEqual(name, "Blabaer-Oy_FTR-1_F_NO-XX_51_2K_20261015_SMPTE_OV")

        let trailer = DCPService.isdcfName(
            title: "Trailer", contentKind: .trailer, frameRate: .fps25, resolution: .fourKScope,
            audioLanguage: "en", audioCode: "20", date: date
        )
        XCTAssertEqual(trailer, "Trailer_TLR-1-25_S_EN-XX_20_4K_20261015_SMPTE_OV")
    }

    func testAudioCarrierMapsSourceLayouts() {
        XCTAssertEqual(DCPAudioCarrier.channelMapFilter(sourceChannels: 1), "pan=5.1|c2=c0")
        XCTAssertEqual(DCPAudioCarrier.channelMapFilter(sourceChannels: 2), "pan=5.1|c0=c0|c1=c1")
        XCTAssertEqual(DCPAudioCarrier.isdcfAudioCode(sourceChannels: 0), "MOS")
        XCTAssertEqual(DCPAudioCarrier.isdcfAudioCode(sourceChannels: 6), "51")
        XCTAssertEqual(DCPAudioCarrier(frameCount: 30, frameRate: .fps24).duration, 1.25, accuracy: 1e-9)
        // 5 frames at 24 fps is 0.208333 s; millisecond rounding would give 9,984 samples.
        XCTAssertEqual(DCPAudioCarrier(frameCount: 5, frameRate: .fps24).sampleCount, 10_000)
        XCTAssertEqual(
            DCPAudioCarrier(frameCount: 5, frameRate: .fps24).lengthFilter,
            "apad=whole_len=10000,atrim=end_sample=10000"
        )
    }

    // MARK: - Validator

    func testMissingAssetMapIsReported() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = await DCPValidator.validate(directory: directory)
        XCTAssertEqual(report.issues.map(\.code), ["MISSING_ASSETMAP"])
    }

    /// Builds a real 30-frame DCP with the bundled ffmpeg and asdcp-wrap, exactly as the
    /// export pipeline does, then checks that it validates cleanly and that corruption is caught.
    func testGeneratedDCPValidatesCleanly() async throws {
        let work = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let dcp = try await buildDCP(in: work, embedAssetIDs: true, mcaLabels: true)

        let report = await DCPValidator.validate(directory: dcp)
        let problems = report.issues.filter { $0.severity != .info }
        XCTAssertTrue(problems.isEmpty, report.text)
        XCTAssertEqual(report.compositions.first?.durationFrames, Self.frameCount)
        XCTAssertEqual(report.compositions.first?.soundChannels, 6)

        // Flip one byte of the sound essence: the PKL hash check must catch it.
        let fm = FileManager.default
        let pcm = try XCTUnwrap(fm.contentsOfDirectory(atPath: dcp.path).first { $0.hasPrefix("pcm_") })
        let handle = try FileHandle(forUpdating: dcp.appendingPathComponent(pcm))
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end - 100)
        let byte = try XCTUnwrap(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: end - 100)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()

        let corrupted = await DCPValidator.validate(directory: dcp)
        XCTAssertTrue(corrupted.issues.contains { $0.code == "INCORRECT_ASSET_HASH" }, corrupted.text)
    }

    /// The pre-fix pipeline let asdcp-wrap pick random AssetUUIDs and wrote no MCA labels.
    func testValidatorFlagsMismatchedAssetIDsAndMissingMCA() async throws {
        let work = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let dcp = try await buildDCP(in: work, embedAssetIDs: false, mcaLabels: false)

        let report = await DCPValidator.validate(directory: dcp, options: .init(verifyHashes: false))
        let codes = report.issues.map(\.code)
        XCTAssertEqual(codes.filter { $0 == "MISMATCHED_ASSET_ID" }.count, 2, report.text)
        XCTAssertTrue(codes.contains("MISSING_SOUND_MCA_LABELS"), report.text)
    }

    // MARK: - Fixture

    private static let frameCount = 30

    private func buildDCP(in work: URL, embedAssetIDs: Bool, mcaLabels: Bool) async throws -> URL {
        guard let ffmpeg = BinaryPathResolver.ffmpegPath, let asdcpWrap = BinaryPathResolver.asdcpWrapPath else {
            throw XCTSkip("Bundled ffmpeg/asdcp-wrap not available")
        }
        let fm = FileManager.default
        let frames = Self.frameCount
        let settings = DCPSettings(defaults: try isolatedDefaults())

        // Picture: the preset's own encoder arguments, written as raw codestreams.
        let j2cDir = work.appendingPathComponent("j2c", isDirectory: true)
        try fm.createDirectory(at: j2cDir, withIntermediateDirectories: true)
        try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24", "-frames:v", "\(frames)"]
            + settings.ffmpegArguments + ["-format", "j2k", j2cDir.appendingPathComponent("f_%06d.j2c").path])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: j2cDir.path).count, frames)

        // Sound: a 1 s stereo source, shorter than the picture, goes through the 5.1 carrier.
        let source = work.appendingPathComponent("source.wav")
        try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=1",
                         "-ac", "2", "-c:a", "pcm_s16le", source.path])
        let extraction = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: source, outputFolder: work, ffmpegPath: ffmpeg, trimStart: nil, trimEnd: nil,
            dcpCarrier: DCPAudioCarrier(frameCount: frames, frameRate: .fps24)
        )
        guard case .extracted(let wav, let sourceChannels) = extraction else {
            XCTFail("Audio extraction failed: \(extraction)")
            throw CancellationError()
        }
        XCTAssertEqual(sourceChannels, 2)

        let videoID = SMPTEPackageUtils.urnUUID()
        let audioID = SMPTEPackageUtils.urnUUID()
        let videoMXF = work.appendingPathComponent("video.mxf")
        let audioMXF = work.appendingPathComponent("audio.mxf")
        let videoIDArgs = embedAssetIDs ? ["-a", SMPTEPackageUtils.uuidString(from: videoID)] : []
        let audioIDArgs = embedAssetIDs ? ["-a", SMPTEPackageUtils.uuidString(from: audioID)] : []
        let mcaArgs = mcaLabels ? ["-m", DCPAudioCarrier.mcaExpression, "-g", "en"] : []
        try run(asdcpWrap, ["-p", "24", "-L"] + videoIDArgs + [j2cDir.path + "/", videoMXF.path])
        try run(asdcpWrap, ["-p", "24", "-L", "-d", "\(frames)"] + audioIDArgs + mcaArgs + [wav.path, audioMXF.path])

        let dcp = work.appendingPathComponent("Test_TST-1_F_EN-XX_20_2K_20261029_SMPTE_OV", isDirectory: true)
        try fm.createDirectory(at: dcp, withIntermediateDirectories: true)
        let assembled = await DCPService.shared.assembleDCP(
            videoMXFURL: videoMXF, videoAssetID: videoID, audioMXFURL: audioMXF, audioAssetID: audioID,
            outputDirectoryURL: dcp, title: "Test", resolution: settings.resolution,
            frameRate: settings.frameRate, frameCount: frames,
            itemMetadata: DCPItemMetadata(contentTitleText: "Test", contentKind: .test),
            progress: { _ in }
        )
        XCTAssertTrue(assembled)
        return dcp
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DCPValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "DCPValidatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(DCPResolution.twoKFlat.rawValue, forKey: AppConstants.dcpResolutionKey)
        return defaults
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DCPValidatorTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(String(decoding: stderr, as: UTF8.self))"
            ])
        }
    }
}
