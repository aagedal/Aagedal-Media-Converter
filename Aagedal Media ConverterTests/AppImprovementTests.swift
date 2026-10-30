import XCTest
import os
@testable import Aagedal_Media_Converter

final class AppImprovementTests: XCTestCase {
    func testSettlingRequiresQuietSizeAndModificationTime() {
        let start = Date(timeIntervalSince1970: 100)
        let first = WatchFolderObservation(size: 100, modifiedAt: start, observedAt: start, previous: nil)
        XCTAssertFalse(first.isStable(at: start.addingTimeInterval(60), interval: 10))
        let quiet = WatchFolderObservation(size: 100, modifiedAt: start, observedAt: start.addingTimeInterval(5), previous: first)
        XCTAssertFalse(quiet.isStable(at: start.addingTimeInterval(5), interval: 10))
        XCTAssertTrue(quiet.isStable(at: start.addingTimeInterval(10), interval: 10))
        let rewritten = WatchFolderObservation(size: 100, modifiedAt: start.addingTimeInterval(10), observedAt: start.addingTimeInterval(10), previous: quiet)
        XCTAssertFalse(rewritten.isStable(at: start.addingTimeInterval(30), interval: 10))
        let growing = WatchFolderObservation(size: 200, modifiedAt: start, observedAt: start.addingTimeInterval(10), previous: quiet)
        XCTAssertFalse(growing.isStable(at: start.addingTimeInterval(30), interval: 10))
    }

    func testInvalidSettlingPreferencesUseSafeDefault() throws {
        let name = "AppImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for value in [0, -1, 10.5, Double.nan, Double.infinity] {
            defaults.set(value, forKey: AppConstants.watchFolderSettlingSecondsKey)
            XCTAssertEqual(WatchFolderObservation.settlingInterval(defaults: defaults), 10)
        }
        defaults.set(30, forKey: AppConstants.watchFolderSettlingSecondsKey)
        XCTAssertEqual(WatchFolderObservation.settlingInterval(defaults: defaults), 30)
    }

    func testCleanupKeepsQueuedAndGrowingFilesButTrashesQuietOldFile() async throws {
        enum Finished: Error { case finished }
        let name = "AppImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: name)
        }
        let queued = folder.appendingPathComponent("queued.mov")
        let growing = folder.appendingPathComponent("growing.mov")
        let quiet = folder.appendingPathComponent("quiet.mov")
        for url in [queued, growing, quiet] { try Data([1]).write(to: url) }
        defaults.set(true, forKey: AppConstants.watchFolderAutoDeleteOlderThanWeekKey)
        defaults.set(1, forKey: AppConstants.watchFolderDeleteDurationValueKey)
        defaults.set("days", forKey: AppConstants.watchFolderDeleteDurationUnitKey)
        defaults.set(folder.path, forKey: WatchFolderSelectionService.writableGrantPathKey)
        let scan = OSAllocatedUnfairLock(initialState: 0)
        let trashed = OSAllocatedUnfairLock(initialState: [URL]())
        let finished = expectation(description: "Cleanup scanned twice")
        let manager = WatchFolderManager(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), settlingInterval: 0, readinessProbe: { _ in true }, trashItem: { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }, pollingWait: {
            let count = scan.withLock { $0 += 1; return $0 }
            if count == 2 { finished.fulfill(); throw Finished.finished }
        }, readResourceValues: { url in
            var values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            values.creationDate = Date(timeIntervalSince1970: 0)
            values.contentModificationDate = Date(timeIntervalSince1970: url == growing ? Double(scan.withLock { $0 }) : 0)
            return values
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { _ in
            XCTFail("Old cleanup candidates must not be imported")
        }, protectedFiles: { [queued] })
        await fulfillment(of: [finished], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(trashed.withLock { $0 }, [quiet])
        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: growing.path))
    }

    func testUnreadableWatchFileRetriesWithoutRepeatedAlerts() async throws {
        enum Finished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.mov")
        try Data([1]).write(to: file)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let imported = OSAllocatedUnfairLock(initialState: [URL]())
        let finished = expectation(description: "Probe eventually succeeds")
        let manager = WatchFolderManager(settlingInterval: 0, readinessProbe: { _ in
            probes.withLock { $0 += 1; return $0 >= 3 }
        }, pollingWait: {
            if !imported.withLock({ $0.isEmpty }) { finished.fulfill(); throw Finished.finished }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            imported.withLock { $0.append(contentsOf: urls) }
        }, onError: { message in errors.withLock { $0.append(message) } })
        await fulfillment(of: [finished], timeout: 3)
        await manager.stopMonitoring(generation: 2)
        XCTAssertEqual(imported.withLock { $0 }, [file])
        XCTAssertEqual(probes.withLock { $0 }, 3)
        XCTAssertEqual(errors.withLock { $0.count }, 1)
    }

    func testSlowReadinessProbeDoesNotDelayHealthyImport() async throws {
        enum Finished: Error { case finished }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let slow = folder.appendingPathComponent("slow.mov")
        let healthy = folder.appendingPathComponent("healthy.mov")
        for url in [slow, healthy] { try Data([1]).write(to: url) }
        let gate = ReadinessProbeGate()
        let imported = expectation(description: "Healthy import arrives while slow probe is blocked")
        let manager = WatchFolderManager(settlingInterval: 0, readinessProbe: { url in
            if url == slow { await gate.wait(); return false }
            return true
        }, pollingWait: {
            if await gate.isOpen { throw Finished.finished }
        })
        await manager.startMonitoring(folderPath: folder.path, generation: 1, onNewFiles: { urls in
            XCTAssertEqual(urls, [healthy])
            imported.fulfill()
        })
        await fulfillment(of: [imported], timeout: 3)
        let slowFinished = await gate.isOpen
        XCTAssertFalse(slowFinished)
        await manager.stopMonitoring(generation: 2)
        await gate.release()
    }

    func testDiagnosticUsesBoundedRunnerAndMatchesReplyID() async throws {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": [
            "isError": false,
            "structuredContent": ["presets": ApplicationPresetID.allCases.map { ["id": $0.rawValue] }]
        ]]
        let data = try JSONSerialization.data(withJSONObject: response) + Data("\n{\"id\":1,\"result\":{}}\n".utf8)
        let runner = DiagnosticRunner(output: data)
        let succeeded = try await ApplicationAgentMCPConnectionDiagnostic.test(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        XCTAssertTrue(succeeded)
        let captured = await runner.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.timeout, .seconds(15))
        let messages = try XCTUnwrap(request.standardInput).split(separator: 0x0A)
        XCTAssertEqual(messages.count, 3)
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[2])) as? [String: Any])
        XCTAssertEqual(call["method"] as? String, "tools/call")
    }

    func testDiagnosticRejectsTruncatedOutput() async throws {
        let runner = DiagnosticRunner(output: Data(), discarded: 1)
        let succeeded = try await ApplicationAgentMCPConnectionDiagnostic.test(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        XCTAssertFalse(succeeded)
    }
}

