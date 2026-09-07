// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decodes audio to raw PCM via FFmpeg, then computes per-frame frequency band
// magnitudes using Accelerate vDSP FFT for the native waveform video renderer.

import Foundation
import Accelerate
import OSLog

/// Per-frame frequency band magnitude data for driving the capsule visualizer.
struct FrequencyBandData: Sendable {
    let bandCount: Int
    let frameCount: Int
    /// magnitudes[frameIndex][bandIndex], each value in 0.0–1.0.
    let magnitudes: [[Float]]
    let totalDuration: Double
}

enum WaveformPCMDecoder {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformPCMDecoder")

    /// Sample rate used for FFT analysis (48 kHz for good frequency resolution).
    private static let analysisRate = 48000
    /// FFT window size: 4096 samples ≈ 85 ms at 48 kHz.
    private static let fftSize = 4096
    /// Number of frequency bands for the capsule visualizer.
    static let defaultBandCount = 32
    /// Lowest frequency edge (Hz).
    private static let minFrequency: Double = 20
    /// Highest frequency edge (Hz).
    private static let maxFrequency: Double = 20000

    // MARK: - Public API

    /// Decodes audio and computes frequency-band magnitudes for every video frame.
    ///
    /// - Parameters:
    ///   - url: Input audio file.
    ///   - ffmpegPath: Path to the FFmpeg binary.
    ///   - frameRate: Video frame rate (determines FFT hop size).
    ///   - duration: Total audio duration in seconds (after trim).
    ///   - bandCount: Number of frequency bands (default 32).
    ///   - normalizeAudio: Apply dynamic normalization during decode.
    ///   - audioRoutingConfig: Optional channel routing applied during decode.
    ///   - trimStart: Optional trim start in seconds.
    ///   - trimEnd: Optional trim end in seconds.
    /// - Returns: ``FrequencyBandData`` with magnitudes for each frame.
    static func decode(
        url: URL,
        ffmpegPath: String,
        frameRate: Double,
        duration: Double,
        bandCount: Int = defaultBandCount,
        frequencyDistribution: FrequencyDistribution = .logarithmic,
        normalizeAudio: Bool = false,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async throws -> FrequencyBandData {
        // 1. Decode audio to mono PCM temp file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.aagedal.MediaConverter.pcmdecode.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pcmFile = tempDir.appendingPathComponent("audio.raw")

        let arguments = buildDecodeArguments(
            url: url,
            outputPath: pcmFile.path,
            normalizeAudio: normalizeAudio,
            audioRoutingConfig: audioRoutingConfig,
            trimStart: trimStart,
            trimEnd: trimEnd
        )

        try await runFFmpeg(
            path: ffmpegPath,
            arguments: arguments,
            inputURL: url,
            outputURL: pcmFile,
            subprocessRunner: subprocessRunner
        )
        try Task.checkCancellation()

        // 2. Read PCM data
        let pcmData = try Data(contentsOf: pcmFile)
        let totalSamples = pcmData.count / MemoryLayout<Float>.size
        guard totalSamples > 0 else {
            throw WaveformPCMDecoderError.noAudioSamples
        }

        // 3. Compute frequency bands via FFT
        let bandEdges = computeBandEdges(distribution: frequencyDistribution, bandCount: bandCount)
        let hopSize = Int(Double(analysisRate) / frameRate)
        let frameCount = max(1, Int(ceil(duration * frameRate)))

        let magnitudes = try computeFrequencyBands(
            pcmData: pcmData,
            totalSamples: totalSamples,
            hopSize: hopSize,
            frameCount: frameCount,
            bandEdges: bandEdges,
            bandCount: bandCount
        )

        try Task.checkCancellation()

        return FrequencyBandData(
            bandCount: bandCount,
            frameCount: frameCount,
            magnitudes: magnitudes,
            totalDuration: duration
        )
    }

    // MARK: - FFmpeg Decode Arguments

    private static func buildDecodeArguments(
        url: URL,
        outputPath: String,
        normalizeAudio: Bool,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?
    ) -> [String] {
        var args: [String] = ["-hide_banner", "-loglevel", "error"]

        // Trim start (seek before input for efficiency)
        if let trimStart, trimStart > 0.01 {
            args.append(contentsOf: ["-ss", String(format: "%.6f", trimStart)])
        }

        args.append(contentsOf: ["-i", url.path])

        // Trim duration
        if let trimStart, let trimEnd, trimEnd > trimStart {
            let duration = trimEnd - trimStart
            args.append(contentsOf: ["-t", String(format: "%.6f", duration)])
        } else if let trimEnd, trimEnd > 0 {
            if trimStart == nil || trimStart! <= 0.01 {
                args.append(contentsOf: ["-t", String(format: "%.6f", trimEnd)])
            }
        }

        args.append("-vn")  // No video

        // Audio routing filter for decode (pick the right channels/tracks for analysis)
        var audioFilters: [String] = []

        if let routingConfig = audioRoutingConfig, let operation = routingConfig.channelOperation {
            // Apply channel routing during decode
            switch operation {
            case .mergeToStereo(let trackIndices):
                if trackIndices.count >= 2 {
                    let inputs = trackIndices.map { "[0:a:\($0)]" }.joined()
                    let mergeFilter = "\(inputs)amerge=inputs=\(trackIndices.count),pan=mono|c0<c0+c1[pcm]"
                    args.append(contentsOf: ["-filter_complex", mergeFilter, "-map", "[pcm]"])
                } else {
                    args.append(contentsOf: ["-map", "0:a:0", "-ac", "1"])
                }
            case .swapChannels(let trackIndex):
                args.append(contentsOf: ["-map", "0:a:\(trackIndex)", "-ac", "1"])
            case .extractChannel(let trackIndex, let channelIndex, _):
                let filter = "[0:a:\(trackIndex)]pan=mono|c0=c\(channelIndex)[pcm]"
                args.append(contentsOf: ["-filter_complex", filter, "-map", "[pcm]"])
            case .splitToMono:
                // splitToMono shouldn't reach here (incompatible with waveform), but handle gracefully
                args.append(contentsOf: ["-map", "0:a:0", "-ac", "1"])
            }
        } else if let routingConfig = audioRoutingConfig, !routingConfig.outputTrackIndices.isEmpty {
            // Simple track selection — use first selected track
            args.append(contentsOf: ["-map", "0:a:\(routingConfig.outputTrackIndices[0])", "-ac", "1"])
        } else {
            // Default: first audio stream, downmix to mono
            args.append(contentsOf: ["-ac", "1"])
        }

        // Audio processing filters (applied after routing)
        audioFilters.append("aresample=\(analysisRate)")
        if normalizeAudio {
            audioFilters.append("dynaudnorm=f=250:g=30:p=0.9")
        }

        // If we didn't use -filter_complex for routing, apply audio filters via -af
        if !args.contains("-filter_complex") {
            args.append(contentsOf: ["-af", audioFilters.joined(separator: ",")])
        } else {
            // Routing used filter_complex; we need to chain audio filters
            // Find the filter_complex argument and append our filters
            if let fcIdx = args.firstIndex(of: "-filter_complex"), fcIdx + 1 < args.count {
                // Replace [pcm] output label with audio processing chain
                var fc = args[fcIdx + 1]
                if fc.hasSuffix("[pcm]") {
                    fc = fc.replacingOccurrences(of: "[pcm]", with: ",\(audioFilters.joined(separator: ","))[pcm]")
                    args[fcIdx + 1] = fc
                }
            }
        }

        // Output format: mono float32 PCM
        args.append(contentsOf: [
            "-f", "f32le",
            "-c:a", "pcm_f32le",
            "-ar", "\(analysisRate)",
            "-y", outputPath
        ])

        return args
    }

    // MARK: - FFT Computation

    /// Computes frequency band edges using the specified distribution.
    static func computeBandEdges(distribution: FrequencyDistribution, bandCount: Int) -> [Double] {
        switch distribution {
        case .logarithmic:
            return computeLogBandEdges(bandCount: bandCount)
        case .mel:
            return computeMelBandEdges(bandCount: bandCount)
        case .linear:
            return computeLinearBandEdges(bandCount: bandCount)
        }
    }

    /// Logarithmic (base-2) spacing — matches human frequency perception.
    private static func computeLogBandEdges(bandCount: Int) -> [Double] {
        var edges = [Double](repeating: 0, count: bandCount + 1)
        let logMin = log2(minFrequency)
        let logMax = log2(maxFrequency)
        for i in 0...bandCount {
            edges[i] = pow(2.0, logMin + (logMax - logMin) * Double(i) / Double(bandCount))
        }
        return edges
    }

    /// Mel scale — psychoacoustic model with smoother bass-to-treble transition.
    private static func computeMelBandEdges(bandCount: Int) -> [Double] {
        var edges = [Double](repeating: 0, count: bandCount + 1)
        let melMin = hzToMel(minFrequency)
        let melMax = hzToMel(maxFrequency)
        for i in 0...bandCount {
            let mel = melMin + (melMax - melMin) * Double(i) / Double(bandCount)
            edges[i] = melToHz(mel)
        }
        return edges
    }

    /// Linear — equal Hz per band.
    private static func computeLinearBandEdges(bandCount: Int) -> [Double] {
        var edges = [Double](repeating: 0, count: bandCount + 1)
        for i in 0...bandCount {
            edges[i] = minFrequency + (maxFrequency - minFrequency) * Double(i) / Double(bandCount)
        }
        return edges
    }

    private static func hzToMel(_ hz: Double) -> Double {
        2595.0 * log10(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Double) -> Double {
        700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    /// Runs FFT on each hop position and groups bins into frequency bands.
    private static func computeFrequencyBands(
        pcmData: Data,
        totalSamples: Int,
        hopSize: Int,
        frameCount: Int,
        bandEdges: [Double],
        bandCount: Int
    ) throws -> [[Float]] {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw WaveformPCMDecoderError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftSize / 2
        let binWidth = Double(analysisRate) / Double(fftSize)

        // Precompute bin ranges per band (guarantees at least 1 bin per band)
        let bandBinRanges = precomputeBandBinRanges(bandEdges: bandEdges, bandCount: bandCount, halfN: halfN, binWidth: binWidth)

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: bandCount), count: frameCount)

        // Track per-band peaks for independent normalization
        var bandPeaks = [Float](repeating: 0, count: bandCount)

        try pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)

            // Temp buffers
            var windowed = [Float](repeating: 0, count: fftSize)
            var realp = [Float](repeating: 0, count: halfN)
            var imagp = [Float](repeating: 0, count: halfN)

            for frame in 0..<frameCount {
                if frame.isMultiple(of: 16) {
                    try Task.checkCancellation()
                }
                let center = frame * hopSize
                let start = max(0, center - fftSize / 2)
                let available = max(0, min(fftSize, totalSamples - start))

                // Zero-pad if not enough samples
                windowed = [Float](repeating: 0, count: fftSize)
                for i in 0..<available {
                    windowed[i] = samples[start + i]
                }

                // Apply window
                vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

                // Pack into split complex and run FFT
                var binMagnitudes = [Float](repeating: 0, count: halfN)
                realp.withUnsafeMutableBufferPointer { rBuf in
                    imagp.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(
                            realp: rBuf.baseAddress!,
                            imagp: iBuf.baseAddress!
                        )

                        // ctoz: interleaved -> split complex
                        windowed.withUnsafeBufferPointer { windowedBuf in
                            windowedBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexBuf in
                                vDSP_ctoz(complexBuf, 2, &splitComplex, 1, vDSP_Length(halfN))
                            }
                        }

                        // Forward FFT
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                        // Compute magnitudes (squared) for each bin
                        vDSP_zvmags(&splitComplex, 1, &binMagnitudes, 1, vDSP_Length(halfN))
                    }
                }

