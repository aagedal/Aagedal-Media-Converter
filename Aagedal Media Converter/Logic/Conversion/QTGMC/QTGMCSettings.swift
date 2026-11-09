// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which deinterlacer the app uses when it deinterlaces an interlaced source on export.
enum DeinterlacerEngine: String, CaseIterable, Identifiable, Sendable {
    /// FFmpeg's bwdif: fast, in-process.
    case bwdif
    /// QTGMC-style motion-compensated deinterlacing on the GPU (Metal).
    case qtgmc

    var id: String { rawValue }
}

/// Speed/quality trade-off for the Metal QTGMC deinterlacer, loosely following
/// QTGMC's Fast / Medium / Slower presets.
enum QTGMCPreset: String, CaseIterable, Identifiable, Sendable {
    case fast
    case medium
    case slow

    var id: String { rawValue }
}

/// Deinterlacer preferences captured with the other conversion preparation settings.
struct DeinterlacerSettings: Equatable, Sendable {
    var engine: DeinterlacerEngine
    var preset: QTGMCPreset
    /// Output one frame per field (50i → 50p), as bwdif does in this app. When false,
    /// QTGMC keeps the source frame rate (50i → 25p), like QTGMC's FPSDivisor=2.
    var doubleRate: Bool

    static let standard = DeinterlacerSettings(engine: .bwdif, preset: .medium, doubleRate: true)

    init(engine: DeinterlacerEngine, preset: QTGMCPreset, doubleRate: Bool) {
        self.engine = engine
        self.preset = preset
        self.doubleRate = doubleRate
    }

    init(defaults: UserDefaults = .standard) {
        engine = defaults.string(forKey: AppConstants.deinterlacerEngineKey)
            .flatMap(DeinterlacerEngine.init(rawValue:)) ?? AppConstants.deinterlacerEngineDefault
        preset = defaults.string(forKey: AppConstants.qtgmcPresetKey)
            .flatMap(QTGMCPreset.init(rawValue:)) ?? AppConstants.qtgmcPresetDefault
        doubleRate = defaults.object(forKey: AppConstants.qtgmcDoubleRateKey) as? Bool
            ?? AppConstants.qtgmcDoubleRateDefault
    }

    var usesQTGMC: Bool { engine == .qtgmc }

    var qtgmcParameters: QTGMCParameters { QTGMCParameters(preset: preset) }
}

/// NNEDI3 neighbourhood sizes, in the order of nnedi3_weights.bin (`nsize`).
enum NNEDINeighbourhood: Int, Sendable {
    case s8x6 = 0, s16x6, s32x6, s48x6, s8x4, s16x4, s32x4

    var xdim: Int { [8, 16, 32, 48, 8, 16, 32][rawValue] }
    var ydim: Int { [6, 6, 6, 6, 4, 4, 4][rawValue] }
}

/// NNEDI3 predictor neuron counts, in the order of nnedi3_weights.bin (`nns`).
enum NNEDINeurons: Int, Sendable {
    case n16 = 0, n32, n64, n128, n256

    var count: Int { [16, 32, 64, 128, 256][rawValue] }
}

/// Tunables of the Metal pipeline. Thresholds are per-pixel mean absolute
/// differences on 0...1 samples; QTGMC's 8x8-block SAD values are converted with
/// `sad / 64 / 255`.
struct QTGMCParameters: Equatable, Sendable {
    var neighbourhood: NNEDINeighbourhood = .s16x6
    var neurons: NNEDINeurons = .n32
    /// 1 or 2 NNEDI3 predictor passes (nnedi3 `qual`).
    var nnediQualityPasses = 1
    /// Motion search block size and step (overlap = blockSize - step), luma pixels.
    var blockSize = 16
    var blockStep = 8
    /// Temporal radius of the first, binomial motion-compensated smoothing (1 or 2).
    var temporalRadius1 = 2
    /// Temporal radius of the final motion-compensated smoothing (1 or 2).
    var temporalRadius2 = 1
    var sharpness: Float = 1.0
    var thresholdSAD1: Float = 640.0 / 64.0 / 255.0
    var thresholdSAD2: Float = 256.0 / 64.0 / 255.0
    var sceneChangeSAD: Float = 180.0 / 64.0 / 255.0
    var sceneChangeFraction: Float = 98.0 / 255.0
    /// Motion vector coherence penalty per pixel of deviation from the predictor.
    var lambda: Float = 0.0015
    /// Sub-pixel refinement steps after the integer search.
    var subpelSteps: [Float] = [0.5, 0.25]
    /// Clamp the final result to the 3x3 range of the interpolated field (Rep2).
    var repair = true
    /// Put the original field lines back into the output and remove the resulting
    /// combing (QTGMC Lossless=1). Scored better than Lossless=0 against ground truth.
    var lossless = true

    init() {}

    init(preset: QTGMCPreset) {
        switch preset {
        case .fast:
            neighbourhood = .s16x4
            neurons = .n32
            temporalRadius1 = 1
            subpelSteps = [0.5]
        case .medium:
            break
        case .slow:
            neurons = .n64
            nnediQualityPasses = 2
            temporalRadius2 = 2
        }
    }

    /// Motion vectors needed by the smoothing passes (field offsets).
    var motionOffsets: [Int] {
        max(temporalRadius1, temporalRadius2) >= 2 ? [-2, -1, 1, 2] : [-1, 1]
    }
}
