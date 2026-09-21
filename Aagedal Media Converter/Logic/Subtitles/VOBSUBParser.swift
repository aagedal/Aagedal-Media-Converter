// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import AppKit

/// Parses VOBSUB subtitle files (.idx + .sub) from DVD sources into subtitle frames.
///
/// The .idx file contains timing metadata and a 16-colour palette.
/// The .sub file is an MPEG-PS stream containing subtitle packets with RLE-encoded images.
enum VOBSUBParser {

    // MARK: - Public API

    /// Parses a VOBSUB subtitle pair and returns decoded subtitle frames.
    /// - Parameters:
    ///   - idxURL: Path to the .idx file
    ///   - subURL: Path to the .sub file
    /// - Returns: Array of decoded SubtitleFrame values
    static func parse(idxURL: URL, subURL: URL) throws -> [SubtitleFrame] {
        let idxText = try String(contentsOf: idxURL, encoding: .utf8)
        let subData = try Data(contentsOf: subURL)

        let palette = parsePalette(from: idxText)
        let entries = parseIDXEntries(from: idxText)

        return try decodeFrames(subData: subData, palette: palette, entries: entries)
    }

    /// Reads the selected DVD subtitle stream from FFmpeg’s MPEG-2 program stream.
    /// The separately dumped codec header retains the original RGB palette.
    static func parse(programStreamURL: URL, paletteURL: URL) throws -> [SubtitleFrame] {
        let data = try Data(contentsOf: programStreamURL)
        let header = try String(contentsOf: paletteURL, encoding: .utf8)
        var entries: [IDXEntry] = []
        var offset = 0
        var previousTicks: Int64?
        var unwrappedTicks: Int64 = 0
        let timestampPeriod: Int64 = 1 << 33
        while offset + 4 <= data.count {
            try Task.checkCancellation()
            guard data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 1 else {
                offset += 1
                continue
            }
            let streamID = data[offset + 3]
            if streamID == 0xBA {
                guard offset + 14 <= data.count, data[offset + 4] & 0xC0 == 0x40 else { break }
                offset += 14 + Int(data[offset + 13] & 7)
                continue
            }
            if streamID == 0xB9 { break }
            guard offset + 6 <= data.count else { break }
            let start = offset + 6
            let end = start + Int(readUInt16BE(data, at: offset + 4))
            guard end <= data.count else { break }
            if streamID == 0xBD, start + 8 <= end,
               data[start] & 0xC0 == 0x80, data[start + 1] & 0x80 != 0,
               data[start + 2] >= 5 {
                let payload = start + 3 + Int(data[start + 2])
                if payload < end, data[payload] & 0xE0 == 0x20 {
                    let pts = start + 3
                    guard data[pts] & 1 == 1, data[pts + 2] & 1 == 1,
                          data[pts + 4] & 1 == 1 else { break }
                    let ticks = (UInt64(data[pts] & 0x0E) << 29)
                        | (UInt64(data[pts + 1]) << 22)
                        | (UInt64(data[pts + 2] & 0xFE) << 14)
                        | (UInt64(data[pts + 3]) << 7)
                        | UInt64(data[pts + 4] >> 1)
                    let rawTicks = Int64(ticks)
                    if let previousTicks {
                        // Resolve the nearest timestamp across the 33-bit PES clock wrap.
                        // Small backward steps remain backward steps, not a new epoch.
                        var delta = rawTicks - previousTicks
                        if delta < -timestampPeriod / 2 { delta += timestampPeriod }
                        if delta > timestampPeriod / 2 { delta -= timestampPeriod }
                        unwrappedTicks += delta
                    } else {
                        unwrappedTicks = rawTicks
                    }
                    previousTicks = rawTicks
                    entries.append(IDXEntry(timestampMs: Int(unwrappedTicks / 90), offset: offset))
                }
            }
            offset = end
        }
        return try decodeFrames(subData: data, palette: parsePalette(from: header), entries: entries)
    }

