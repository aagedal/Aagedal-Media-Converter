// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One row of the metadata comparison grid: a label plus one value per displayed file.
struct MetadataTableRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case field
        /// Introduces the rows of one stream (e.g. "Audio 2") when a section has several.
        case streamHeader
    }

    let id: String
    let label: String
    let values: [String?]
    var kind: Kind = .field
    /// Rows sharing a group belong to the same stream; a header survives filtering
    /// when any of its group's field rows does.
    var group: Int? = nil

    /// True when the displayed files disagree, including one file lacking the value.
    var valuesDiffer: Bool {
        values.count > 1 && Set(values.map { $0 ?? "" }).count > 1
    }

    /// True when at least two files carry different non-empty values (used for highlighting).
    var hasConflictingValues: Bool {
        Set(values.compactMap { $0 }).count > 1
    }
}

struct MetadataTableSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    var rows: [MetadataTableRow]
    /// Shown instead of rows when the section has nothing to list (e.g. no audio streams).
    var emptyMessage: String? = nil

    var fieldCount: Int { rows.filter { $0.kind == .field }.count }
}

/// Builds the metadata grid from queue items. Pure apart from reading file-system dates,
/// so search, difference filtering, copying and the window all share one row definition.
@MainActor
struct MetadataTableBuilder {
    let items: [VideoItem]
    var c2pa: (VideoItem) -> C2PAMetadata? = { $0.c2paMetadata }
    var c2paStatus: (VideoItem) -> String? = { item in
        item.c2paMetadata.map { $0.hasContentCredentials ? "Present" : "No" } ?? "Not available"
    }
    var camera: (VideoItem) -> CameraMetadata? = { $0.cameraMetadata }
    var cameraStatus: (VideoItem) -> String? = { item in
        item.cameraMetadata?.hasAnyData == true ? "Present" : nil
    }

    func build() -> [MetadataTableSection] {
        [
            generalSection(),
            videoSection(),
            audioSection(),
            subtitleSection(),
            chapterSection(),
            cameraSection(),
            c2paSection()
        ].compactMap { $0 }
    }

    // MARK: - Sections

