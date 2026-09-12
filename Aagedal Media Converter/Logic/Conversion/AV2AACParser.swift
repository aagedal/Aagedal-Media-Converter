// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Packetizes the AAC-LC ADTS output used by AV2 audio staging. Channel configuration zero
/// carries its layout in a Program Config Element (PCE), which must also reach CodecPrivate.
enum AV2AACParser {
    struct Track {
        let frames: [Data]
        let audioSpecificConfig: Data
        let sampleRate: Double
        let channels: Int
    }

    static func channelCount(forConfiguration configuration: UInt8) -> Int? {
        switch configuration {
        case 1...6: Int(configuration)
        case 7: 8
        default: nil
        }
    }

    static func parse(_ data: Data) -> Track? {
        try? parseChecked(Array(data))
    }

    private enum ParseError: Error { case malformed }
    private static let sampleRates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    private static func parseChecked(_ bytes: [UInt8]) throws -> Track {
        var position = 0
        var frames: [Data] = []
        var configuration: [UInt8]?
        var audioSpecificConfig = Data()
        var programConfig: Data?
        var channels = 0
        var sampleRate: Double = 0

        while position < bytes.count {
            guard bytes.count - position >= 7,
                  bytes[position] == 0xFF, bytes[position + 1] & 0xF6 == 0xF0,
                  bytes[position + 6] & 0x03 == 0 else { throw ParseError.malformed }
            // Multi-block ADTS requires raw-data-block splitting and separate CRC handling;
            // native AAC staging emits one 1024-sample access unit per header.
            let headerLength = bytes[position + 1] & 1 == 1 ? 7 : 9
            let profile = bytes[position + 2] >> 6
            let rateIndex = (bytes[position + 2] >> 2) & 15
            let channelConfiguration = ((bytes[position + 2] & 1) << 2) | (bytes[position + 3] >> 6)
            let frameLength = Int(bytes[position + 3] & 3) << 11 | Int(bytes[position + 4]) << 3 | Int(bytes[position + 5] >> 5)
            guard Int(rateIndex) < sampleRates.count,
                  frameLength > headerLength, frameLength <= bytes.count - position else { throw ParseError.malformed }
            let currentConfiguration = [profile, rateIndex, channelConfiguration]
            if let configuration, configuration != currentConfiguration { throw ParseError.malformed }

            var payload = Array(bytes[(position + headerLength)..<(position + frameLength)])
            if configuration == nil {
                let objectType = profile + 1
                audioSpecificConfig = Data([(objectType << 3) | (rateIndex >> 1), (rateIndex & 1) << 7 | channelConfiguration << 3])
                sampleRate = sampleRates[Int(rateIndex)]
                if channelConfiguration != 0 {
                    guard let count = channelCount(forConfiguration: channelConfiguration) else { throw ParseError.malformed }
                    channels = count
                }
            }

            if channelConfiguration == 0 {
                // Like FFmpeg's aac_adtstoasc boundary, accept a PCE at the first syntax element.
                // Arbitrary in-band AAC syntax needs a full decoder; do not guess where a PCE ends.
                let startsWithPCE = payload[0] >> 5 == 5
                guard configuration != nil || startsWithPCE else { throw ParseError.malformed }
                if startsWithPCE {
                    let pce = try readProgramConfig(payload, profile: profile, rateIndex: rateIndex)
                    if let programConfig, programConfig != pce.data { throw ParseError.malformed }
                    if programConfig == nil {
                        programConfig = pce.data
                        audioSpecificConfig.append(pce.data)
                        channels = pce.channels
                    }
                    payload.removeFirst(pce.consumedBytes)
                    guard !payload.isEmpty else { throw ParseError.malformed }
                }
            }
            configuration = currentConfiguration
            frames.append(Data(payload))
            position += frameLength
        }
        guard !frames.isEmpty, channels > 0 else { throw ParseError.malformed }
        return Track(frames: frames, audioSpecificConfig: audioSpecificConfig, sampleRate: sampleRate, channels: channels)
    }

    /// PCE fields follow ISO/IEC 14496-3. The three-bit syntax ID belongs to the access unit,
    /// not AudioSpecificConfig; source and destination therefore have different byte alignment.
    /// Reference behavior: https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/bsf/aac_adtstoasc.c
    private static func readProgramConfig(_ bytes: [UInt8], profile: UInt8, rateIndex: UInt8) throws -> (data: Data, channels: Int, consumedBytes: Int) {
        var reader = BitReader(bytes: bytes)
        var writer = BitWriter()
        guard try reader.read(3) == 5 else { throw ParseError.malformed }
        func field(_ width: Int) throws -> Int {
            let value = try reader.read(width)
            writer.append(value, width: width)
            return value
        }
        _ = try field(4) // element instance tag
        guard try field(2) == Int(profile), try field(4) == Int(rateIndex) else { throw ParseError.malformed }
        let front = try field(4)
        let side = try field(4)
        let back = try field(4)
        let lfe = try field(2)
        let associatedData = try field(3)
        let coupling = try field(4)
        if try field(1) != 0 { _ = try field(4) } // mono mixdown element
        if try field(1) != 0 { _ = try field(4) } // stereo mixdown element
        if try field(1) != 0 { _ = try field(3) } // matrix index + pseudo-surround

        var channels = 0
        var elementTags: Set<Int> = []
        for _ in 0..<(front + side + back) {
            let pair = try field(1)
            let tag = try field(4)
            guard elementTags.insert(pair * 16 + tag).inserted else { throw ParseError.malformed }
            channels += pair == 1 ? 2 : 1
        }
        for _ in 0..<lfe {
            let tag = try field(4)
            guard elementTags.insert(32 + tag).inserted else { throw ParseError.malformed }
            channels += 1
        }
        for _ in 0..<associatedData { _ = try field(4) }
        for _ in 0..<coupling { _ = try field(5) }
        guard channels > 0 else { throw ParseError.malformed }
        try reader.align()
        writer.align()
        let commentLength = try field(8)
        for _ in 0..<commentLength { _ = try field(8) }
        return (Data(writer.bytes), channels, reader.position / 8)
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        mutating func read(_ width: Int) throws -> Int {
            guard width <= bytes.count * 8 - position else { throw ParseError.malformed }
            var value = 0
            for _ in 0..<width {
                value = value << 1 | Int((bytes[position / 8] >> (7 - position % 8)) & 1)
                position += 1
            }
            return value
        }

        mutating func align() throws {
            _ = try read((8 - position % 8) % 8)
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var position = 0

        mutating func append(_ value: Int, width: Int) {
            for bit in (0..<width).reversed() {
                if position % 8 == 0 { bytes.append(0) }
                bytes[position / 8] |= UInt8((value >> bit) & 1) << (7 - position % 8)
                position += 1
            }
        }

        mutating func align() {
            append(0, width: (8 - position % 8) % 8)
        }
    }
}
