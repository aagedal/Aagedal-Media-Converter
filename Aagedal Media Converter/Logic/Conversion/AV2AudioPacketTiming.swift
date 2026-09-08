// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Restores the routed Matroska timeline after elementary audio extraction discards timestamps.
enum AV2AudioPacketTiming {
    static func applying(manifest: String, to track: MatroskaMuxer.AudioTrack) -> MatroskaMuxer.AudioTrack? {
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
        let frames = zip(track.frames, timestamps).map { frame, timestamp in
            MatroskaMuxer.AudioFrame(
                data: frame.data, durationSamples: frame.durationSamples,
                presentationTimestampMilliseconds: timestamp
            )
        }
        return MatroskaMuxer.AudioTrack(info: track.info, frames: frames)
    }
}
