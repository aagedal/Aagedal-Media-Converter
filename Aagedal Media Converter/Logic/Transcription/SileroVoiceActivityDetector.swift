// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Foundation

/// Silero VAD (MIT), run on the CPU from the bundled ggml file that the FFmpeg
/// whisper filter also uses. It mirrors whisper.cpp's implementation, so it
/// finds the same speech whisper.cpp would: a reflect-padded STFT, four
/// convolutions and an LSTM give one speech probability per 32 ms window.
struct SileroVoiceActivityDetector: Sendable {
    struct Parameters: Sendable {
        var threshold: Float = 0.5
        /// Shorter bursts are dropped.
        var minSpeech = 0.25
        /// Shorter pauses do not end speech.
        var minSilence = 0.1
        /// Added around each stretch of speech.
        var speechPadding = 0.03
    }

    enum ModelError: Error {
        case invalidModel
        case unsupportedAudio
    }

    static let sampleRate = 16_000

    /// Samples per probability.
    let window: Int
    private let basis: [Float]          // [frameLength x 2·bins]
    private let bins: Int
    private let layers: [ConvolutionLayer]
    private let inputWeights: [Float]   // [hidden x 4·hidden]
    private let hiddenWeights: [Float]  // [hidden x 4·hidden]
    private let gateBias: [Float]       // [4·hidden]
    private let hidden: Int
    private let outputWeights: [Float]  // [hidden]
    private let outputBias: Float

    private static let frameLength = 256
    private static let hop = 128
    private static let reflectPadding = 64
    private static let strides = [1, 2, 2, 1]

    private struct ConvolutionLayer: Sendable {
        let inputs: Int
        let outputs: Int
        let kernel: Int
        let stride: Int
        let weights: [Float]  // [kernel·inputs x outputs]
        let bias: [Float]
    }

    init(modelURL: URL) throws {
        var reader = GGMLReader(data: try Data(contentsOf: modelURL))
        guard reader.int32() == 0x6767_6d6c else { throw ModelError.invalidModel }
        _ = reader.bytes(Int(reader.int32()))           // model type
        _ = (reader.int32(), reader.int32(), reader.int32())  // version
        window = Int(reader.int32())
        _ = reader.int32()                               // context samples, unused by whisper.cpp
        let layerCount = Int(reader.int32())
        let shapes = (0..<layerCount).map { _ in (Int(reader.int32()), Int(reader.int32()), Int(reader.int32())) }
        let lstmInput = Int(reader.int32())
        hidden = Int(reader.int32())
        _ = (reader.int32(), reader.int32())             // final convolution in and out

        var tensors: [String: [Float]] = [:]
        while let tensor = reader.tensor() { tensors[tensor.name] = tensor.values }
        guard !reader.failed, layerCount == Self.strides.count, window > 0, lstmInput == hidden else {
            throw ModelError.invalidModel
        }

        func tensor(_ name: String, count: Int) throws -> [Float] {
            guard let values = tensors["_model." + name], values.count == count else { throw ModelError.invalidModel }
            return values
        }

        // PyTorch [out][in][kernel] becomes an im2col matrix [kernel·in x out].
        func columns(_ values: [Float], inputs: Int, outputs: Int, kernel: Int) -> [Float] {
            var matrix = [Float](repeating: 0, count: values.count)
            for output in 0..<outputs {
                for input in 0..<inputs {
                    for tap in 0..<kernel {
                        matrix[(tap * inputs + input) * outputs + output] = values[(output * inputs + input) * kernel + tap]
                    }
                }
            }
            return matrix
        }

        guard let stft = tensors["_model.stft.forward_basis_buffer"], !stft.isEmpty,
              stft.count % (2 * Self.frameLength) == 0 else { throw ModelError.invalidModel }
        bins = stft.count / Self.frameLength / 2
        basis = columns(stft, inputs: 1, outputs: 2 * bins, kernel: Self.frameLength)

        var channels = bins
        layers = try shapes.enumerated().map { index, shape in
            let (inputs, outputs, kernel) = shape
            guard inputs == channels else { throw ModelError.invalidModel }
            channels = outputs
            return ConvolutionLayer(
                inputs: inputs, outputs: outputs, kernel: kernel, stride: Self.strides[index],
                weights: columns(try tensor("encoder.\(index).reparam_conv.weight", count: inputs * outputs * kernel),
                                 inputs: inputs, outputs: outputs, kernel: kernel),
                bias: try tensor("encoder.\(index).reparam_conv.bias", count: outputs)
            )
        }
        guard channels == hidden else { throw ModelError.invalidModel }

        let gates = 4 * hidden
        inputWeights = columns(try tensor("decoder.rnn.weight_ih", count: gates * hidden), inputs: hidden, outputs: gates, kernel: 1)
        hiddenWeights = columns(try tensor("decoder.rnn.weight_hh", count: gates * hidden), inputs: hidden, outputs: gates, kernel: 1)
        gateBias = zip(try tensor("decoder.rnn.bias_ih", count: gates), try tensor("decoder.rnn.bias_hh", count: gates)).map(+)
        outputWeights = try tensor("decoder.decoder.2.weight", count: hidden)
        outputBias = try tensor("decoder.decoder.2.bias", count: 1)[0]
    }

