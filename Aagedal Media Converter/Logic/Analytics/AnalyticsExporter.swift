// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI
import OSLog
import CoreText

/// Exports analytics results to JSON or PDF
enum AnalyticsExporter {

    /// Portable whole-program results retain all readings, independently of chart decimation.
    private struct LoudnessReport: Encodable {
        let schemaVersion = 1
        let analysis = "whole_program_loudness"
        let sourceFileName: String
        let timestamp: Date
        let semantics = Semantics()
        let results: [Measurement]

        struct Semantics: Encodable {
            let scope = "complete_selected_file_independent_of_volume_mute_and_conversion_trims"
            let trackIndexing = "zero_based_audio_relative_matching_0:a:index"
            let timeline = "seconds_relative_to_selected_audio_presentation_start"
            let integrated = "gated_whole_program_LUFS_not_average_of_timeline_readings"
            let belowGate = "integrated_LUFS_at_or_below_minus70_means_below_gate"
            let loudnessRange = "LU_not_considered_stable_for_programs_shorter_than_one_minute"
            let maximumTruePeak = "dBTP_across_all_selected_channels_null_when_unavailable"
            let truePeakMethod = "FFmpeg_ebur128_separate_branch_100_ms_zero_context_at_both_edges_no_certification"
            let windowing = "100_ms_readings_momentary_400_ms_short_term_3_s"
            let levels = "unweighted_sample_peak_and_RMS_dBFS_across_selected_channels_per_window"
            let unavailableReading = "null_means_below_gate_silence_or_incomplete_window_not_zero"
            let samples = "full_resolution_measurements_without_chart_decimation"
        }

        struct Measurement: Encodable {
            let presentation: Presentation
            let integratedLUFS: Double
            let loudnessRangeLU: Double
            let maximumTruePeakDBTP: Double?
            let samples: [Sample]

            init(_ result: LoudnessResults) {
                presentation = Presentation(result.presentation)
                integratedLUFS = result.integratedLUFS
                loudnessRangeLU = result.loudnessRangeLU
                maximumTruePeakDBTP = result.maximumTruePeakDBTP
                samples = result.samples.map(Sample.init)
            }

            enum CodingKeys: String, CodingKey { case presentation, integratedLUFS, loudnessRangeLU, maximumTruePeakDBTP, samples }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(presentation, forKey: .presentation)
                try values.encode(integratedLUFS, forKey: .integratedLUFS)
                try values.encode(loudnessRangeLU, forKey: .loudnessRangeLU)
                try values.encode(maximumTruePeakDBTP, forKey: .maximumTruePeakDBTP)
                try values.encode(samples, forKey: .samples)
            }
        }

        struct Presentation: Encodable {
            let type: String
            let audioRelativeTrackIndices: [Int]
            let channelOrder: [String]

            init(_ presentation: LoudnessPresentation) {
                audioRelativeTrackIndices = presentation.streamIndices
                switch presentation {
                case .track:
                    type = "track"
                    channelOrder = ["all_source_track_channels_in_decoded_order"]
                case .stereo:
                    type = "stereo"
                    channelOrder = ["FL", "FR"]
                case .surround51:
                    type = "surround51"
                    channelOrder = ["FL", "FR", "FC", "LFE", "SL", "SR"]
                }
            }
        }

