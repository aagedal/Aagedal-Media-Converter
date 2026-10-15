// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import Darwin
import OSLog

/// A minimal Matroska (`.mkv`) muxer — just enough to wrap an already-encoded video track plus
/// zero or more audio tracks into a seekable container.
///
/// It exists because FFmpeg cannot (yet) write the experimental AV2 codec: its Matroska demuxer
/// reads a `V_AV2` track but has no AVCodecID mapping for it, so `ffmpeg -c copy` refuses to remux.
/// Rather than hand-build the AV2 codec-configuration record (which is content-dependent — the
/// level/bit-depth bytes change with resolution and depth), we harvest the authoritative
/// `CodecPrivate` from a tiny `avmenc --webm` probe and copy the video frames verbatim out of the
/// IVF bitstream (the IVF frame payload is byte-identical to the Matroska block payload).
///
/// The writer streams blocks and clusters to a sibling temporary file, patches sizes
/// and cues, then atomically installs the completed output. Video payloads can be read
/// directly from IVF in bounded buffers; the timeline retains only lightweight offsets.
enum MatroskaMuxer {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MatroskaMuxer")

    struct VideoTrackInfo: Sendable {
        var codecID: String = "V_AV2"
        let codecPrivate: Data?
        let width: Int
        let height: Int
        let fpsNumerator: Int
        let fpsDenominator: Int
    }

    struct AudioTrackInfo: Sendable {
        let codecID: String          // e.g. "A_AAC", "A_OPUS"
        let codecPrivate: Data?      // AudioSpecificConfig (AAC) / OpusHead (Opus)
        let sampleRate: Double       // 48000 for Opus (its Matroska timestamp clock)
        let channels: Int
        var codecDelayNs: Int64? = nil    // Opus pre-skip, in nanoseconds
        var seekPreRollNs: Int64? = nil   // Opus seek pre-roll (80 ms), in nanoseconds
    }

    /// Global Matroska tags that apply to the whole output file.
    struct Metadata: Sendable, Equatable {
        var comment: String? = nil
        var timecode: String? = nil
        var description: String? = nil
        var title: String? = nil
        var artist: String? = nil
        var sourceURL: String? = nil
    }

    /// A decoded video frame ready to mux: the raw bitstream payload + whether it is a key frame.
    struct VideoFrame: Sendable {
        let data: Data
        let isKeyframe: Bool
    }

    /// One audio access unit plus its duration and optional source timestamp. AAC frames are a
    /// constant 1024 samples; Opus packets vary (derived from the packet's TOC byte).
    struct AudioFrame: Sendable {
        let data: Data
        let durationSamples: Int
        /// Container block timestamp, including codec delay for Opus. Nil retains the legacy
        /// continuous sample clock for callers without source packet timing.
        var presentationTimestampMilliseconds: Int64? = nil
        /// Exact trailing encoder padding, in nanoseconds. Padded packets use a BlockGroup
        /// because SimpleBlock cannot carry Matroska's DiscardPadding element.
        var discardPaddingNanoseconds: Int64 = 0
    }

    /// One complete encoded audio track ready to mux. Keeping the track description and frames
    /// together prevents frame arrays from becoming misaligned when routing duplicates or
    /// reorders source tracks.
    struct AudioTrack: Sendable {
        let info: AudioTrackInfo
        let frames: [AudioFrame]
    }

