// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Restores the routed Matroska timeline after elementary audio extraction discards timestamps.
enum AV2AudioPacketTiming {
    static func applying(
        manifest: String,
        to track: MatroskaMuxer.AudioTrack,
        discardPaddingNanoseconds: [Int64]? = nil
    ) -> MatroskaMuxer.AudioTrack? {
        if let discardPaddingNanoseconds, discardPaddingNanoseconds.count != track.frames.count { return nil }
        var timebase: Double?
        var timestamps: [Int64] = []
        let codecDelayMs = Double(track.info.codecDelayNs ?? 0) / 1_000_000
        for line in manifest.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#tb 0:") {
                let components = line.dropFirst(6).split(separator: "/")
                guard components.count == 2,
                      let numerator = Double(components[0].trimmingCharacters(in: .whitespaces)),
                      let denominator = Double(components[1].trimmingCharacters(in: .whitespaces)),
                      numerator.isFinite, denominator.isFinite, numerator > 0, denominator > 0 else { return nil }
                timebase = numerator / denominator
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",")
                guard fields.count >= 6, let timebase,
                      fields[0].trimmingCharacters(in: .whitespaces) == "0",
                      let pts = Double(fields[2].trimmingCharacters(in: .whitespaces)) else { return nil }
                // FFmpeg's demuxed Opus PTS already subtracts CodecDelay. Matroska blocks must
                // add it back because players subtract the track's CodecDelay when decoding.
                // CodecDelay can fall halfway between container milliseconds (Opus uses 6.5 ms).
                // Avoid manufacturing a negative block at the zero origin when demux quantization
                // reports -7 ms: ties-to-even restores zero instead of rounding -0.5 away to -1.
                let milliseconds = (pts * timebase * 1000 + codecDelayMs).rounded(.toNearestOrEven)
                guard milliseconds.isFinite, milliseconds >= -32_768, milliseconds < 9e15,
                      timestamps.last.map({ milliseconds >= Double($0) }) ?? true else { return nil }
                timestamps.append(Int64(milliseconds))
            }
        }
        guard timestamps.count == track.frames.count, !timestamps.isEmpty else { return nil }
        var frames: [MatroskaMuxer.AudioFrame] = []
        for (index, pair) in zip(track.frames, timestamps).enumerated() {
            let (frame, timestamp) = pair
            let padding = discardPaddingNanoseconds?[index] ?? frame.discardPaddingNanoseconds
            // Reject corrupt metadata rather than silently dropping audio or writing a block
            // whose padding extends beyond the packet it belongs to.
            let durationNanoseconds = Double(frame.durationSamples) * 1_000_000_000 / track.info.sampleRate
            guard padding >= 0, durationNanoseconds.isFinite,
                  Double(padding) <= durationNanoseconds.rounded() else { return nil }
            frames.append(MatroskaMuxer.AudioFrame(
                data: frame.data, durationSamples: frame.durationSamples,
                presentationTimestampMilliseconds: timestamp,
                discardPaddingNanoseconds: padding
            ))
        }
        return MatroskaMuxer.AudioTrack(info: track.info, frames: frames)
    }

    /// Reads packet padding from FFmpeg's routed Matroska before elementary extraction. Ogg
    /// granules and framecrc durations are derived from millisecond packet timing at that point,
    /// while DiscardPadding retains the encoder's exact sample count in nanoseconds.
    /// The result follows audio TrackEntry order, with one value per un-laced audio block.
    static func discardPadding(inMatroska data: Data) -> [[Int64]]? {
        try? PaddingReader(data: data).read()
    }

    private struct PaddingReader {
        let data: Data
        private struct Element {
            let id: UInt64
            let payload: Range<Int>
        }
        private enum ParseError: Error { case malformed }

        func read() throws -> [[Int64]] {
            let roots = try elements(in: data.startIndex..<data.endIndex)
            let segments = roots.filter { $0.id == 0x18538067 }
            guard segments.count == 1 else { throw ParseError.malformed }
            let children = try elements(in: segments[0].payload)
            var audioTrackNumbers: [UInt64] = []
            for tracks in children where tracks.id == 0x1654AE6B {
                for entry in try elements(in: tracks.payload) where entry.id == 0xAE {
                    let fields = try elements(in: entry.payload)
                    guard let type = fields.first(where: { $0.id == 0x83 }),
                          let number = fields.first(where: { $0.id == 0xD7 }) else { throw ParseError.malformed }
                    if try unsignedInteger(in: type.payload) == 2 {
                        let trackNumber = try unsignedInteger(in: number.payload)
                        guard trackNumber > 0, !audioTrackNumbers.contains(trackNumber) else { throw ParseError.malformed }
                        audioTrackNumbers.append(trackNumber)
                    }
                }
            }
            guard !audioTrackNumbers.isEmpty else { throw ParseError.malformed }
            var paddingByTrack = Dictionary(uniqueKeysWithValues: audioTrackNumbers.map { ($0, [Int64]()) })
            for cluster in children where cluster.id == 0x1F43B675 {
                for element in try elements(in: cluster.payload) {
                    let block: Element
                    var padding: Int64 = 0
                    switch element.id {
                    case 0xA3:
                        block = element
                    case 0xA0:
                        let group = try elements(in: element.payload)
                        let blocks = group.filter { $0.id == 0xA1 }
                        let paddings = group.filter { $0.id == 0x75A2 }
                        guard blocks.count == 1, paddings.count <= 1 else { throw ParseError.malformed }
                        block = blocks[0]
                        if let discard = paddings.first {
                            padding = try signedInteger(in: discard.payload)
                            guard padding >= 0 else { throw ParseError.malformed }
                        }
                    default:
                        continue
                    }
                    var position = block.payload.lowerBound
                    let trackNumber = try vint(at: &position, limit: block.payload.upperBound, preserveMarker: false).value
                    guard block.payload.upperBound - position >= 4 else { throw ParseError.malformed }
                    guard paddingByTrack[trackNumber] != nil else { continue }
                    // FFmpeg writes one packet per block. Refuse lacing, which would otherwise
                    // make packet counts/padding ambiguous for the elementary packet parser.
                    guard data[position + 2] & 0x06 == 0 else { throw ParseError.malformed }
                    paddingByTrack[trackNumber, default: []].append(padding)
                }
            }
            return audioTrackNumbers.map { paddingByTrack[$0, default: []] }
        }

        private func elements(in range: Range<Int>) throws -> [Element] {
            var position = range.lowerBound
            var result: [Element] = []
            while position < range.upperBound {
                let id = try vint(at: &position, limit: range.upperBound, preserveMarker: true).value
                let size = try vint(at: &position, limit: range.upperBound, preserveMarker: false)
                let end: Int
                if size.isUnknown {
                    // The routed file is seekable and normally has finite sizes. Permit an
                    // unknown Segment size, but never consume siblings as an unknown child.
                    guard id == 0x18538067 else { throw ParseError.malformed }
                    end = range.upperBound
                } else {
                    guard size.value <= UInt64(range.upperBound - position) else { throw ParseError.malformed }
                    end = position + Int(size.value)
                }
                result.append(Element(id: id, payload: position..<end))
                position = end
            }
            return result
        }

        private func vint(at position: inout Int, limit: Int, preserveMarker: Bool) throws -> (value: UInt64, isUnknown: Bool) {
            guard position < limit, data[position] != 0 else { throw ParseError.malformed }
            let first = data[position]
            let width = first.leadingZeroBitCount + 1
            guard width <= (preserveMarker ? 4 : 8), width <= limit - position else { throw ParseError.malformed }
            let marker = UInt8(0x80 >> (width - 1))
            var value = UInt64(preserveMarker ? first : first & (marker - 1))
            for offset in 1..<width { value = value << 8 | UInt64(data[position + offset]) }
            position += width
            return (value, !preserveMarker && value == (UInt64(1) << (7 * width)) - 1)
        }

        private func unsignedInteger(in range: Range<Int>) throws -> UInt64 {
            guard (1...8).contains(range.count) else { throw ParseError.malformed }
            return range.reduce(UInt64(0)) { $0 << 8 | UInt64(data[$1]) }
        }

        private func signedInteger(in range: Range<Int>) throws -> Int64 {
            var bits = try unsignedInteger(in: range)
            if range.count < 8, data[range.lowerBound] & 0x80 != 0 {
                bits |= UInt64.max << (range.count * 8)
            }
            return Int64(bitPattern: bits)
        }
    }
}