                // Scale
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(binMagnitudes, 1, &scale, &binMagnitudes, 1, vDSP_Length(halfN))

                // sqrt to get magnitude (not squared)
                var count = Int32(halfN)
                vvsqrtf(&binMagnitudes, binMagnitudes, &count)

                // Accumulate into bands using precomputed bin ranges
                for band in 0..<bandCount {
                    let (startBin, endBin) = bandBinRanges[band]
                    var sum: Float = 0
                    var count = 0
                    for bin in startBin...endBin {
                        sum += binMagnitudes[bin]
                        count += 1
                    }
                    magnitudes[frame][band] = count > 0 ? sum / Float(count) : 0
                    bandPeaks[band] = max(bandPeaks[band], magnitudes[frame][band])
                }
            }
        }

        // Per-band normalization: each band independently scaled to 0.0–1.0
        // This ensures treble bands are as visually active as bass bands,
        // since raw FFT magnitudes drop off steeply with frequency.
        for band in 0..<bandCount {
            let peak = bandPeaks[band]
            if peak > 0 {
                for frame in 0..<frameCount {
                    magnitudes[frame][band] /= peak
                }
            }
        }

        return magnitudes
    }

    /// Precomputes the range of FFT bins for each frequency band.
    /// Guarantees every band has at least one bin by clamping to the nearest bin
    /// when the band is too narrow to contain one at the current FFT resolution.
    private static func precomputeBandBinRanges(bandEdges: [Double], bandCount: Int, halfN: Int, binWidth: Double) -> [(Int, Int)] {
        var ranges = [(Int, Int)](repeating: (0, 0), count: bandCount)
        for band in 0..<bandCount {
            // Ideal bin range for this band's frequency range
            let idealStart = Int(round(bandEdges[band] / binWidth))
            let idealEnd = Int(round(bandEdges[band + 1] / binWidth)) - 1

            var startBin = max(0, min(halfN - 1, idealStart))
            var endBin = max(0, min(halfN - 1, idealEnd))

            // Ensure at least one bin per band
            if endBin < startBin {
                // Band is too narrow — use the nearest bin to the band center
                let centerFreq = (bandEdges[band] + bandEdges[band + 1]) / 2.0
                let nearestBin = max(0, min(halfN - 1, Int(round(centerFreq / binWidth))))
                startBin = nearestBin
                endBin = nearestBin
            }

            ranges[band] = (startBin, endBin)
        }
        return ranges
    }

    // MARK: - FFmpeg Process

    private static func runFFmpeg(
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
            throw WaveformPCMDecoderError.decodeFailed("FFmpeg audio decode timed out")
        } catch {
            throw WaveformPCMDecoderError.decodeFailed(
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
            throw WaveformPCMDecoderError.decodeFailed(message)
        }
    }
}

enum WaveformPCMDecoderError: Error, LocalizedError {
    case noAudioSamples
    case fftSetupFailed
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioSamples:
            return "No audio samples decoded from input file"
        case .fftSetupFailed:
            return "Failed to create FFT setup"
        case .decodeFailed(let message):
            return "FFmpeg decode failed: \(message)"
        }
    }
}
