// Aagedal Media Player / Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
// Vendored unchanged except type name from Media Player 0c56c2c, UI/TimecodeFormatter.swift.

import Foundation

nonisolated struct StitchMarkerTimecodeRate: Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64
    let nominalFPS: Int64
    let isDropFrame: Bool

    init(numerator: Int, denominator: Int, dropFrame: Bool = false) {
        let safeNumerator = max(Int64(numerator), 1)
        let safeDenominator = max(Int64(denominator), 1)
        let divisor = Self.greatestCommonDivisor(safeNumerator, safeDenominator)

        self.numerator = safeNumerator / divisor
        self.denominator = safeDenominator / divisor
        self.nominalFPS = max(Int64((Double(safeNumerator) / Double(safeDenominator)).rounded()), 1)
        self.isDropFrame = dropFrame && Self.isDropFrameCompatible(
            numerator: safeNumerator,
            denominator: safeDenominator,
            nominalFPS: nominalFPS
        )
    }

    init(frameRate: Double, dropFrame: Bool = false) {
        let safeRate = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        let broadcastRates = [(24_000, 1_001), (30_000, 1_001), (48_000, 1_001), (60_000, 1_001), (120_000, 1_001)]

        if let rate = broadcastRates.first(where: {
            abs(safeRate - (Double($0.0) / Double($0.1))) < 0.001
        }) {
            self.init(numerator: rate.0, denominator: rate.1, dropFrame: dropFrame)
        } else if abs(safeRate - safeRate.rounded()) < 0.000_001 {
            self.init(numerator: Int(safeRate.rounded()), denominator: 1, dropFrame: dropFrame)
        } else {
            self.init(
                numerator: Int((safeRate * 1_000_000).rounded()),
                denominator: 1_000_000,
                dropFrame: dropFrame
            )
        }
    }

    var value: Double {
        Double(numerator) / Double(denominator)
    }

    var droppedFramesPerMinute: Int64 {
        guard isDropFrame else { return 0 }
        return nominalFPS / 15
    }

    func frameCount(forSeconds seconds: Double) -> Int64? {
        guard seconds.isFinite else { return nil }
        let frames = seconds * Double(numerator) / Double(denominator)
        let rounded = frames.rounded()
        // Double(Int64.max) rounds up to 2^63, which cannot be converted to Int64.
        guard rounded >= Double(Int64.min), rounded < Double(Int64.max) else { return nil }
        return Int64(rounded)
    }

    func seconds(forFrameCount frames: Int64) -> Double {
        Double(frames) * Double(denominator) / Double(numerator)
    }

    func timecode(forFrameCount frames: Int64) -> String {
        let labelFrames: Int64

        if isDropFrame {
            let dropped = droppedFramesPerMinute
            let framesPerMinute = nominalFPS * 60 - dropped
            let framesPerTenMinutes = nominalFPS * 600 - dropped * 9
            let framesPer24Hours = framesPerTenMinutes * 6 * 24
            let wrapped = Self.positiveModulo(frames, framesPer24Hours)
            let tenMinuteBlocks = wrapped / framesPerTenMinutes
            let remainder = wrapped % framesPerTenMinutes

            var labelsSkipped = dropped * 9 * tenMinuteBlocks
            if remainder >= dropped {
                labelsSkipped += dropped * ((remainder - dropped) / framesPerMinute)
            }
            labelFrames = wrapped + labelsSkipped
        } else {
            labelFrames = Self.positiveModulo(frames, nominalFPS * 60 * 60 * 24)
        }

        let frame = labelFrames % nominalFPS
        let totalSeconds = labelFrames / nominalFPS
        let second = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minute = totalMinutes % 60
        let hour = (totalMinutes / 60) % 24
        let separator = isDropFrame ? ";" : ":"

        return String(format: "%02lld:%02lld:%02lld%@%02lld", hour, minute, second, separator, frame)
    }

    /// Invalid dropped labels such as 00:01:00;00 at 29.97 are rejected.
    func frameCount(forTimecode timecode: String) -> Int64? {
        let fields = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard fields.count == 4,
              let hour = Int64(fields[0]),
              let minute = Int64(fields[1]),
              let second = Int64(fields[2]),
              let frame = Int64(fields[3]),
              hour >= 0, hour < 24,
              minute >= 0, minute < 60,
              second >= 0, second < 60,
              frame >= 0, frame < nominalFPS else {
            return nil
        }

        if isDropFrame,
           minute % 10 != 0,
           second == 0,
           frame < droppedFramesPerMinute {
            return nil
        }

        let totalMinutes = hour * 60 + minute
        let nominalFrames = ((hour * 3_600 + minute * 60 + second) * nominalFPS) + frame
        let droppedLabels = isDropFrame
            ? droppedFramesPerMinute * (totalMinutes - totalMinutes / 10)
            : 0
        return nominalFrames - droppedLabels
    }

    private static func isDropFrameCompatible(
        numerator: Int64,
        denominator: Int64,
        nominalFPS: Int64
    ) -> Bool {
        guard nominalFPS == 30 || nominalFPS == 60 else { return false }
        let actual = Double(numerator) / Double(denominator)
        let expected = Double(nominalFPS) * 1_000 / 1_001
        return abs(actual - expected) < 0.001
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    private static func positiveModulo(_ value: Int64, _ modulus: Int64) -> Int64 {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}

