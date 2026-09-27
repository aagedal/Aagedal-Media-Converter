// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A playout program is one file, measured through one selected audio presentation.
/// Stream indices are audio-relative (`0:a:N`), not absolute container indices.
enum LoudnessPresentation: Equatable, Sendable, Identifiable {
    case track(Int)
    case stereo(left: Int, right: Int)
    /// Order: L, R, C, LFE, Ls, Rs (SMPTE/5.1 side).
    case surround51([Int])

    var id: String {
        switch self {
        case .track(let index): return "track-\(index)"
        case .stereo(let left, let right): return "stereo-\(left)-\(right)"
        case .surround51(let indices): return "surround-\(indices.map(String.init).joined(separator: "-"))"
        }
    }

    var streamIndices: [Int] {
        switch self {
        case .track(let index): return [index]
        case .stereo(let left, let right): return [left, right]
        case .surround51(let indices): return indices
        }
    }

    var displayName: String {
        switch self {
        case .track(let index): return "Track \(index + 1)"
        case .stereo(let left, let right): return "Stereo: \(left + 1) L + \(right + 1) R"
        case .surround51(let indices):
            return "5.1: \(indices.map { String($0 + 1) }.joined(separator: ", ")) (L, R, C, LFE, Ls, Rs)"
        }
    }

    /// Only propose grouping when the participating streams are known to be mono.
    static func presets(for tracks: [AudioTrackInfo]) -> [LoudnessPresentation] {
        let singles = tracks.map { LoudnessPresentation.track($0.streamIndex) }
        guard tracks.count > 1, tracks.allSatisfy({ $0.channels == 1 }) else {
            return singles
        }
        let mono = tracks.map(\.streamIndex).sorted()
        let pairs = stride(from: 0, to: mono.count - mono.count % 2, by: 2).map {
            LoudnessPresentation.stereo(left: mono[$0], right: mono[$0 + 1])
        }
        var presentations = singles + pairs
        if mono.count == 6 {
            presentations.append(.surround51(mono))
            // Alternative file order L, R, C, Ls, Rs, LFE. The enum always
            // stores indices in meter order L, R, C, LFE, Ls, Rs.
            presentations.append(.surround51([mono[0], mono[1], mono[2], mono[5], mono[3], mono[4]]))
        }
        return presentations
    }
}

struct LoudnessSample: Equatable, Sendable {
    let seconds: Double
    let momentaryLUFS: Double?
    let shortTermLUFS: Double?
}

struct LoudnessResults: Equatable, Sendable {
    let presentation: LoudnessPresentation
    let integratedLUFS: Double
    let loudnessRangeLU: Double
    let maximumTruePeakDBTP: Double?
    let samples: [LoudnessSample]

    /// Reduce chart work without discarding momentary/short-term extremes from
    /// any time bucket. The measured final summary remains untouched.
    func graphSamples(maxBuckets: Int = 750) -> [LoudnessSample] {
        guard samples.count > maxBuckets * 6 else { return samples }
        let bucketSize = (samples.count + maxBuckets - 1) / maxBuckets
        var selected: [LoudnessSample] = []
        for start in stride(from: 0, to: samples.count, by: bucketSize) {
            let end = min(start + bucketSize, samples.count)
            var indices = Set([start, end - 1])
            for keyPath in [\.momentaryLUFS, \.shortTermLUFS] as [KeyPath<LoudnessSample, Double?>] {
                let valid = (start..<end).filter { samples[$0][keyPath: keyPath] != nil }
                if let minimum = valid.min(by: { samples[$0][keyPath: keyPath]! < samples[$1][keyPath: keyPath]! }) {
                    indices.insert(minimum)
                }
                if let maximum = valid.max(by: { samples[$0][keyPath: keyPath]! < samples[$1][keyPath: keyPath]! }) {
                    indices.insert(maximum)
                }
            }
            selected.append(contentsOf: indices.sorted().map { samples[$0] })
        }
        return selected
    }
}

/// Available video quality metrics
enum QualityMetric: String, CaseIterable, Codable, Sendable {
    case vmaf
    case psnr
    case xpsnr
    case ssimulacra2

    var displayName: String {
        switch self {
        case .vmaf: return "VMAF"
        case .psnr: return "PSNR"
        case .xpsnr: return "XPSNR"
        case .ssimulacra2: return "SSIMULACRA2"
        }
    }

    var description: String {
        switch self {
        case .vmaf:
            return "Video Multi-Method Assessment Fusion. Perceptual quality metric developed by Netflix. Scale: 0-100."
        case .psnr:
            return "Peak Signal-to-Noise Ratio. Traditional mathematical quality metric measured in dB."
        case .xpsnr:
            return "Extended PSNR by Fraunhofer HHI. Perceptually weighted PSNR metric measured in dB."
        case .ssimulacra2:
            return "Perceptual image quality metric by Cloudflare. Scale: 0-100."
        }
    }
}

