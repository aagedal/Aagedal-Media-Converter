// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decodes audio to raw PCM via FFmpeg and builds waveform envelopes natively in Swift.
// Ported from Aagedal Media Player's AudioWaveformGenerator for fast preview waveforms.

import Foundation
import AppKit
import OSLog

/// Per-channel waveform data: one envelope and label per audio channel.
struct SendableChannelWaveform: Sendable {
    let channelLabels: [String]
    var channelEnvelopes: [WaveformEnvelope] = []
}

/// Peak envelopes retain amplitude precision independently of display size.
/// Each coarser level combines adjacent bins, preserving short transients.
/// `powerLevels` holds each bin's mean square, so views can draw an RMS body.
struct WaveformEnvelope: Sendable, Equatable {
    struct Peak: Sendable, Equatable {
        var minimum: Float
        var maximum: Float
    }
    let levels: [[Peak]]
    /// Mean square per bin, parallel to `levels`; empty when unknown.
    let powerLevels: [[Float]]
    let duration: Double
    let framesPerBin: Int
    let frameCount: Int
    let sampleRate: Double

    init(pcmData: Data, channelCount: Int, sampleRate: Double, minimumFramesPerBin: Int = 256, channel: Int? = nil) {
        let channels = max(1, channelCount)
        let frameCount = pcmData.count / (MemoryLayout<Float>.size * channels)
        // Bound retained data even for exceptionally long recordings.
        let framesPerBin = max(1, max(minimumFramesPerBin, Int(ceil(Double(frameCount) / 2_000_000))))
        let bins = (frameCount + framesPerBin - 1) / framesPerBin
        var base = [Peak](repeating: Peak(minimum: 0, maximum: 0), count: bins)
        var sums = [Float](repeating: 0, count: bins)
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
                    let clamped = min(1, max(-1, value))
                    base[bin].minimum = min(base[bin].minimum, clamped)
                    base[bin].maximum = max(base[bin].maximum, clamped)
                    sums[bin] += clamped * clamped
                }
            }
        }
        let meanSquares = sums.indices.map { bin in
            sums[bin] / Float(min(binSize, frames - bin * binSize) * selectedChannels.count)
        }
        self.init(peaks: base, meanSquares: meanSquares, frameCount: frameCount,
                  framesPerBin: framesPerBin, sampleRate: max(1, sampleRate))
    }

    init(peaks: [Peak], meanSquares: [Float] = [], frameCount: Int, framesPerBin: Int, sampleRate: Double) {
        self.frameCount = frameCount
        self.framesPerBin = framesPerBin
        self.sampleRate = sampleRate
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
        // Power is optional; a mismatched array is dropped rather than misaligned.
        var power = meanSquares.count == peaks.count && !peaks.isEmpty ? [meanSquares] : []
        while let previous = power.last, previous.count > 1 {
            var next: [Float] = []
            next.reserveCapacity((previous.count + 1) / 2)
            for index in stride(from: 0, to: previous.count, by: 2) {
                next.append((previous[index] + previous[min(index + 1, previous.count - 1)]) / 2)
            }
            power.append(next)
        }
        powerLevels = power
    }

    /// Combines channels decoded together into one envelope. Peaks take the
    /// extremes, so opposite-phase channels don't cancel; power is averaged.
    static func merging(_ channels: [WaveformEnvelope]) -> WaveformEnvelope? {
        guard let first = channels.first, let firstPeaks = first.levels.first,
              channels.allSatisfy({ $0.frameCount == first.frameCount && $0.framesPerBin == first.framesPerBin
                  && $0.sampleRate == first.sampleRate && $0.levels.first?.count == firstPeaks.count }) else {
            return nil
        }
        guard channels.count > 1 else { return first }
        var peaks = firstPeaks
        for channel in channels.dropFirst() {
            for (index, peak) in channel.levels[0].enumerated() {
                peaks[index].minimum = min(peaks[index].minimum, peak.minimum)
                peaks[index].maximum = max(peaks[index].maximum, peak.maximum)
            }
        }
        var meanSquares: [Float] = []
        if channels.allSatisfy({ $0.powerLevels.first?.count == firstPeaks.count }) {
            meanSquares = [Float](repeating: 0, count: firstPeaks.count)
            for channel in channels {
                for (index, power) in channel.powerLevels[0].enumerated() { meanSquares[index] += power }
            }
            let scale = 1 / Float(channels.count)
            for index in meanSquares.indices { meanSquares[index] *= scale }
        }
        return WaveformEnvelope(peaks: peaks, meanSquares: meanSquares, frameCount: first.frameCount,
                                framesPerBin: first.framesPerBin, sampleRate: first.sampleRate)
    }

    func level(secondsPerPixel: Double) -> Int {
        guard duration > 0, frameCount > 0, secondsPerPixel > 0 else { return 0 }
        return min(levels.count - 1, max(0, Int(floor(log2(max(1, secondsPerPixel / secondsPerBin(level: 0)))))))
    }

    func secondsPerBin(level: Int) -> Double {
        Double(framesPerBin) * pow(2, Double(max(0, level))) / sampleRate
    }

    func peak(from start: Double, to end: Double, level: Int) -> Peak {
        guard let (index, bins) = binRange(from: start, to: end, level: level) else {
            return Peak(minimum: 0, maximum: 0)
        }
        return levels[index][bins].reduce(Peak(minimum: 0, maximum: 0)) {
            Peak(minimum: min($0.minimum, $1.minimum), maximum: max($0.maximum, $1.maximum))
        }
    }

    /// Root mean square over a time range, or nil when the envelope has no power data.
    func rms(from start: Double, to end: Double, level: Int) -> Float? {
        guard !powerLevels.isEmpty else { return nil }
        guard let (index, bins) = binRange(from: start, to: end, level: level) else { return 0 }
        let power = powerLevels[index][bins]
        return (power.reduce(0, +) / Float(power.count)).squareRoot()
    }

    /// Peak and RMS interpolated between neighbouring base bins, so a pixel
    /// narrower than one bin follows a smooth outline instead of a step.
    func interpolated(at time: Double) -> (peak: Peak, rms: Float?) {
        guard let base = levels.first, !base.isEmpty, duration > 0 else {
            return (Peak(minimum: 0, maximum: 0), powerLevels.isEmpty ? nil : 0)
        }
        guard time >= 0, time < duration else {
            return (Peak(minimum: 0, maximum: 0), powerLevels.isEmpty ? nil : 0)
        }
        let position = min(Double(base.count - 1), max(0, time / secondsPerBin(level: 0) - 0.5))
        let lower = Int(position)
        let upper = min(base.count - 1, lower + 1)
        let fraction = Float(position - Double(lower))
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * fraction }
        let peak = Peak(minimum: mix(base[lower].minimum, base[upper].minimum),
                        maximum: mix(base[lower].maximum, base[upper].maximum))
        guard let power = powerLevels.first else { return (peak, nil) }
        return (peak, mix(power[lower], power[upper]).squareRoot())
    }

    private func binRange(from start: Double, to end: Double, level: Int) -> (Int, Range<Int>)? {
        guard duration > 0, frameCount > 0, start < duration, end > 0 else { return nil }
        let index = min(levels.count - 1, max(0, level))
        let count = levels[index].count
        guard count > 0 else { return nil }
        let secondsPerBin = secondsPerBin(level: index)
        let lower = min(count - 1, max(0, Int(floor(start / secondsPerBin))))
        let upper = min(count, max(lower + 1, Int(ceil(end / secondsPerBin))))
        return (index, lower..<upper)
    }
}

