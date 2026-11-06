// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// JSON reports and Resolve marker EDLs for black and scene cut detection.
extension AnalyticsExporter {
    private struct BlackReport: Encodable {
        let schemaVersion = 1
        let analysis = "source_video_black"
        let sourceFileName: String
        let timestamp: Date
        let semantics = Semantics()
        let result: BlackDetectionResult

        struct Semantics: Encodable {
            let detector = "ffmpeg_blackdetect"
            let videoStream = "first_video_stream_excluding_attached_pictures_matching_0:V:0"
            let timeUnit = "seconds"
            let timeline = "file_relative"
            let pictureBlackRatio = "pic_th_minimum_share_of_black_pixels_per_picture"
            let pixelThreshold = "pix_th_maximum_luma_as_fraction_of_range_for_a_black_pixel"
            let minimumDuration = "continuous_black_required_before_reporting_interval"
            let intervalBoundaries = "first_black_frame_to_first_following_non_black_frame_or_last_frame_at_end_of_stream"
            let intervalDuration = "end_minus_start_seconds"
            let emptyIntervals = "complete_analysis_found_no_qualifying_black"
            let scope = "complete_source_video_independent_of_conversion_trims"
        }
    }

    private struct SceneCutReport: Encodable {
        let schemaVersion = 1
        let analysis = "source_video_scene_cuts"
        let sourceFileName: String
        let timestamp: Date
        let semantics = Semantics()
        let result: SceneCutResult

        struct Semantics: Encodable {
            let detector = "ffmpeg_scdet"
            let videoStream = "first_video_stream_excluding_attached_pictures_matching_0:V:0"
            let timeUnit = "seconds"
            let timeline = "file_relative"
            let cutTime = "presentation_time_of_first_frame_after_cut"
            let score = "scdet_scene_change_score_0_to_100"
            let thresholdComparison = "greater_than_or_equal"
            let emptyCuts = "complete_analysis_found_no_qualifying_cuts"
            let scope = "complete_source_video_independent_of_conversion_trims"
        }
    }

    static func blackJSON(result: BlackDetectionResult, sourceFile: URL, timestamp: Date) throws -> Data {
        try result.settings.validate()
        var previousEnd = 0.0
        let validIntervals = result.intervals.allSatisfy { interval in
            defer { previousEnd = interval.end }
            return interval.start.isFinite && interval.end.isFinite && interval.duration.isFinite &&
                interval.start >= previousEnd && interval.end > interval.start
        }
        guard timestamp.timeIntervalSince1970.isFinite, validIntervals else {
            throw EncodingError.invalidValue(result, .init(codingPath: [], debugDescription: "Invalid black report."))
        }
        return try videoEventEncoder().encode(
            BlackReport(sourceFileName: sourceFile.lastPathComponent, timestamp: timestamp, result: result))
    }

    static func exportBlackJSON(result: BlackDetectionResult, sourceFile: URL, timestamp: Date, to url: URL) throws {
        try blackJSON(result: result, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    static func sceneCutJSON(result: SceneCutResult, sourceFile: URL, timestamp: Date) throws -> Data {
        try result.settings.validate()
        var previous = -1.0
        let validCuts = result.cuts.allSatisfy { cut in
            defer { previous = cut.time }
            return cut.time.isFinite && cut.score.isFinite && cut.time >= 0 && cut.time > previous &&
                cut.score >= 0 && cut.score <= 100
        }
        guard timestamp.timeIntervalSince1970.isFinite, validCuts else {
            throw EncodingError.invalidValue(result, .init(codingPath: [], debugDescription: "Invalid scene cut report."))
        }
        return try videoEventEncoder().encode(
            SceneCutReport(sourceFileName: sourceFile.lastPathComponent, timestamp: timestamp, result: result))
    }

    static func exportSceneCutJSON(result: SceneCutResult, sourceFile: URL, timestamp: Date, to url: URL) throws {
        try sceneCutJSON(result: result, sourceFile: sourceFile, timestamp: timestamp).write(to: url, options: .atomic)
    }

    private static func videoEventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Resolve marker EDL

    /// Point markers at each cut, numbered in cut order.
    static func sceneCutMarkers(_ result: SceneCutResult) -> [StitchCutMarker] {
        result.cuts.enumerated().map { index, cut in
            StitchCutMarker(title: "Cut \(index + 1) • score " + String(format: "%.1f", cut.score),
                            start: cut.time, end: cut.time)
        }
    }

    /// Duration markers spanning each black interval.
    static func blackMarkers(_ result: BlackDetectionResult) -> [StitchCutMarker] {
        result.intervals.enumerated().map { index, interval in
            StitchCutMarker(title: "Black \(index + 1) • " + String(format: "%.2f s", interval.duration),
                            start: interval.start, end: interval.end)
        }
    }

    /// Serializes with the stitching timeline's Resolve EDL writer. Markers on the
    /// same frame are combined, as Resolve keeps only one marker per frame.
    static func videoEventEDL(title: String, markers: [StitchCutMarker], frameRate: Double,
                              startTimecode: String?, ranges: Bool) throws -> String {
        let coalesced = try StitchMarkerExport.coalescedForEDL(markers, frameRate: frameRate)
        return try StitchMarkerExport.resolveEDL(title: title, markers: coalesced, frameRate: frameRate,
                                                 startTimecode: startTimecode, includeRanges: ranges)
    }

    /// Reads the source's frame rate and start timecode, then writes the EDL atomically.
    static func exportVideoEventEDL(markers: [StitchCutMarker], sourceFile: URL, title: String,
                                    ranges: Bool, to url: URL) async throws {
        let media = try await StitchMarkerMedia.read(sourceFile)
        guard let frameRate = media.frameRate else { throw StitchMarkerError.invalidRate }
        let text = try videoEventEDL(title: title, markers: markers, frameRate: frameRate,
                                     startTimecode: media.timecode, ranges: ranges)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
