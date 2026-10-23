// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stream Copy merges of MXF clips into MXF are rewrapped with bmxtranswrap instead of
/// FFmpeg's concat demuxer. FFmpeg's MXF muxer rewrites the picture descriptor (losing
/// camera transfer/primaries labels such as S-Log3/S-Gamut3 that Resolve's colour
/// management reads), drops the ANC track carrying per-frame acquisition metadata, and
/// replaces the writer identification that Resolve uses to enable vendor metadata
/// parsing. bmx keeps all three; Sony NonRealTimeMeta XML is re-embedded and written as
/// the `<name>M01.XML` sidecar that Resolve reads for camera model, serial and lens.
struct NativeMXFMergeRequest: Sendable, Equatable {
    /// Source clips in merge order.
    let segmentURLs: [URL]
    /// Company Name for the Identification set, copied from the first source.
    let companyName: String
    /// Merged Sony NonRealTimeMeta document, when the sources carry one.
    let nonRealTimeMetaXML: String?
}

enum NativeMXFMerge {
    /// Sony's RP 2057 text scheme identifier for NonRealTimeMeta (as written by FX6 firmware).
    static let sonyNRTSchemeID = "786d4d22-8280-11de-8a39-08004678031c"
    static let productName = "Aagedal Media Converter"
    static let productUID = "a6c7a3b2-5e0f-4f8e-9a51-3d7b2c9e4f10"
    static let fallbackCompanyName = "Aagedal"

    // MARK: - Eligibility

    /// Trimmed merges stay on the FFmpeg path: a bmx-trimmed segment is rewritten with a
    /// normalised descriptor (e.g. stored height 1080 instead of Sony's 1088), and bmx's
    /// sequence reader then silently drops the video track as incompatible.
    static func isEligible(
        preset: ExportPreset,
        outputExtension: String,
        sourceURLs: [URL],
        hasTrims: Bool,
        hasGeneratedVideo: Bool,
        audioRoutingCustomized: Bool,
        hasManualTimecode: Bool
    ) -> Bool {
        preset == .streamCopy && outputExtension.lowercased() == "mxf" && sourceURLs.count >= 2
            && sourceURLs.allSatisfy { $0.pathExtension.lowercased() == "mxf" }
            && !hasTrims && !hasGeneratedVideo && !audioRoutingCustomized && !hasManualTimecode
    }

