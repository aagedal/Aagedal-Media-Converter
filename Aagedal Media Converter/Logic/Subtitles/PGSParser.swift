// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import AppKit

/// A decoded subtitle frame with timing and PNG image data
struct SubtitleFrame: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let imageData: Data  // PNG bytes

    /// Intersect source timestamps with the exported interval, then rebase to zero.
    func clipped(to range: AnalyticsSourceRange) -> SubtitleFrame? {
        guard range.isValid, startTime.isFinite, endTime.isFinite else { return nil }
        let start = max(startTime, range.start)
        let end = min(endTime, range.end ?? endTime)
        guard end > start else { return nil }
        return SubtitleFrame(startTime: start - range.start, endTime: end - range.start, imageData: imageData)
    }
}

/// Parses binary PGS (.sup) files from Blu-ray sources into subtitle frames.
///
/// PGS format reference:
/// https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/
enum PGSParser {

    // Segment type codes
    private static let kPDS: UInt8 = 0x14  // Palette Definition Segment
    private static let kODS: UInt8 = 0x15  // Object Definition Segment
    private static let kPCS: UInt8 = 0x16  // Presentation Composition Segment
    private static let kWDS: UInt8 = 0x17  // Window Definition Segment
    private static let kEND: UInt8 = 0x80  // End of Display Set

    // PCS composition state
    private static let kEpochStart: UInt8 = 0x80

    // ODS sequence flags
    private static let kODSFirstAndLast: UInt8 = 0xC0
    private static let kODSFirst: UInt8 = 0x80
    private static let kODSLast: UInt8 = 0x40

    // PGS segment header magic
    private static let kMagic: UInt16 = 0x5047  // "PG"