    /// The stretches of `audio` that hold speech, in seconds.
    func speech(in audio: PCMWaveFile, parameters: Parameters = Parameters()) throws -> [ClosedRange<Double>] {
        Self.segments(
            probabilities: try probabilities(audio), window: window,
            duration: audio.duration, parameters: parameters
        )
    }

    /// One speech probability per `window` samples.
    func probabilities(_ audio: PCMWaveFile) throws -> [Float] {
        guard audio.sampleRate == Self.sampleRate else { throw ModelError.unsupportedAudio }
        let windows = (audio.sampleCount + window - 1) / window
        var result: [Float] = []
        result.reserveCapacity(windows)
        var cell = [Float](repeating: 0, count: hidden)
        var state = [Float](repeating: 0, count: hidden)
        let block = 2048
        for first in stride(from: 0, to: windows, by: block) {
            try Task.checkCancellation()
            let count = min(block, windows - first)
            let features = encode(audio.floatSamples(first * window..<(first + count) * window), windows: count)
            result += recur(features, windows: count, cell: &cell, state: &state)
        }
        return result
    }

    /// The convolutional front end for `windows` consecutive windows: one
    /// `hidden`-wide feature vector each.
    private func encode(_ samples: [Float], windows: Int) -> [Float] {
        // Reflect-padded frames, `hop` apart, for every window.
        let padded = window + 2 * Self.reflectPadding
        let frames = (padded - Self.frameLength) / Self.hop + 1
        var input = [Float](repeating: 0, count: windows * frames * Self.frameLength)
        samples.withUnsafeBufferPointer { samples in
            for index in 0..<windows {
                let base = index * window
                func sample(_ position: Int) -> Float {
                    var source = position - Self.reflectPadding
                    if source < 0 { source = -source } else if source >= window { source = 2 * (window - 1) - source }
                    let absolute = base + source
                    return absolute < samples.count ? samples[absolute] : 0
                }
                for frame in 0..<frames {
                    let row = (index * frames + frame) * Self.frameLength
                    for offset in 0..<Self.frameLength {
                        input[row + offset] = sample(frame * Self.hop + offset)
                    }
                }
            }
        }
        let spectrum = multiply(input, rows: windows * frames, inner: Self.frameLength, by: basis, columns: 2 * bins)
        var magnitude = [Float](repeating: 0, count: windows * frames * bins)
        for row in 0..<windows * frames {
            for bin in 0..<bins {
                let real = spectrum[row * 2 * bins + bin]
                let imaginary = spectrum[row * 2 * bins + bins + bin]
                magnitude[row * bins + bin] = (real * real + imaginary * imaginary).squareRoot()
            }
        }

        var features = magnitude
        var length = frames
        for layer in layers {
            (features, length) = convolve(features, windows: windows, length: length, layer: layer)
        }
        // whisper.cpp keeps the first time step of the last layer.
        guard length > 1 else { return features }
        return (0..<windows).flatMap { features[($0 * length) * hidden..<($0 * length + 1) * hidden] }
    }

    /// A padded (by one) 1-D convolution with ReLU, as an im2col matrix product.
    private func convolve(_ input: [Float], windows: Int, length: Int, layer: ConvolutionLayer) -> ([Float], Int) {
        let padding = layer.kernel / 2
        let outputLength = (length + 2 * padding - layer.kernel) / layer.stride + 1
        let width = layer.kernel * layer.inputs
        var matrix = [Float](repeating: 0, count: windows * outputLength * width)
        for index in 0..<windows {
            for step in 0..<outputLength {
                let row = (index * outputLength + step) * width
                for tap in 0..<layer.kernel {
                    let position = step * layer.stride + tap - padding
                    guard position >= 0, position < length else { continue }
                    let source = (index * length + position) * layer.inputs
                    for channel in 0..<layer.inputs {
                        matrix[row + tap * layer.inputs + channel] = input[source + channel]
                    }
                }
            }
        }
        var output = multiply(matrix, rows: windows * outputLength, inner: width, by: layer.weights, columns: layer.outputs)
        for row in 0..<windows * outputLength {
            for channel in 0..<layer.outputs {
                output[row * layer.outputs + channel] = max(0, output[row * layer.outputs + channel] + layer.bias[channel])
            }
        }
        return (output, outputLength)
    }