/// Analytics status for a VideoItem (mirrors SubtitleStatus pattern)
enum AnalyticsStatus: Equatable, Sendable {
    case notQueued
    case pending
    case running(metric: QualityMetric, progress: Double)
    case completed
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .pending, .running:
            return true
        default:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .notQueued:
            return ""
        case .pending:
            return "Pending"
        case .running(let metric, let progress):
            return "Analyzing \(metric.displayName) \(Int(progress * 100))%"
        case .completed:
            return "Done"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Result for a single quality metric
struct MetricResult: Codable, Equatable, Sendable {
    let metric: QualityMetric
    let overallScore: Double
    let min: Double?
    let max: Double?
    let unit: String

    /// Individual channel scores (PSNR y/u/v)
    let channelScores: [String: Double]?

    var formattedScore: String {
        switch metric {
        case .psnr, .xpsnr:
            return String(format: "%.2f %@", overallScore, unit)
        case .vmaf, .ssimulacra2:
            return String(format: "%.1f", overallScore)
        }
    }

    var qualityRating: String {
        switch metric {
        case .vmaf:
            if overallScore >= 93 { return "Excellent" }
            if overallScore >= 80 { return "Good" }
            if overallScore >= 60 { return "Fair" }
            return "Poor"
        case .psnr:
            if overallScore >= 40 { return "Excellent" }
            if overallScore >= 30 { return "Good" }
            if overallScore >= 20 { return "Fair" }
            return "Poor"
        case .xpsnr:
            if overallScore >= 42 { return "Excellent" }
            if overallScore >= 32 { return "Good" }
            if overallScore >= 22 { return "Fair" }
            return "Poor"
        case .ssimulacra2:
            if overallScore >= 90 { return "Excellent" }
            if overallScore >= 70 { return "Good" }
            if overallScore >= 50 { return "Fair" }
            return "Poor"
        }
    }

    var qualityColor: String {
        switch metric {
        case .vmaf:
            if overallScore >= 80 { return "green" }
            if overallScore >= 60 { return "yellow" }
            return "red"
        case .psnr:
            if overallScore >= 30 { return "green" }
            if overallScore >= 20 { return "yellow" }
            return "red"
        case .xpsnr:
            if overallScore >= 32 { return "green" }
            if overallScore >= 22 { return "yellow" }
            return "red"
        case .ssimulacra2:
            if overallScore >= 70 { return "green" }
            if overallScore >= 50 { return "yellow" }
            return "red"
        }
    }
}

/// Complete analytics results for one video item
struct AnalyticsResults: Codable, Equatable, Sendable {
    let sourceFileName: String
    let encodedFileName: String
    let metrics: [MetricResult]
    let timestamp: Date
    let durationSeconds: Double

    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}

/// VMAF model variants
enum VMAFModel: String, CaseIterable, Codable, Sendable {
    case vmaf_v0_6_1 = "vmaf_v0.6.1"
    case vmaf_v0_6_1neg = "vmaf_v0.6.1neg"
    case vmaf_4k_v0_6_1 = "vmaf_4k_v0.6.1"

    var displayName: String {
        switch self {
        case .vmaf_v0_6_1: return "VMAF v0.6.1 (Default)"
        case .vmaf_v0_6_1neg: return "VMAF v0.6.1neg (No Enhancement Gain)"
        case .vmaf_4k_v0_6_1: return "VMAF 4K v0.6.1 (4K content)"
        }
    }

    var description: String {
        switch self {
        case .vmaf_v0_6_1:
            return "Standard VMAF model. Recommended for most content."
        case .vmaf_v0_6_1neg:
            return "Penalizes enhancement artifacts. Use when encoder may sharpen or upscale."
        case .vmaf_4k_v0_6_1:
            return "Optimized for 4K/UHD content. Use for high-resolution videos."
        }
    }
}

/// Export format for analytics results
enum AnalyticsExportFormat: String, CaseIterable, Codable, Sendable {
    case json
    case pdf

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String {
        rawValue
    }
}

/// Errors for analytics operations
enum AnalyticsError: Error, LocalizedError {
    case ffmpegNotFound
    case sourceFileNotFound
    case encodedFileNotFound
    case metricFailed(QualityMetric, String)
    case parsingFailed(String)
    case ssimulacra2NotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg binary not found."
        case .ssimulacra2NotFound:
            return "ssimulacra2_rs binary not found. Install Rust (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh), then run: cargo install ssimulacra2_rs --no-default-features"
        case .sourceFileNotFound:
            return "Source file not found."
        case .encodedFileNotFound:
            return "Encoded output file not found."
        case .metricFailed(let metric, let reason):
            return "\(metric.displayName) failed: \(reason)"
        case .parsingFailed(let reason):
            return "Failed to parse results: \(reason)"
        case .cancelled:
            return "Analysis was cancelled."
        }
    }
}
