// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Planar YUV layout described by a YUV4MPEG2 stream header.
struct Y4MFormat: Equatable, Sendable {
    enum Interlacing: String, Sendable {
        case progressive = "p"
        case topFieldFirst = "t"
        case bottomFieldFirst = "b"
        case mixed = "m"
    }

    var width: Int
    var height: Int
    var frameRateNumerator: Int
    var frameRateDenominator: Int
    var interlacing: Interlacing
    var sampleAspectNumerator: Int
    var sampleAspectDenominator: Int
    /// Colour-space tag as written by FFmpeg, e.g. `420jpeg`, `422p10`, `444p16`.
    var colorSpaceTag: String
    var chromaShiftX: Int
    var chromaShiftY: Int
    var bitDepth: Int
    /// Remaining `X…` extension tokens (FFmpeg writes `XYSCSS=` and `XCOLORRANGE=`).
    var extensions: [String]

    var bytesPerSample: Int { bitDepth > 8 ? 2 : 1 }
    var maxSampleValue: Int { (1 << bitDepth) - 1 }

    func planeWidth(_ plane: Int) -> Int {
        plane == 0 ? width : (width + (1 << chromaShiftX) - 1) >> chromaShiftX
    }

    func planeHeight(_ plane: Int) -> Int {
        plane == 0 ? height : (height + (1 << chromaShiftY) - 1) >> chromaShiftY
    }

    func planeByteCount(_ plane: Int) -> Int {
        planeWidth(plane) * planeHeight(plane) * bytesPerSample
    }

    func planeByteOffset(_ plane: Int) -> Int {
        (0..<plane).reduce(0) { $0 + planeByteCount($1) }
    }

    var frameByteCount: Int { planeByteOffset(3) }

    /// Header for a progressive stream with the same layout at `frameRateMultiplier`
    /// times the frame rate.
    func headerLine(progressiveAtRateMultiplier frameRateMultiplier: Int) -> String {
        var numerator = frameRateNumerator * frameRateMultiplier
        var denominator = frameRateDenominator
        let divisor = Self.gcd(numerator, denominator)
        if divisor > 1 {
            numerator /= divisor
            denominator /= divisor
        }
        var tokens = [
            "YUV4MPEG2",
            "W\(width)",
            "H\(height)",
            "F\(numerator):\(denominator)",
            "Ip",
            "A\(sampleAspectNumerator):\(sampleAspectDenominator)",
            "C\(colorSpaceTag)",
        ]
        tokens += extensions
        return tokens.joined(separator: " ") + "\n"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case notYUV4MPEG
        case missingDimensions
        case unsupportedColorSpace(String)

        var errorDescription: String? {
            switch self {
            case .notYUV4MPEG:
                return "The decoder did not produce a YUV4MPEG2 stream"
            case .missingDimensions:
                return "The YUV4MPEG2 header has no frame size"
            case .unsupportedColorSpace(let tag):
                return "Unsupported YUV4MPEG2 colour space \(tag)"
            }
        }
    }

    init(headerLine: String) throws {
        let tokens = headerLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.first == "YUV4MPEG2" else { throw ParseError.notYUV4MPEG }
        var width: Int?
        var height: Int?
        var rate = (25, 1)
        var interlacing = Interlacing.progressive
        var aspect = (1, 1)
        var tag = "420jpeg"
        var extensions: [String] = []
        for token in tokens.dropFirst() {
            guard let key = token.first else { continue }
            let value = String(token.dropFirst())
            switch key {
            case "W": width = Int(value)
            case "H": height = Int(value)
            case "F": rate = Self.ratio(value) ?? rate
            case "I": interlacing = Interlacing(rawValue: value) ?? .progressive
            case "A":
                if let parsed = Self.ratio(value), parsed.0 > 0, parsed.1 > 0 { aspect = parsed }
            case "C": tag = value
            case "X": extensions.append(token)
            default: break
            }
        }
        guard let width, let height, width > 0, height > 0 else { throw ParseError.missingDimensions }
        guard let layout = Self.layout(forColorSpaceTag: tag) else { throw ParseError.unsupportedColorSpace(tag) }
        self.width = width
        self.height = height
        frameRateNumerator = rate.0
        frameRateDenominator = rate.1
        self.interlacing = interlacing
        sampleAspectNumerator = aspect.0
        sampleAspectDenominator = aspect.1
        colorSpaceTag = tag
        chromaShiftX = layout.shiftX
        chromaShiftY = layout.shiftY
        bitDepth = layout.bitDepth
        self.extensions = extensions
    }

