// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captured before conversion suspends so later preference edits affect the next job.
struct SubtitleExportSettings: Sendable {
    let keepSubtitles: Bool

    init(defaults: UserDefaults = .standard) {
        keepSubtitles = defaults.bool(forKey: AppConstants.keepSubtitlesKey)
    }
}

/// Owns the optional source map together with its container-compatible encoder.
enum SubtitleMappingPlan: Equatable, Sendable {
    case omit
    case copy
    case quickTimeText

    init(keepSubtitles: Bool, outputExtension: String) {
        guard keepSubtitles else {
            self = .omit
            return
        }
        switch outputExtension.lowercased() {
        case "mkv": self = .copy
        case "mp4", "mov": self = .quickTimeText
        default: self = .omit
        }
    }

    var arguments: [String] {
        switch self {
        case .omit: return []
        case .copy: return ["-map", "0:s?", "-c:s", "copy"]
        case .quickTimeText: return ["-map", "0:s?", "-c:s", "mov_text"]
        }
    }
}

/// Matroska sources carry the fonts their ASS/SSA subtitles were authored
/// against as attachments. Without them players substitute fonts with other
/// metrics, which shifts karaoke and typesetting away from burned-in text.
enum SubtitleAttachmentPlan: Equatable, Sendable {
    case omit
    /// Stream tags survive, so every attachment can be copied verbatim.
    case copyAll
    /// `-map_metadata -1` also drops the filename/mimetype tags the Matroska
    /// muxer requires, and a blanket `0:s:t` source would copy the first
    /// attachment's tags onto all of them. Map and restore each probed index.
    case copyRestoringTags(count: Int)

    init(subtitlePlan: SubtitleMappingPlan, stripsStreamMetadata: Bool, attachmentCount: Int?) {
        guard subtitlePlan == .copy else {
            self = .omit
            return
        }
        guard stripsStreamMetadata else {
            self = .copyAll
            return
        }
        guard let attachmentCount, attachmentCount > 0 else {
            self = .omit
            return
        }
        self = .copyRestoringTags(count: attachmentCount)
    }

    /// MIME prefixes FFmpeg's Matroska demuxer turns into attached pictures
    /// (`mkv_image_mime_tags` in matroskadec.c) rather than `t` streams.
    private static let ffmpegAttachedPictureMIMEPrefixes = ["image/gif", "image/jpeg", "image/png", "image/tiff"]

    /// Number of `t:<n>` streams FFmpeg exposes for Matroska attachments with these MIME types.
    static func ffmpegAttachmentStreamCount(mimeTypes: [String]) -> Int {
        mimeTypes.filter { mime in
            !ffmpegAttachedPictureMIMEPrefixes.contains { mime.hasPrefix($0) }
        }.count
    }

    /// Whether `arguments` (already carrying the metadata policy) disable
    /// FFmpeg's automatic per-stream tag copy.
    static func stripsStreamMetadata(_ arguments: some Collection<String>) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { option, value in
            value == "-1" && (option == "-map_metadata" || option.hasPrefix("-map_metadata:s"))
        }
    }

    var arguments: [String] {
        switch self {
        case .omit:
            return []
        case .copyAll:
            return ["-map", "0:t?", "-c:t", "copy"]
        case .copyRestoringTags(let count):
            let indices = 0..<count
            return indices.flatMap { ["-map", "0:t:\($0)"] } + ["-c:t", "copy"]
                + indices.flatMap { ["-map_metadata:s:t:\($0)", "0:s:t:\($0)"] }
        }
    }
}
