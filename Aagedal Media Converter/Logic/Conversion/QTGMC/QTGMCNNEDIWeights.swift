// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads nnedi3_weights.bin (the weights shipped with nnedi3/znedi3 and used by
// FFmpeg's nnedi filter) and prepares one prescreener and one predictor model the
// way FFmpeg's vf_nnedi.c does: prescreener kernels are de-interleaved, mean
// removed and scaled; predictor filters have their means removed.

import Foundation

struct QTGMCNNEDIWeights: Sendable {
    /// Size of the canonical nnedi3_weights.bin.
    static let expectedFileSize = 13_574_928
    static let resourceName = "nnedi3_weights"
    static let resourceExtension = "bin"

    /// `PrescreenerWeights` in QTGMC.metal: kernel0[4][64], bias0[4], kernel1[4][4], bias1[4].
    let prescreener: [Float]
    /// Per quality pass: softmax[n][size], elliott[n][size], softmaxBias[n], elliottBias[n].
    let predictor: [Float]
    let neighbourhood: NNEDINeighbourhood
    let neurons: NNEDINeurons
    let qualityPasses: Int

    enum LoadError: Error, LocalizedError {
        case missingResource
        case unexpectedSize(Int)
        case unsupportedNeighbourhood

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The NNEDI3 weights file is missing from the app bundle"
            case .unexpectedSize(let size):
                return "The NNEDI3 weights file has an unexpected size (\(size) bytes)"
            case .unsupportedNeighbourhood:
                return "The selected NNEDI3 neighbourhood is too large for the Metal predictor"
            }
        }
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }

    static func load(
        from url: URL,
        neighbourhood: NNEDINeighbourhood,
        neurons: NNEDINeurons,
        qualityPasses: Int
    ) throws -> QTGMCNNEDIWeights {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try QTGMCNNEDIWeights(
            data: data, neighbourhood: neighbourhood, neurons: neurons, qualityPasses: qualityPasses
        )
    }

    /// Largest predictor window the Metal kernel accepts (`QTGMC_MAX_PREDICTOR_INPUTS`).
    static let maxPredictorInputs = 128

    init(data: Data, neighbourhood: NNEDINeighbourhood, neurons: NNEDINeurons, qualityPasses: Int) throws {
        guard data.count == Self.expectedFileSize else { throw LoadError.unexpectedSize(data.count) }
        guard neighbourhood.xdim * neighbourhood.ydim <= Self.maxPredictorInputs else {
            throw LoadError.unsupportedNeighbourhood
        }
        let floats: [Float] = data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        var cursor = 0
        func take(_ count: Int) -> ArraySlice<Float> {
            defer { cursor += count }
            return floats[cursor..<(cursor + count)]
        }

        // Original prescreener (unused): 4x48 kernel, biases, 4x4, 4x8.
        _ = take(4 * 48); _ = take(4); _ = take(16); _ = take(4); _ = take(32); _ = take(4)

        // Three "new" prescreeners; FFmpeg's default pscrn=new uses the first.
        var prescreener: [Float] = []
        for index in 0..<3 {
            let shuffled0 = Array(take(4 * 64))
            let bias0 = Array(take(4))
            let shuffled1 = Array(take(16))
            let bias1 = Array(take(4))
            guard index == 0 else { continue }
            var kernel0 = [Float](repeating: 0, count: 4 * 64)
            var kernel1 = [Float](repeating: 0, count: 16)
            for n in 0..<4 {
                for k in 0..<64 {
                    kernel0[n * 64 + k] = shuffled0[(k / 8) * 32 + n * 8 + k % 8]
                }
                for k in 0..<4 {
                    kernel1[n * 4 + k] = shuffled1[k * 4 + n]
                }
            }
            let half: Float = 255.0 / 2.0
            for n in 0..<4 {
                var mean: Float = 0
                for k in 0..<64 { mean += kernel0[n * 64 + k] }
                mean /= 64
                for k in 0..<64 { kernel0[n * 64 + k] = (kernel0[n * 64 + k] - mean) / half }
            }
            prescreener = kernel0 + bias0 + kernel1 + bias1
        }

        let neuronCounts = [16, 32, 64, 128, 256]
        let xdims = [8, 16, 32, 48, 8, 16, 32]
        let ydims = [6, 6, 6, 6, 4, 4, 4]
        var predictor: [Float] = []
        // Weight sets: [0] trained for absolute error (nnedi3 etype=0), [1] squared error.
        for etype in 0..<2 {
            for neuronIndex in 0..<5 {
                for sizeIndex in 0..<7 {
                    let count = neuronCounts[neuronIndex]
                    let size = xdims[sizeIndex] * ydims[sizeIndex]
                    for pass in 0..<2 {
                        let softmax = take(count * size)
                        let elliott = take(count * size)
                        let softmaxBias = take(count)
                        let elliottBias = take(count)
                        guard etype == 0, neuronIndex == neurons.rawValue,
                              sizeIndex == neighbourhood.rawValue, pass < qualityPasses else { continue }
                        predictor += Self.meanAdjusted(
                            softmax: Array(softmax), elliott: Array(elliott),
                            softmaxBias: Array(softmaxBias), elliottBias: Array(elliottBias),
                            neurons: count, size: size
                        )
                    }
                }
            }
        }
        precondition(cursor == floats.count, "nnedi3_weights.bin layout mismatch")

        self.prescreener = prescreener
        self.predictor = predictor
        self.neighbourhood = neighbourhood
        self.neurons = neurons
        self.qualityPasses = qualityPasses
    }

    /// FFmpeg's `subtract_mean_predictor` for one quality pass.
    private static func meanAdjusted(
        softmax: [Float], elliott: [Float], softmaxBias: [Float], elliottBias: [Float],
        neurons: Int, size: Int
    ) -> [Float] {
        var softmax = softmax
        var elliott = elliott
        var softmaxBias = softmaxBias
        var softmaxMeans = [Double](repeating: 0, count: neurons)
        var elliottMeans = [Double](repeating: 0, count: neurons)
        var meanFilter = [Double](repeating: 0, count: size)
        for n in 0..<neurons {
            var s: Float = 0
            var e: Float = 0
            for k in 0..<size {
                s += softmax[n * size + k]
                e += elliott[n * size + k]
            }
            softmaxMeans[n] = Double(s / Float(size))
            elliottMeans[n] = Double(e / Float(size))
            for k in 0..<size {
                meanFilter[k] += Double(softmax[n * size + k]) - softmaxMeans[n]
            }
        }
        for k in 0..<size { meanFilter[k] *= 1.0 / Double(neurons) }
        var biasSum: Float = 0
        for value in softmaxBias { biasSum += value }
        let biasMean = biasSum / Float(neurons)
        for n in 0..<neurons {
            for k in 0..<size {
                softmax[n * size + k] = Float(Double(softmax[n * size + k]) - (softmaxMeans[n] + meanFilter[k]))
                elliott[n * size + k] = Float(Double(elliott[n * size + k]) - elliottMeans[n])
            }
            softmaxBias[n] -= biasMean
        }
        return softmax + elliott + softmaxBias + elliottBias
    }
}