private actor DiagnosticRunner: SubprocessRunning {
    var request: SubprocessRequest?
    let output: Data
    let discarded: Int

    init(output: Data, discarded: Int = 0) {
        self.output = output
        self.discarded = discarded
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        self.request = request
        return SubprocessResult(terminationStatus: 0, termination: .exited, standardOutput: output, standardError: Data(), discardedStandardOutputBytes: discarded, discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor ReadinessProbeGate {
    var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class PreviewWaveformCacheTests: XCTestCase {
    private func waveform(_ value: Float = 0.5) -> SendableChannelWaveform {
        SendableChannelWaveform(channelImages: [], channelLabels: ["L"], channelEnvelopes: [
            WaveformEnvelope(peaks: [.init(minimum: -value, maximum: value)],
                             frameCount: 256, framesPerBin: 256, sampleRate: 48_000)
        ])
    }

    func testWaveformCacheEvictsLeastRecentlyUsedSourceWithinBudget() {
        let value = waveform()
        let cost = PreviewWaveformCache.cost(value)
        var cache = PreviewWaveformCache(byteLimit: cost * 2)
        let urls = (0..<3).map { URL(fileURLWithPath: "/cache/\($0).wav") }
        cache.insert(value, for: urls[0], fingerprint: "a", stream: 0)
        cache.insert(value, for: urls[1], fingerprint: "b", stream: 0)
        XCTAssertEqual(cache.waveforms(for: urls[0], fingerprint: "a").count, 1)
        cache.insert(value, for: urls[2], fingerprint: "c", stream: 0)
        XCTAssertTrue(cache.waveforms(for: urls[1], fingerprint: "b").isEmpty)
        XCTAssertEqual(cache.waveforms(for: urls[0], fingerprint: "a").count, 1)
        XCTAssertEqual(cache.retainedBytes, cost * 2)
    }

    func testChangedSourceAndExplicitCleanupReleaseWaveforms() {
        var cache = PreviewWaveformCache()
        let url = URL(fileURLWithPath: "/cache/replaced.wav")
        cache.insert(waveform(), for: url, fingerprint: "original", stream: 0)
        XCTAssertTrue(cache.waveforms(for: url, fingerprint: "replacement").isEmpty)
        XCTAssertEqual(cache.retainedBytes, 0)
        cache.insert(waveform(), for: url, fingerprint: "replacement", stream: 1)
        cache.remove(url)
        XCTAssertTrue(cache.waveforms(for: url, fingerprint: "replacement").isEmpty)
        cache.insert(waveform(), for: url, fingerprint: "replacement", stream: 1)
        cache.removeAll()
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertTrue(cache.waveforms(for: url, fingerprint: "replacement").isEmpty)
    }

    func testOversizedWaveformsAreNotRetainedAndReplacementUpdatesCost() {
        let value = waveform()
        let cost = PreviewWaveformCache.cost(value)
        var cache = PreviewWaveformCache(byteLimit: cost)
        let url = URL(fileURLWithPath: "/cache/multitrack.wav")
        cache.insert(value, for: url, fingerprint: "a", stream: 0)
        cache.insert(value, for: url, fingerprint: "a", stream: 0)
        XCTAssertEqual(cache.retainedBytes, cost)
        cache.insert(value, for: url, fingerprint: "a", stream: 1)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertTrue(cache.waveforms(for: url, fingerprint: "a").isEmpty)
    }
}

final class NativeWaveformImprovementTests: XCTestCase {
    func testSilentBandIsNotAmplifiedToFullScale() {
        // Band 0 carries real signal; band 1 is only a faint noise floor.
        var magnitudes = (0..<200).map { frame -> [Float] in
            [Float(frame % 10) / 10, 0.0001 * Float(frame % 3)]
        }
        WaveformPCMDecoder.normalizePerBand(&magnitudes, bandCount: 2)
        XCTAssertGreaterThan(magnitudes.map { $0[0] }.max() ?? 0, 0.9)
        XCTAssertLessThan(magnitudes.map { $0[1] }.max() ?? 1, 0.05)
    }

    func testSingleTransientDoesNotFlattenBand() {
        var magnitudes = [[Float]](repeating: [0.5], count: 1000)
        magnitudes[500] = [50]
        WaveformPCMDecoder.normalizePerBand(&magnitudes, bandCount: 1)
        XCTAssertEqual(magnitudes[0][0], 1, accuracy: 0.001)
    }

    func testDecayFactorKeepsReleaseTimeAcrossFrameRates() {
        let at25 = WaveformAnimationState.decayFactor(frameRate: 25)
        let at50 = WaveformAnimationState.decayFactor(frameRate: 50)
        XCTAssertEqual(at25, 0.85, accuracy: 0.0001)
        // Two frames at 50 fps decay as much as one frame at 25 fps.
        XCTAssertEqual(at50 * at50, at25, accuracy: 0.0001)
    }

    func testReusedContextDoesNotLeakPreviousFrame() throws {
        let ctx = try XCTUnwrap(NativeWaveformVideoRenderer.makeContext(width: 64, height: 36))
        let loud = [Float](repeating: 1, count: 8)
        let silent = [Float](repeating: 0, count: 8)
        _ = NativeWaveformVideoRenderer.renderFrame(
            style: .bars, frame: WaveformFrameInput(magnitudes: loud), width: 64, height: 36,
            foregroundColor: (255, 255, 255), backgroundColor: (0, 0, 0), context: ctx)
        let reused = NativeWaveformVideoRenderer.renderFrame(
            style: .bars, frame: WaveformFrameInput(magnitudes: silent), width: 64, height: 36,
            foregroundColor: (255, 255, 255), backgroundColor: (0, 0, 0), context: ctx)
        let fresh = NativeWaveformVideoRenderer.renderFrame(
            style: .bars, frame: WaveformFrameInput(magnitudes: silent), width: 64, height: 36,
            foregroundColor: (255, 255, 255), backgroundColor: (0, 0, 0))
        XCTAssertEqual(reused, fresh)
    }

    func testSyntheticPreviewMagnitudesStayInRange() {
        for step in 0..<100 {
            let mags = WaveformStylePreview.syntheticMagnitudes(at: Double(step) * 0.037, bandCount: 32)
            XCTAssertEqual(mags.count, 32)
            XCTAssertTrue(mags.allSatisfy { (0...1).contains($0) })
        }
    }

    func testPeakHoldsThenFalls() {
        var state = WaveformAnimationState(bandCount: 1, frameRate: 25, style: .led)
        _ = state.advance(raw: [1])
        var input = state.advance(raw: [0])
        for _ in 0..<5 { input = state.advance(raw: [0]) }
        // Still inside the 0.5 s hold window.
        XCTAssertEqual(input.peakMagnitudes?[0] ?? 0, 1, accuracy: 0.0001)
        for _ in 0..<40 { input = state.advance(raw: [0]) }
        XCTAssertLessThan(input.peakMagnitudes?[0] ?? 1, 0.1)
    }

    func testRidgeHistoryScrollsContinuously() {
        let stride = WaveformAnimationState.historyStride(frameRate: 50)
        var state = WaveformAnimationState(bandCount: 4, frameRate: 50, style: .ridgeline)
        var input = WaveformFrameInput(magnitudes: [])
        // Frames 0...(3 * stride + 1): samples at 0, stride, 2·stride, 3·stride.
        for _ in 0..<(stride * 3 + 2) { input = state.advance(raw: [0.5, 0.5, 0.5, 0.5]) }
        XCTAssertEqual(input.history.count, 4)
        XCTAssertEqual(input.historyPhase, 1.0 / Double(stride), accuracy: 0.0001)

        var other = WaveformAnimationState(bandCount: 4, frameRate: 50, style: .bars)
        XCTAssertTrue(other.advance(raw: [1, 1, 1, 1]).history.isEmpty)
    }

    func testEveryStyleRendersForEdgeCaseBandCounts() throws {
        for style in SwiftWaveformStyle.allCases {
            for bandCount in [1, 2, 64] {
                for gradient in [false, true] {
                    let frame = WaveformStylePreview.simulatedFrame(
                        at: 1000, style: style, bandCount: bandCount, frameRate: 25)
                    let image = NativeWaveformVideoRenderer.renderImage(
                        style: style, frame: frame, width: 160, height: 90,
                        foregroundColor: (255, 255, 255), backgroundColor: (0, 0, 0),
                        foregroundGradientEnd: gradient ? (255, 0, 0) : nil,
                        waveformOpacity: gradient ? 0.7 : 1)
                    XCTAssertNotNil(image, "\(style) bands=\(bandCount)")
                }
            }
        }
    }

    // MARK: Alpha export

    func testAlphaOutputDecisionPerEncoder() {
        var prores4444 = ["-pix_fmt", "yuv422p10le", "-vcodec", "prores_videotoolbox", "-profile:v", "4444"]
        XCTAssertTrue(FFMPEGCommandBuilder.enableAlphaOutput(in: &prores4444))
        XCTAssertEqual(prores4444, ["-pix_fmt", "yuva444p10le", "-vcodec", "prores_videotoolbox", "-profile:v", "4444"])

        var proresXQ = ["-c:v", "prores_ks", "-profile:v", "4444xq"]
        XCTAssertTrue(FFMPEGCommandBuilder.enableAlphaOutput(in: &proresXQ))
        XCTAssertEqual(proresXQ.suffix(2), ["-pix_fmt", "yuva444p10le"])

        var proresHQ = ["-pix_fmt", "yuv422p10le", "-vcodec", "prores_videotoolbox", "-profile:v", "hq"]
        XCTAssertFalse(FFMPEGCommandBuilder.enableAlphaOutput(in: &proresHQ))
        XCTAssertEqual(proresHQ[1], "yuv422p10le")

        var h264 = ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        XCTAssertFalse(FFMPEGCommandBuilder.enableAlphaOutput(in: &h264))
        var png = ["-c:v", "png", "-an"]
        XCTAssertTrue(FFMPEGCommandBuilder.enableAlphaOutput(in: &png))
        var jpeg = ["-c:v", "mjpeg", "-q:v", "2"]
        XCTAssertFalse(FFMPEGCommandBuilder.enableAlphaOutput(in: &jpeg))
        var ffv1 = ["-c:v", "ffv1", "-level", "3"]
        XCTAssertTrue(FFMPEGCommandBuilder.enableAlphaOutput(in: &ffv1))
        var imf4444 = ["-c:v", "prores_ks", "-profile:v", "hq", "-pix_fmt", "yuva444p10le"]
        XCTAssertTrue(FFMPEGCommandBuilder.enableAlphaOutput(in: &imf4444))
    }

    func testTransparentFrameUsesStraightAlphaAndEmptyBackground() throws {
        let width = 64, height = 36
        let data = NativeWaveformVideoRenderer.renderFrame(
            style: .bars, frame: WaveformFrameInput(magnitudes: [Float](repeating: 1, count: 4)),
            width: width, height: height,
            foregroundColor: (255, 255, 255), backgroundColor: (200, 0, 0),
            waveformOpacity: 0.5, transparentBackground: true)
        let bytes = [UInt8](data)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
        XCTAssertEqual(pixel(0, 0), [0, 0, 0, 0], "Background must stay fully transparent")
        // Centre of the first bar: white at 50 % opacity, un-premultiplied for FFmpeg's `bgra`.
        let bar = pixel(Int(CGFloat(width) * 0.04) + 3, height / 2)
        XCTAssertEqual(Int(bar[3]), 128, accuracy: 2)
        XCTAssertEqual(Int(bar[0]), 255, accuracy: 2)
    }

    func testRidgelineOcclusionClearsTransparentBackground() throws {
        var state = WaveformAnimationState(bandCount: 8, frameRate: 25, style: .ridgeline)
        var frame = WaveformFrameInput(magnitudes: [])
        for _ in 0..<80 { frame = state.advance(raw: [Float](repeating: 0.6, count: 8)) }
        let image = try XCTUnwrap(NativeWaveformVideoRenderer.renderImage(
            style: .ridgeline, frame: frame, width: 320, height: 180,
            foregroundColor: (255, 255, 255), backgroundColor: (200, 0, 0), transparentBackground: true))
        let rgba = try XCTUnwrap(image.dataProvider?.data as Data?)
        let bytesPerRow = image.bytesPerRow
        // No pixel may carry the (opaque red) fallback background color.
        for y in stride(from: 0, to: 180, by: 3) {
            for x in stride(from: 0, to: 320, by: 3) {
                let o = y * bytesPerRow + x * 4
                let isRedBackground = rgba[o + 2] > 150 && rgba[o + 1] < 50 && rgba[o + 3] == 255
                XCTAssertFalse(isRedBackground, "Opaque background painted at \(x),\(y)")
                if isRedBackground { return }
            }
        }
    }

    func testProRes4444WaveformExportKeepsAlpha() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProResProfile.fourFourFourFour.rawValue, forKey: AppConstants.proResProfileKey)
        let settings = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        try await runFFmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", audio.path])

        let (width, height, fps) = (64, 36, 24)
        let output = directory.appendingPathComponent("waveform.mov")
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: audio, outputFileURL: output, preset: .prores, codecSettings: settings,
            width: width, height: height, frameRate: Double(fps), trimStart: nil, trimEnd: nil,
            includeDateTag: false, transparentBackground: true)
        XCTAssertTrue(command.preservesAlpha)
        XCTAssertTrue(command.arguments.contains("yuva444p10le"), command.arguments.joined(separator: " "))
        try await requireHardwareProResEncoder(in: directory)

        var frames = Data()
        for _ in 0..<fps {
            frames += NativeWaveformVideoRenderer.renderFrame(
                style: .bars, frame: WaveformFrameInput(magnitudes: [Float](repeating: 1, count: 4)),
                width: width, height: height, foregroundColor: (255, 255, 255),
                backgroundColor: (0, 0, 0), transparentBackground: true)
        }
        try await runFFmpeg(Array(command.arguments.drop(while: { $0 != "-f" })), standardInput: frames)

        let decoded = directory.appendingPathComponent("frame.rgba")
        try await runFFmpeg(["-i", output.path, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", decoded.path])
        let rgba = [UInt8](try Data(contentsOf: decoded))
        XCTAssertEqual(rgba.count, width * height * 4)
        XCTAssertLessThan(rgba[3], 5, "Background corner should be transparent")
        let bar = ((height / 2) * width + Int(CGFloat(width) * 0.04) + 3) * 4
        XCTAssertGreaterThan(rgba[bar + 3], 250, "Waveform should be opaque")
    }

    func testProRes4444ConversionKeepsSourceAlpha() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProResProfile.fourFourFourFour.rawValue, forKey: AppConstants.proResProfileKey)
        let settings = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))
        let metadata = alphaSourceMetadata()
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/source/alpha.mov"),
            outputFileURL: URL(fileURLWithPath: "/output/alpha.mov"),
            preset: .prores, codecSettings: settings, comment: "", includeDateTag: false,
            trimStart: nil, trimEnd: nil, sourceMetadata: metadata)
        XCTAssertTrue(command.arguments.contains("yuva444p10le"), command.arguments.joined(separator: " "))
    }

    // MARK: Matte sidecar

    func testMatteSidecarNaming() {
        XCTAssertEqual(FFMPEGCommandBuilder.matteSidecarURL(for: URL(fileURLWithPath: "/out/clip_h264.mp4")).path,
                       "/out/clip_h264_matte.mp4")
    }

    func testMatteOutputOptionsKeepOnlyVideoEncoderSettings() {
        let main = ["-hide_banner", "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-map", "0:v:0", "-map", "0:a?",
                    "-map_metadata", "0", "-metadata", "comment=x", "-metadata:s:a:0", "language=nor",
                    "-filter:a:0", "volume=2", "-disposition:a:0", "default", "-shortest", "-an",
                    "-movflags", "+faststart", "-tag:v", "avc1"]
        XCTAssertEqual(FFMPEGCommandBuilder.matteSidecarOutputOptions(from: main),
                       ["-hide_banner", "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", "-tag:v", "avc1"])
    }

    func testSourceMatteArgumentsReuseTrimAndFilters() throws {
        let main = ["-y", "-nostdin", "-progress", "pipe:2", "-ss", "1.0", "-i", "/in/a.mov",
                    "-t", "2.0", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "crop=100:100:0:0,scale=50:50",
                    "-filter_complex", "[0:a:0]pan=mono|c0=c0[aout]", "-map", "0:v:0", "-map", "[aout]",
                    "-c:a", "aac", "/out/a.mp4"]
        let matte = try XCTUnwrap(FFMPEGCommandBuilder.sourceMatteArguments(
            fromMainArguments: main, matteOutputURL: URL(fileURLWithPath: "/out/a_matte.mp4")))
        XCTAssertEqual(matte, ["-nostats", "-loglevel", "error", "-y", "-nostdin", "-ss", "1.0", "-i", "/in/a.mov",
                               "-map", "0:v:0", "-t", "2.0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                               "-vf", "crop=100:100:0:0,scale=50:50,format=yuva444p16le,alphaextract",
                               "-an", "-sn", "-dn", "/out/a_matte.mp4"])

        let noFilter = try XCTUnwrap(FFMPEGCommandBuilder.sourceMatteArguments(
            fromMainArguments: ["-i", "/in/a.mov", "-c:v", "libx264", "/out/a.mp4"],
            matteOutputURL: URL(fileURLWithPath: "/out/m.mp4")))
        XCTAssertEqual(Array(noFilter.suffix(8)), ["-c:v", "libx264", "-vf", "format=yuva444p16le,alphaextract", "-an", "-sn", "-dn", "/out/m.mp4"])

        XCTAssertNil(FFMPEGCommandBuilder.sourceMatteArguments(
            fromMainArguments: ["-i", "/in/a.mov", "-filter_complex", "[0:v]split[a][b]", "-map", "[a]", "/out/a.mp4"],
            matteOutputURL: URL(fileURLWithPath: "/out/m.mp4")))
    }

    func testOutputKeepsAlphaIgnoresRawvideoInput() {
        let waveform = ["-f", "rawvideo", "-pix_fmt", "bgra", "-i", "pipe:0", "-i", "/a.wav",
                        "-c:v", "libx264", "/out.mp4"]
        XCTAssertFalse(FFMPEGCommandBuilder.outputKeepsAlpha(waveform))
        XCTAssertTrue(FFMPEGCommandBuilder.outputKeepsAlpha(["-i", "/a.mov", "-c:v", "png", "/out.mov"]))
    }

    func testTransparentWaveformToH264WritesMatte() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        try await runFFmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", audio.path])

        let (width, height, fps) = (64, 36, 24)
        let output = directory.appendingPathComponent("waveform.mp4")
        let matte = FFMPEGCommandBuilder.matteSidecarURL(for: output)
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: audio, outputFileURL: output, preset: .h264, codecSettings: settings,
            width: width, height: height, frameRate: Double(fps), trimStart: nil, trimEnd: nil,
            includeDateTag: false, transparentBackground: true, matteOutputURL: matte)
        XCTAssertFalse(command.preservesAlpha)
        XCTAssertEqual(command.matteOutputURL, matte)

        var frames = Data()
        for _ in 0..<fps {
            frames += NativeWaveformVideoRenderer.renderFrame(
                style: .bars, frame: WaveformFrameInput(magnitudes: [Float](repeating: 1, count: 4)),
                width: width, height: height, foregroundColor: (255, 255, 255),
                backgroundColor: (200, 0, 0), transparentBackground: true)
        }
        try await runFFmpeg(Array(command.arguments.drop(while: { $0 != "-f" })), standardInput: frames)

        let matteGray = try await decodeGray(matte, directory: directory)
        let fillGray = try await decodeGray(output, directory: directory)
        XCTAssertEqual(matteGray.count, fillGray.count, "Matte and fill must have the same frames")
        let bar = (height / 2) * width + Int(CGFloat(width) * 0.04) + 3
        XCTAssertGreaterThan(matteGray[bar], 240, "Waveform is white in the matte")
        XCTAssertLessThan(matteGray[0], 15, "Background is black in the matte")
        XCTAssertLessThan(fillGray[0], 15, "Fill is black (not the red background) where transparent")
        try await assertCodec(of: matte, equalsCodecOf: output)
    }

    func testAlphaSourceToH264WritesAlignedMatte() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 2 s ProRes 4444 source: transparent left half, opaque white right half.
        let source = directory.appendingPathComponent("alpha.mov")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "color=c=white:s=64x36:r=25:d=2,format=yuva444p10le,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(lt(X,32),0,1023)'",
            "-f", "lavfi", "-i", "sine=duration=2",
            "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-c:a", "pcm_s16le", source.path,
        ])

        let output = directory.appendingPathComponent("alpha_h264.mp4")
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: source, outputFileURL: output, preset: .h264, codecSettings: settings,
            comment: "", includeDateTag: false, trimStart: 0.4, trimEnd: 1.6,
            sourceMetadata: alphaSourceMetadata())
        XCTAssertFalse(FFMPEGCommandBuilder.outputKeepsAlpha(command.arguments))
        let matte = FFMPEGCommandBuilder.matteSidecarURL(for: output)
        let matteArguments = try XCTUnwrap(FFMPEGCommandBuilder.sourceMatteArguments(
            fromMainArguments: command.arguments, matteOutputURL: matte))

        try await runFFmpeg(Array(command.arguments.drop(while: { $0 != "-progress" }).dropFirst(2)))
        try await runFFmpeg(Array(matteArguments.dropFirst(3)))

        let matteGray = try await decodeGray(matte, directory: directory)
        let fillGray = try await decodeGray(output, directory: directory)
        XCTAssertFalse(matteGray.isEmpty)
        XCTAssertEqual(matteGray.count, fillGray.count, "Matte must match the trimmed main output frame for frame")
        let row = 18 * 64
        XCTAssertLessThan(matteGray[row + 4], 15, "Transparent half is black")
        XCTAssertGreaterThan(matteGray[row + 60], 240, "Opaque half is white")
        try await assertCodec(of: matte, equalsCodecOf: output)
    }

    func testConverterWritesSourceMatteSidecar() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("graphic.mov")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "color=c=white:s=64x36:r=25:d=1,format=yuva444p10le,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(lt(X,32),0,1023)'",
            "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", source.path,
        ])

        var request = ConversionRequest(
            inputURL: source, outputURL: directory.appendingPathComponent("graphic_out"), preset: .h264,
            includeDateTag: false, sourceMetadata: alphaSourceMetadata(width: 64, height: 36), expectedDuration: 1)
        request.exportsMatteSidecar = true
        let ffmpegPath = bundledFFmpegURL.path
        let converter = FFMPEGConverter(ffmpegPathProvider: { ffmpegPath })
        let outcome = OSAllocatedUnfairLock<(Bool, String?)?>(initialState: nil)
        let finished = expectation(description: "Conversion completed")
        await converter.convert(request: request, codecSettings: settings, progressUpdate: { _, _ in },
                                completion: { ok, reason in outcome.withLock { $0 = (ok, reason) }; finished.fulfill() })
        await fulfillment(of: [finished], timeout: 60)
        XCTAssertEqual(outcome.withLock { $0?.0 }, true, outcome.withLock { $0?.1 } ?? "")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let main = try XCTUnwrap(files.first { $0.hasPrefix("graphic_out") && !$0.contains("_matte") }, "\(files)")
        let matte = try XCTUnwrap(files.first { $0.hasPrefix("graphic_out") && $0.contains("_matte") }, "\(files)")
        XCTAssertEqual((main as NSString).deletingPathExtension + "_matte." + (main as NSString).pathExtension, matte)
        let matteGray = try await decodeGray(directory.appendingPathComponent(matte), directory: directory)
        let fillGray = try await decodeGray(directory.appendingPathComponent(main), directory: directory)
        XCTAssertEqual(matteGray.count, fillGray.count)
        XCTAssertLessThan(matteGray[18 * 64 + 4], 15)
        XCTAssertGreaterThan(matteGray[18 * 64 + 60], 240)
    }

    func testConverterSkipsMatteWhenFormatKeepsAlpha() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProResProfile.fourFourFourFour.rawValue, forKey: AppConstants.proResProfileKey)
        let settings = try XCTUnwrap(CodecExportSettings(preset: .prores, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await requireHardwareProResEncoder(in: directory)
        let source = directory.appendingPathComponent("graphic.mov")
        try await runFFmpeg(["-f", "lavfi", "-i", "color=c=white@0.5:s=64x36:r=25:d=1,format=yuva444p10le",
                             "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", source.path])

        var request = ConversionRequest(
            inputURL: source, outputURL: directory.appendingPathComponent("graphic_out"), preset: .prores,
            includeDateTag: false, sourceMetadata: alphaSourceMetadata(width: 64, height: 36), expectedDuration: 1)
        request.exportsMatteSidecar = true
        let ffmpegPath = bundledFFmpegURL.path
        let converter = FFMPEGConverter(ffmpegPathProvider: { ffmpegPath })
        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let finished = expectation(description: "Conversion completed")
        await converter.convert(request: request, codecSettings: settings, progressUpdate: { _, _ in },
                                completion: { ok, _ in outcome.withLock { $0 = ok }; finished.fulfill() })
        await fulfillment(of: [finished], timeout: 60)
        XCTAssertEqual(outcome.withLock { $0 }, true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.contains("_matte") }, "\(files)")
    }

    func testConverterWritesWaveformMatteSidecar() async throws {
        let suite = "NativeWaveformImprovementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try XCTUnwrap(CodecExportSettings(preset: .h264, defaults: defaults))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        try await runFFmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", audio.path])

        var request = ConversionRequest(
            inputURL: audio, outputURL: directory.appendingPathComponent("tone_out"), preset: .h264,
            includeDateTag: false, expectedDuration: 1,
            waveformRequest: WaveformVideoRequest(
                width: 128, height: 72, backgroundHex: "C80000", foregroundHex: "FFFFFF",
                normalizeAudio: false, style: .linear, frameRate: 25, renderingEngine: .swift,
                swiftStyle: .halo, bandCount: 16, frequencyDistribution: .mel,
                foregroundGradientEnabled: false, foregroundGradientEndHex: "FFFFFF",
                backgroundGradientEnabled: false, backgroundGradientEndHex: "000000",
                waveformOpacity: 1, transparentBackground: true))
        request.exportsMatteSidecar = true
        let ffmpegPath = bundledFFmpegURL.path
        let converter = FFMPEGConverter(ffmpegPathProvider: { ffmpegPath })
        let outcome = OSAllocatedUnfairLock<(Bool, String?)?>(initialState: nil)
        let finished = expectation(description: "Conversion completed")
        await converter.convert(request: request, codecSettings: settings, progressUpdate: { _, _ in },
                                completion: { ok, reason in outcome.withLock { $0 = (ok, reason) }; finished.fulfill() })
        await fulfillment(of: [finished], timeout: 60)
        XCTAssertEqual(outcome.withLock { $0?.0 }, true, outcome.withLock { $0?.1 } ?? "")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let main = try XCTUnwrap(files.first { $0.hasPrefix("tone_out") && !$0.contains("_matte") }, "\(files)")
        let matte = try XCTUnwrap(files.first { $0.hasPrefix("tone_out") && $0.contains("_matte") }, "\(files)")
        let matteGray = try await decodeGray(directory.appendingPathComponent(matte), directory: directory)
        let fillGray = try await decodeGray(directory.appendingPathComponent(main), directory: directory)
        XCTAssertEqual(matteGray.count, fillGray.count)
        XCTAssertLessThan(matteGray[0], 15, "Corner is transparent → black matte")
        XCTAssertLessThan(fillGray[0], 15, "Fill is black where transparent, not the red background")
        XCTAssertTrue(matteGray.contains { $0 > 240 }, "Halo is opaque somewhere")
    }

    /// The ProRes preset encodes with `prores_videotoolbox`, which needs Apple's hardware
    /// ProRes encoder. Virtualized CI hosts don't expose it, so skip the encode there.
    private func requireHardwareProResEncoder(in directory: URL) async throws {
        let probe = directory.appendingPathComponent("prores-probe.mov")
        do {
            try await runFFmpeg(["-f", "lavfi", "-i", "color=c=black:s=64x36:r=25:d=0.04",
                                 "-c:v", "prores_videotoolbox", "-profile:v", "4444", probe.path])
        } catch {
            throw XCTSkip("Hardware ProRes encoder (VideoToolbox) unavailable on this host")
        }
    }

    /// All frames of the first video stream as 8-bit luma.
    private func decodeGray(_ url: URL, directory: URL) async throws -> [UInt8] {
        let raw = directory.appendingPathComponent(UUID().uuidString + ".gray")
        try await runFFmpeg(["-i", url.path, "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "gray", raw.path])
        return [UInt8](try Data(contentsOf: raw))
    }

    private func assertCodec(of matte: URL, equalsCodecOf main: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        func codec(_ url: URL) async throws -> String {
            let result = try await SubprocessRunner().run(SubprocessRequest(
                executableURL: bundledFFmpegURL, arguments: ["-hide_banner", "-i", url.path],
                timeout: .seconds(30), standardErrorCaptureLimit: 16_384))
            let line = result.standardErrorText.components(separatedBy: "\n").first { $0.contains("Video:") } ?? ""
            return line.components(separatedBy: "Video: ").last?.components(separatedBy: " ").first ?? ""
        }
        let mainCodec = try await codec(main)
        XCTAssertFalse(mainCodec.isEmpty, file: file, line: line)
        let matteCodec = try await codec(matte)
        XCTAssertEqual(matteCodec, mainCodec, file: file, line: line)
    }

    private func alphaSourceMetadata(width: Int = 1920, height: Int = 1080) -> VideoMetadata {
        VideoMetadata(
            duration: 10, formatName: "mov", containerLongName: "QuickTime / MOV", sizeBytes: nil,
            bitRate: nil, comment: nil, timecode: nil, timecodes: [], frameCount: nil,
            containerCreationDate: nil, containerModificationDate: nil, title: nil, artist: nil,
            gpsLatitude: nil, gpsLongitude: nil, gpsAltitude: nil, warnings: [],
            videoStreams: [
                VideoMetadata.VideoStream(
                    codec: "prores", codecLongName: nil, profile: "4444", width: width, height: height,
                    pixelFormat: "yuva444p12le", hasAlpha: true,
                    pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: 25), bitDepth: 12, bitRate: nil,
                    duration: 10, chromaSubsampling: "4:4:4", colorPrimaries: nil, colorTransfer: nil,
                    colorSpace: nil, colorRange: nil, chromaLocation: nil, fieldOrder: nil,
                    isInterlaced: false, title: nil, isDefault: true, isForced: false
                )
            ],
            audioStreams: [], subtitleStreams: []
        )
    }

    private var bundledFFmpegURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
    }

    private func runFFmpeg(_ arguments: [String], standardInput: Data? = nil) async throws {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: bundledFFmpegURL, arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments,
            standardInput: standardInput, timeout: .seconds(60), standardErrorCaptureLimit: 16_384
        ))
        guard result.succeeded else {
            throw NSError(domain: "NativeWaveformImprovementTests", code: Int(result.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: result.standardErrorText])
        }
    }
}
