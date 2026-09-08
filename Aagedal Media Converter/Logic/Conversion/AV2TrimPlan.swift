// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Shared seek and duration policy for AV2 picture, audio, progress and chunk planning.
struct AV2TrimPlan: Equatable, Sendable {
    let start: Double
    let end: Double?

    init(start: Double?, end: Double?) {
        let normalizedStart = start.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        self.start = normalizedStart
        self.end = end.flatMap { $0.isFinite && $0 > normalizedStart ? $0 : nil }
    }

    var inputArguments: [String] {
        start > 0 ? ["-ss", String(format: "%.6f", start)] : []
    }

    var outputArguments: [String] {
        end.map { ["-t", String(format: "%.6f", $0 - start)] } ?? []
    }

    func effectiveDuration(sourceDuration: Double?) -> Double? {
        let source = sourceDuration.flatMap { $0.isFinite ? max(0, $0) : nil }
        if let end {
            return max(0, (source.map { min(end, $0) } ?? end) - start)
        }
        return source.map { max(0, $0 - start) }
    }
}