    private func generalSection() -> MetadataTableSection {
        var rows = RowCollector(items: items, section: "general")
        rows.add("Container") { $0.metadata?.containerLongName ?? $0.metadata?.formatName }
        rows.add("Duration") { $0.duration.isEmpty ? nil : $0.duration }
        rows.add("File Size") { item in
            Self.byteFormatter.string(fromByteCount: item.metadata?.sizeBytes ?? item.size)
        }
        rows.add("Bit Rate") { Self.formatBitRate($0.metadata?.bitRate) }
        rows.add("Tracks") { Self.trackSummary(for: $0) }
        rows.add("Title") { $0.metadata?.title }
        rows.add("Artist") { $0.metadata?.artist }
        rows.add("Description") { $0.metadata?.description }
        rows.add("Comment") { $0.metadataComment }
        rows.add("Source URL") { $0.metadata?.sourceURL }
        rows.add("Date Created") { item in
            if let date = item.metadata?.containerCreationDate { return Self.dateFormatter.string(from: date) }
            return (try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                .map(Self.dateFormatter.string(from:))
        }
        rows.add("Date Modified") { item in
            if let date = item.metadata?.containerModificationDate { return Self.dateFormatter.string(from: date) }
            return (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map(Self.dateFormatter.string(from:))
        }

        // Timecodes: when files carry several sources, list each so disagreements stand out.
        let maxTimecodeSources = items.map { $0.metadata?.timecodes.count ?? 0 }.max() ?? 0
        if maxTimecodeSources <= 1 {
            rows.add("Timecode") { $0.metadata?.timecodes.first?.value ?? $0.metadata?.timecode }
        } else {
            for source in unique(items.flatMap { $0.metadata?.timecodes.map(\.source) ?? [] }) {
                rows.add("Timecode (\(source.label))") { item in
                    item.metadata?.timecodes.first { $0.source == source }?.value
                }
            }
        }

        rows.add("GPS") { item in
            guard let lat = item.metadata?.gpsLatitude, let lon = item.metadata?.gpsLongitude else { return nil }
            return String(format: "%.6f, %.6f", lat, lon)
        }
        rows.add("GPS Altitude") { item in
            item.metadata?.gpsAltitude.map { String(format: "%.1f m", $0) }
        }
        rows.add("Broadcast Service") { item in
            item.metadata?.broadcastServices.nilIfEmpty?.joined(separator: "\n")
        }
        rows.add("Data Tracks") { item in
            item.metadata?.dataTracks.nilIfEmpty?.joined(separator: "\n")
        }
        rows.add("Attachments") { item in
            guard let count = item.metadata?.attachmentCount, count > 0 else { return nil }
            return count == 1 ? "1 file" : "\(count) files"
        }
        rows.add("Live Photo ID") { $0.metadata?.contentIdentifier }

        let warnings = unique(items.flatMap { $0.metadata?.warnings ?? [] })
        for (index, warning) in warnings.enumerated() {
            rows.add(index == 0 ? "Warnings" : "", id: "warning-\(index)") { item in
                item.metadata?.warnings.contains(warning) == true ? warning : nil
            }
        }

        return MetadataTableSection(id: "general", title: "General", systemImage: "doc", rows: rows.rows)
    }

    private func videoSection() -> MetadataTableSection {
        var rows = RowCollector(items: items, section: "video")
        let streamCount = items.map { $0.metadata?.videoStreams.count ?? 0 }.max() ?? 0
        for index in 0..<streamCount {
            func stream(_ item: VideoItem) -> VideoMetadata.VideoStream? {
                item.metadata?.videoStreams[safe: index]
            }
            if streamCount > 1 {
                rows.header("Video \(index + 1)", group: index) { item in
                    stream(item).map(Self.videoSummary)
                }
            }
            rows.group = index
            rows.add("Codec") { item in stream(item).flatMap { $0.codecLongName ?? $0.codec } }
            rows.add("Profile") { stream($0)?.profile }
            rows.add("Track Title") { stream($0)?.title }
            rows.add("Resolution") { item in
                if index == 0, let description = item.videoResolutionDescription { return description }
                guard let width = stream(item)?.width, let height = stream(item)?.height else { return nil }
                return "\(width) × \(height)"
            }
            rows.add("Display Aspect") { stream($0)?.displayAspectRatio?.stringValue }
            rows.add("Pixel Aspect") { stream($0)?.pixelAspectRatio?.stringValue }
            rows.add("Rotation") { item in
                guard let rotation = stream(item)?.rotation, rotation != 0 else { return nil }
                return "\(rotation)°"
            }
            rows.add("Frame Rate") { Self.formatFrameRate(stream($0)?.frameRate) }
            if index == 0 {
                rows.add("Frame Count") { $0.metadata?.frameCount.map(String.init) }
            }
            rows.add("Scan Type") { item in
                guard let stream = stream(item) else { return nil }
                guard let isInterlaced = stream.isInterlaced else { return stream.fieldOrder }
                return isInterlaced ? "Interlaced" : "Progressive"
            }
            rows.add("Field Order") { stream($0).flatMap(Self.formatFieldOrder) }
            rows.add("Bit Depth") { stream($0)?.bitDepth.map { "\($0)-bit" } }
            rows.add("Bit Rate") { Self.formatBitRate(stream($0)?.bitRate) }
            rows.add("Chroma Subsampling") { stream($0)?.chromaSubsampling }
            rows.add("Chroma Resolution") { stream($0)?.chromaResolutionDescription }
            rows.add("Pixel Format") { stream($0)?.pixelFormat }
            rows.add("Alpha Channel") { item in stream(item).map { $0.hasAlpha ? "Yes" : "No" } }
            rows.add("Dynamic Range") { stream($0)?.dynamicRangeDescription }
            rows.add("Color Primaries") { stream($0)?.colorPrimaries }
            rows.add("Color Transfer") { stream($0)?.colorTransfer }
            rows.add("Color Space") { stream($0)?.colorSpace }
            rows.add("Color Range") { stream($0)?.colorRange }
            rows.add("Chroma Location") { stream($0)?.chromaLocation }
            rows.add("Mastering Display") { stream($0)?.hdr?.masteringDisplay }
            rows.add("Content Light Level") { stream($0)?.hdr?.contentLightLevel }
            rows.add("Dolby Vision") { stream($0)?.hdr?.dolbyVision }
            rows.add("Closed Captions") { stream($0)?.hasClosedCaptions == true ? "Embedded (CEA-608/708)" : nil }
            rows.add("Default") { stream($0)?.isDefault == true ? "Yes" : nil }
            rows.add("Forced") { stream($0)?.isForced == true ? "Yes" : nil }
        }
        return MetadataTableSection(
            id: "video", title: "Video", systemImage: "film", rows: rows.rows,
            emptyMessage: "No video stream detected."
        )
    }

    private func audioSection() -> MetadataTableSection {
        var rows = RowCollector(items: items, section: "audio")
        let streamCount = items.map { $0.metadata?.audioStreams.count ?? 0 }.max() ?? 0
        for index in 0..<streamCount {
            func stream(_ item: VideoItem) -> VideoMetadata.AudioStream? {
                item.metadata?.audioStreams[safe: index]
            }
            if streamCount > 1 {
                rows.header("Audio \(index + 1)", group: index) { item in
                    stream(item).map(Self.audioSummary)
                }
            }
            rows.group = index
            rows.add("Codec") { item in stream(item).flatMap { $0.codecLongName ?? $0.codec } }
            rows.add("Profile") { stream($0)?.profile }
            rows.add("Track Title") { stream($0)?.title }
            rows.add("Language") { stream($0)?.languageCode.map(Self.languageName) }
            rows.add("Channels") { stream($0)?.channels.map(String.init) }
            rows.add("Channel Layout") { stream($0)?.channelLayout }
            rows.add("Channel Label") { stream($0)?.mcaLabel }
            rows.add("Soundfield Group") { stream($0)?.mcaSoundfieldGroup }
            rows.add("Sample Rate") { Self.formatSampleRate(stream($0)?.sampleRate) }
            rows.add("Bit Depth") { stream($0)?.bitDepth.map { "\($0)-bit" } }
            rows.add("Bit Rate") { Self.formatBitRate(stream($0)?.bitRate) }
            rows.add("Duration") { Self.formatStreamDuration(stream($0)?.duration) }
            rows.add("Default") { stream($0)?.isDefault == true ? "Yes" : nil }
        }
        return MetadataTableSection(
            id: "audio", title: "Audio", systemImage: "waveform", rows: rows.rows,
            emptyMessage: "No audio stream detected."
        )
    }

    private func subtitleSection() -> MetadataTableSection {
        var rows = RowCollector(items: items, section: "subtitle")
        let streamCount = items.map { $0.metadata?.subtitleStreams.count ?? 0 }.max() ?? 0
        for index in 0..<streamCount {
            func stream(_ item: VideoItem) -> VideoMetadata.SubtitleStream? {
                item.metadata?.subtitleStreams[safe: index]
            }
            if streamCount > 1 {
                rows.header("Subtitle \(index + 1)", group: index) { item in
                    stream(item).map { stream in
                        [stream.codec?.uppercased(), stream.languageCode.map(Self.languageName), stream.title]
                            .compactMap { $0 }.joined(separator: " · ")
                    }
                }
            }
            rows.group = index
            rows.add("Codec") { item in stream(item).flatMap { $0.codecLongName ?? $0.codec } }
            rows.add("Language") { stream($0)?.languageCode.map(Self.languageName) }
            rows.add("Title") { stream($0)?.title }
            rows.add("Duration") { Self.formatStreamDuration(stream($0)?.duration) }
            rows.add("Default") { stream($0)?.isDefault == true ? "Yes" : nil }
            rows.add("Forced") { stream($0)?.isForced == true ? "Yes" : nil }
            rows.add("Hearing Impaired (SDH)") { stream($0)?.isHearingImpaired == true ? "Yes" : nil }
        }
        return MetadataTableSection(
            id: "subtitle", title: "Subtitles", systemImage: "captions.bubble", rows: rows.rows,
            emptyMessage: "No subtitle stream detected."
        )
    }

    private func chapterSection() -> MetadataTableSection? {
        let chapterCount = items.map { $0.metadata?.chapters.count ?? 0 }.max() ?? 0
        guard chapterCount > 0 else { return nil }
        var rows = RowCollector(items: items, section: "chapters")
        for index in 0..<chapterCount {
            rows.add("Chapter \(index + 1)") { item in
                guard let chapter = item.metadata?.chapters[safe: index] else { return nil }
                let start = Self.formatTimestamp(chapter.startTime)
                return chapter.title.map { "\(start)  \($0)" } ?? start
            }
        }
        return MetadataTableSection(id: "chapters", title: "Chapters", systemImage: "list.bullet.rectangle", rows: rows.rows)
    }

    /// Omitted for files without camera metadata, which is most of them; the section
    /// appears once the lazy camera probe finds data for any displayed file.
    private func cameraSection() -> MetadataTableSection? {
        guard items.contains(where: { camera($0)?.hasAnyData == true }) else { return nil }
        var rows = RowCollector(items: items, section: "camera")
        rows.add("Status", value: cameraStatus)
        rows.add("Manufacturer") { camera($0)?.deviceManufacturer }
        rows.add("Model") { camera($0)?.deviceModelName }
        rows.add("Serial Number") { camera($0)?.deviceSerialNumber }
        rows.add("Lens") { camera($0)?.lensModelName }
        rows.add("Time Zone") { camera($0)?.timeZone }
        rows.add("Gamma/Color Profile") { camera($0)?.captureGammaEquation }
        rows.add("Recording Mode") { camera($0)?.recordingModeType }
        rows.add("Capture FPS") { camera($0)?.captureFps }
        rows.add("Clip Creation") { camera($0)?.creationDate.map(Self.dateFormatter.string(from:)) }
        rows.add("User Metadata") { item in
            guard let entries = camera(item)?.userDescriptiveMetadata, !entries.isEmpty else { return nil }
            return entries.map { "\($0.name): \($0.content)" }.joined(separator: "\n")
        }
        return MetadataTableSection(id: "camera", title: "Camera", systemImage: "camera", rows: rows.rows)
    }

    private func c2paSection() -> MetadataTableSection {
        var rows = RowCollector(items: items, section: "c2pa")
        rows.add("Content Credentials", value: c2paStatus)
        // Detail rows only add noise when no file carries credentials ("Signature: Not found").
        guard items.contains(where: { c2pa($0)?.hasContentCredentials == true }) else {
            return MetadataTableSection(
                id: "c2pa", title: "Content Authenticity (C2PA)", systemImage: "checkmark.seal", rows: rows.rows
            )
        }
        for field in C2PADisplayField.allCases {
            rows.add(field.label) { c2pa($0)?.displayValue(for: field) }
        }
        return MetadataTableSection(
            id: "c2pa", title: "Content Authenticity (C2PA)", systemImage: "checkmark.seal", rows: rows.rows
        )
    }

    // MARK: - Summaries

    private static func trackSummary(for item: VideoItem) -> String? {
        guard let metadata = item.metadata else { return nil }
        let parts = [
            (metadata.videoStreams.count, "video"),
            (metadata.audioStreams.count, "audio"),
            (metadata.subtitleStreams.count, "subtitle"),
            (metadata.dataTracks.count, "data")
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func videoSummary(_ stream: VideoMetadata.VideoStream) -> String {
        let resolution = stream.width.flatMap { w in stream.height.map { "\(w)×\($0)" } }
        let fps = stream.frameRate?.value.map { String(format: "%g fps", ($0 * 1000).rounded() / 1000) }
        return [stream.codec?.uppercased(), resolution, fps].compactMap { $0 }.joined(separator: " · ")
    }

    private static func audioSummary(_ stream: VideoMetadata.AudioStream) -> String {
        let channels = stream.channels.map { "\($0) ch" }
        return [stream.codec?.uppercased(), channels, stream.languageCode?.uppercased(), stream.title]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Formatters

    static func formatBitRate(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 1_000_000 { return String(format: "%.2f Mbps", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f kbps", Double(value) / 1_000) }
        return "\(value) bps"
    }

    private static func formatFrameRate(_ frameRate: VideoMetadata.FrameRate?) -> String? {
        guard let frameRate else { return nil }
        return frameRate.value.map { String(format: "%.3f fps", $0) } ?? frameRate.stringValue
    }

    private static func formatSampleRate(_ sampleRate: Int?) -> String? {
        guard let sampleRate else { return nil }
        return numberFormatter.string(from: NSNumber(value: sampleRate)).map { "\($0) Hz" }
    }

    /// Maps the ffprobe-style field order ("tt", "bb", …) to a readable label. Progressive and
    /// unknown sources hide the row: Scan Type already covers them.
    private static func formatFieldOrder(_ stream: VideoMetadata.VideoStream) -> String? {
        switch stream.fieldOrder {
        case "tt": return "Top Field First (TFF)"
        case "bb": return "Bottom Field First (BFF)"
        case "progressive", "unknown", nil: return nil
        case let order?: return order
        }
    }

    private static func formatStreamDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0, seconds.isFinite else { return nil }
        return formatTimestamp(seconds)
    }

    /// `HH:MM:SS.mmm`, matching the precision of chapter markers.
    static func formatTimestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let secs = totalMilliseconds / 1000 % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, totalMilliseconds % 1000)
    }

    /// "nor" → "Norwegian (NOR)"; unknown or undetermined codes stay as written.
    static func languageName(_ code: String) -> String {
        let upper = code.uppercased()
        guard code != "und", let name = Locale.current.localizedString(forLanguageCode: code) else { return upper }
        return "\(name) (\(upper))"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Accumulates rows for one section, dropping fields that no displayed file carries.
@MainActor
private struct RowCollector {
    let items: [VideoItem]
    let section: String
    var group: Int? = nil
    private(set) var rows: [MetadataTableRow] = []

    init(items: [VideoItem], section: String) {
        self.items = items
        self.section = section
    }

    mutating func add(_ label: String, id: String? = nil, value: (VideoItem) -> String?) {
        let values = items.map { item in value(item).flatMap { $0.isEmpty ? nil : $0 } }
        guard values.contains(where: { $0 != nil }) else { return }
        let rowID = [section, group.map(String.init), id ?? label].compactMap { $0 }.joined(separator: ".")
        rows.append(MetadataTableRow(id: rowID, label: label, values: values, group: group))
    }

    mutating func header(_ label: String, group: Int, summary: (VideoItem) -> String?) {
        let values = items.map { item in summary(item).flatMap { $0.isEmpty ? nil : $0 } }
        rows.append(MetadataTableRow(
            id: "\(section).\(group).header", label: label, values: values, kind: .streamHeader, group: group
        ))
    }
}

/// Narrows sections to rows matching a search query and/or rows whose values differ.
enum MetadataTableFilter {
    static func apply(
        _ sections: [MetadataTableSection],
        query: String,
        differencesOnly: Bool
    ) -> [MetadataTableSection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || differencesOnly else { return sections }

        return sections.compactMap { section in
            let sectionMatches = !query.isEmpty && matches(section.title, query)
            let keptFields = section.rows.filter { row in
                guard row.kind == .field else { return false }
                if differencesOnly && !row.valuesDiffer { return false }
                guard !query.isEmpty, !sectionMatches else { return true }
                return matches(row.label, query) || row.values.contains { $0.map { matches($0, query) } ?? false }
            }
            let keptIDs = Set(keptFields.map(\.id))
            let keptGroups = Set(keptFields.compactMap(\.group))
            let rows = section.rows.filter { row in
                row.kind == .streamHeader ? row.group.map(keptGroups.contains) ?? false : keptIDs.contains(row.id)
            }
            guard !rows.isEmpty else { return nil }
            var filtered = section
            filtered.rows = rows
            return filtered
        }
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Ranges of `query` in `text`, for highlighting search hits.
    static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            ranges.append(range)
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return ranges
    }
}

/// Plain-text rendering for the clipboard: one "Label: value" line per file column.
enum MetadataTableTextExporter {
    static func text(for sections: [MetadataTableSection], fileNames: [String]) -> String {
        var lines: [String] = []
        if fileNames.count > 1 {
            for (index, name) in fileNames.enumerated() {
                lines.append("[\(index + 1)] \(name)")
            }
        } else if let name = fileNames.first {
            lines.append(name)
        }
        for section in sections {
            lines.append("")
            lines.append(section.title.uppercased())
            for row in section.rows {
                if row.kind == .streamHeader {
                    lines.append("  \(row.label)")
                    continue
                }
                let indent = row.group == nil ? "  " : "    "
                if row.values.count == 1 {
                    lines.append("\(indent)\(row.label): \(flatten(row.values[0]))")
                } else {
                    let joined = row.values.enumerated()
                        .map { "[\($0.offset + 1)] \(flatten($0.element))" }
                        .joined(separator: "  ")
                    lines.append("\(indent)\(row.label): \(joined)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func flatten(_ value: String?) -> String {
        (value ?? "—").replacingOccurrences(of: "\n", with: "; ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
