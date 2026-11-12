// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stream Copy timing fixes shared by ConversionManager and FFMPEGConverter: MXF
// index rewrites, FFmpeg framecrc packet listings and clean Stream Copy end cuts.

import Foundation

/// FFmpeg's MXF muxer builds the index table's temporal offsets for MPEG-2 from each
/// picture header's `temporal_reference`, not from packet timestamps. When a Stream
/// Copy start trim drops an open GOP's leading B-frames, the first GOP's remaining
/// pictures still count from the dropped ones, so the index points at missing
/// pictures and the file decodes with timestamps running backwards. Renumbering that
/// GOP from zero lets the next MXF mux write a valid index.
enum MXFMPEG2LeadingGOPRenumbering {
    private static let maximumPictureElements = 1024
    private static let maximumElementLength: UInt64 = 64 * 1024 * 1024

    /// Returns `true` when the file was changed. Files that are not frame-wrapped
    /// MPEG-2 in KLV, or whose first GOP already counts from zero, are left untouched.
    static func renumberFirstGOP(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        // File offset of each first-GOP picture header's temporal_reference, its value,
        // and the following byte, which also holds the picture coding type.
        var pictures: [(offset: UInt64, reference: Int, trailingByte: UInt8)] = []
        var gopHeaders = 0
        var pictureElements = 0
        var offset: UInt64 = 0

        scan: while offset + 17 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 25), header.count >= 17 else { return false }
            let bytes = [UInt8](header)
            guard bytes.starts(with: [0x06, 0x0E, 0x2B, 0x34]) else { return false }
            let length: UInt64
            let lengthSize: Int
            if bytes[16] < 0x80 {
                length = UInt64(bytes[16])
                lengthSize = 1
            } else {
                let count = Int(bytes[16] & 0x7F)
                guard (1...8).contains(count), bytes.count >= 17 + count else { return false }
                length = bytes[17..<(17 + count)].reduce(0) { $0 << 8 | UInt64($1) }
                lengthSize = 1 + count
            }
            let valueOffset = offset + 16 + UInt64(lengthSize)
            guard length <= fileSize - min(valueOffset, fileSize) else { return false }

            if isPictureElement(bytes) {
                pictureElements += 1
                guard pictureElements <= maximumPictureElements, length <= maximumElementLength else { return false }
                try handle.seek(toOffset: valueOffset)
                guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else { return false }
                let value = [UInt8](data)
                // Only MPEG-2 starts its first picture with a sequence header.
                if pictureElements == 1 && !value.starts(with: [0x00, 0x00, 0x01, 0xB3]) { return false }
                var index = 0
                while index + 5 < value.count {
                    guard value[index] == 0, value[index + 1] == 0, value[index + 2] == 1 else {
                        index += 1
                        continue
                    }
                    switch value[index + 3] {
                    case 0xB8:
                        gopHeaders += 1
                        if gopHeaders > 1 { break scan }
                    case 0x00 where gopHeaders == 1:
                        let reference = Int(value[index + 4]) << 2 | Int(value[index + 5]) >> 6
                        pictures.append((valueOffset + UInt64(index + 4), reference, value[index + 5]))
                    default:
                        break
                    }
                    index += 3
                }
                if gopHeaders == 0 { return false }
            }
            offset = valueOffset + length
        }

        guard let first = pictures.map(\.reference).min(), first > 0 else { return false }
        for picture in pictures {
            let reference = picture.reference - first
            try handle.seek(toOffset: picture.offset)
            try handle.write(contentsOf: [
                UInt8(reference >> 2),
                UInt8((reference & 0x03) << 6) | (picture.trailingByte & 0x3F),
            ])
        }
        return true
    }

    /// Frame-wrapped essence element of a Generic Container (0x15) or SDTI-CP (0x05) picture item.
    private static func isPictureElement(_ key: [UInt8]) -> Bool {
        key[4] == 0x01 && key[5] == 0x02 && key[6] == 0x01
            && key[8] == 0x0D && key[9] == 0x01 && key[10] == 0x03 && key[11] == 0x01
            && (key[12] == 0x15 || key[12] == 0x05)
    }
}

