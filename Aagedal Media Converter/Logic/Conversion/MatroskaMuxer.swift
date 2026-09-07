// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
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
/// The writer builds the whole file in memory (≈ output size) and writes it in one pass with all
/// element sizes known, which keeps the EBML correct and the file seekable. AV2 encodes are slow
/// and short, so the memory cost is a non-issue in practice.
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
    }

    /// A decoded video frame ready to mux: the raw bitstream payload + whether it is a key frame.
    struct VideoFrame: Sendable {
        let data: Data
        let isKeyframe: Bool
    }

    /// One audio access unit plus its duration in samples at the track's sample rate. AAC frames
    /// are a constant 1024 samples; Opus packets vary (derived from the packet's TOC byte).
    struct AudioFrame: Sendable {
        let data: Data
        let durationSamples: Int
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
    ///   - audioFrames: in presentation order; each is one access unit. For AAC every unit is
    ///     1024 samples, so timestamps are derived from `audio.sampleRate`.
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
        guard !videoFrames.isEmpty else { throw MuxError.noVideoFrames }
        let activeAudioTracks = audioTracks.filter { !$0.frames.isEmpty }

        let fpsNum = max(1, video.fpsNumerator)
        let fpsDen = max(1, video.fpsDenominator)

        // MARK: Build the block timeline (ms timestamps, TimestampScale = 1,000,000 ns).
        struct Block { let track: Int; let pts: Int64; let data: Data; let key: Bool }
        var blocks: [Block] = []
        blocks.reserveCapacity(videoFrames.count + activeAudioTracks.reduce(0) { $0 + $1.frames.count })

        for (i, frame) in videoFrames.enumerated() {
            let pts = Int64((Double(i) * 1000.0 * Double(fpsDen) / Double(fpsNum)).rounded())
            blocks.append(Block(track: 1, pts: pts, data: frame.data, key: frame.isKeyframe))
        }
        var lastAudioEndMs: Int64 = 0
        for (audioIndex, audioTrack) in activeAudioTracks.enumerated() {
            let trackNumber = audioIndex + 2
            var sampleOffset = 0
            for frame in audioTrack.frames {
                let pts = Int64((Double(sampleOffset) * 1000.0 / audioTrack.info.sampleRate).rounded())
                blocks.append(Block(track: trackNumber, pts: pts, data: frame.data, key: true))
                sampleOffset += max(0, frame.durationSamples)
            }
            let trackEndMs = Int64((Double(sampleOffset) * 1000.0 / audioTrack.info.sampleRate).rounded())
            lastAudioEndMs = max(lastAudioEndMs, trackEndMs)
        }

        // Stable order: by timestamp, video before audio on ties (keeps each cluster opening on the
        // video key frame).
        blocks.sort { $0.pts != $1.pts ? $0.pts < $1.pts : $0.track < $1.track }

        let lastVideoEndMs = Int64((Double(videoFrames.count) * 1000.0 * Double(fpsDen) / Double(fpsNum)).rounded())
        let durationMs = max(lastVideoEndMs, lastAudioEndMs)

        // MARK: EBML header
        var ebml = Data()
        ebml += element(0x4286, uintData(1))                 // EBMLVersion
        ebml += element(0x42F7, uintData(1))                 // EBMLReadVersion
        ebml += element(0x42F2, uintData(4))                 // EBMLMaxIDLength
        ebml += element(0x42F3, uintData(8))                 // EBMLMaxSizeLength
        ebml += element(0x4282, Data("matroska".utf8))       // DocType
        ebml += element(0x4287, uintData(4))                 // DocTypeVersion
        ebml += element(0x4285, uintData(2))                 // DocTypeReadVersion
        let ebmlHeader = element(0x1A45DFA3, ebml)

        // MARK: Segment » Info
        let appName = "Aagedal Media Converter"
        var info = Data()
        info += element(0x2AD7B1, uintData(1_000_000))       // TimestampScale (1 ms)
        info += element(0x4D80, Data(appName.utf8))          // MuxingApp
        info += element(0x5741, Data(appName.utf8))          // WritingApp
        info += element(0x4489, float64Data(Double(durationMs))) // Duration (TimestampScale units)
        let infoElement = element(0x1549A966, info)

        // MARK: Segment » Tracks
        var tracks = Data()
        tracks += buildVideoTrackEntry(video, defaultDurationNs: Int64((1_000_000_000.0 * Double(fpsDen) / Double(fpsNum)).rounded()))
        for (audioIndex, audioTrack) in activeAudioTracks.enumerated() {
            tracks += buildAudioTrackEntry(audioTrack.info, trackNumber: audioIndex + 2)
        }
        let tracksElement = element(0x1654AE6B, tracks)

        // MARK: Segment » Clusters (group blocks, each cluster opening on a video key frame)
        var groups: [[Block]] = []
        var current: [Block] = []
        var clusterStart: Int64 = 0
        for b in blocks {
            var startNew = false
            if current.isEmpty {
                startNew = false
            } else if b.track == 1 && b.key {
                startNew = true                       // open a new cluster at each video key frame
            } else if b.pts - clusterStart > 1000 {
                startNew = true                       // cap cluster span ≈ 1 s (keeps rel ts in Int16)
            }
            if startNew { groups.append(current); current = [] }
            if current.isEmpty { clusterStart = b.pts }
            current.append(b)
        }
        if !current.isEmpty { groups.append(current) }

        var clusterElements: [Data] = []
        clusterElements.reserveCapacity(groups.count)
        var cuePoints: [(time: Int64, clusterIndex: Int)] = []
        for (gi, group) in groups.enumerated() {
            let base = group[0].pts
            var body = Data()
            body += element(0xE7, uintData(UInt64(base)))    // cluster Timestamp
            for b in group {
                let rel = Int(b.pts - base)
                let clamped = Int16(max(-32768, min(32767, rel)))
                var sb = Data()
                sb += vint(UInt64(b.track))                  // track number VINT (1→0x81, 2→0x82)
                let u = UInt16(bitPattern: clamped)
                sb.append(UInt8((u >> 8) & 0xFF))
                sb.append(UInt8(u & 0xFF))
                sb.append(b.key ? 0x80 : 0x00)               // flags: bit7 = key frame
                sb += b.data
                body += element(0xA3, sb)                    // SimpleBlock
            }
            clusterElements.append(element(0x1F43B675, body))
            if group.contains(where: { $0.track == 1 && $0.key }) {
                cuePoints.append((time: base, clusterIndex: gi))
            }
        }

        // Cluster Segment-positions (offset from the first byte of the Segment's data) for Cues.
        let positionBase = infoElement.count + tracksElement.count
        var clusterOffsets: [Int] = []
        var running = positionBase
        for ce in clusterElements { clusterOffsets.append(running); running += ce.count }

        // MARK: Segment » Cues (one per cluster that opens on a video key frame)
        var cuesBody = Data()
        for cp in cuePoints {
            var positions = Data()
            positions += element(0xF7, uintData(1))                                // CueTrack = video
            positions += element(0xF1, uintData(UInt64(clusterOffsets[cp.clusterIndex]))) // CueClusterPosition
            var cuePoint = Data()
            cuePoint += element(0xB3, uintData(UInt64(cp.time)))                   // CueTime
            cuePoint += element(0xB7, positions)                                   // CueTrackPositions
            cuesBody += element(0xBB, cuePoint)                                    // CuePoint
        }
        let cuesElement = cuePoints.isEmpty ? Data() : element(0x1C53BB6B, cuesBody)
        let tagsElement = buildTags(metadata)

        // MARK: Assemble
        var segmentBody = Data()
        segmentBody += infoElement
        segmentBody += tracksElement
        for ce in clusterElements { segmentBody += ce }
        segmentBody += cuesElement
        segmentBody += tagsElement
        let segment = element(0x18538067, segmentBody)

        var file = Data()
        file += ebmlHeader
        file += segment

        do {
            try file.write(to: url, options: .atomic)
        } catch {
            throw MuxError.writeFailed(error.localizedDescription)
        }
        let audioFrameCount = activeAudioTracks.reduce(0) { $0 + $1.frames.count }
        logger.info("Wrote Matroska \(url.lastPathComponent, privacy: .public): \(videoFrames.count) video + \(audioFrameCount) audio frames across \(activeAudioTracks.count) tracks, \(durationMs) ms")
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
            ("TIMECODE", metadata.timecode)
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

    /// 8-byte IEEE-754 big-endian float (Matroska floats).
    private static func float64Data(_ value: Double) -> Data {
        var be = value.bitPattern.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}
