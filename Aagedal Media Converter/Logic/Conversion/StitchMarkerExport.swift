// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

struct StitchCutMarker: Equatable, Sendable {
    let title: String
    let start: Double
    let end: Double
}

struct StitchMarkerMedia: Sendable {
    let duration: Double
    let frameRate: Double?
    let timecode: String?
    let chapters: [StitchCutMarker]
    var hasChapterMetadata: Bool = false

    static func read(_ url: URL) async throws -> Self {
        try await NonJoiningTaskDeadline.run(timeout: .seconds(15)) {
            let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
            defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
            let metadata = try await SwiftExifMediaProbe.readVideo(url)
            guard let duration = metadata.duration, duration.isFinite, duration > 0 else {
                throw StitchMarkerError.unavailableTiming
            }
            let primary = metadata.videoStreams.first { $0.isAttachedPic != true }
            let sorted = metadata.chapters.sorted { $0.startTime < $1.startTime }
            let chapters = sorted.enumerated().compactMap { index, chapter -> StitchCutMarker? in
                let end = chapter.endTime ?? (index + 1 < sorted.count ? sorted[index + 1].startTime : duration)
                guard chapter.startTime.isFinite, end.isFinite, end > chapter.startTime else { return nil }
                return StitchCutMarker(title: chapter.title ?? "Chapter \(index + 1)",
                                       start: chapter.startTime, end: end)
            }
            return Self(duration: duration,
                        frameRate: primary?.avgFrameRate ?? primary?.rFrameRate ?? primary?.frameRate,
                        timecode: metadata.timecode ?? primary?.timecode, chapters: chapters,
                        hasChapterMetadata: !metadata.chapters.isEmpty)
        }
    }
}

enum StitchMarkerError: LocalizedError {
    case unavailableTiming, invalidRate, tooManyMarkers, duplicateFrame, midnightWrap, sidecarCollision
    var errorDescription: String? {
        switch self {
        case .unavailableTiming: "Clip markers could not be exported because exact media timing was unavailable."
        case .invalidRate: "Resolve marker EDL requires a supported video frame rate of at most 60 fps and valid output timecode."
        case .tooManyMarkers: "Resolve marker EDL supports at most 999 markers. Embedded chapters are unaffected."
        case .duplicateFrame: "Two clip boundaries fall on the same frame. Resolve can discard duplicate markers, so the EDL was not exported."
        case .midnightWrap: "Clip markers reach the 24-hour timecode boundary and cannot be represented safely in Resolve marker EDL."
        case .sidecarCollision: "Could not find an unused filename for the marker EDL."
        }
    }
}

enum StitchMarkerExport {
    static let supportedChapterExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv"]

    static func cuts(names: [String], durations: [Double]) throws -> [StitchCutMarker] {
        guard names.count == durations.count, !names.isEmpty else { throw StitchMarkerError.unavailableTiming }
        var offset = 0.0
        return try zip(names, durations).map { name, duration in
            guard duration.isFinite, duration > 0, (offset + duration).isFinite else {
                throw StitchMarkerError.unavailableTiming
            }
            defer { offset += duration }
            return StitchCutMarker(title: name, start: offset, end: offset + duration)
        }
    }

    /// Used when a preparation pass omits chapters. Keep source titles and
    /// intersect chapter ranges with the retained source interval.
    static func retainedChapters(_ chapters: [StitchCutMarker], trimStart: Double,
                                 duration: Double) -> [StitchCutMarker] {
        chapters.compactMap { chapter in
            let start = max(0, chapter.start - trimStart)
            let end = min(duration, chapter.end - trimStart)
            guard end > start else { return nil }
            return StitchCutMarker(title: chapter.title, start: start, end: end)
        }
    }

    static func concatenateChapters(_ media: [StitchMarkerMedia]) -> [StitchCutMarker] {
        var offset = 0.0
        return media.flatMap { source in
            defer { offset += source.duration }
            return source.chapters.compactMap { chapter -> StitchCutMarker? in
                let start = max(0, chapter.start)
                let end = min(source.duration, chapter.end)
                guard end > start else { return nil }
                return StitchCutMarker(title: chapter.title, start: offset + start, end: offset + end)
            }
        }
    }

