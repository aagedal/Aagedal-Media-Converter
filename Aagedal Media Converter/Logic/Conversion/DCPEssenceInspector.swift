// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Minimal read-only MXF (SMPTE ST 377-1) reader for AS-DCP essence: enough of the header
/// metadata to cross-check a CPL, plus per-frame sizes from the essence KLVs.
struct MXFEssenceInfo: Sendable {
    enum Kind: Sendable { case picture, sound, other }

    var kind: Kind = .other
    /// AssetUUID: the material number of the file (source) package UMID.
    var assetUUID: String?
    var editRate: (numerator: Int, denominator: Int)?
    var containerDuration: Int?
    var storedWidth: Int?
    var storedHeight: Int?
    var audioSampleRate: Int?
    var channelCount: Int?
    var quantizationBits: Int?
    var hasMCALabels = false
    var isEncrypted = false
    /// Byte ranges of each essence element's value, in file order.
    var frameRanges: [Range<UInt64>] = []

    var maxFrameSize: Int { frameRanges.map { Int($0.upperBound - $0.lowerBound) }.max() ?? 0 }
}

enum MXFReaderError: LocalizedError {
    case notMXF
    case truncated

    var errorDescription: String? {
        switch self {
        case .notMXF: return "Not an MXF file (no header partition pack)"
        case .truncated: return "MXF file is truncated"
        }
    }
}

