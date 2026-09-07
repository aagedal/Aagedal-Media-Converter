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
        let effectiveWidth = max(400, width)

        // Downsample to reduce data: aim for ~100 samples per output pixel column.
        // This is plenty for visual waveform accuracy while keeping data manageable
        // (e.g. a 1-hour file at 1kHz ≈ 14 MB vs 700+ MB at full rate).
        let idealRate = max(1000, min(48000, Int(ceil(Double(effectiveWidth) * 100.0 / max(duration, 0.1)))))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.aagedal.MediaConverter.waveforms.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pcmFile = tempDir.appendingPathComponent("audio.raw")

        // Decode to mono f32le PCM
        let arguments: [String] = [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path,
            "-vn",
            "-map", "0:a:\(streamIndex)",
            "-ac", "1",
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

        let pcmData = try Data(contentsOf: pcmFile)
        let totalFrames = pcmData.count / MemoryLayout<Float>.size
        guard totalFrames > 0 else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }

        // Compute amplitudes
        let (mins, maxs) = computeAmplitudes(pcmData: pcmData, channelCount: 1, channel: 0, totalFrames: totalFrames, width: effectiveWidth)

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
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> ([NSImage], [String]) {
        let effectiveWidth = max(800, width)
        let effectiveChannelCount = max(1, channelCount)

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

        let pcmData = try Data(contentsOf: pcmFile)
        let floatCount = pcmData.count / MemoryLayout<Float>.size
        let totalFrames = floatCount / effectiveChannelCount
        guard totalFrames > 0 else {
            throw PreviewAssetError.generationFailed("No audio samples decoded")
        }

        let (r, g, b) = parseHexColor(colorHex)
        let labels = channelNames(count: effectiveChannelCount, layout: channelLayout)
        var images: [NSImage] = []

        for ch in 0..<effectiveChannelCount {
            try Task.checkCancellation()

            let (mins, maxs) = computeAmplitudes(
                pcmData: pcmData,
                channelCount: effectiveChannelCount,
                channel: ch,
                totalFrames: totalFrames,
                width: effectiveWidth
            )

            guard let image = renderWaveformImage(
                mins: mins, maxs: maxs,
                width: effectiveWidth, height: heightPerChannel,
                r: r, g: g, b: b
            ) else {
                continue
            }
            images.append(image)
        }

        guard !images.isEmpty else {
            throw PreviewAssetError.generationFailed("Failed to render any channel waveform images")
        }

        return (images, labels)
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