/// FFmpeg's MXF muxer writes a zero temporal offset for every H.264 picture, so
/// readers show Long GOP frames in decode order (XAVC-L decodes with timestamps
/// running backwards and frames dropped). bmxtranswrap can rebuild the index of a
/// single clip, but rejects merges whose later clips start on a non-IDR I-frame. The
/// stream copy keeps every picture in order, so the offsets FFmpeg reads from the
/// merge's inputs are the ones its output needs.
enum MXFIndexTemporalOffsets {
    private static let indexTableSegmentKey: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x10, 0x01, 0x00,
    ]
    private static let maximumSegmentLength: UInt64 = 64 * 1024 * 1024

    /// Each displayed picture's offset to its stored position, from packet presentation
    /// times in decode order. Nil when an offset doesn't fit the index's signed byte.
    static func temporalOffsets(presentationTimes: [Int64]) -> [Int8]? {
        let displayOrder = presentationTimes.indices.sorted {
            (presentationTimes[$0], $0) < (presentationTimes[$1], $1)
        }
        var offsets: [Int8] = []
        offsets.reserveCapacity(displayOrder.count)
        for (display, stored) in displayOrder.enumerated() {
            guard let offset = Int8(exactly: stored - display) else { return nil }
            offsets.append(offset)
        }
        return offsets
    }

    /// Writes `offsets` into every index entry of the file's picture index. Returns
    /// `false`, leaving the file untouched, unless the entries cover exactly the
    /// offsets given.
    static func write(_ offsets: [Int8], to url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        // File offsets of each edit unit's TemporalOffset bytes (segments can repeat).
        var entryOffsets: [Int: [UInt64]] = [:]
        var offset: UInt64 = 0
        while offset + 17 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 25), header.count >= 17 else { return false }
            let bytes = [UInt8](header)
            guard bytes.starts(with: [0x06, 0x0E, 0x2B, 0x34]) else { return false }
            let length: UInt64
            let lengthSize: Int
            if bytes[16] < 0x80 {
                length = UInt64(bytes[16])
                lengthSize = 1
            } else {
                let count = Int(bytes[16] & 0x7F)
                guard (1...8).contains(count), bytes.count >= 17 + count else { return false }
                length = bytes[17..<(17 + count)].reduce(0) { $0 << 8 | UInt64($1) }
                lengthSize = 1 + count
            }
            let valueOffset = offset + 16 + UInt64(lengthSize)
            guard length <= fileSize - min(valueOffset, fileSize) else { return false }
            if bytes.starts(with: indexTableSegmentKey) {
                guard length <= maximumSegmentLength else { return false }
                try handle.seek(toOffset: valueOffset)
                guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else { return false }
                guard readEntries(of: [UInt8](data), at: valueOffset, into: &entryOffsets) else { return false }
            }
            offset = valueOffset + length
        }
        guard entryOffsets.count == offsets.count,
              entryOffsets.keys.allSatisfy({ (0..<offsets.count).contains($0) }) else { return false }
        for (editUnit, fileOffsets) in entryOffsets {
            for entryOffset in fileOffsets {
                try handle.seek(toOffset: entryOffset)
                try handle.write(contentsOf: [UInt8(bitPattern: offsets[editUnit])])
            }
        }
        return true
    }

    /// Records the TemporalOffset byte of each entry in one index table segment.
    private static func readEntries(of value: [UInt8], at valueOffset: UInt64, into entryOffsets: inout [Int: [UInt64]]) -> Bool {
        var startPosition: Int64?
        var entryArray: (offset: Int, count: Int, length: Int)?
        var index = 0
        while index + 4 <= value.count {
            let tag = UInt16(value[index]) << 8 | UInt16(value[index + 1])
            let length = Int(value[index + 2]) << 8 | Int(value[index + 3])
            let item = index + 4
            guard item + length <= value.count else { return false }
            switch tag {
            case 0x3F0C where length == 8: // IndexStartPosition
                startPosition = value[item..<(item + 8)].reduce(0) { $0 << 8 | Int64($1) }
            case 0x3F0A where length >= 8: // IndexEntryArray: count, entry length, entries
                let count = value[item..<(item + 4)].reduce(0) { $0 << 8 | Int($1) }
                let entryLength = value[(item + 4)..<(item + 8)].reduce(0) { $0 << 8 | Int($1) }
                guard entryLength >= 11, count * entryLength == length - 8 else { return false }
                entryArray = (item + 8, count, entryLength)
            default:
                break
            }
            index = item + length
        }
        // Segments without entries (e.g. constant byte count) leave nothing to patch.
        guard let entryArray else { return true }
        guard let startPosition, startPosition >= 0 else { return false }
        for entry in 0..<entryArray.count {
            entryOffsets[Int(startPosition) + entry, default: []].append(valueOffset + UInt64(entryArray.offset + entry * entryArray.length))
        }
        return true
    }
}

/// Video packet timestamps listed by FFmpeg's `framecrc` muxer.
enum FrameCRC {
    struct Packet: Equatable {
        let dts: Int64
        let pts: Int64
    }