    /// Parses a PGS .sup file and returns a list of subtitle frames.
    /// - Parameter supData: Raw bytes of the .sup file
    /// - Returns: Array of decoded subtitle frames with timing and PNG image data
    static func parse(supData: Data) throws -> [SubtitleFrame] {
        var frames: [SubtitleFrame] = []
        var offset = 0

        // Per-display-set state
        var currentPTS: TimeInterval = 0
        var palette: [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = [:]
        var objectData: Data = Data()
        var objectWidth: Int = 0
        var objectHeight: Int = 0
        var pendingStartTime: TimeInterval? = nil

        while offset + 13 <= supData.count {
            // Read 2-byte magic
            let magic = readUInt16BE(supData, at: offset)
            guard magic == kMagic else {
                // Try to resync
                offset += 1
                continue
            }

            // PTS (4 bytes, 90kHz clock)
            let pts = readUInt32BE(supData, at: offset + 2)
            // DTS (4 bytes) - skip
            let segType = supData[offset + 10]
            let segLen = Int(readUInt16BE(supData, at: offset + 11))
            let headerSize = 13
            let segStart = offset + headerSize
            let segEnd = segStart + segLen

            guard segEnd <= supData.count else { break }

            let segData = supData[segStart..<segEnd]
            let timeSeconds = TimeInterval(pts) / 90000.0

            switch segType {
            case kPCS:
                currentPTS = timeSeconds
                // Parse PCS to determine if this is an epoch start (new subtitle)
                // or a clear (end of subtitle)
                if segData.count >= 11 {
                    let base = segData.startIndex
                    let numObjects = segData[base + 10]
                    let compositionState = segData[base + 7]

                    if numObjects == 0 {
                        // Clear display — record end time and save frame
                        if let startTime = pendingStartTime,
                           !objectData.isEmpty,
                           objectWidth > 0,
                           objectHeight > 0 {
                            if let png = renderToPNG(
                                rleData: objectData,
                                width: objectWidth,
                                height: objectHeight,
                                palette: palette
                            ) {
                                let frame = SubtitleFrame(
                                    startTime: startTime,
                                    endTime: currentPTS,
                                    imageData: png
                                )
                                frames.append(frame)
                            }
                            pendingStartTime = nil
                            objectData = Data()
                            objectWidth = 0
                            objectHeight = 0
                        }
                    } else if compositionState == kEpochStart || pendingStartTime == nil {
                        // New subtitle starting
                        pendingStartTime = currentPTS
                        // Reset object buffer for new display set
                        objectData = Data()
                        objectWidth = 0
                        objectHeight = 0
                        palette = [:]
                    }
                }

            case kPDS:
                // Palette Definition Segment — each entry is 5 bytes: id Y Cr Cb alpha
                parsePalette(segData, into: &palette)

            case kODS:
                // Object Definition Segment — RLE-compressed image
                parseODS(segData, objectData: &objectData, width: &objectWidth, height: &objectHeight)

            case kEND:
                // End of Display Set — if we have a pending start with object data,
                // emit the frame. End time will be updated when a clear PCS arrives.
                // (Some encoders use PTS on END segments for timing.)
                break

            default:
                break
            }

            offset = segEnd
        }

        // Handle any trailing frame where no clear PCS was emitted
        // (rare but possible in malformed files — skip)

        return frames
    }

    // MARK: - Segment Parsers

    private static func parsePalette(
        _ data: Data,
        into palette: inout [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
    ) {
        // First 2 bytes: palette ID and version — skip
        var i = data.startIndex + 2
        while i + 4 < data.endIndex {
            let entryID = data[i]
            let y  = Int(data[i + 1])
            let cr = Int(data[i + 2])
            let cb = Int(data[i + 3])
            let alpha = data[i + 4]

            // YCbCr → RGB (BT.601)
            let r = clampUInt8(y + Int(1.402  * Double(cr - 128)))
            let g = clampUInt8(y - Int(0.3441 * Double(cb - 128)) - Int(0.7141 * Double(cr - 128)))
            let b = clampUInt8(y + Int(1.772  * Double(cb - 128)))

            palette[entryID] = (r: r, g: g, b: b, a: alpha)
            i += 5
        }
    }

    private static func parseODS(
        _ data: Data,
        objectData: inout Data,
        width: inout Int,
        height: inout Int
    ) {
        // ODS layout:
        //  0-1: Object ID
        //  2:   Version number
        //  3:   Last in sequence flag
        //  4-6: Object data length (3 bytes, big-endian)
        //  7-8: Width
        //  9-10: Height
        //  11+: RLE data (for first/only segment)
        //
        // For continuation segments (not first), data starts at offset 4.
        guard data.count >= 4 else { return }

        let flag = data[data.startIndex + 3]
        let isFirst = (flag & kODSFirst) != 0 || flag == kODSFirstAndLast

        if isFirst {
            guard data.count >= 11 else { return }
            let base = data.startIndex
            width  = Int(readUInt16BE(data, at: base + 7))
            height = Int(readUInt16BE(data, at: base + 9))
            objectData = Data(data[(base + 11)...])
        } else {
            // Continuation segment — append RLE data starting at offset 4
            let base = data.startIndex + 4
            if base < data.endIndex {
                objectData.append(contentsOf: data[base...])
            }
        }
    }

    // MARK: - RLE Decoder + PNG Renderer

    /// Decodes PGS RLE data and renders to a PNG image.
    private static func renderToPNG(
        rleData: Data,
        width: Int,
        height: Int,
        palette: [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }

        // Decode RLE into a flat RGBA pixel buffer
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var pixelIndex = 0
        var linePixelCount = 0

        var i = rleData.startIndex
        while i < rleData.endIndex && pixelIndex < pixels.count {
            let byte = rleData[i]
            i += 1

            if byte != 0x00 {
                // Literal pixel
                writePixel(byte, palette: palette, into: &pixels, at: pixelIndex)
                pixelIndex += 4
                linePixelCount += 1
            } else {
                // Escape sequence
                guard i < rleData.endIndex else { break }
                let control = rleData[i]
                i += 1

                if control == 0x00 {
                    // End of line — advance to next row start
                    let remaining = width - linePixelCount
                    pixelIndex = max(0, pixelIndex + remaining * 4)
                    linePixelCount = 0
                } else {
                    let topBits = control & 0xC0
                    let lower6 = Int(control & 0x3F)

                    switch topBits {
                    case 0x00:
                        // Short run of color 0 (transparent)
                        let count = lower6
                        for _ in 0..<count {
                            writePixel(0, palette: palette, into: &pixels, at: pixelIndex)
                            pixelIndex += 4
                        }
                        linePixelCount += count

                    case 0x40:
                        // Long run of color 0
                        guard i < rleData.endIndex else { break }
                        let ext = Int(rleData[i]); i += 1
                        let count = (lower6 << 8) | ext
                        for _ in 0..<count {
                            writePixel(0, palette: palette, into: &pixels, at: pixelIndex)
                            pixelIndex += 4
                        }
                        linePixelCount += count

                    case 0x80:
                        // Short run of specified color
                        guard i < rleData.endIndex else { break }
                        let color = rleData[i]; i += 1
                        let count = lower6
                        for _ in 0..<count {
                            writePixel(color, palette: palette, into: &pixels, at: pixelIndex)
                            pixelIndex += 4
                        }
                        linePixelCount += count

                    case 0xC0:
                        // Long run of specified color
                        guard i + 1 < rleData.endIndex else { break }
                        let ext   = Int(rleData[i]); i += 1
                        let color = rleData[i]; i += 1
                        let count = (lower6 << 8) | ext
                        for _ in 0..<count {
                            writePixel(color, palette: palette, into: &pixels, at: pixelIndex)
                            pixelIndex += 4
                        }
                        linePixelCount += count

                    default:
                        break
                    }
                }
            }
        }

        // Build CGImage from the RGBA pixel buffer
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    @inline(__always)
    private static func writePixel(
        _ colorIndex: UInt8,
        palette: [UInt8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)],
        into pixels: inout [UInt8],
        at index: Int
    ) {
        guard index >= 0, index + 3 < pixels.count else { return }
        if let entry = palette[colorIndex] {
            pixels[index]     = entry.r
            pixels[index + 1] = entry.g
            pixels[index + 2] = entry.b
            pixels[index + 3] = entry.a
        }
        // If no palette entry: leave as transparent (zeroes)
    }

    // MARK: - Binary Helpers

    @inline(__always)
    private static func readUInt16BE(_ data: Data, at index: Data.Index) -> UInt16 {
        guard index + 1 < data.endIndex else { return 0 }
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    @inline(__always)
    private static func readUInt32BE(_ data: Data, at index: Data.Index) -> UInt32 {
        guard index + 3 < data.endIndex else { return 0 }
        return (UInt32(data[index]) << 24) |
               (UInt32(data[index + 1]) << 16) |
               (UInt32(data[index + 2]) << 8) |
                UInt32(data[index + 3])
    }

    @inline(__always)
    private static func clampUInt8(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }
}