    /// Resolve serialization adapted from Media Player 0c56c2c's
    /// CompareReviewReportExporter.resolveMarkersEDL. Event layout, frame math,
    /// CRLF, note escaping, and rejection rules retain its round-trip contract.
    static func resolveEDL(title: String, markers: [StitchCutMarker], frameRate: Double,
                           startTimecode: String?, markerNumbers: [Int]? = nil, includeRanges: Bool = false) throws -> String {
        guard frameRate.isFinite, frameRate >= 1, frameRate <= 60.001 else { throw StitchMarkerError.invalidRate }
        let rate = StitchMarkerTimecodeRate(frameRate: frameRate, dropFrame: startTimecode?.contains(";") ?? false)
        guard rate.nominalFPS <= 60 else { throw StitchMarkerError.invalidRate }
        guard markers.count <= 999 else { throw StitchMarkerError.tooManyMarkers }
        let startFrame: Int64
        if let startTimecode {
            guard let frame = rate.frameCount(forTimecode: startTimecode),
                  !startTimecode.contains(";") || rate.isDropFrame else { throw StitchMarkerError.invalidRate }
            startFrame = frame
        } else { startFrame = 0 }
        var occupiedFrames = Set<Int64>()
        var lines = ["TITLE: \(edlText(title))", "FCM: \(rate.isDropFrame ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        for (index, marker) in markers.enumerated() {
            guard let relative = rate.frameCount(forSeconds: marker.start), relative >= 0 else { throw StitchMarkerError.unavailableTiming }
            guard occupiedFrames.insert(relative).inserted else { throw StitchMarkerError.duplicateFrame }
            let (frame, overflow) = startFrame.addingReportingOverflow(relative)
            let duration: Int64
            if includeRanges {
                guard let count = rate.frameCount(forSeconds: marker.end - marker.start), count > 0 else {
                    throw StitchMarkerError.unavailableTiming
                }
                duration = count
            } else { duration = 1 }
            let (end, endOverflow) = frame.addingReportingOverflow(duration)
            let framesPerDay = rate.nominalFPS * 86_400 - rate.droppedFramesPerMinute * 1_296
            guard !overflow, !endOverflow, frame >= 0, end < framesPerDay else { throw StitchMarkerError.midnightWrap }
            let input = rate.timecode(forFrameCount: frame)
            let output = rate.timecode(forFrameCount: end)
            lines.append(String(format: "%03d  001      V     C        %@ %@ %@ %@", markerNumbers.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? index + 1, input, output, input, output))
            lines.append(" |C:ResolveColorBlue |M:\(edlText(marker.title)) |D:\(duration)")
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    private static func edlText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
    }

    static func chapterMetadata(_ chapters: [StitchCutMarker]) throws -> String {
        var result = ";FFMETADATA1\n"
        for chapter in chapters {
            guard chapter.start.isFinite, chapter.end.isFinite, chapter.start >= 0,
                  chapter.end > chapter.start, chapter.end < 1_000_000_000 else { throw StitchMarkerError.unavailableTiming }
            let start = Int64((chapter.start * 1_000_000).rounded())
            let end = Int64((chapter.end * 1_000_000).rounded())
            guard end > start else { throw StitchMarkerError.unavailableTiming }
            let title = chapter.title.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "=", with: "\\=")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: "#", with: "\\#")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            result += "[CHAPTER]\nTIMEBASE=1/1000000\nSTART=\(start)\nEND=\(end)\ntitle=\(title)\n"
        }
        return result
    }

    static func writeEDL(_ text: String, alongside outputURL: URL) throws -> URL {
        let stem = outputURL.deletingPathExtension()
        for index in 0..<1000 {
            let suffix = index == 0 ? ".cuts.edl" : ".cuts-\(index + 1).edl"
            let url = stem.deletingLastPathComponent().appendingPathComponent(stem.lastPathComponent + suffix)
            do {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw StitchMarkerError.sidecarCollision
    }

    @MainActor
    static func presentWarning(_ message: String, outputURL: URL) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Media exported with a marker warning")
        alert.informativeText = outputURL.lastPathComponent + "\n\n" + message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    @MainActor
    static func shouldReplaceExistingChapters() async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "These clips already contain chapters")
        alert.informativeText = String(localized: "Keep their existing chapters in the stitched file, or replace them with chapters at each clip boundary? The EDL sidecar will include clip boundaries either way.")
        alert.addButton(withTitle: String(localized: "Keep Existing Chapters"))
        alert.addButton(withTitle: String(localized: "Replace with Clip Boundaries"))
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else {
            // Unattended conversions never silently replace chapters.
            return false
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }
}