    private static func ratio(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d != 0 else { return nil }
        return (n, d)
    }

    /// Planar YUV tags only; alpha and mono streams are not deinterlaced by QTGMC.
    static func layout(forColorSpaceTag tag: String) -> (shiftX: Int, shiftY: Int, bitDepth: Int)? {
        let lowered = tag.lowercased()
        let prefix = String(lowered.prefix(3))
        let shifts: (Int, Int)
        switch prefix {
        case "420": shifts = (1, 1)
        case "422": shifts = (1, 0)
        case "444": shifts = (0, 0)
        case "411": shifts = (2, 0)
        default: return nil
        }
        if lowered.hasPrefix("444alpha") { return nil }
        let rest = lowered.dropFirst(3)
        var depth = 8
        if rest.hasPrefix("p"), let parsed = Int(rest.dropFirst()), (9...16).contains(parsed) {
            depth = parsed
        } else if !rest.isEmpty, !["jpeg", "mpeg2", "paldv"].contains(String(rest)) {
            return nil
        }
        return (shifts.0, shifts.1, depth)
    }
}

/// Incremental YUV4MPEG2 reader: feed arbitrary chunks, receive whole frames.
struct Y4MReader {
    enum ReadError: Error, LocalizedError {
        case headerTooLong
        case malformedFrameHeader

        var errorDescription: String? {
            switch self {
            case .headerTooLong: return "The YUV4MPEG2 header is too long"
            case .malformedFrameHeader: return "The decoder produced a malformed YUV4MPEG2 frame"
            }
        }
    }

    private(set) var format: Y4MFormat?
    private var buffer: [UInt8] = []
    private var offset = 0

    init() {}

    /// Appends `data` and calls `frame` for every complete frame. The bytes passed to
    /// `frame` are only valid during the call.
    mutating func consume(_ data: Data, frame: (Y4MFormat, UnsafeRawBufferPointer) throws -> Void) throws {
        buffer.append(contentsOf: data)
        defer { compact() }
        while true {
            guard let newline = firstNewline(from: offset) else {
                if buffer.count - offset > 4096 {
                    throw format == nil ? ReadError.headerTooLong : ReadError.malformedFrameHeader
                }
                return
            }
            guard let format else {
                let line = String(decoding: buffer[offset..<newline], as: UTF8.self)
                format = try Y4MFormat(headerLine: line)
                offset = newline + 1
                continue
            }
            let frameStart = newline + 1
            guard buffer.count - frameStart >= format.frameByteCount else { return }
            guard newline - offset >= 5, buffer[offset..<offset + 5].elementsEqual("FRAME".utf8) else {
                throw ReadError.malformedFrameHeader
            }
            try buffer.withUnsafeBytes { raw in
                let start = raw.baseAddress!.advanced(by: frameStart)
                try frame(format, UnsafeRawBufferPointer(start: start, count: format.frameByteCount))
            }
            offset = frameStart + format.frameByteCount
        }
    }

    /// Bytes left over that do not form a complete frame.
    var pendingByteCount: Int { buffer.count - offset }

    private func firstNewline(from start: Int) -> Int? {
        guard start < buffer.count else { return nil }
        return buffer[start...].firstIndex(of: 0x0A)
    }

    private mutating func compact() {
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 0, offset >= buffer.count / 2 {
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
    }
}

enum Y4MWriter {
    static let frameMarker = Data("FRAME\n".utf8)
}
