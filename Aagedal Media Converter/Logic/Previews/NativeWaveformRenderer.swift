// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decodes audio to raw PCM via FFmpeg and renders waveform images natively in Swift.
// Ported from Aagedal Media Player's AudioWaveformGenerator for fast preview waveforms.

import Foundation
import AppKit
import OSLog

/// @unchecked Sendable wrapper for NSImage (created once, read-only afterward).
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Per-channel waveform data: one image and label per audio channel.
struct SendableChannelWaveform: @unchecked Sendable {
    let channelImages: [NSImage]
    let channelLabels: [String]
    var channelEnvelopes: [WaveformEnvelope] = []
}

/// Peak envelopes retain amplitude precision independently of display size.
/// Each coarser level combines adjacent bins, preserving short transients.
struct WaveformEnvelope: Sendable {
    struct Peak: Sendable, Equatable {
        var minimum: Float
        var maximum: Float
    }
    let levels: [[Peak]]
    let duration: Double
    let framesPerBin: Int
    let frameCount: Int

    init(pcmData: Data, channelCount: Int, sampleRate: Double, minimumFramesPerBin: Int = 256, channel: Int? = nil) {
        let channels = max(1, channelCount)
        let frameCount = pcmData.count / (MemoryLayout<Float>.size * channels)
        // Bound retained data even for exceptionally long recordings.
        let framesPerBin = max(1, max(minimumFramesPerBin, Int(ceil(Double(frameCount) / 2_000_000))))
        let bins = (frameCount + framesPerBin - 1) / framesPerBin
        var base = [Peak](repeating: Peak(minimum: 0, maximum: 0), count: bins)
        let binSize = framesPerBin
        let frames = frameCount
        let selectedChannels = channel.map { min(channels - 1, max(0, $0))..<(min(channels - 1, max(0, $0)) + 1) } ?? (0..<channels)
        pcmData.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for frame in 0..<frames {
                let bin = frame / binSize
                for channel in selectedChannels {
                    let value = samples[frame * channels + channel]
                    guard value.isFinite else { continue }
                    base[bin].minimum = min(base[bin].minimum, max(-1, value))
                    base[bin].maximum = max(base[bin].maximum, min(1, value))
                }
            }
        }
        self.init(peaks: base, frameCount: frameCount, framesPerBin: framesPerBin,
                  sampleRate: max(1, sampleRate))
    }

    init(peaks: [Peak], frameCount: Int, framesPerBin: Int, sampleRate: Double) {
        self.frameCount = frameCount
        self.framesPerBin = framesPerBin
        duration = Double(frameCount) / sampleRate
        var pyramid = [peaks]
        while let previous = pyramid.last, previous.count > 1 {
            var next: [Peak] = []
            next.reserveCapacity((previous.count + 1) / 2)
            for index in stride(from: 0, to: previous.count, by: 2) {
                let other = previous[min(index + 1, previous.count - 1)]
                next.append(Peak(minimum: min(previous[index].minimum, other.minimum),
                                 maximum: max(previous[index].maximum, other.maximum)))
            }
            pyramid.append(next)
        }
        levels = pyramid
    }

    func level(secondsPerPixel: Double) -> Int {
        guard duration > 0, frameCount > 0, secondsPerPixel > 0 else { return 0 }
        let baseSeconds = Double(framesPerBin) / Double(frameCount) * duration
        return min(levels.count - 1, max(0, Int(floor(log2(max(1, secondsPerPixel / baseSeconds))))))
    }

    func peak(from start: Double, to end: Double, level: Int) -> Peak {
        guard duration > 0, frameCount > 0, start < duration, end > 0 else {
            return Peak(minimum: 0, maximum: 0)
        }
        let index = min(levels.count - 1, max(0, level))
        let values = levels[index]
        guard !values.isEmpty else { return Peak(minimum: 0, maximum: 0) }
        let secondsPerBin = Double(framesPerBin) * pow(2, Double(index)) / Double(frameCount) * duration
        let lower = min(values.count - 1, max(0, Int(floor(start / secondsPerBin))))
        let upper = min(values.count, max(lower + 1, Int(ceil(end / secondsPerBin))))
        return values[lower..<upper].reduce(Peak(minimum: 0, maximum: 0)) {
            Peak(minimum: min($0.minimum, $1.minimum), maximum: max($0.maximum, $1.maximum))
        }
    }
}