    /// The first stream's packets in decode order, and its time base in seconds.
    static func packets(from text: String) -> (timeBase: Double, packets: [Packet])? {
        var timeBase: Double?
        var packets: [Packet] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#tb 0:") {
                let parts = line.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/")
                guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 else { return nil }
                timeBase = num / den
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[0] == "0" else { continue }
            // Packets without timestamps can't be ordered.
            guard let dts = Int64(fields[1]), let pts = Int64(fields[2]) else { return nil }
            packets.append(Packet(dts: dts, pts: pts))
        }
        guard let timeBase, !packets.isEmpty else { return nil }
        return (timeBase, packets)
    }
}

/// FFmpeg ends a Stream Copy `-t` cut by decode time. With B-frames that keeps a
/// reference picture shown after the trim end but drops B-frames shown before it, so
/// the clip ends on a frame from past the cut, with a gap before it. Ending where every
/// picture shown before the cut is also decoded before it keeps the clip contiguous.
enum StreamCopyEndCut {
    enum Cut: Equatable {
        /// Video shown from `end` on is dropped; `frame` is a picture interval. Both are
        /// seconds on the trim's timeline, which starts at its seek.
        case at(end: Double, frame: Double)
        /// No clean point before the source ends, so the clip keeps the rest of it.
        case endOfFile
        /// FFmpeg's own cut applies.
        case unknown

        /// Seconds of the trim's timeline to keep; nil keeps the rest of the source.
        func duration(requested: Double) -> Double? {
            switch self {
            case .at(let end, _): end
            case .endOfFile: nil
            case .unknown: requested
            }
        }

        /// Noise filter term dropping video shown from the cut on.
        var droppedVideo: String? {
            guard case .at(let end, let frame) = self else { return nil }
            // `-t` keeps every packet decoded before the end, including reference
            // pictures shown after it. Nothing kept depends on them at a clean end.
            return String(format: "not(eq(pts,nopts))*gte(pts*tb,%.9f)", end - frame / 2)
        }
    }

    private static let lookAhead = 3.0

    /// Lists the video packets a trim reads up to `end` (seconds after the seek) and a
    /// little beyond. The listing must seek exactly like the trim: FFmpeg rounds a seek
    /// offset to whole time-base units, so any other seek can shift the timeline by a frame.
    static func listingArguments(inputURL: URL, seek: [String], end: Double, listURL: URL) -> [String] {
        ["-y"] + seek + [
            "-i", inputURL.path, "-map", "0:v:0", "-c", "copy",
            "-t", FFMPEGCommandBuilder.ffmpegTimeString(from: end + lookAhead),
            "-f", "framecrc", listURL.path,
        ]
    }

    /// The first clean end at or after `end` in a listing from `listingArguments`.
    static func cut(fromListing text: String?, end: Double) -> Cut {
        guard let text, let (timeBase, packets) = FrameCRC.packets(from: text) else { return .unknown }
        if let cut = cleanEnd(packets: packets, timeBase: timeBase, requestedEnd: end) {
            // Pictures are at least one time-base unit apart.
            let pictureTimes = Set(packets.map(\.pts)).sorted()
            let interval = zip(pictureTimes, pictureTimes.dropFirst()).map { $1 - $0 }.min() ?? 1
            return .at(end: Double(cut) * timeBase, frame: Double(max(interval, 1)) * timeBase)
        }
        // A single picture (cover art) or video ending before `end` says nothing about
        // where the clip ends, so FFmpeg's cut applies.
        let lastShown = Double(packets.map(\.pts).max() ?? 0) * timeBase
        guard packets.count > 1, lastShown >= end else { return .unknown }
        // Packets stopping well short of the listed span mean the source ended.
        let lastDecode = Double(packets.map(\.dts).max() ?? 0) * timeBase
        return lastDecode < end + lookAhead - 1 ? .endOfFile : .unknown
    }

    /// The earliest presentation timestamp at or after `requestedEnd` (seconds) where
    /// the packets before it in decode order are exactly the pictures shown before it.
    /// Nil when the packets hold no such point.
    static func cleanEnd(packets: [FrameCRC.Packet], timeBase: Double, requestedEnd: Double) -> Int64? {
        guard packets.count > 1 else { return nil }
        var suffixMinimum = Array(repeating: Int64.max, count: packets.count + 1)
        for index in packets.indices.reversed() {
            suffixMinimum[index] = min(packets[index].pts, suffixMinimum[index + 1])
        }
        var prefixMaximum = Int64.min
        for index in packets.indices.dropLast() {
            prefixMaximum = max(prefixMaximum, packets[index].pts)
            let next = suffixMinimum[index + 1]
            guard prefixMaximum < next else { continue }
            if Double(next) * timeBase >= requestedEnd - 1e-9 { return next }
        }
        return nil
    }
}