    /// The LSTM decoder, carrying its state from one block to the next.
    private func recur(_ features: [Float], windows: Int, cell: inout [Float], state: inout [Float]) -> [Float] {
        let gates = 4 * hidden
        let projected = multiply(features, rows: windows, inner: hidden, by: inputWeights, columns: gates)
        var probabilities = [Float](repeating: 0, count: windows)
        var activation = [Float](repeating: 0, count: gates)
        for index in 0..<windows {
            vDSP_mmul(state, 1, hiddenWeights, 1, &activation, 1, 1, vDSP_Length(gates), vDSP_Length(hidden))
            for gate in 0..<gates {
                activation[gate] += projected[index * gates + gate] + gateBias[gate]
            }
            var logit = outputBias
            for unit in 0..<hidden {
                let input = Self.sigmoid(activation[unit])
                let forget = Self.sigmoid(activation[hidden + unit])
                let candidate = tanh(activation[2 * hidden + unit])
                let output = Self.sigmoid(activation[3 * hidden + unit])
                cell[unit] = forget * cell[unit] + input * candidate
                state[unit] = output * tanh(cell[unit])
                logit += max(0, state[unit]) * outputWeights[unit]
            }
            probabilities[index] = Self.sigmoid(logit)
        }
        return probabilities
    }

    private func multiply(_ left: [Float], rows: Int, inner: Int, by right: [Float], columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * columns)
        vDSP_mmul(left, 1, right, 1, &result, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
        return result
    }

    private static func sigmoid(_ value: Float) -> Float { 1 / (1 + exp(-value)) }

    // MARK: - Segments

    /// Turns probabilities into stretches of speech the way whisper.cpp does:
    /// speech starts above `threshold`, ends after `minSilence` below
    /// `threshold - 0.15`, gaps under 0.2 s are joined and short bursts dropped.
    static func segments(
        probabilities: [Float], window: Int, duration: Double, parameters: Parameters = Parameters()
    ) -> [ClosedRange<Double>] {
        let rate = Double(sampleRate)
        let minSilence = Int(parameters.minSilence * rate)
        let minSpeech = Int(parameters.minSpeech * rate)
        let padding = Int(parameters.speechPadding * rate)
        let length = probabilities.count * window
        let lower = max(parameters.threshold - 0.15, 0.01)

        var speeches: [(start: Int, end: Int)] = []
        var start: Int?
        var silenceStart: Int?
        for (index, probability) in probabilities.enumerated() {
            let sample = index * window
            if probability >= parameters.threshold {
                silenceStart = nil
                if start == nil {
                    start = sample
                    continue
                }
            }
            guard let speechStart = start, probability < lower else { continue }
            let silence = silenceStart ?? sample
            silenceStart = silence
            if sample - silence < minSilence { continue }
            if silence - speechStart > minSpeech { speeches.append((speechStart, silence)) }
            start = nil
            silenceStart = nil
        }
        if let start, length - start > minSpeech { speeches.append((start, length)) }

        var merged: [(start: Int, end: Int)] = []
        for speech in speeches {
            if let last = merged.last, speech.start - last.end < Int(0.2 * rate) {
                merged[merged.count - 1].end = speech.end
            } else {
                merged.append(speech)
            }
        }
        merged.removeAll { $0.end - $0.start < minSpeech }

        for index in merged.indices {
            if index == 0 { merged[index].start = max(merged[index].start - padding, 0) }
            if index + 1 < merged.count {
                let silence = merged[index + 1].start - merged[index].end
                let extend = silence < 2 * padding ? silence / 2 : padding
                merged[index].end += extend
                merged[index + 1].start = max(merged[index + 1].start - extend, 0)
            } else {
                merged[index].end = min(merged[index].end + padding, length)
            }
        }
        return merged.map { speech in
            let start = Double(speech.start) / rate
            return start...max(start, min(Double(speech.end) / rate, duration))
        }
    }
}

/// Reads the little-endian ggml layout whisper.cpp writes for its VAD models.
private struct GGMLReader {
    let data: Data
    var offset = 0
    var failed = false

    mutating func bytes(_ count: Int) -> Data {
        guard count >= 0, offset + count <= data.count else {
            failed = true
            offset = data.count
            return Data()
        }
        defer { offset += count }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
    }

    mutating func int32() -> Int32 {
        let raw = bytes(4)
        guard raw.count == 4 else { return 0 }
        return raw.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
    }

    /// The next tensor, or nil at the end of the file.
    mutating func tensor() -> (name: String, values: [Float])? {
        guard !failed, offset < data.count else { return nil }
        let dimensions = Int(int32())
        let nameLength = Int(int32())
        let type = int32()
        guard (0...4).contains(dimensions) else {
            failed = true
            return nil
        }
        let count = (0..<dimensions).reduce(1) { product, _ in product * Int(int32()) }
        let name = String(decoding: bytes(nameLength), as: UTF8.self)
        let values: [Float]
        switch type {
        case 0:
            values = bytes(count * 4).withUnsafeBytes { raw in
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
        case 1:
            values = bytes(count * 2).withUnsafeBytes { raw in
                (0..<count).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))) }
            }
        default:
            failed = true
            return nil
        }
        guard !failed else { return nil }
        return (name, values)
    }
}