enum MXFReader {
    private static let ulPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34]
    private static let encryptedTripletKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x04, 0x01, 0x07,
                                                      0x0D, 0x01, 0x03, 0x01, 0x02, 0x7E, 0x01, 0x00]

    static func read(url: URL) throws -> MXFEssenceInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        var info = MXFEssenceInfo()
        var offset: UInt64 = 0
        var sawHeaderPartition = false

        while offset + 17 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let head = try handle.read(upToCount: 25), head.count >= 17 else { break }
            let key = [UInt8](head.prefix(16))
            guard key.starts(with: ulPrefix) else { throw MXFReaderError.notMXF }
            guard let (length, lengthSize) = berLength(Array(head.dropFirst(16))) else { throw MXFReaderError.truncated }
            let valueStart = offset + 16 + UInt64(lengthSize)
            let valueEnd = valueStart + length
            guard valueEnd <= fileSize else { throw MXFReaderError.truncated }

            if !sawHeaderPartition {
                // Header partition pack: 06.0e.2b.34.02.05.01.01.0d.01.02.01.01.02.xx
                guard key[4] == 0x02, key[5] == 0x05, key[12] == 0x01, key[13] == 0x02 else {
                    throw MXFReaderError.notMXF
                }
                sawHeaderPartition = true
            } else if key == encryptedTripletKey {
                info.isEncrypted = true
                info.frameRanges.append(valueStart..<valueEnd)
            } else if key[4] == 0x01, key[8] == 0x0D, key[9] == 0x01, key[10] == 0x03, key[11] == 0x01,
                      key[12] == 0x15 || key[12] == 0x16 {
                // Generic container essence element: 0x15 picture, 0x16 sound.
                info.frameRanges.append(valueStart..<valueEnd)
            } else if key[4] == 0x02, key[5] == 0x53, length < 1_000_000 {
                try handle.seek(toOffset: valueStart)
                let value = try handle.read(upToCount: Int(length)) ?? Data()
                parseLocalSet(key: key, value: [UInt8](value), into: &info)
            }
            offset = valueEnd
        }

        guard sawHeaderPartition else { throw MXFReaderError.notMXF }
        if info.storedWidth != nil {
            info.kind = .picture
        } else if info.audioSampleRate != nil || info.channelCount != nil {
            info.kind = .sound
        }
        return info
    }

    static func berLength(_ bytes: [UInt8]) -> (UInt64, Int)? {
        guard let first = bytes.first else { return nil }
        if first < 0x80 { return (UInt64(first), 1) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 8, bytes.count > count else { return nil }
        let value = bytes[1...count].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (value, count + 1)
    }

    /// Local sets use 2-byte static tags; only the static tags we need are read.
    private static func parseLocalSet(key: [UInt8], value: [UInt8], into info: inout MXFEssenceInfo) {
        let setType = key[13] == 0x01 ? key[14] : 0
        // 0x6B AudioChannelLabel, 0x6C SoundfieldGroupLabel, 0x6D GroupOfSoundfieldGroupsLabel
        if [0x6B, 0x6C, 0x6D].contains(setType) {
            info.hasMCALabels = true
        }
        var tags: [UInt16: ArraySlice<UInt8>] = [:]
        var index = 0
        while index + 4 <= value.count {
            let tag = UInt16(value[index]) << 8 | UInt16(value[index + 1])
            let length = Int(value[index + 2]) << 8 | Int(value[index + 3])
            let start = index + 4
            guard start + length <= value.count else { break }
            tags[tag] = value[start..<(start + length)]
            index = start + length
        }

        // Source package (0x37): PackageUID UMID, whose last 16 bytes are the AssetUUID.
        if setType == 0x37, let umid = tags[0x4401], umid.count == 32 {
            info.assetUUID = uuidString(Array(umid.suffix(16)))
        }
        // File descriptors carry ContainerDuration alongside SampleRate (the edit rate).
        if tags[0x3002] != nil || tags[0x3203] != nil || tags[0x3D03] != nil {
            if let duration = tags[0x3002].flatMap(integer) { info.containerDuration = duration }
            if let rate = tags[0x3001].flatMap(rational) { info.editRate = rate }
        }
        if let width = tags[0x3203].flatMap(integer) { info.storedWidth = width }
        if let height = tags[0x3202].flatMap(integer) { info.storedHeight = height }
        if let rate = tags[0x3D03].flatMap(rational), rate.denominator != 0 {
            info.audioSampleRate = rate.numerator / rate.denominator
        }
        if let channels = tags[0x3D07].flatMap(integer) { info.channelCount = channels }
        if let bits = tags[0x3D01].flatMap(integer) { info.quantizationBits = bits }
    }

    private static func integer(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return Int(truncatingIfNeeded: bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    private static func rational(_ bytes: ArraySlice<UInt8>) -> (numerator: Int, denominator: Int)? {
        guard bytes.count == 8,
              let numerator = integer(bytes.prefix(4)),
              let denominator = integer(bytes.suffix(4)) else { return nil }
        return (numerator, denominator)
    }

    static func uuidString(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }
}

/// Main-header summary of a JPEG 2000 codestream (ISO 15444-1), as checked by libdcp.
struct J2KCodestreamInfo: Equatable, Sendable {
    var rsiz: Int = 0
    var width: Int = 0
    var height: Int = 0
    var tileWidth: Int = 0
    var tileHeight: Int = 0
    var components: Int = 0
    var bitDepth: Int = 0
    var progressionOrder: Int = -1
    var layers: Int = 0
    var decompositionLevels: Int = 0
    var codeBlockWidth: Int = 0
    var codeBlockHeight: Int = 0
    var guardBits: Int = 0
    var hasTLM = false
    var hasPOC = false
    var tileParts = 0

    static let cprl = 4

    /// Parses the main header and walks tile-part headers (via Psot) to count tile parts.
    static func parse(_ data: Data) -> J2KCodestreamInfo? {
        let bytes = [UInt8](data)
        guard let soc = firstIndex(of: [0xFF, 0x4F, 0xFF, 0x51], in: bytes) else { return nil }
        var info = J2KCodestreamInfo()
        var position = soc + 2

        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }

        // Main header markers until the first SOT.
        while position + 4 <= bytes.count {
            let marker = u16(position)
            if marker == 0xFF90 { break }
            let length = u16(position + 2)
            let segment = position + 4
            guard length >= 2, position + 2 + length <= bytes.count else { return nil }
            switch marker {
            case 0xFF51 where length >= 41:
                info.rsiz = u16(segment)
                info.width = u32(segment + 2) - u32(segment + 10)
                info.height = u32(segment + 6) - u32(segment + 14)
                info.tileWidth = u32(segment + 18)
                info.tileHeight = u32(segment + 22)
                info.components = u16(segment + 34)
                info.bitDepth = Int(bytes[segment + 36] & 0x7F) + 1
            case 0xFF52 where length >= 12:
                info.progressionOrder = Int(bytes[segment + 1])
                info.layers = u16(segment + 2)
                info.decompositionLevels = Int(bytes[segment + 5])
                info.codeBlockWidth = 1 << (Int(bytes[segment + 6]) + 2)
                info.codeBlockHeight = 1 << (Int(bytes[segment + 7]) + 2)
            case 0xFF5C where length >= 3:
                info.guardBits = Int(bytes[segment] >> 5)
            case 0xFF55:
                info.hasTLM = true
            case 0xFF5F:
                info.hasPOC = true
            default:
                break
            }
            position += 2 + length
        }

        // Tile parts: SOT(FF90) Lsot(2) Isot(2) Psot(4) TPsot TNsot.
        while position + 12 <= bytes.count, u16(position) == 0xFF90 {
            info.tileParts += 1
            let psot = u32(position + 6)
            guard psot > 0 else { break }
            position += psot
        }
        return info
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        // The codestream starts at offset 0 in DCP MXF frames; JP2 files have a short box header.
        for start in 0...(min(bytes.count - pattern.count, 4096)) where bytes[start] == pattern[0] {
            if Array(bytes[start..<(start + pattern.count)]) == pattern { return start }
        }
        return nil
    }
}