/// A compact, versioned cache of base peaks and power. Coarser levels are rebuilt on load.
/// Destinations belong to the preview cache's source fingerprint directory.
enum WaveformEnvelopeCache {
    private static let magic: UInt64 = 0x324B414550434D41 // "AMCPEAK2", little endian
    private static let headerSize = 40
    private static let bytesPerBin = 12
    private static let maximumBins = 2_000_000

    static func write(_ envelope: WaveformEnvelope, to url: URL) throws {
        guard let peaks = envelope.levels.first, let power = envelope.powerLevels.first,
              power.count == peaks.count else { return }
        var data = Data(capacity: headerSize + peaks.count * bytesPerBin)
        func append<T>(_ value: T) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(magic.littleEndian)
        append(UInt64(envelope.frameCount).littleEndian)
        append(UInt64(envelope.framesPerBin).littleEndian)
        append(envelope.duration.bitPattern.littleEndian)
        append(UInt64(peaks.count).littleEndian)
        for (peak, meanSquare) in zip(peaks, power) {
            append(peak.minimum.bitPattern.littleEndian)
            append(peak.maximum.bitPattern.littleEndian)
            append(meanSquare.bitPattern.littleEndian)
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> WaveformEnvelope? {
        // Reject oversized or truncated caches before allocating peak arrays.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= headerSize, size <= headerSize + maximumBins * bytesPerBin,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> WaveformEnvelope? in
            guard raw.count >= headerSize else { return nil }
            func integer(_ offset: Int) -> UInt64 {
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            }
            func float(_ offset: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            let frames = integer(8)
            let binSize = integer(16)
            let duration = Double(bitPattern: integer(24))
            let count = integer(32)
            guard integer(0) == magic, frames > 0, frames <= UInt64(Int.max),
                  binSize > 0, binSize <= UInt64(Int.max), duration.isFinite, duration > 0,
                  count > 0, count <= UInt64(maximumBins),
                  count == (frames - 1) / binSize + 1,
                  raw.count == headerSize + Int(count) * bytesPerBin else { return nil }
            var peaks: [WaveformEnvelope.Peak] = []
            var meanSquares: [Float] = []
            peaks.reserveCapacity(Int(count))
            meanSquares.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let offset = headerSize + index * bytesPerBin
                let minimum = float(offset)
                let maximum = float(offset + 4)
                let meanSquare = float(offset + 8)
                guard minimum.isFinite, maximum.isFinite, minimum >= -1, minimum <= 0,
                      maximum >= 0, maximum <= 1,
                      meanSquare.isFinite, meanSquare >= 0, meanSquare <= 1 else { return nil }
                peaks.append(.init(minimum: minimum, maximum: maximum))
                meanSquares.append(meanSquare)
            }
            let rate = Double(frames) / duration
            guard rate.isFinite, rate > 0 else { return nil }
            return WaveformEnvelope(peaks: peaks, meanSquares: meanSquares, frameCount: Int(frames),
                                    framesPerBin: Int(binSize), sampleRate: rate)
        }
    }
}

/// Consumes arbitrarily split PCM pipe chunks without retaining the recording,
/// keeping one envelope per interleaved channel. The lock protects the output
/// callback and the final snapshot. Rebinning also bounds memory when the
/// source's duration metadata underestimates its length.
final class StreamingWaveformEnvelope: @unchecked Sendable {
    private let lock = NSLock()
    private let channels: Int
    private let sampleRate: Double
    private let maximumBins: Int
    private var framesPerBin: Int
    private var frameCount = 0
    private var pending = Data()
    private var peaks: [[WaveformEnvelope.Peak]]
    private var sumsOfSquares: [[Float]]