    enum MuxError: LocalizedError {
        case noVideoFrames
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoFrames: return "No video frames to mux"
            case .writeFailed(let detail): return "Failed to write Matroska file: \(detail)"
            }
        }
    }

    /// Writes a `.mkv` containing the given video frames and (optionally) audio frames.
    /// - Parameters:
    ///   - videoFrames: in presentation order; timestamps are derived from the video frame rate.
    ///   - audioFrames: in presentation order; each is one access unit. Missing timestamps are
    ///     reconstructed from frame durations and `audio.sampleRate`.
    static func write(
        to url: URL,
        video: VideoTrackInfo,
        videoFrames: [VideoFrame],
        audio: AudioTrackInfo?,
        audioFrames: [AudioFrame],
        metadata: Metadata? = nil
    ) throws {
        let audioTracks = audio.map { [AudioTrack(info: $0, frames: audioFrames)] } ?? []
        try write(
            to: url,
            video: video,
            videoFrames: videoFrames,
            audioTracks: audioTracks,
            metadata: metadata
        )
    }

    /// Writes a `.mkv` containing the given video frames and routed audio tracks.
    static func write(
        to url: URL,
        video: VideoTrackInfo,
        videoFrames: [VideoFrame],
        audioTracks: [AudioTrack],
        metadata: Metadata? = nil
    ) throws {
        try writeStream(to: url, video: video, videoSizes: videoFrames.map { $0.data.count },
            isKeyframe: { videoFrames[$0].isKeyframe },
            writeVideo: { index, output in try output.write(contentsOf: videoFrames[index].data) },
            audioTracks: audioTracks, metadata: metadata)
    }

    /// Stream payloads directly from IVF. Only frame offsets/sizes and block timing are
    /// indexed; payload reads are capped at 1 MiB regardless of frame or output size.
    static func write(
        to url: URL,
        video: VideoTrackInfo,
        videoIVFURL: URL,
        keyframeIndices: [Int],
        audioTracks: [AudioTrack],
        metadata: Metadata? = nil
    ) throws {
        guard let header = IVFHeaderParser.parse(url: videoIVFURL),
              header.width == video.width, header.height == video.height,
              header.fpsNumerator == video.fpsNumerator, header.fpsDenominator == video.fpsDenominator else {
            throw MuxError.writeFailed("IVF geometry or frame rate does not match the video track")
        }
        let records = try IVFConcatenator.frameRecords(in: videoIVFURL)
        let input = try FileHandle(forReadingFrom: videoIVFURL)
        defer { try? input.close() }
        let keys = Set(keyframeIndices)
        try writeStream(to: url, video: video, videoSizes: records.map(\.payloadSize),
            isKeyframe: { $0 == 0 || keys.contains($0) },
            writeVideo: { index, output in
                let record = records[index]
                try input.seek(toOffset: record.payloadOffset)
                var remaining = record.payloadSize
                while remaining > 0 {
                    try Task.checkCancellation()
                    guard let bytes = try input.read(upToCount: min(1024 * 1024, remaining)), !bytes.isEmpty else {
                        throw MuxError.writeFailed("Truncated IVF frame")
                    }
                    try output.write(contentsOf: bytes)
                    remaining -= bytes.count
                }
            }, audioTracks: audioTracks, metadata: metadata)
    }

    private static func writeStream(
        to url: URL, video: VideoTrackInfo, videoSizes: [Int],
        isKeyframe: (Int) -> Bool,
        writeVideo: (Int, FileHandle) throws -> Void,
        audioTracks: [AudioTrack], metadata: Metadata?
    ) throws {
        try Task.checkCancellation()
        guard !videoSizes.isEmpty else { throw MuxError.noVideoFrames }
        let activeAudioTracks = audioTracks.filter { !$0.frames.isEmpty }
        let fpsNum = max(1, video.fpsNumerator)
        let fpsDen = max(1, video.fpsDenominator)
        struct Block {
            let track: Int
            let order: Int
            let pts: Int64
            let videoIndex: Int?
            let data: Data?
            let payloadSize: Int
            let key: Bool
            var discardPaddingNanoseconds: Int64 = 0
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(videoSizes.count + activeAudioTracks.reduce(0) { $0 + $1.frames.count })
        for index in videoSizes.indices {
            try Task.checkCancellation()
            let pts = Int64((Double(index) * 1000 * Double(fpsDen) / Double(fpsNum)).rounded())
            blocks.append(Block(track: 1, order: blocks.count, pts: pts, videoIndex: index, data: nil,
                payloadSize: videoSizes[index], key: isKeyframe(index)))
        }
        var lastAudioEndMs: Double = 0
        for (audioIndex, audioTrack) in activeAudioTracks.enumerated() {
            var sampleOffset = 0
            for frame in audioTrack.frames {
                try Task.checkCancellation()
                let pts = frame.presentationTimestampMilliseconds
                    ?? Int64((Double(sampleOffset) * 1000 / audioTrack.info.sampleRate).rounded())
                blocks.append(Block(track: audioIndex + 2, order: blocks.count, pts: pts, videoIndex: nil, data: frame.data,
                    payloadSize: frame.data.count, key: true, discardPaddingNanoseconds: frame.discardPaddingNanoseconds))
                let duration = Double(max(0, frame.durationSamples)) * 1000 / audioTrack.info.sampleRate
                lastAudioEndMs = max(lastAudioEndMs, Double(pts) + duration
                    - Double(frame.discardPaddingNanoseconds) / 1_000_000
                    - Double(audioTrack.info.codecDelayNs ?? 0) / 1_000_000)
                sampleOffset += max(0, frame.durationSamples)
            }
        }
        blocks.sort {
            if $0.pts != $1.pts { return $0.pts < $1.pts }
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.order < $1.order
        }
        let durationMs = max((Double(videoSizes.count) * 1000 * Double(fpsDen) / Double(fpsNum)).rounded(), lastAudioEndMs)
        var ebml = Data()
        ebml += element(0x4286, uintData(1))
        ebml += element(0x42F7, uintData(1))
        ebml += element(0x42F2, uintData(4))
        ebml += element(0x42F3, uintData(8))
        ebml += element(0x4282, Data("matroska".utf8))
        ebml += element(0x4287, uintData(4))
        ebml += element(0x4285, uintData(2))
        var info = Data()
        info += element(0x2AD7B1, uintData(1_000_000))
        info += element(0x4D80, Data("Aagedal Media Converter".utf8))
        info += element(0x5741, Data("Aagedal Media Converter".utf8))
        info += element(0x4489, float64Data(durationMs))
        var tracks = buildVideoTrackEntry(video,
            defaultDurationNs: Int64((1_000_000_000 * Double(fpsDen) / Double(fpsNum)).rounded()))
        for (index, track) in activeAudioTracks.enumerated() { tracks += buildAudioTrackEntry(track.info, trackNumber: index + 2) }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mkv_\(UUID().uuidString).partial")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MuxError.writeFailed("Could not create temporary output") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        func header(_ id: UInt32, _ size: Int) throws {
            try output.write(contentsOf: idBytes(id) + vint(UInt64(size)))
        }
        func begin(_ id: UInt32) throws -> UInt64 {
            try output.write(contentsOf: idBytes(id))
            let offset = try output.offset()
            try output.write(contentsOf: Data([0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
            return offset
        }
        func finish(_ offset: UInt64) throws {
            let end = try output.offset()
            let size = end - offset - 8
            guard size < (UInt64(1) << 56) - 1 else { throw MuxError.writeFailed("Matroska element is too large") }
            var bytes = (0..<8).map { UInt8((size >> (8 * (7 - $0))) & 0xff) }
            bytes[0] |= 0x01
            try output.seek(toOffset: offset)
            try output.write(contentsOf: Data(bytes))
            try output.seek(toOffset: end)
        }
        try output.write(contentsOf: element(0x1A45DFA3, ebml))
        let segmentSizeOffset = try begin(0x18538067)
        let segmentStart = try output.offset()
        try output.write(contentsOf: element(0x1549A966, info))
        try output.write(contentsOf: element(0x1654AE6B, tracks))
        var clusterSizeOffset: UInt64?
        var clusterPosition: UInt64 = 0
        var clusterStart: Int64 = 0
        var clusterBase: Int64 = 0
        var clusterHasKeyframe = false
        var cues: [(time: Int64, offset: UInt64)] = []
        func closeCluster() throws {
            guard let offset = clusterSizeOffset else { return }
            try finish(offset)
            if clusterHasKeyframe { cues.append((clusterBase, clusterPosition)) }
        }
        for block in blocks {
            try Task.checkCancellation()
            if clusterSizeOffset == nil || (block.track == 1 && block.key) || block.pts - clusterStart > 1000 {
                try closeCluster()
                clusterStart = block.pts
                clusterBase = max(0, block.pts)
                clusterPosition = try output.offset() - segmentStart
                clusterSizeOffset = try begin(0x1F43B675)
                clusterHasKeyframe = false
                try output.write(contentsOf: element(0xE7, uintData(UInt64(clusterBase))))
            }
            clusterHasKeyframe = clusterHasKeyframe || (block.track == 1 && block.key)
            let relative = block.pts - clusterBase
            guard relative >= Int64(Int16.min), relative <= Int64(Int16.max) else {
                throw MuxError.writeFailed("Block timestamp exceeds the cluster range")
            }
            var prefix = vint(UInt64(block.track))
            let timestamp = UInt16(bitPattern: Int16(relative))
            prefix.append(UInt8(timestamp >> 8)); prefix.append(UInt8(timestamp & 0xff))
            prefix.append(block.discardPaddingNanoseconds == 0 && block.key ? 0x80 : 0)
            let size = prefix.count + block.payloadSize
            if block.discardPaddingNanoseconds > 0 {
                let padding = element(0x75A2, signedIntData(block.discardPaddingNanoseconds))
                try header(0xA0, idBytes(0xA1).count + vint(UInt64(size)).count + size + padding.count)
                try header(0xA1, size)
                try output.write(contentsOf: prefix)
                if let index = block.videoIndex { try writeVideo(index, output) }
                else if let data = block.data { try output.write(contentsOf: data) }
                try output.write(contentsOf: padding)
            } else {
                try header(0xA3, size)
                try output.write(contentsOf: prefix)
                if let index = block.videoIndex { try writeVideo(index, output) }
                else if let data = block.data { try output.write(contentsOf: data) }
            }
        }
        try closeCluster()
        if !cues.isEmpty {
            let cuesOffset = try begin(0x1C53BB6B)
            for cue in cues {
                try Task.checkCancellation()
                let positions = element(0xF7, uintData(1)) + element(0xF1, uintData(cue.offset))
                try output.write(contentsOf: element(0xBB, element(0xB3, uintData(UInt64(cue.time))) + element(0xB7, positions)))
            }
            try finish(cuesOffset)
        }
        try output.write(contentsOf: buildTags(metadata))
        try finish(segmentSizeOffset)
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MuxError.writeFailed("Could not install completed Matroska output") }
        logger.info("Streamed Matroska: \(videoSizes.count) video frames, \(durationMs) ms")
    }

    // MARK: - Track entries

    private static func buildVideoTrackEntry(_ video: VideoTrackInfo, defaultDurationNs: Int64) -> Data {
        var entry = Data()
        entry += element(0xD7, uintData(1))                  // TrackNumber
        entry += element(0x73C5, uintData(1))                // TrackUID
        entry += element(0x83, uintData(1))                  // TrackType = video
        entry += element(0x9C, uintData(0))                  // FlagLacing = 0
        entry += element(0x86, Data(video.codecID.utf8))     // CodecID
        if let cp = video.codecPrivate, !cp.isEmpty {
            entry += element(0x63A2, cp)                     // CodecPrivate
        }
        if defaultDurationNs > 0 {
            entry += element(0x23E383, uintData(UInt64(defaultDurationNs))) // DefaultDuration (ns)
        }
        var videoSub = Data()
        videoSub += element(0xB0, uintData(UInt64(max(0, video.width))))   // PixelWidth
        videoSub += element(0xBA, uintData(UInt64(max(0, video.height))))  // PixelHeight
        entry += element(0xE0, videoSub)                     // Video
        return element(0xAE, entry)                          // TrackEntry
    }

    private static func buildAudioTrackEntry(_ audio: AudioTrackInfo, trackNumber: Int) -> Data {
        var entry = Data()
        entry += element(0xD7, uintData(UInt64(trackNumber)))   // TrackNumber
        entry += element(0x73C5, uintData(UInt64(trackNumber))) // TrackUID
        entry += element(0x83, uintData(2))                  // TrackType = audio
        entry += element(0x88, uintData(trackNumber == 2 ? 1 : 0)) // FlagDefault: first audio only
        entry += element(0x9C, uintData(0))                  // FlagLacing = 0
        entry += element(0x86, Data(audio.codecID.utf8))     // CodecID
        if let cp = audio.codecPrivate, !cp.isEmpty {
            entry += element(0x63A2, cp)                     // CodecPrivate
        }
        if let delay = audio.codecDelayNs, delay > 0 {
            entry += element(0x56AA, uintData(UInt64(delay)))    // CodecDelay (Opus pre-skip)
        }
        if let preroll = audio.seekPreRollNs, preroll > 0 {
            entry += element(0x56BB, uintData(UInt64(preroll)))  // SeekPreRoll (Opus)
        }
        var audioSub = Data()
        audioSub += element(0xB5, float64Data(audio.sampleRate))           // SamplingFrequency
        audioSub += element(0x9F, uintData(UInt64(max(1, audio.channels)))) // Channels
        entry += element(0xE1, audioSub)                     // Audio
        return element(0xAE, entry)                          // TrackEntry
    }

    // MARK: - Global tags

    private static func buildTags(_ metadata: Metadata?) -> Data {
        guard let metadata else { return Data() }

        let values: [(name: String, value: String?)] = [
            ("COMMENT", metadata.comment),
            ("TIMECODE", metadata.timecode),
            ("DESCRIPTION", metadata.description),
            ("TITLE", metadata.title),
            ("ARTIST", metadata.artist),
            ("PURL", metadata.sourceURL)
        ]
        let populated = values.compactMap { pair -> (String, String)? in
            guard let value = pair.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return (pair.name, value)
        }
        guard !populated.isEmpty else { return Data() }

        var globalTag = element(0x63C0, Data())              // Targets (empty = whole Segment)
        for (name, value) in populated {
            var simpleTag = Data()
            simpleTag += element(0x45A3, Data(name.utf8))    // TagName
            simpleTag += element(0x4487, Data(value.utf8))   // TagString
            globalTag += element(0x67C8, simpleTag)          // SimpleTag
        }

        var tags = element(0x7373, globalTag)                // Global Tag
        if let timecode = metadata.timecode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !timecode.isEmpty {
            var targets = Data()
            targets += element(0x63C5, uintData(1))          // TrackUID = primary video
            var trackTag = element(0x63C0, targets)
            var simpleTag = Data()
            simpleTag += element(0x45A3, Data("TIMECODE".utf8))
            simpleTag += element(0x4487, Data(timecode.utf8))
            trackTag += element(0x67C8, simpleTag)
            tags += element(0x7373, trackTag)
        }

        return element(0x1254C367, tags)                     // Tags
    }

    // MARK: - EBML primitives

    /// Wraps `payload` as an EBML element: element-ID bytes + size VINT + payload.
    /// The `id` is given as its canonical integer (e.g. 0x1654AE6B) and emitted big-endian using
    /// only its significant bytes (the leading byte already carries the length descriptor).
    private static func element(_ id: UInt32, _ payload: Data) -> Data {
        var out = idBytes(id)
        out.append(vint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    /// Emits a Matroska element ID as its significant bytes, big-endian.
    private static func idBytes(_ id: UInt32) -> Data {
        var bytes: [UInt8] = []
        if id & 0xFF00_0000 != 0 { bytes.append(UInt8((id >> 24) & 0xFF)) }
        if id & 0xFFFF_0000 != 0 { bytes.append(UInt8((id >> 16) & 0xFF)) }
        if id & 0xFFFF_FF00 != 0 { bytes.append(UInt8((id >> 8) & 0xFF)) }
        bytes.append(UInt8(id & 0xFF))
        return Data(bytes)
    }

    /// Encodes `value` as an EBML variable-length size integer (1–8 bytes), minimal width.
    private static func vint(_ value: UInt64) -> Data {
        var length = 1
        // The all-ones value of a given width is reserved (means "unknown size"), so the largest
        // usable value in `length` bytes is 2^(7·length) − 2.
        while length < 8 && value > (UInt64(1) << (7 * length)) - 2 { length += 1 }
        var bytes = [UInt8](repeating: 0, count: length)
        var v = value
        for i in stride(from: length - 1, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (length - 1))  // length-descriptor marker bit
        return Data(bytes)
    }

    /// Big-endian unsigned integer using the minimal number of bytes (0 → a single 0x00).
    private static func uintData(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data(bytes)
    }

    /// Eight-byte two's-complement signed integer. DiscardPadding is signed even for positive
    /// end padding; unsigned minimal-width encoding can accidentally set its sign bit.
    private static func signedIntData(_ value: Int64) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// 8-byte IEEE-754 big-endian float (Matroska floats).
    private static func float64Data(_ value: Double) -> Data {
        var be = value.bitPattern.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}