/// A compact, versioned cache of base peaks. Coarser levels are rebuilt on load.
/// Destinations belong to the preview cache's source fingerprint directory.
enum WaveformEnvelopeCache {
    private static let magic: UInt64 = 0x314B414550434D41 // "AMCPEAK1", little endian
    private static let headerSize = 40

    static func write(_ envelope: WaveformEnvelope, to url: URL) throws {
        guard let peaks = envelope.levels.first else { return }
        var data = Data(capacity: headerSize + peaks.count * 8)
        func append<T>(_ value: T) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(magic.littleEndian)
        append(UInt64(envelope.frameCount).littleEndian)
        append(UInt64(envelope.framesPerBin).littleEndian)
        append(envelope.duration.bitPattern.littleEndian)
        append(UInt64(peaks.count).littleEndian)
        for peak in peaks {
            append(peak.minimum.bitPattern.littleEndian)
            append(peak.maximum.bitPattern.littleEndian)
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> WaveformEnvelope? {
        // Reject oversized or truncated caches before allocating peak arrays.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= headerSize, size <= headerSize + 2_000_000 * 8,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> WaveformEnvelope? in
            guard raw.count >= headerSize else { return nil }
            func integer(_ offset: Int) -> UInt64 {
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            }
            let frames = integer(8)
            let binSize = integer(16)
            let duration = Double(bitPattern: integer(24))
            let count = integer(32)
            guard integer(0) == magic, frames > 0, frames <= UInt64(Int.max),
                  binSize > 0, binSize <= UInt64(Int.max), duration.isFinite, duration > 0,
                  count > 0, count <= 2_000_000,
                  count == (frames - 1) / binSize + 1,
                  raw.count == headerSize + Int(count) * 8 else { return nil }
            var peaks: [WaveformEnvelope.Peak] = []
            peaks.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let offset = headerSize + index * 8
                let minimum = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let maximum = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                guard minimum.isFinite, maximum.isFinite, minimum >= -1, minimum <= 0,
                      maximum >= 0, maximum <= 1 else { return nil }
                peaks.append(.init(minimum: minimum, maximum: maximum))
            }
            let rate = Double(frames) / duration
            guard rate.isFinite, rate > 0 else { return nil }
            return WaveformEnvelope(peaks: peaks, frameCount: Int(frames),
                                    framesPerBin: Int(binSize), sampleRate: rate)
        }
    }
}

/// Consumes arbitrarily split PCM pipe chunks without retaining the recording.
/// The lock protects the output callback and the final snapshot. Rebinning also
/// bounds memory when the source's duration metadata underestimates its length.
final class StreamingWaveformEnvelope: @unchecked Sendable {
    private let lock = NSLock()
    private let channels: Int
    private let sampleRate: Double
    private let maximumBins: Int
    private var framesPerBin: Int
    private var frameCount = 0
    private var pending = Data()
    private var peaks: [WaveformEnvelope.Peak] = []

    init(channelCount: Int, sampleRate: Double, duration: Double, maximumBins: Int = 2_000_000) {
        channels = max(1, channelCount)
        self.sampleRate = sampleRate
        self.maximumBins = max(1, maximumBins)
        let expectedFrames = duration.isFinite ? max(0, duration) * sampleRate : 0
        framesPerBin = max(256, Int(ceil(min(Double(Int.max / 2), expectedFrames) / Double(self.maximumBins))))
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let completeBytes = pending.count / bytesPerFrame * bytesPerFrame
        pending.withUnsafeBytes { raw in
            var offset = 0
            while offset < completeBytes {
                if frameCount / framesPerBin >= maximumBins {
                    var coarser: [WaveformEnvelope.Peak] = []
                    coarser.reserveCapacity((peaks.count + 1) / 2)
                    for index in stride(from: 0, to: peaks.count, by: 2) {
                        let other = peaks[min(index + 1, peaks.count - 1)]
                        coarser.append(.init(minimum: min(peaks[index].minimum, other.minimum),
                                             maximum: max(peaks[index].maximum, other.maximum)))
                    }
                    peaks = coarser
                    framesPerBin *= 2
                }
                let bin = frameCount / framesPerBin
                if bin == peaks.count { peaks.append(.init(minimum: 0, maximum: 0)) }
                // Update the retained peak once per bin, rather than once per frame.
                // All interleaved channels contribute, so opposite-phase audio survives.
                let frames = min(framesPerBin - frameCount % framesPerBin,
                                 (completeBytes - offset) / bytesPerFrame)
                let end = offset + frames * bytesPerFrame
                var peak = peaks[bin]
                while offset < end {
                    let value = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    if value.isFinite {
                        peak.minimum = min(peak.minimum, max(-1, value))
                        peak.maximum = max(peak.maximum, min(1, value))
                    }
                    offset += MemoryLayout<Float>.size
                }
                peaks[bin] = peak
                frameCount += frames
            }
        }
        pending = Data(pending.suffix(pending.count - completeBytes))
    }