    /// `maximumBins` is shared across channels.
    init(channelCount: Int, sampleRate: Double, duration: Double, maximumBins: Int = 2_000_000) {
        channels = max(1, channelCount)
        self.sampleRate = sampleRate
        self.maximumBins = max(1, maximumBins / channels)
        let expectedFrames = duration.isFinite ? max(0, duration) * sampleRate : 0
        framesPerBin = max(256, Int(ceil(min(Double(Int.max / 2), expectedFrames) / Double(self.maximumBins))))
        peaks = Array(repeating: [], count: channels)
        sumsOfSquares = Array(repeating: [], count: channels)
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
                if frameCount / framesPerBin >= maximumBins { halveResolution() }
                let bin = frameCount / framesPerBin
                if bin == peaks[0].count {
                    for channel in 0..<channels {
                        peaks[channel].append(.init(minimum: 0, maximum: 0))
                        sumsOfSquares[channel].append(0)
                    }
                }
                // Update each retained bin once per chunk, rather than once per frame.
                let frames = min(framesPerBin - frameCount % framesPerBin,
                                 (completeBytes - offset) / bytesPerFrame)
                for channel in 0..<channels {
                    var peak = peaks[channel][bin]
                    var sum = sumsOfSquares[channel][bin]
                    var position = offset + channel * MemoryLayout<Float>.size
                    for _ in 0..<frames {
                        let value = raw.loadUnaligned(fromByteOffset: position, as: Float.self)
                        if value.isFinite {
                            let clamped = min(1, max(-1, value))
                            peak.minimum = min(peak.minimum, clamped)
                            peak.maximum = max(peak.maximum, clamped)
                            sum += clamped * clamped
                        }
                        position += bytesPerFrame
                    }
                    peaks[channel][bin] = peak
                    sumsOfSquares[channel][bin] = sum
                }
                offset += frames * bytesPerFrame
                frameCount += frames
            }
        }
        pending = Data(pending.suffix(pending.count - completeBytes))
    }

    /// One envelope per decoded channel.
    func channelEnvelopes() -> [WaveformEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<channels).map { channel in
            let sums = sumsOfSquares[channel]
            let meanSquares = sums.indices.map { bin in
                sums[bin] / Float(max(1, min(framesPerBin, frameCount - bin * framesPerBin)))
            }
            return WaveformEnvelope(peaks: peaks[channel], meanSquares: meanSquares, frameCount: frameCount,
                                    framesPerBin: framesPerBin, sampleRate: sampleRate)
        }
    }

    /// All channels in one envelope, so opposite-phase audio survives.
    func envelope() -> WaveformEnvelope {
        let channels = channelEnvelopes()
        return WaveformEnvelope.merging(channels) ?? channels[0]
    }

    private func halveResolution() {
        for channel in 0..<channels {
            let previous = peaks[channel]
            let sums = sumsOfSquares[channel]
            var coarser: [WaveformEnvelope.Peak] = []
            var coarserSums: [Float] = []
            coarser.reserveCapacity((previous.count + 1) / 2)
            coarserSums.reserveCapacity((previous.count + 1) / 2)
            for index in stride(from: 0, to: previous.count, by: 2) {
                let next = min(index + 1, previous.count - 1)
                coarser.append(.init(minimum: min(previous[index].minimum, previous[next].minimum),
                                     maximum: max(previous[index].maximum, previous[next].maximum)))
                coarserSums.append(sums[index] + (next == index ? 0 : sums[next]))
            }
            peaks[channel] = coarser
            sumsOfSquares[channel] = coarserSums
        }
        framesPerBin *= 2
    }
}