    private static func decodeFrames(
        subData: Data, palette: [(r: UInt8, g: UInt8, b: UInt8)], entries: [IDXEntry]
    ) throws -> [SubtitleFrame] {
        var frames: [SubtitleFrame] = []

        for (idx, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let nextOffset = idx + 1 < entries.count ? entries[idx + 1].offset : subData.count
            let packet = extractSubtitlePacket(from: subData, at: entry.offset, end: nextOffset)
            guard let packet else { continue }

            guard let (image, startMs, stopMs) = decodeSubtitlePacket(packet, palette: palette) else { continue }
            guard let pngData = image.pngData() else { continue }

            let startTime = Double(entry.timestampMs + startMs) / 1000.0
            let endTime: TimeInterval
            if let stopMs, stopMs > startMs {
                endTime = Double(entry.timestampMs + stopMs) / 1000.0
            } else if idx + 1 < entries.count {
                // Use next subtitle's start time as end time
                endTime = Double(entries[idx + 1].timestampMs) / 1000.0
            } else {
                endTime = startTime + 3.0 // Fallback: 3 seconds
            }

            frames.append(SubtitleFrame(startTime: startTime, endTime: endTime, imageData: pngData))
        }

        return frames
    }

    // MARK: - IDX Parsing

    private struct IDXEntry {
        let timestampMs: Int
        let offset: Int
    }