        struct Sample: Encodable {
            let sample: LoudnessSample
            init(_ sample: LoudnessSample) { self.sample = sample }
            enum CodingKeys: String, CodingKey { case seconds, momentaryLUFS, shortTermLUFS, peakDBFS, rmsDBFS }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(sample.seconds, forKey: .seconds)
                try values.encode(sample.momentaryLUFS, forKey: .momentaryLUFS)
                try values.encode(sample.shortTermLUFS, forKey: .shortTermLUFS)
                try values.encode(sample.peakDBFS, forKey: .peakDBFS)
                try values.encode(sample.rmsDBFS, forKey: .rmsDBFS)
            }
        }
    }

    static func loudnessJSON(results: [LoudnessResults], sourceFile: URL, timestamp: Date) throws -> Data {
        func invalid() -> EncodingError {
            .invalidValue(results, .init(codingPath: [], debugDescription: "Invalid loudness report."))
        }
        guard !results.isEmpty, timestamp.timeIntervalSince1970.isFinite,
              Set(results.map(\.presentation.id)).count == results.count else { throw invalid() }
        for result in results {
            let indices = result.presentation.streamIndices
            let validLayout: Bool
            if case .surround51 = result.presentation { validLayout = indices.count == 6 }
            else { validLayout = true }
            guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count,
                  validLayout, result.integratedLUFS.isFinite,
                  result.loudnessRangeLU.isFinite, result.loudnessRangeLU >= 0,
                  result.maximumTruePeakDBTP.map(\.isFinite) ?? true else { throw invalid() }
            var previousTime: Double?
            for sample in result.samples {
                guard sample.seconds.isFinite, sample.seconds >= 0,
                      previousTime.map({ sample.seconds > $0 }) ?? true,
                      [sample.momentaryLUFS, sample.shortTermLUFS, sample.peakDBFS, sample.rmsDBFS]
                        .allSatisfy({ $0.map(\.isFinite) ?? true }) else { throw invalid() }
                previousTime = sample.seconds
            }
        }
        let report = LoudnessReport(sourceFileName: sourceFile.lastPathComponent, timestamp: timestamp,
                                    results: results.map(LoudnessReport.Measurement.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func exportLoudnessJSON(results: [LoudnessResults], sourceFile: URL, timestamp: Date, to url: URL) throws {
        try loudnessJSON(results: results, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    private struct AudioPhaseReport: Encodable {
        let schemaVersion = 1
        let analysis = "source_stereo_phase_analysis"
        let sourceFileName: String
        let timestamp: Date
        let presentation: Presentation
        let semantics = Semantics()
        let result: AudioPhaseAnalysisResult

        struct Presentation: Encodable {
            let type: String
            let audioRelativeTrackIndices: [Int]
            let channelOrder = ["L", "R"]
        }
        struct Semantics: Encodable {
            let scope = "complete_source_presentation_independent_of_volume_mute_and_conversion_trims"
            let timeUnit = "seconds"
            let timeline = "file_relative_including_initial_audio_offset"
            let duration = "end_of_decoded_audio_on_file_timeline"
            let trackIndexing = "zero_based_audio_relative_matching_0:a:index"
            let correlation = "uncentered_sum_LR_divided_by_sqrt_sum_L2_sum_R2_no_DC_removal"
            let unavailableCorrelation = "null_when_either_channel_has_zero_energy"
            let monoFoldDown = "M=(L+R)/2"
            let monoFoldDownDeltaDB = "10_log10_sum_M2_divided_by_mean_sum_L2_sum_R2"
            let unavailableMonoFoldDown = "null_when_both_channels_are_silent"
            let negativeInfinity = "-Infinity_means_exact_mono_cancellation_of_non_silent_channels"
            let midSide = "mid=(L+R)/2_side=(L-R)/2"
            let rmsUnit = "linear_full_scale"
            let weighting = "unweighted_source_samples_not_LUFS_or_frequency_dependent_phase"
            let windowing = "4800_native_sample_frames_unpadded_final_window"
            let sourceTimestampTolerance = "1_ms_container_rounding_before_reframing"
            let totals = "sample_energy_sums_not_average_window_correlations"
            let phaseDisplay = "33_by_33_row_major_y_mid_x_side_nearest_bins_fixed_minus1_plus1_clamped_no_gain_normalization"
        }
    }

    static func audioPhaseJSON(result: AudioPhaseAnalysisResult, sourceFile: URL, timestamp: Date) throws -> Data {
        func invalid() -> EncodingError {
            .invalidValue(result, .init(codingPath: [], debugDescription: "Invalid stereo phase report."))
        }
        let indices = result.presentation.streamIndices
        let type: String
        switch result.presentation {
        case .track: type = "track"
        case .stereo: type = "stereo"
        case .surround51: throw invalid()
        }
        guard indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count,
              timestamp.timeIntervalSince1970.isFinite, result.sampleRate > 0,
              result.windowSourceSamples == 4_800, !result.windows.isEmpty,
              result.windows.count <= 100_000 else { throw invalid() }
        func valid(_ m: AudioPhaseMeasurement) -> Bool {
            let energy = [m.leftEnergy, m.rightEnergy, m.midEnergy, m.sideEnergy]
            guard m.sampleCount > 0, energy.allSatisfy({ $0.isFinite && $0 >= 0 }), m.crossProduct.isFinite else { return false }
            let total = m.leftEnergy + m.rightEnergy
            guard total.isFinite, abs(2 * (m.midEnergy + m.sideEnergy) - total) <= max(1e-12, total * 1e-9),
                  abs((m.midEnergy - m.sideEnergy) - m.crossProduct) <= max(1e-12, total * 1e-9),
                  abs(m.crossProduct) <= sqrt(m.leftEnergy) * sqrt(m.rightEnergy) + max(1e-12, total * 1e-9) else { return false }
            return true
        }
        var previousEnd: Double?
        var count: Int64 = 0
        var sums = [Double](repeating: 0, count: 5)
        for (index, window) in result.windows.enumerated() {
            let m = window.measurement
            guard valid(m), m.sampleCount <= 4_800,
                  index == result.windows.count - 1 || m.sampleCount == 4_800,
                  window.start.isFinite, window.start >= 0, window.end.isFinite, window.end > window.start,
                  abs((window.end - window.start) * Double(result.sampleRate) - Double(m.sampleCount)) < 0.001,
                  previousEnd.map({ abs(window.start - $0) * Double(result.sampleRate) < 0.001 }) ?? true else { throw invalid() }
            previousEnd = window.end
            count += m.sampleCount
            for (offset, value) in [m.leftEnergy, m.rightEnergy, m.midEnergy, m.sideEnergy, m.crossProduct].enumerated() {
                sums[offset] += value
            }
        }
        guard valid(result.totals), result.totals.sampleCount == count else { throw invalid() }
        for (sum, value) in zip(sums, [result.totals.leftEnergy, result.totals.rightEnergy, result.totals.midEnergy,
                                       result.totals.sideEnergy, result.totals.crossProduct]) {
            guard abs(sum - value) <= max(1e-12, abs(sum) * 1e-9) else { throw invalid() }
        }
        guard result.scope.dimension == 33, result.scope.bins.count == 1089,
              result.scope.clippedSampleCount >= 0, result.scope.clippedSampleCount <= count else { throw invalid() }
        var remaining = count
        for bin in result.scope.bins {
            guard bin >= 0, bin <= remaining else { throw invalid() }
            remaining -= bin
        }
        guard remaining == 0 else { throw invalid() }
        let report = AudioPhaseReport(sourceFileName: sourceFile.lastPathComponent, timestamp: timestamp,
                                      presentation: .init(type: type, audioRelativeTrackIndices: indices), result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(report)
    }

    static func exportAudioPhaseJSON(result: AudioPhaseAnalysisResult, sourceFile: URL,
                                     timestamp: Date, to url: URL) throws {
        try audioPhaseJSON(result: result, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    /// Sample-only reports retain versions 1/2; estimated true peaks use version 3.
    /// The explicit context is independent of Swift's enum encoding and UI language.
    private struct AudioPeakReport: Encodable {
        let schemaVersion: Int
        let analysis = "source_sample_peaks_and_channel_balance"
        let sourceFileName: String
        let audioRelativeTrackIndex: Int?
        let timestamp: Date
        let presentation: PresentationContext?
        let semantics: Semantics
        let result: Measurements

        struct Measurements: Encodable {
            let settings: AudioPeakSettings
            let intervals: [AudioPeakInterval]
            let channels: [AudioChannelLevel]
            let duration: Double
            let imbalanceDB: Double?
            let truePeaks: AudioTruePeakResult?

            init(_ result: AudioPeakAnalysisResult) {
                settings = result.settings
                intervals = result.intervals
                channels = result.channels
                duration = result.duration
                imbalanceDB = result.imbalanceDB
                truePeaks = result.truePeaks
            }
        }

        struct PresentationContext: Encodable {
            let type: String
            let audioRelativeTrackIndices: [Int]
            let channelLayout: String
            let channelOrder: [String]

            init(_ presentation: LoudnessPresentation) {
                audioRelativeTrackIndices = presentation.streamIndices
                switch presentation {
                case .track:
                    type = "track"
                    channelLayout = "source_track_layout"
                    channelOrder = ["all_source_track_channels_in_decoded_order"]
                case .stereo:
                    type = "stereo"
                    channelLayout = "stereo"
                    channelOrder = ["FL", "FR"]
                case .surround51:
                    type = "surround51"
                    channelLayout = "5.1(side)"
                    channelOrder = ["FL", "FR", "FC", "LFE", "SL", "SR"]
                }
            }
        }

        struct Semantics: Encodable {
            let channelNumbering: String
            let trackIndexing = "zero_based_audio_relative_matching_0:a:index"
            let timeUnit = "seconds"
            let timeline = "file_relative_including_initial_audio_offset"
            let duration = "end_of_decoded_audio_on_file_timeline"
            let peakUnit = "dBFS"
            let peakMeasurement = "source_sample_peak_not_intersample_true_peak"
            let windowSamples = 4_800
            let intervalBoundaries = "analysis_windows_merged_per_channel_when_adjacent"
            let thresholdComparison = "greater_than_or_equal"
            let rmsMeasurement: String
            let imbalanceUnit = "dB"
            let imbalanceMeasurement = "maximum_minus_minimum_channel_rms"
            let unavailableImbalance = "omitted_for_mono_or_entirely_silent_audio"
            let negativeInfinity = "-Infinity_means_digital_silence"
            let positiveInfinity = "Infinity_means_silent_and_active_channels"
            let scope: String
            let truePeakUnit: String?
            let truePeakMeasurement: String?

            init(grouped: Bool, truePeaks: Bool) {
                truePeakUnit = truePeaks ? "dBTP" : nil
                truePeakMeasurement = truePeaks ? "estimated_continuous_4x_interpolation_zero_extended_edges_not_certified_BS1770" : nil
                channelNumbering = grouped ? "one_based_presentation_channel_order" : "one_based_decoded_order"
                rmsMeasurement = grouped ? "unweighted_whole_presentation_sample_weighted_energy" : "unweighted_whole_track_sample_weighted_energy"
                scope = grouped ? "complete_selected_source_presentation_independent_of_volume_mute_and_conversion_trims" : "complete_selected_source_track_independent_of_volume_mute_and_conversion_trims"
            }
        }
    }

    /// Production exports use the presentation captured by the completed analysis.
    static func audioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL, timestamp: Date) throws -> Data {
        guard let presentation = result.presentation else {
            throw invalidAudioPeakReport(result)
        }
        return try encodeAudioPeakJSON(result: result, sourceFile: sourceFile,
                                       presentation: presentation, timestamp: timestamp)
    }

    /// Compatibility for legacy results without captured presentation. A caller may
    /// never relabel a captured result with a different track or flatten a group.
    static func audioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                              trackIndex: Int, timestamp: Date) throws -> Data {
        if let presentation = result.presentation, presentation != .track(trackIndex) {
            throw invalidAudioPeakReport(result)
        }
        return try encodeAudioPeakJSON(result: result, sourceFile: sourceFile,
                                       presentation: .track(trackIndex), timestamp: timestamp)
    }

    private static func invalidAudioPeakReport(_ result: AudioPeakAnalysisResult) -> EncodingError {
        .invalidValue(result, .init(codingPath: [], debugDescription: "Invalid audio peak report or presentation."))
    }

    private static func encodeAudioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                                            presentation: LoudnessPresentation, timestamp: Date) throws -> Data {
        try result.settings.validate()
        let indices = presentation.streamIndices
        let channelIDs = result.channels.map(\.channel)
        let expectedChannelIDs = Array(1...max(1, result.channels.count))
        let grouped: Bool
        let trackIndex: Int?
        let validChannelCount: Bool
        switch presentation {
        case .track(let index):
            grouped = false
            trackIndex = index
            validChannelCount = !result.channels.isEmpty
        case .stereo:
            grouped = true
            trackIndex = nil
            validChannelCount = result.channels.count == 2
        case .surround51:
            grouped = true
            trackIndex = nil
            validChannelCount = indices.count == 6 && result.channels.count == 6
        }
        guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count,
              validChannelCount, channelIDs == expectedChannelIDs,
              timestamp.timeIntervalSince1970.isFinite,
              result.duration.isFinite, result.duration > 0,
              result.channels.allSatisfy({
                  ($0.peakDBFS.isFinite || $0.peakDBFS == -.infinity) &&
                  ($0.rmsDBFS.isFinite || $0.rmsDBFS == -.infinity)
              }),
              result.intervals.allSatisfy({
                  channelIDs.contains($0.channel) &&
                  $0.start.isFinite && $0.end.isFinite && $0.peakDBFS.isFinite &&
                  $0.start >= 0 && $0.end > $0.start && $0.end <= result.duration
              }),
              result.imbalanceDB.map({ ($0.isFinite && $0 >= 0) || $0 == .infinity }) ?? true else {
            throw invalidAudioPeakReport(result)
        }
        if let truePeaks = result.truePeaks {
            guard truePeaks.thresholdDBTP == result.settings.truePeakThresholdDBTP,
                  (1...192_000).contains(truePeaks.sourceSampleRate),
                  truePeaks.measurementSampleRate == truePeaks.sourceSampleRate * 4,
                  truePeaks.windowSourceSamples == 4_800,
                  truePeaks.method == "estimated_4x_libswresample_swr_filter64_cutoff0.97_no_certification",
                  truePeaks.channels.map(\.channel) == channelIDs,
                  truePeaks.channels.allSatisfy({ $0.peakDBTP.isFinite || $0.peakDBTP == -.infinity }),
                  truePeaks.intervals.allSatisfy({
                      channelIDs.contains($0.channel) && $0.start.isFinite && $0.end.isFinite && $0.peakDBTP.isFinite &&
                      $0.peakDBTP >= truePeaks.thresholdDBTP && $0.start >= 0 && $0.end > $0.start && $0.end <= result.duration
                  }) else { throw invalidAudioPeakReport(result) }
        } else if result.settings.truePeakThresholdDBTP != nil {
            throw invalidAudioPeakReport(result)
        }
        let report = AudioPeakReport(schemaVersion: result.truePeaks != nil ? 3 : (grouped ? 2 : 1), sourceFileName: sourceFile.lastPathComponent,
                                     audioRelativeTrackIndex: trackIndex, timestamp: timestamp,
                                     presentation: result.presentation.map(AudioPeakReport.PresentationContext.init),
                                     semantics: .init(grouped: grouped, truePeaks: result.truePeaks != nil), result: .init(result))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // JSON has no infinity literal. Preserve silence and infinite channel
        // difference explicitly rather than conflating either with missing data.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(report)
    }

    static func exportAudioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                                    timestamp: Date, to url: URL) throws {
        try audioPeakJSON(result: result, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    static func exportAudioPeakJSON(result: AudioPeakAnalysisResult, sourceFile: URL,
                                    trackIndex: Int, timestamp: Date, to url: URL) throws {
        try audioPeakJSON(result: result, sourceFile: sourceFile, trackIndex: trackIndex,
                          timestamp: timestamp).write(to: url, options: .atomic)
    }

    /// Complete source silence report, independent of UI presentation.
    private struct SilenceReport: Encodable {
        let schemaVersion = 1
        let analysis = "source_sample_silence"
        let sourceFileName: String
        let timestamp: Date
        let presentation: PresentationContext
        let semantics = Semantics()
        let result: SilenceAnalysisResult

        struct PresentationContext: Encodable {
            let type: String
            let audioRelativeTrackIndices: [Int]
            let channelLayout: String
            let channelOrder: [String]

            init(_ presentation: LoudnessPresentation) {
                audioRelativeTrackIndices = presentation.streamIndices
                switch presentation {
                case .track:
                    type = "track"
                    channelLayout = "source_track_layout"
                    channelOrder = ["all_source_track_channels_in_decoded_order"]
                case .stereo:
                    type = "stereo"
                    channelLayout = "stereo"
                    channelOrder = ["FL", "FR"]
                case .surround51:
                    type = "surround51"
                    channelLayout = "5.1(side)"
                    channelOrder = ["FL", "FR", "FC", "LFE", "SL", "SR"]
                }
            }
        }

        struct Semantics: Encodable {
            let trackIndexing = "zero_based_audio_relative_matching_0:a:index"
            let timeUnit = "seconds"
            let timeline = "file_relative_including_initial_audio_offset"
            let thresholdUnit = "dBFS"
            let measurement = "absolute_decoded_source_sample_amplitude_not_rms_loudness_or_true_peak"
            let thresholdComparison = "strictly_less_than"
            let channelAggregation = "all_selected_channels_below_threshold_together"
            let minimumDuration = "continuous_silence_required_before_reporting_interval"
            let intervalBoundaries = "detected_silence_start_and_end_including_filter_reported_end_of_audio"
            let intervalDuration = "end_minus_start_seconds"
            let absentAudio = "initial_audio_offset_is_not_synthesized_silence"
            let emptyIntervals = "complete_analysis_found_no_qualifying_silence"
            let scope = "complete_selected_source_presentation_independent_of_volume_mute_and_conversion_trims"
        }
    }

    static func silenceJSON(result: SilenceAnalysisResult, sourceFile: URL, timestamp: Date) throws -> Data {
        try result.settings.validate()
        let indices = result.presentation.streamIndices
        var previousEnd = 0.0
        let validIntervals = result.intervals.allSatisfy { interval in
            defer { previousEnd = interval.end }
            return interval.start.isFinite && interval.end.isFinite && interval.duration.isFinite &&
                interval.start >= previousEnd && interval.end > interval.start
        }
        let validLayout: Bool
        if case .surround51 = result.presentation { validLayout = indices.count == 6 }
        else { validLayout = true }
        guard timestamp.timeIntervalSince1970.isFinite,
              !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count,
              validLayout, validIntervals else {
            throw EncodingError.invalidValue(result, .init(codingPath: [], debugDescription: "Invalid silence report."))
        }
        let report = SilenceReport(sourceFileName: sourceFile.lastPathComponent, timestamp: timestamp,
                                   presentation: .init(result.presentation), result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func exportSilenceJSON(result: SilenceAnalysisResult, sourceFile: URL,
                                  timestamp: Date, to url: URL) throws {
        try silenceJSON(result: result, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AnalyticsExporter")

    /// Automatically exports analytics results next to the encoded file if auto-export is enabled in settings
    @MainActor
    static func autoExportIfEnabled(
        results: AnalyticsResults,
        encodedFileURL: URL,
        settings: AnalyticsAutoExportSettingsSnapshot
    ) {
        guard settings.enabled else { return }
        do {
            let exportURL = try autoExport(results: results, encodedFileURL: encodedFileURL, format: settings.format)
            logger.info("Auto-exported analytics to \(exportURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Auto-export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exclusive creation also protects against another app process exporting concurrently.
    @MainActor
    static func autoExport(results: AnalyticsResults, encodedFileURL: URL, format: AnalyticsExportFormat) throws -> URL {
        let data: Data
        switch format {
        case .json:
            guard let json = results.toJSON() else {
                throw AnalyticsError.parsingFailed("Failed to encode results to JSON")
            }
            data = json
        case .pdf:
            data = try pdfData(results: results)
        }
        let baseName = encodedFileURL.deletingPathExtension().lastPathComponent + "_analytics"
        let folder = encodedFileURL.deletingLastPathComponent()
        var suffix = 0
        while true {
            let name = suffix == 0 ? baseName : "\(baseName)_\(suffix)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    /// Exports results to a pretty-printed JSON file
    static func exportJSON(results: AnalyticsResults, to url: URL) throws {
        guard let data = results.toJSON() else {
            throw AnalyticsError.parsingFailed("Failed to encode results to JSON")
        }
        try data.write(to: url, options: .atomic)
    }

    /// Exports results to a PDF report
    @MainActor
    static func exportPDF(results: AnalyticsResults, to url: URL) throws {
        try pdfData(results: results).write(to: url, options: .atomic)
    }

    @MainActor
    private static func pdfData(results: AnalyticsResults) throws -> Data {
        try QualityPDFRenderer(results: results).render()
    }

    /// Render the same summary and timelines as the analysis sheet on an A4 page.
    @MainActor
    static func exportLoudnessPDF(results: LoudnessResults, fileName: String, to url: URL) throws {
        try exportLoudnessPDF(results: [results], fileName: fileName, to: url)
    }

    /// Each independently measured presentation receives its own complete A4 page.
    @MainActor
    static func exportLoudnessPDF(results: [LoudnessResults], fileName: String, timestamp: Date = Date(), to url: URL) throws {
        guard !results.isEmpty else {
            throw AnalyticsError.parsingFailed("No loudness reports to export")
        }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AnalyticsError.parsingFailed("Could not create the loudness PDF report")
        }
        for result in results {
            let report = LoudnessPDFReportView(results: result, fileName: fileName, timestamp: timestamp)
                .frame(width: 595, height: 842)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: report)
            renderer.proposedSize = ProposedViewSize(width: 595, height: 842)
            var succeeded = false
            renderer.render { _, render in
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
                succeeded = true
            }
            guard succeeded else {
                context.closePDF()
                throw AnalyticsError.parsingFailed("Could not render the loudness PDF report")
            }
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

}

private struct LoudnessPDFReportView: View {
    let results: LoudnessResults
    let fileName: String
    let timestamp: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Loudness Analysis").font(.title.bold())
            VStack(alignment: .leading, spacing: 5) {
                Text(fileName).font(.headline).lineLimit(2)
                Text("Audio presentation: \(results.presentation.displayName)")
                Text("Complete file • \(timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Divider()
            LoudnessSummaryView(results: results)
            LoudnessTimelineView(results: results, chartHeight: 180)
            Text("Integrated loudness is the gated whole-program measurement, not an average of graph readings. Below gate indicates no loudness above -70 LUFS. Maximum true peak is measured across the selected channels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if (results.samples.last?.seconds ?? 0) < 60 {
                Text("Loudness range is not considered stable for programs shorter than one minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Generated by Aagedal Media Converter").font(.caption).foregroundStyle(.secondary)
        }
        .padding(36)
    }
}

// MARK: - Paginated video quality report

/// Text is laid out using Core Text's visible ranges, so long filenames, method
/// descriptions and warnings continue on A4 pages instead of shrinking or clipping.
/// Charts are vector paths; full-resolution samples remain in the JSON report.
@MainActor
private final class QualityPDFRenderer {
    private let results: AnalyticsResults
    private let width: CGFloat = 595
    private let height: CGFloat = 842
    private let margin: CGFloat = 38
    private let bottom: CGFloat = 792
    private var context: CGContext!
    private var cursor: CGFloat = 66
    private var page = 0

    init(results: AnalyticsResults) { self.results = results }

    func render() throws -> Data {
        guard !results.metrics.isEmpty else { throw AnalyticsError.parsingFailed("No quality reports to export") }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw AnalyticsError.parsingFailed("Could not create the quality PDF report")
        }
        context = pdf
        var closed = false
        defer { if !closed { context.closePDF() } }
        for metric in results.metrics {
            newPage()
            try text(metric.metric.displayName, size: 24, bold: true, spacing: 12)
            try text(String(localized: "Source File:") + " " + results.sourceFileName)
            try text(String(localized: "Encoded File:") + " " + results.encodedFileName)
            try text(String(localized: "Date:") + " " + results.timestamp.formatted(date: .abbreviated, time: .shortened), color: .secondaryLabelColor, spacing: 14)
            try text(String(localized: "Overall Score") + ": " + metric.formattedScore + "   ·   " + Bundle.main.localizedString(forKey: metric.qualityRating, value: nil, table: nil),
                     size: 16, bold: true, spacing: 10)
            if let channels = metric.channelScores, !channels.isEmpty {
                try text(channels.sorted { $0.key < $1.key }.map { "\($0.key): \(score($0.value)) \(metric.unit)" }.joined(separator: "    "))
            }
            if metric.scoreAggregation == "minimum_channel_average", let channels = metric.channelScores {
                try text("XPSNR = min(" + channels.keys.sorted().joined(separator: ", ") + ")", color: .secondaryLabelColor)
            }
            if let minimum = metric.min { try text(String(localized: "Min") + ": " + score(minimum) + " " + metric.unit) }
            if let maximum = metric.max { try text(String(localized: "Max") + ": " + score(maximum) + " " + metric.unit) }
            if let comparison = metric.comparison {
                try text(comparison.summary, size: 10, color: .secondaryLabelColor, spacing: 8)
                for warning in comparison.warnings { try text(warning, size: 10, color: .systemBrown, spacing: 6) }
            }
            let timeline = QualityTimeline(result: metric, fallbackDuration: results.durationSeconds)
            if timeline.samples.isEmpty {
                try text(String(localized: "No timeline data"), size: 14, bold: true, spacing: 8)
                try text(String(localized: "Run this metric again to collect timestamped quality scores."))
            } else {
                ensureSpace(220)
                try text(String(localized: "Quality timeline"), size: 14, bold: true, spacing: 8)
                chart(timeline)
                try text("P05: " + (timeline.fifthPercentile.map(score) ?? "—") + "    n = \(timeline.samples.count)", size: 10)
                try text(String(localized: "Encoded time (seconds)"), size: 10, color: .secondaryLabelColor, spacing: 10)
                try text(metric.metric == .ssimulacra2
                    ? String(localized: "Sampled frames only. Quality between these points was not measured.")
                    : String(localized: "Per-frame measurements. The graph preserves brief lows and highs when reducing detail."), size: 10, color: .secondaryLabelColor)
                if timeline.graphSamples.contains(where: { $0.score == .infinity }) {
                    try text(String(localized: "∞ (perfect match) is drawn at the chart ceiling."), size: 10, color: .secondaryLabelColor)
                }
                ensureSpace(46)
                try text(String(localized: "Lowest measured sections"), size: 14, bold: true, spacing: 8)
                if timeline.worstSamples.isEmpty {
                    try text(String(localized: "All measured frames have infinite (perfect-match) scores."), size: 10)
                } else {
                    for sample in timeline.worstSamples {
                        try text(String(format: "%.3f s    ", sample.seconds) + score(sample.score) + " " + metric.unit, size: 11, spacing: 5)
                    }
                }
            }
        }
        context.endPDFPage()
        // Flush the PDF trailer before copying NSMutableData into a value.
        context.closePDF()
        closed = true
        return data as Data
    }

    private func newPage() {
        if page > 0 { context.endPDFPage() }
        context.beginPDFPage(nil)
        page += 1
        cursor = 66
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        line(String(localized: "Quality Analytics Report"), at: CGPoint(x: margin, y: height - 39), size: 11, bold: true)
        line(String(localized: "Generated by Aagedal Media Converter"), at: CGPoint(x: margin, y: 26), size: 8)
        line(String(page), at: CGPoint(x: width - margin - 20, y: 26), size: 8)
    }

    private func ensureSpace(_ amount: CGFloat) {
        if cursor + amount > bottom { newPage() }
    }

    private func attributes(size: CGFloat, bold: Bool, color: NSColor) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        // Resolve adaptive colors against a light appearance for a printable PDF.
        var resolved = NSColor.black.cgColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font.fontName as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolved]
    }

    private func line(_ string: String, at position: CGPoint, size: CGFloat, bold: Bool = false) {
        let value = NSAttributedString(string: string, attributes: attributes(size: size, bold: bold, color: .labelColor))
        context.textPosition = position
        CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), context)
    }

    private func text(_ string: String, size: CGFloat = 11, bold: Bool = false,
                      color: NSColor = .labelColor, spacing: CGFloat = 5) throws {
        var remaining = NSAttributedString(string: string, attributes: attributes(size: size, bold: bold, color: color))
        while remaining.length > 0 {
            ensureSpace(size * 2)
            let framesetter = CTFramesetterCreateWithAttributedString(remaining as CFAttributedString)
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: width - 2 * margin, height: .greatestFiniteMagnitude), nil)
            let available = bottom - cursor
            let blockHeight = min(ceil(needed.height) + 3, available)
            let path = CGPath(rect: CGRect(x: margin, y: height - cursor - blockHeight, width: width - 2 * margin, height: blockHeight), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw AnalyticsError.parsingFailed("Could not lay out the quality PDF report") }
            CTFrameDraw(frame, context)
            cursor += blockHeight + spacing
            remaining = remaining.attributedSubstring(from: NSRange(location: visible.length, length: remaining.length - visible.length))
            if remaining.length > 0 { newPage() }
        }
    }

    private func score(_ value: Double) -> String {
        value == .infinity ? "∞" : String(format: "%.2f", value)
    }

    private func chart(_ timeline: QualityTimeline) {
        let finite = timeline.graphSamples.map(\.score).filter(\.isFinite)
        let db = timeline.metric == .psnr || timeline.metric == .xpsnr
        let low = min(0, (finite.min() ?? 0) - 2)
        let high = max(db ? 50 : 100, (finite.max() ?? 0) + 2)
        let plot = CGRect(x: margin + 38, y: height - cursor - 138, width: width - 2 * margin - 46, height: 124)
        context.saveGState()
        for tick in 0...4 {
            let fraction = Double(tick) / 4
            let y = plot.minY + plot.height * fraction
            context.setStrokeColor(NSColor(calibratedWhite: 0.88, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.strokePath()
            line(String(format: "%.0f", low + (high - low) * fraction), at: CGPoint(x: margin, y: y - 3), size: 8)
            line(String(format: "%.2f", timeline.duration * fraction), at: CGPoint(x: plot.minX + plot.width * fraction - 7, y: plot.minY - 16), size: 8)
        }
        line(db ? "dB" : String(localized: "Score"), at: CGPoint(x: margin, y: plot.maxY + 5), size: 8)
        func point(_ sample: QualitySample) -> CGPoint {
            let value = sample.score.isFinite ? sample.score : high
            return CGPoint(x: plot.minX + plot.width * min(1, max(0, sample.seconds / timeline.duration)),
                           y: plot.minY + plot.height * min(1, max(0, (value - low) / (high - low))))
        }
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.1)
        for (index, sample) in timeline.graphSamples.enumerated() {
            let p = point(sample)
            if timeline.metric == .ssimulacra2 || timeline.graphSamples.count == 1 {
                context.fillEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            } else if index == 0 { context.move(to: p) }
            else { context.addLine(to: p) }
        }
        context.strokePath()
        if let percentile = timeline.fifthPercentile, percentile.isFinite {
            let y = point(QualitySample(frame: 0, seconds: 0, score: percentile)).y
            context.setStrokeColor(NSColor.systemOrange.cgColor)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.strokePath()
        }
        context.restoreGState()
        cursor += 165
    }
}