    func envelope() -> WaveformEnvelope {
        lock.lock()
        defer { lock.unlock() }
        return WaveformEnvelope(peaks: peaks, frameCount: frameCount,
                                framesPerBin: framesPerBin, sampleRate: sampleRate)
    }
}

/// Renders audio waveform images natively in Swift from raw PCM data.
/// Replaces FFmpeg's showwavespic filter for preview waveform generation.
struct NativeWaveformRenderer {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "NativeWaveform")

    // MARK: - Public API

    /// Generates a mono waveform image for one audio stream.
    /// Decodes audio once as raw PCM via FFmpeg, then computes amplitudes and renders pixels natively.
    static nonisolated func generateWaveform(
        url: URL,
        ffmpegPath: String,
        streamIndex: Int,
        duration: Double,
        width: Int,
        height: Int,
        colorHex: String = "FF2D78",
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> NSImage {
        try await generateWaveformAssets(url: url, ffmpegPath: ffmpegPath, streamIndex: streamIndex,
                                        duration: duration, width: width, height: height,
                                        colorHex: colorHex, includeEnvelope: false,
                                        subprocessRunner: subprocessRunner).image
    }

    static nonisolated func generateWaveformAssets(
        url: URL, ffmpegPath: String, streamIndex: Int, duration: Double, width: Int, height: Int,
        colorHex: String = "FF2D78", includeEnvelope: Bool = true, channelCount: Int = 1,
        envelopeCacheURL: URL? = nil,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> (image: NSImage, envelope: WaveformEnvelope?) {
        if includeEnvelope {
            return try await generateStreamingWaveform(
                url: url, ffmpegPath: ffmpegPath, streamIndex: streamIndex,
                duration: duration, width: width, height: height, colorHex: colorHex,
                channelCount: channelCount, envelopeCacheURL: envelopeCacheURL,
                subprocessRunner: subprocessRunner)
        }
        let channels = 1
        let effectiveWidth = max(400, width)

        // Bitmap-only previews can use downsampled PCM. Timeline envelopes use
        // the streaming full-rate path above to preserve short transients.
        let idealRate = max(1000, min(48000, Int(ceil(Double(effectiveWidth) * 100.0 / max(duration, 0.1)))))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.aagedal.MediaConverter.waveforms.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pcmFile = tempDir.appendingPathComponent("audio.raw")

        let arguments: [String] = [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path,
            "-vn",
            "-map", "0:a:\(streamIndex)",
            "-ac", "\(channels)",
            // Preserve delayed tracks and timestamp gaps on the source timeline.
            "-af", "aresample=\(idealRate):async=1:first_pts=0",
            "-ar", "\(idealRate)",
            "-f", "f32le",
            "-c:a", "pcm_f32le",
            "-y", pcmFile.path
        ]

        try await runFFmpeg(
            path: ffmpegPath,
            arguments: arguments,
            inputURL: url,
            outputURL: pcmFile,
            subprocessRunner: subprocessRunner
        )
        try Task.checkCancellation()

        let pcmData = try Data(contentsOf: pcmFile, options: .mappedIfSafe)
        let totalFrames = pcmData.count / (MemoryLayout<Float>.size * channels)
        guard totalFrames > 0 else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }

        // Compute amplitudes
        let (mins, maxs) = computeAmplitudes(pcmData: pcmData, channelCount: channels, channel: 0, totalFrames: totalFrames, width: effectiveWidth)

        try Task.checkCancellation()

        // Parse color and render
        let (r, g, b) = parseHexColor(colorHex)
        guard let image = renderWaveformImage(
            mins: mins, maxs: maxs,
            width: effectiveWidth, height: height,
            r: r, g: g, b: b
        ) else {
            throw PreviewAssetError.generationFailed("Failed to render waveform image")
        }

        try Task.checkCancellation()
        return (image, nil)
    }

    private static nonisolated func generateStreamingWaveform(
        url: URL, ffmpegPath: String, streamIndex: Int, duration: Double,
        width: Int, height: Int, colorHex: String, channelCount: Int, envelopeCacheURL: URL?,
        subprocessRunner: any SubprocessRunning
    ) async throws -> (image: NSImage, envelope: WaveformEnvelope?) {
        try Task.checkCancellation()
        if let envelopeCacheURL, let envelope = WaveformEnvelopeCache.read(from: envelopeCacheURL) {
            let image = try renderEnvelope(envelope, width: max(400, width), height: height, colorHex: colorHex)
            try Task.checkCancellation()
            return (image, envelope)
        }
        let builder = StreamingWaveformEnvelope(channelCount: channelCount, sampleRate: 48000, duration: duration)
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path,
                        "-vn", "-map", "0:a:\(streamIndex)", "-ac", "\(max(1, channelCount))",
                        "-af", "aresample=48000:async=1:first_pts=0", "-ar", "48000",
                        "-f", "f32le", "-c:a", "pcm_f32le", "pipe:1"],
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [ffmpegPath, url.path])
        let result = try await subprocessRunner.run(request) { chunk in
            if case .standardOutput = chunk.stream { builder.append(chunk.data) }
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw PreviewAssetError.generationFailed(request.redactedDiagnostic(result.standardErrorText, limit: 2_000))
        }
        let envelope = builder.envelope()
        guard envelope.frameCount > 0 else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }
        let image = try renderEnvelope(envelope, width: max(400, width), height: height, colorHex: colorHex)
        try Task.checkCancellation()
        // Cache failures should never prevent displaying a successfully decoded waveform.
        if let envelopeCacheURL { try? WaveformEnvelopeCache.write(envelope, to: envelopeCacheURL) }
        return (image, envelope)
    }

    private static nonisolated func renderEnvelope(
        _ envelope: WaveformEnvelope, width: Int, height: Int, colorHex: String
    ) throws -> NSImage {
        let secondsPerColumn = envelope.duration / Double(width)
        let level = envelope.level(secondsPerPixel: secondsPerColumn)
        var mins = [Float]()
        var maxs = [Float]()
        mins.reserveCapacity(width)
        maxs.reserveCapacity(width)
        for column in 0..<width {
            let peak = envelope.peak(from: Double(column) * secondsPerColumn,
                                     to: Double(column + 1) * secondsPerColumn, level: level)
            mins.append(peak.minimum)
            maxs.append(peak.maximum)
        }
        let (r, g, b) = parseHexColor(colorHex)
        guard let image = renderWaveformImage(mins: mins, maxs: maxs, width: width,
                                              height: height, r: r, g: g, b: b) else {
            throw PreviewAssetError.generationFailed("Failed to render waveform image")
        }
        return image
    }

    // MARK: - Amplitude Computation

    /// Computes average positive/negative amplitude per pixel column from raw PCM data.
    /// Matches FFmpeg showwavespic's default "average" mode.
    private static nonisolated func computeAmplitudes(
        pcmData: Data,
        channelCount: Int,
        channel: Int,
        totalFrames: Int,
        width: Int
    ) -> (mins: [Float], maxs: [Float]) {
        var columnMins = [Float](repeating: 0, count: width)
        var columnMaxs = [Float](repeating: 0, count: width)

        pcmData.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float.self)

            for col in 0..<width {
                let startFrame = col * totalFrames / width
                let endFrame = min((col + 1) * totalFrames / width, totalFrames)
                guard startFrame < endFrame else { continue }

                var posSum: Float = 0
                var posCount: Int = 0
                var negSum: Float = 0
                var negCount: Int = 0

                for frame in startFrame..<endFrame {
                    let sample = floats[frame * channelCount + channel]
                    if sample >= 0 {
                        posSum += sample
                        posCount += 1
                    } else {
                        negSum += sample
                        negCount += 1
                    }
                }

                columnMaxs[col] = min(posCount > 0 ? posSum / Float(posCount) : 0, 1.0)
                columnMins[col] = max(negCount > 0 ? negSum / Float(negCount) : 0, -1.0)
            }
        }

        return (columnMins, columnMaxs)
    }

    // MARK: - Image Rendering

    /// Renders a waveform image from min/max amplitude data to an RGBA pixel buffer.
    private static nonisolated func renderWaveformImage(
        mins: [Float], maxs: [Float],
        width: Int, height: Int,
        r: UInt8, g: UInt8, b: UInt8
    ) -> NSImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let centerY = Float(height) / 2.0
        // Leave a few pixels of margin so peaks don't touch the edges
        let margin: Float = 3.0
        let halfRange = centerY - margin

        for col in 0..<width {
            let maxVal = maxs[col]
            let minVal = mins[col]
            let topRow = max(0, Int(centerY - maxVal * halfRange))
            let bottomRow = min(height - 1, Int(centerY - minVal * halfRange))

            for row in topRow...bottomRow {
                let idx = (row * width + col) * 4
                pixels[idx] = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Per-Channel Generation

    /// Generates one waveform image per audio channel for the given stream.
    /// Unlike `generateWaveform()` which downmixes to mono, this preserves all channels.
    static nonisolated func generatePerChannelWaveforms(
        url: URL,
        ffmpegPath: String,
        streamIndex: Int,
        channelCount: Int,
        channelLayout: String?,
        duration: Double,
        width: Int,
        heightPerChannel: Int,
        colorHex: String = "FF2D78",
        envelopeCacheDirectory: URL? = nil,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> ([NSImage], [String], [WaveformEnvelope]) {
        let effectiveWidth = max(800, width)
        let effectiveChannelCount = max(1, channelCount)

        let cacheURLs = (0..<effectiveChannelCount).map { channel in
            envelopeCacheDirectory?.appendingPathComponent("waveform_a\(streamIndex)_c\(channel)_of\(effectiveChannelCount)_peaks_v1.bin")
        }
        let cachedEnvelopes = cacheURLs.compactMap { $0.flatMap { WaveformEnvelopeCache.read(from: $0) } }
        if cachedEnvelopes.count == effectiveChannelCount {
            try Task.checkCancellation()
            let images = try cachedEnvelopes.map {
                try renderEnvelope($0, width: effectiveWidth, height: heightPerChannel, colorHex: colorHex)
            }
            return (images, channelNames(count: effectiveChannelCount, layout: channelLayout), cachedEnvelopes)
        }

        let idealRate = max(1000, min(48000, Int(ceil(Double(effectiveWidth) * 100.0 / max(duration, 0.1)))))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.aagedal.MediaConverter.waveforms.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pcmFile = tempDir.appendingPathComponent("audio.raw")

        // Decode preserving all channels (no -ac 1)
        let arguments: [String] = [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path,
            "-vn",
            "-map", "0:a:\(streamIndex)",
            "-af", "aresample=\(idealRate):async=1:first_pts=0",
            "-ar", "\(idealRate)",
            "-f", "f32le",
            "-c:a", "pcm_f32le",
            "-y", pcmFile.path
        ]

        try await runFFmpeg(
            path: ffmpegPath,
            arguments: arguments,
            inputURL: url,
            outputURL: pcmFile,
            subprocessRunner: subprocessRunner
        )
        try Task.checkCancellation()

        let pcmData = try Data(contentsOf: pcmFile, options: .mappedIfSafe)
        let floatCount = pcmData.count / MemoryLayout<Float>.size
        let totalFrames = floatCount / effectiveChannelCount
        guard totalFrames > 0 else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }

        let labels = channelNames(count: effectiveChannelCount, layout: channelLayout)
        var images: [NSImage] = []
        var envelopes: [WaveformEnvelope] = []
        // Share the envelope memory budget across channels for long recordings.
        let binSize = max(256, Int(ceil(Double(totalFrames) * Double(effectiveChannelCount) / 2_000_000)))

        for ch in 0..<effectiveChannelCount {
            try Task.checkCancellation()
            let envelope = WaveformEnvelope(pcmData: pcmData, channelCount: effectiveChannelCount,
                                            sampleRate: Double(idealRate), minimumFramesPerBin: binSize,
                                            channel: ch)
            images.append(try renderEnvelope(envelope, width: effectiveWidth,
                                             height: heightPerChannel, colorHex: colorHex))
            envelopes.append(envelope)
        }

        guard !images.isEmpty else {
            throw PreviewAssetError.generationFailed("Failed to render any channel waveform images")
        }

        try Task.checkCancellation()
        if envelopes.count == effectiveChannelCount {
            for (envelope, cacheURL) in zip(envelopes, cacheURLs) {
                if let cacheURL { try? WaveformEnvelopeCache.write(envelope, to: cacheURL) }
            }
        }
        return (images, labels, envelopes)
    }

    // MARK: - Channel Labels

    /// Returns human-readable channel names based on count and layout string from ffprobe.
    static nonisolated func channelNames(count: Int, layout: String?) -> [String] {
        if let layout, !layout.isEmpty {
            let knownLayouts: [String: [String]] = [
                "mono": ["Mono"],
                "stereo": ["Left", "Right"],
                "2.1": ["Left", "Right", "LFE"],
                "3.0": ["Left", "Right", "Center"],
                "3.0(back)": ["Left", "Right", "Back Center"],
                "3.1": ["Left", "Right", "Center", "LFE"],
                "4.0": ["Left", "Right", "Center", "Back Center"],
                "quad": ["Left", "Right", "Back Left", "Back Right"],
                "quad(side)": ["Left", "Right", "Side Left", "Side Right"],
                "5.0": ["Left", "Right", "Center", "Back Left", "Back Right"],
                "5.0(side)": ["Left", "Right", "Center", "Side Left", "Side Right"],
                "5.1": ["Left", "Right", "Center", "LFE", "Back Left", "Back Right"],
                "5.1(side)": ["Left", "Right", "Center", "LFE", "Side Left", "Side Right"],
                "6.1": ["Left", "Right", "Center", "LFE", "Back Center", "Side Left", "Side Right"],
                "7.1": ["Left", "Right", "Center", "LFE", "Back Left", "Back Right", "Side Left", "Side Right"],
                "7.1(wide)": ["Left", "Right", "Center", "LFE", "Back Left", "Back Right", "Front Left of Center", "Front Right of Center"],
            ]
            let normalized = layout.lowercased()
            if let names = knownLayouts[normalized], names.count == count {
                return names
            }
        }

        if count == 1 { return ["Mono"] }
        if count == 2 { return ["Left", "Right"] }
        return (0..<count).map { "Channel \($0 + 1)" }
    }

    // MARK: - Utilities

    /// Parses a hex color string (RRGGBB, with optional #/0x prefix) into RGB byte components.
    static nonisolated func parseHexColor(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned = String(cleaned.dropFirst()) }
        if cleaned.hasPrefix("0x") { cleaned = String(cleaned.dropFirst(2)) }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return (255, 255, 255) // default white
        }
        return (
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        )
    }

    // MARK: - FFmpeg Process

    private static nonisolated func runFFmpeg(
        path: String,
        arguments: [String],
        inputURL: URL,
        outputURL: URL,
        subprocessRunner: any SubprocessRunning
    ) async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [path, inputURL.path, outputURL.path]
        )

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch SubprocessRunnerError.timedOut {
            throw PreviewAssetError.generationFailed("FFmpeg waveform decode timed out")
        } catch {
            throw PreviewAssetError.generationFailed(
                request.redactedDiagnostic(error.localizedDescription, limit: 1_000)
            )
        }

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 2_000
            )
            let message = diagnostic.isEmpty
                ? "FFmpeg exited with status \(result.terminationStatus)"
                : diagnostic
            throw PreviewAssetError.generationFailed(message)
        }
    }
}