    /// Essence kinds per track from `mxf2raw --info`, e.g. ["Picture", "Sound", …].
    /// A merge whose output lacks any input kind lost tracks in bmx's sequence reader.
    static func essenceKinds(fromMXFInfo info: String) -> [String] {
        info.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("essence_kind"), let colon = trimmed.firstIndex(of: ":") else { return nil }
            return trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - bmxtranswrap arguments

    static func mergeArguments(
        companyName: String,
        appVersion: String,
        embeddedXMLURL: URL?
    ) -> [String] {
        var arguments = [
            "-t", "op1a",
            "--pass-anc", "all",
            // Keep queue order; camera clips rarely have continuous timecode.
            "--no-reorder",
            "--prod-info", companyName, productName, productVersion(appVersion), appVersion, productUID,
        ]
        if let embeddedXMLURL {
            arguments += [
                "--xml-scheme-id", sonyNRTSchemeID,
                "--xml-lang", "und",
                "--embed-xml", embeddedXMLURL.path,
            ]
        }
        return arguments
    }

    /// bmx requires `<major>.<minor>.<patch>.<build>.<release>`.
    static func productVersion(_ appVersion: String) -> String {
        var parts = appVersion.split(separator: ".").prefix(4).map { Int($0) ?? 0 }
        while parts.count < 4 { parts.append(0) }
        return (parts + [0]).map(String.init).joined(separator: ".")
    }

    /// First Identification company in `mxf2raw --info` output (the original writer).
    static func companyName(fromMXFInfo info: String) -> String? {
        for line in info.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("company_name"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Sony NonRealTimeMeta

    /// Sony cards store `<clip>M01.XML` beside `<clip>.MXF`.
    static func sidecarURL(for mediaURL: URL) -> URL {
        let base = mediaURL.deletingPathExtension().lastPathComponent
        return mediaURL.deletingLastPathComponent().appendingPathComponent(base + "M01.XML")
    }

    static func loadNonRealTimeMeta(for mediaURL: URL) -> String? {
        let folder = mediaURL.deletingLastPathComponent()
        let expected = sidecarURL(for: mediaURL).lastPathComponent.lowercased()
        if let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first(where: { $0.lowercased() == expected }),
           let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
           text.contains("<NonRealTimeMeta") {
            return text
        }
        return embeddedNonRealTimeMeta(in: mediaURL)
    }

    /// Sony writes the XML in header metadata, either as a dark KLV (XDCAM/FX9) or an
    /// RP 2057 text set (FX6). Both store it verbatim, so a bounded byte search suffices.
    static func embeddedNonRealTimeMeta(in mediaURL: URL, limit: Int = 16 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: mediaURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return nonRealTimeMeta(in: data)
    }

    static func nonRealTimeMeta(in data: Data) -> String? {
        guard let rootStart = data.range(of: Data("<NonRealTimeMeta".utf8)),
              let rootEnd = data.range(of: Data("</NonRealTimeMeta>".utf8), in: rootStart.upperBound..<data.endIndex)
        else { return nil }
        let searchStart = data.index(rootStart.lowerBound, offsetBy: -256, limitedBy: data.startIndex) ?? data.startIndex
        let start = data.range(of: Data("<?xml".utf8), in: searchStart..<rootStart.lowerBound)?.lowerBound
            ?? rootStart.lowerBound
        return String(data: data[start..<rootEnd.upperBound], encoding: .utf8)
    }

    static func durationFrames(in xml: String) -> Int? {
        firstMatch(#"<Duration value="(\d+)""#, in: xml).flatMap(Int.init)
    }

    struct XMLSegment: Sendable {
        let xml: String?
        /// Frames contributed to the merged file.
        let frameCount: Int
    }

    /// Builds the merged document from the first segment's XML: total Duration, a
    /// per-segment LtcChangeTable (omitted if any source timecode can't be represented),
    /// no body-UMID tables (bmx does not carry the per-frame system item they index),
    /// and a fresh lastUpdate.
    static func mergedNonRealTimeMeta(segments: [XMLSegment], now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let base = segments.first?.xml, !segments.isEmpty else { return nil }
        let total = segments.reduce(0) { $0 + $1.frameCount }
        var xml = base
        xml = replacing(#"<Duration value="\d+"\s*/>"#, in: xml, with: "<Duration value=\"\(total)\"/>")
        let lineEnding = base.contains("\r\n") ? "\r\n" : "\n"
        let ltc = mergedLtcChangeTable(segments: segments)?.replacingOccurrences(of: "\n", with: lineEnding)
        xml = replacing(#"[ \t]*<LtcChangeTable\b[^>]*>.*?</LtcChangeTable>[ \t]*\r?\n?"#, in: xml, with: ltc.map { escapedTemplate($0) } ?? "")
        xml = replacing(#"[ \t]*<BodyUmid\w*ChangeTable>.*?</BodyUmid\w*ChangeTable>[ \t]*\r?\n?"#, in: xml, with: "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        xml = replacing(#"lastUpdate="[^"]*""#, in: xml, with: "lastUpdate=\"\(formatter.string(from: now))\"")
        return xml
    }

    static func mergedLtcChangeTable(segments: [XMLSegment]) -> String? {
        var tcFps: Int?
        var halfStep: Bool?
        var entries: [(frame: Int, value: String, status: String)] = []
        var mergedFrame = 0
        var expectedNext: Int?
        var last: (index: Int, frames: Int)?
        for segment in segments {
            guard let xml = segment.xml, let table = ltcTable(in: xml) else { return nil }
            if tcFps == nil { tcFps = table.tcFps; halfStep = table.halfStep }
            guard table.tcFps == tcFps, table.halfStep == halfStep,
                  let sourceStart = SonyLTC.frameIndex(table.firstValue, tcFps: table.tcFps, halfStep: table.halfStep)
            else { return nil }
            let start = sourceStart
            if start != expectedNext {
                entries.append((mergedFrame, SonyLTC.value(frameIndex: start, tcFps: table.tcFps, halfStep: table.halfStep), "increment"))
            }
            mergedFrame += segment.frameCount
            expectedNext = start + segment.frameCount
            last = (start, segment.frameCount)
        }
        guard let tcFps, let halfStep, let last, last.frames > 0 else { return nil }
        entries.append((mergedFrame - 1, SonyLTC.value(frameIndex: last.index + last.frames - 1, tcFps: tcFps, halfStep: halfStep), "end"))
        let lines = entries.map { "\t\t<LtcChange frameCount=\"\($0.frame)\" value=\"\($0.value)\" status=\"\($0.status)\"/>" }
        return "\t<LtcChangeTable tcFps=\"\(tcFps)\" halfStep=\"\(halfStep)\">\n" + lines.joined(separator: "\n") + "\n\t</LtcChangeTable>\n"
    }

    private static func ltcTable(in xml: String) -> (tcFps: Int, halfStep: Bool, firstValue: String)? {
        guard let header = firstMatch(#"<LtcChangeTable\b([^>]*)>"#, in: xml),
              let fps = firstMatch(#"tcFps="(\d+)""#, in: header).flatMap(Int.init),
              let value = firstMatch(#"<LtcChange\b[^>]*\bvalue="([0-9A-Fa-f]{8})""#, in: xml) else { return nil }
        let halfStep = firstMatch(#"halfStep="(\w+)""#, in: header) == "true"
        return (fps, halfStep, value)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func escapedTemplate(_ text: String) -> String {
        NSRegularExpression.escapedTemplate(for: text)
    }
}

/// Sony NonRealTimeMeta LTC values: four BCD bytes (frames, seconds, minutes, hours)
/// written as eight hex digits. With `halfStep` the timecode counts at half the video
/// rate and bit 7 of the hours byte marks the second video frame of a timecode frame.
enum SonyLTC {
    static func frameIndex(_ value: String, tcFps: Int, halfStep: Bool) -> Int? {
        guard value.count == 8, tcFps > 0, let raw = UInt32(value, radix: 16) else { return nil }
        let bytes = (0..<4).map { UInt8((raw >> (24 - 8 * $0)) & 0xFF) }
        // Drop-frame counting is not representable with this simple arithmetic.
        guard bytes[0] & 0x40 == 0,
              let frames = bcd(bytes[0] & 0x3F), let seconds = bcd(bytes[1] & 0x7F),
              let minutes = bcd(bytes[2] & 0x7F), let hours = bcd(bytes[3] & 0x3F),
              frames < tcFps, seconds < 60, minutes < 60, hours < 24 else { return nil }
        let tcFrames = ((hours * 60 + minutes) * 60 + seconds) * tcFps + frames
        guard halfStep else { return tcFrames }
        return tcFrames * 2 + (bytes[3] & 0x80 != 0 ? 1 : 0)
    }

    static func value(frameIndex: Int, tcFps: Int, halfStep: Bool) -> String {
        let perDay = tcFps * 86_400 * (halfStep ? 2 : 1)
        let index = ((frameIndex % perDay) + perDay) % perDay
        let tcFrames = halfStep ? index / 2 : index
        let second = halfStep && index % 2 == 1
        let frames = tcFrames % tcFps
        let totalSeconds = tcFrames / tcFps
        let hoursByte = toBCD(totalSeconds / 3600 % 24) | (second ? 0x80 : 0)
        let bytes = [toBCD(frames), toBCD(totalSeconds % 60), toBCD(totalSeconds / 60 % 60), hoursByte]
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func bcd(_ byte: UInt8) -> Int? {
        let high = Int(byte >> 4), low = Int(byte & 0x0F)
        guard high <= 9, low <= 9 else { return nil }
        return high * 10 + low
    }

    private static func toBCD(_ value: Int) -> UInt8 {
        UInt8((value / 10) << 4 | (value % 10))
    }
}