/// Builds waveform envelopes and images natively in Swift from raw PCM data.
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
        let channels = 1
        let effectiveWidth = max(400, width)

        // Bitmap-only previews can use downsampled PCM. Timeline envelopes use
        // the full-rate path in generateChannelWaveforms to preserve short transients.
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

    // MARK: - Per-Channel Envelopes

    /// Decodes one audio stream once, at 48 kHz, and builds a peak and RMS envelope
    /// per channel. Full-rate decoding keeps transients that a downsampled decode
    /// would filter away; envelopes are cached per channel beside the preview assets.
    static nonisolated func generateChannelWaveforms(
        url: URL,
        ffmpegPath: String,
        streamIndex: Int,
        channelCount: Int,
        channelLayout: String?,
        duration: Double,
        envelopeCacheDirectory: URL? = nil,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> SendableChannelWaveform {
        let channels = max(1, channelCount)
        let labels = channelNames(count: channels, layout: channelLayout)
        let cacheURLs = (0..<channels).map { channel in
            envelopeCacheDirectory?.appendingPathComponent("waveform_a\(streamIndex)_c\(channel)_of\(channels)_peaks_v2.bin")
        }
        let cachedEnvelopes = cacheURLs.compactMap { $0.flatMap { WaveformEnvelopeCache.read(from: $0) } }
        if cachedEnvelopes.count == channels {
            try Task.checkCancellation()
            return SendableChannelWaveform(channelLabels: labels, channelEnvelopes: cachedEnvelopes)
        }

        let sampleRate = 48000
        let builder = StreamingWaveformEnvelope(channelCount: channels, sampleRate: Double(sampleRate),
                                                duration: duration)
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path,
                         "-vn", "-map", "0:a:\(streamIndex)"]
        // Multichannel streams keep their layout; a stream of unknown width is
        // mixed down so the interleaved PCM always matches the expected count.
        if channels == 1 { arguments += ["-ac", "1"] }
        arguments += [
            // Preserve delayed tracks and timestamp gaps on the source timeline.
            "-af", "aresample=\(sampleRate):async=1:first_pts=0", "-ar", "\(sampleRate)",
            "-f", "f32le", "-c:a", "pcm_f32le", "pipe:1"
        ]
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: .seconds(12 * 60 * 60), standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024, sensitiveValues: [ffmpegPath, url.path])
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request) { chunk in
                if case .standardOutput = chunk.stream { builder.append(chunk.data) }
            }
        } catch SubprocessRunnerError.timedOut {
            throw PreviewAssetError.generationFailed("FFmpeg waveform decode timed out")
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw PreviewAssetError.generationFailed(request.redactedDiagnostic(result.standardErrorText, limit: 2_000))
        }
        let envelopes = builder.channelEnvelopes()
        guard envelopes.first.map({ $0.frameCount > 0 }) == true else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }
        // Cache failures should never prevent displaying a successfully decoded waveform.
        for (envelope, cacheURL) in zip(envelopes, cacheURLs) {
            if let cacheURL { try? WaveformEnvelopeCache.write(envelope, to: cacheURL) }
        }
        return SendableChannelWaveform(channelLabels: labels, channelEnvelopes: envelopes)
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
