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

/// Joins several AV2 `.ivf` segment files (produced by parallel `avmenc` workers, one per
/// frame range) into a single `.ivf` bitstream.
///
/// IVF is a trivial wrapper: a 32-byte header (see ``IVFHeaderParser``) followed by, per frame,
/// a 12-byte frame header (4-byte little-endian payload size + 8-byte little-endian timestamp)
/// and the raw payload. Concatenation therefore means: keep the first segment's container header
/// (rewriting the total frame count), then append every segment's frames in order, re-stamping
/// each frame's presentation timestamp to a running 0,1,2,… counter (the IVF timebase is one
/// tick per frame, so consecutive integers give correct, monotonic timing).
///
/// **Correctness assumption:** each segment is a *self-contained* AV2 sequence — `avmenc` always
/// emits a sequence-header OBU plus a key frame at the start of every encode, so a decoder
/// re-synchronises at each segment boundary. This is the same property Av1an-style chunked
/// encoding relies on. The per-segment first frame is therefore a guaranteed key frame, which is
/// reported back via ``ConcatResult/keyframeIndices`` for downstream muxing.
enum IVFConcatenator {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "IVFConcatenator")

    enum ConcatError: LocalizedError {
        case noSegments
        case unreadable(URL)
        case notIVF(URL)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .noSegments: return "No AV2 segments to concatenate"
            case .unreadable(let url): return "Could not read AV2 segment \(url.lastPathComponent)"
            case .notIVF(let url): return "AV2 segment \(url.lastPathComponent) is not a valid IVF bitstream"
            case .mismatch(let detail): return "AV2 segments are not compatible for concatenation: \(detail)"
            }
        }
    }

    struct ConcatResult: Sendable {
        /// Total number of frames written to the combined file.
        let totalFrames: Int
        /// Global frame indices that begin a source segment — guaranteed key frames.
        let keyframeIndices: [Int]
        let width: Int
        let height: Int
        let fpsNumerator: Int
        let fpsDenominator: Int
    }

    /// Concatenates `segmentURLs` (in order) into a single `.ivf` at `outputURL`.
    /// - Returns: frame total, key-frame indices, and the shared video geometry.
    /// - Throws: ``ConcatError`` when a segment is unreadable, not IVF, or geometry/codec mismatches.
    @discardableResult
    static func concatenate(segmentURLs: [URL], into outputURL: URL) throws -> ConcatResult {
        try Task.checkCancellation()
        guard let first = segmentURLs.first else { throw ConcatError.noSegments }

        guard let firstHeader = IVFHeaderParser.parse(url: first) else { throw ConcatError.notIVF(first) }

        // Validate every segment shares the first one's container geometry. Differing dimensions
        // or frame rate means the segmentation step diverged and the streams can't be joined.
        for url in segmentURLs {
            guard let h = IVFHeaderParser.parse(url: url) else { throw ConcatError.notIVF(url) }
            guard h.fpsNumerator > 0, h.fpsDenominator > 0,
                  h.fpsNumerator == firstHeader.fpsNumerator,
                  h.fpsDenominator == firstHeader.fpsDenominator else {
                throw ConcatError.mismatch("\(url.lastPathComponent): frame rate")
            }
            if h.fourCC != firstHeader.fourCC || h.width != firstHeader.width || h.height != firstHeader.height {
                throw ConcatError.mismatch("\(url.lastPathComponent): \(h.fourCC) \(h.width)x\(h.height) ≠ \(firstHeader.fourCC) \(firstHeader.width)x\(firstHeader.height)")
            }
        }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: outputURL) else { throw ConcatError.unreadable(outputURL) }
        var completed = false
        defer {
            try? out.close()
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }

        // Container header: copy the first segment's 32 bytes, then patch the frame-count field
        // (bytes 24..27) after we know the running total. Write a placeholder header now and
        // rewrite it at the end so we never have to buffer the whole bitstream.
        let firstInput = try FileHandle(forReadingFrom: first)
        defer { try? firstInput.close() }
        guard let headerBytes = try firstInput.read(upToCount: 32), headerBytes.count == 32 else {
            throw ConcatError.notIVF(first)
        }
        try out.write(contentsOf: headerBytes)

        var totalFrames = 0
        var keyframeIndices: [Int] = []

        for url in segmentURLs {
            keyframeIndices.append(totalFrames) // first frame of each segment is a key frame
            try forEachFrame(in: url) { payload, _ in
                guard totalFrames < Int(UInt32.max) else {
                    throw ConcatError.mismatch("frame count exceeds IVF capacity")
                }
                var frameHeader = [UInt8](repeating: 0, count: 12)
                let size = UInt32(payload.count)
                frameHeader[0] = UInt8(size & 0xFF)
                frameHeader[1] = UInt8((size >> 8) & 0xFF)
                frameHeader[2] = UInt8((size >> 16) & 0xFF)
                frameHeader[3] = UInt8((size >> 24) & 0xFF)
                let ts = UInt64(totalFrames)
                for i in 0..<8 { frameHeader[4 + i] = UInt8((ts >> (8 * i)) & 0xFF) }
                try out.write(contentsOf: Data(frameHeader))
                try out.write(contentsOf: payload)
                totalFrames += 1
            }
        }

        // Rewrite the frame-count field now that the total is known.
        let fc = UInt32(truncatingIfNeeded: totalFrames)
        let countBytes = Data([
            UInt8(fc & 0xFF),
            UInt8((fc >> 8) & 0xFF),
            UInt8((fc >> 16) & 0xFF),
            UInt8((fc >> 24) & 0xFF),
        ])
        try out.seek(toOffset: 24)
        try out.write(contentsOf: countBytes)
        try out.close()
        completed = true

        logger.info("Concatenated \(segmentURLs.count) AV2 segments → \(totalFrames) frames at \(firstHeader.width)x\(firstHeader.height)")

        return ConcatResult(
            totalFrames: totalFrames,
            keyframeIndices: keyframeIndices,
            width: firstHeader.width,
            height: firstHeader.height,
            fpsNumerator: firstHeader.fpsNumerator,
            fpsDenominator: firstHeader.fpsDenominator
        )
    }

    /// Streams every frame of a single IVF file, invoking `body` with the raw payload and the
    /// frame's original (per-segment) timestamp. The 32-byte container header is skipped.
    /// Reads one frame at a time, rejecting incomplete records instead of publishing a shortened video.
    static func forEachFrame(in url: URL, _ body: (_ payload: Data, _ timestamp: UInt64) throws -> Void) throws {
        try Task.checkCancellation()
        guard let input = try? FileHandle(forReadingFrom: url) else { throw ConcatError.unreadable(url) }
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard let data = try input.read(upToCount: 32), data.count == 32,
              let header = IVFHeaderParser.parse(data: data),
              data[4] == 0, data[5] == 0, data[6] == 32, data[7] == 0 else {
            throw ConcatError.notIVF(url)
        }

        var frameCount = 0
        while let record = try input.read(upToCount: 12), !record.isEmpty {
            try Task.checkCancellation()
            guard record.count == 12 else { throw ConcatError.notIVF(url) }
            let size = Int(record[0]) | (Int(record[1]) << 8) | (Int(record[2]) << 16) | (Int(record[3]) << 24)
            let position = try input.offset()
            guard size > 0, position <= fileSize, UInt64(size) <= fileSize - position,
                  let payload = try input.read(upToCount: size), payload.count == size else {
                throw ConcatError.notIVF(url)
            }
            var timestamp: UInt64 = 0
            for i in 0..<8 { timestamp |= UInt64(record[4 + i]) << (8 * i) }
            try body(payload, timestamp)
            frameCount += 1
        }
        // Zero is permitted for streams whose writer did not patch the optional count.
        guard frameCount > 0, header.frameCount == 0 || header.frameCount == frameCount else {
            throw ConcatError.notIVF(url)
        }
        try Task.checkCancellation()
    }
}