    private static func parsePalette(from idxText: String) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        // Look for: palette: RRGGBB, RRGGBB, ...
        let pattern = #"palette:\s*((?:[0-9a-fA-F]{6},?\s*)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: idxText, range: NSRange(idxText.startIndex..., in: idxText)),
              let range = Range(match.range(at: 1), in: idxText) else {
            return []
        }
        let colorList = String(idxText[range])
        return colorList
            .components(separatedBy: ",")
            .compactMap { hex -> (r: UInt8, g: UInt8, b: UInt8)? in
                let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
                return (
                    r: UInt8((value >> 16) & 0xFF),
                    g: UInt8((value >> 8) & 0xFF),
                    b: UInt8(value & 0xFF)
                )
            }
    }

    private static func parseIDXEntries(from idxText: String) -> [IDXEntry] {
        // Timestamp lines: timestamp: HH:MM:SS:mmm, filepos: XXXXXXXX
        let pattern = #"timestamp:\s*(\d{2}):(\d{2}):(\d{2}):(\d{3}),\s*filepos:\s*([0-9a-fA-F]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = idxText as NSString
        let matches = regex.matches(in: idxText, range: NSRange(location: 0, length: nsText.length))

        return matches.compactMap { match -> IDXEntry? in
            guard match.numberOfRanges >= 6 else { return nil }
            let h  = Int(nsText.substring(with: match.range(at: 1))) ?? 0
            let m  = Int(nsText.substring(with: match.range(at: 2))) ?? 0
            let s  = Int(nsText.substring(with: match.range(at: 3))) ?? 0
            let ms = Int(nsText.substring(with: match.range(at: 4))) ?? 0
            let offsetHex = nsText.substring(with: match.range(at: 5))
            guard let offset = Int(offsetHex, radix: 16) else { return nil }

            let totalMs = (h * 3600 + m * 60 + s) * 1000 + ms
            return IDXEntry(timestampMs: totalMs, offset: offset)
        }
    }

    // MARK: - MPEG-PS Packet Extraction

    /// Extracts the raw subtitle data bytes from a single MPEG-PS private stream packet.
    private static func extractSubtitlePacket(from data: Data, at start: Int, end: Int) -> Data? {
        let limit = min(end, data.count)
        guard start >= 0, start < limit else { return nil }
        var offset = start
        var subtitleData = Data()
        var subtitleStream: UInt8?
        while offset + 4 <= limit {
            guard data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 1 else {
                offset += 1
                continue
            }
            let streamID = data[offset + 3]
            if streamID == 0xBA {
                // Pack headers have no PES length field. DVD uses the MPEG-2 form.
                guard offset + 14 <= limit, data[offset + 4] & 0xC0 == 0x40 else { return nil }
                offset += 14 + Int(data[offset + 13] & 7)
                continue
            }
            if streamID == 0xB9 { break }
            guard offset + 6 <= limit else { return nil }
            let packetLen = Int(readUInt16BE(data, at: offset + 4))
            let packetStart = offset + 6
            let packetEnd = packetStart + packetLen
            guard packetEnd <= limit else { return nil }
            offset = packetEnd
            guard streamID == 0xBD else { continue }
            guard packetLen >= 4 else { return nil }
            let dataStart = packetStart + 3 + Int(data[packetStart + 2])
            guard dataStart < packetEnd else { return nil }
            let subStreamID = data[dataStart]
            guard subStreamID & 0xE0 == 0x20 else { continue }
            if let subtitleStream, subtitleStream != subStreamID { continue }
            subtitleStream = subStreamID
            subtitleData.append(contentsOf: data[(dataStart + 1)..<packetEnd])
            if subtitleData.count >= 2 {
                let size = Int(readUInt16BE(subtitleData, at: 0))
                if size >= 4, subtitleData.count >= size {
                    return Data(subtitleData.prefix(size))
                }
            }
        }
        return nil
    }

    // MARK: - Subtitle Packet Decoder

    /// Decodes a raw VOBSUB subtitle packet into an image and display duration.
    private static func decodeSubtitlePacket(
        _ data: Data,
        palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> (CGImage, startMs: Int, stopMs: Int?)? {
        guard data.count >= 4 else { return nil }

        // Packet structure:
        //   2 bytes: packet size (big-endian)
        //   2 bytes: offset to control sequence
        //   N bytes: RLE image data (two fields interleaved)
        //   M bytes: control sequence

        let packetSize = Int(readUInt16BE(data, at: 0))
        let controlOffset = Int(readUInt16BE(data, at: 2))
        guard packetSize <= data.count, controlOffset >= 4, controlOffset + 4 <= packetSize else { return nil }

        // Parse control sequence to get dimensions, colors, display duration
        var width = 0
        var height = 0
        var field1Offset = -1
        var field2Offset = -1
        var startMs = 0
        var stopMs: Int?
        var colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = [:]
        // Color and contrast commands update independent DVD subtitle state.
        // Keep alpha even when its command precedes the first palette selection.
        var alphaValues = [UInt8](repeating: 255, count: 4)

        var ctrlOff = controlOffset
        while ctrlOff + 4 <= packetSize {
            let blockStart = ctrlOff
            // DVD command dates use 1024 ticks of the 90 kHz clock.
            let displayTime = Int(readUInt16BE(data, at: ctrlOff)) * 1024 / 90
            let nextBlock = Int(readUInt16BE(data, at: ctrlOff + 2))
            ctrlOff += 4

            var done = false
            while !done && ctrlOff < packetSize {
                let cmd = data[ctrlOff]
                ctrlOff += 1
                switch cmd {
                case 0x00:
                    // Force display
                    break
                case 0x01:
                    // Start display time
                    startMs = displayTime
                case 0x02:
                    // Stop display time
                    stopMs = displayTime
                case 0x03:
                    // Set color indices (4 indices into subtitle palette)
                    guard ctrlOff + 2 <= packetSize else { return nil }
                    let b0 = Int(data[ctrlOff]); ctrlOff += 1
                    let b1 = Int(data[ctrlOff]); ctrlOff += 1
                    // Map subtitle color indices 3,2,1,0 to palette entries
                    for k in 0..<4 {
                        let palIdx: Int
                        if k < 2 {
                            palIdx = (b1 >> (k * 4)) & 0x0F
                        } else {
                            palIdx = (b0 >> ((k - 2) * 4)) & 0x0F
                        }
                        if palIdx < palette.count {
                            let p = palette[palIdx]
                            colorMap[k] = (r: p.r, g: p.g, b: p.b, a: alphaValues[k])
                        }
                    }
                case 0x04:
                    // Set alpha values (4 values)
                    guard ctrlOff + 2 <= packetSize else { return nil }
                    let a0 = Int(data[ctrlOff]); ctrlOff += 1
                    let a1 = Int(data[ctrlOff]); ctrlOff += 1
                    for k in 0..<4 {
                        let alpha: UInt8
                        if k < 2 {
                            alpha = UInt8(((a1 >> (k * 4)) & 0x0F) * 17)
                        } else {
                            alpha = UInt8(((a0 >> ((k - 2) * 4)) & 0x0F) * 17)
                        }
                        alphaValues[k] = alpha
                        if var entry = colorMap[k] {
                            entry.a = alpha
                            colorMap[k] = entry
                        }
                    }
                case 0x05:
                    // Set display area: x1,x2,y1,y2 packed in 6 bytes
                    guard ctrlOff + 6 <= packetSize else { return nil }
                    let x1 = (Int(data[ctrlOff]) << 4) | (Int(data[ctrlOff + 1]) >> 4)
                    let x2 = ((Int(data[ctrlOff + 1]) & 0x0F) << 8) | Int(data[ctrlOff + 2])
                    let y1 = (Int(data[ctrlOff + 3]) << 4) | (Int(data[ctrlOff + 4]) >> 4)
                    let y2 = ((Int(data[ctrlOff + 4]) & 0x0F) << 8) | Int(data[ctrlOff + 5])
                    ctrlOff += 6
                    width  = x2 - x1 + 1
                    height = y2 - y1 + 1
                case 0x06:
                    // Set pixel data offsets (field 1 and field 2)
                    guard ctrlOff + 4 <= packetSize else { return nil }
                    field1Offset = Int(readUInt16BE(data, at: ctrlOff)); ctrlOff += 2
                    field2Offset = Int(readUInt16BE(data, at: ctrlOff)); ctrlOff += 2
                case 0xFF:
                    // End of control sequence
                    done = true
                default:
                    // Unsupported commands must not be interpreted as bitmap data.
                    return nil
                }
            }

            guard done else { return nil }
            if nextBlock == blockStart { break }
            guard nextBlock >= ctrlOff, nextBlock + 4 <= packetSize else { return nil }
            ctrlOff = nextBlock
        }

        guard width > 0, height > 0,
              field1Offset >= 4, field1Offset < controlOffset,
              (height == 1 || (field2Offset >= 4 && field2Offset < controlOffset)) else { return nil }

        // Decode two interlaced fields into a full RGBA image
        guard let pixels = decodeRLE(
            data: Data(data.prefix(controlOffset)),
            field1Offset: field1Offset,
            field2Offset: field2Offset,
            width: width,
            height: height,
            colorMap: colorMap
        ) else { return nil }

        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        return (cgImage, startMs, stopMs)
    }

    // MARK: - VOBSUB RLE Decoder

    /// Decodes VOBSUB 2-bit RLE into an RGBA pixel buffer.
    /// VOBSUB images are stored as two interlaced fields (even lines = field 1, odd lines = field 2).
    private static func decodeRLE(
        data: Data,
        field1Offset: Int,
        field2Offset: Int,
        width: Int,
        height: Int,
        colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard decodeField(
            data: data, startOffset: field1Offset,
            width: width, height: height, startLine: 0, step: 2,
            colorMap: colorMap, into: &pixels
        ) else { return nil }
        guard decodeField(
            data: data, startOffset: field2Offset,
            width: width, height: height, startLine: 1, step: 2,
            colorMap: colorMap, into: &pixels
        ) else { return nil }

        return pixels
    }

    private static func decodeField(
        data: Data,
        startOffset: Int,
        width: Int,
        height: Int,
        startLine: Int,
        step: Int,
        colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)],
        into pixels: inout [UInt8]
    ) -> Bool {
        var byteOffset = startOffset
        var bitPos = 0  // next bit to read within current byte (0 = MSB)
        var line = startLine

        func readBits(_ n: Int) -> Int? {
            var result = 0
            for _ in 0..<n {
                guard byteOffset >= 0, byteOffset < data.count else { return nil }
                let byte = Int(data[byteOffset])
                let bit = (byte >> (7 - bitPos)) & 1
                result = (result << 1) | bit
                bitPos += 1
                if bitPos == 8 { bitPos = 0; byteOffset += 1 }
            }
            return result
        }

        while line < height {
            var col = 0
            while col < width {
                // Each code has one to four nibbles; its low two bits are color.
                guard var code = readBits(4) else { return false }
                for threshold in [4, 16, 64] {
                    if code < threshold {
                        guard let nibble = readBits(4) else { return false }
                        code = (code << 4) | nibble
                    } else {
                        break
                    }
                }
                let color = code & 3
                let runLength = code < 4 ? width - col : code >> 2
                guard runLength <= width - col else { return false }

                let entry = colorMap[color]
                for _ in 0..<runLength {
                    if col >= width { break }
                    let pixelIdx = (line * width + col) * 4
                    if let c = entry {
                        pixels[pixelIdx]     = UInt8(Int(c.r) * Int(c.a) / 255)
                        pixels[pixelIdx + 1] = UInt8(Int(c.g) * Int(c.a) / 255)
                        pixels[pixelIdx + 2] = UInt8(Int(c.b) * Int(c.a) / 255)
                        pixels[pixelIdx + 3] = c.a
                    }
                    col += 1
                }
            }
            // Align to byte boundary between lines
            if bitPos != 0 { bitPos = 0; byteOffset += 1 }
            line += step
        }
        return true
    }

    // MARK: - Helpers

    @inline(__always)
    private static func readUInt16BE(_ data: Data, at index: Int) -> UInt16 {
        guard index + 1 < data.count else { return 0 }
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }
}

// MARK: - PNG helper

private extension CGImage {
    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}
