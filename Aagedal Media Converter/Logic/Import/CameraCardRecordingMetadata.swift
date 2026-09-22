// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Adapts probed metadata only after a caller has resolved logical recordings.
/// This does not infer spans from filenames or enable automatic card splitting.
enum CameraCardRecordingMetadata {
    static func recording(
        resolvedSegmentURLs urls: [URL],
        metadata: [URL: VideoMetadata],
        cameraMetadata: [URL: CameraMetadata]
    ) -> CameraCardRecordingGrouping.Recording {
        // A later segment's timestamp is not the start of the recording.
        let first = urls.first
        var duration: Double? = urls.isEmpty ? nil : 0
        for url in urls {
            guard let total = duration, let segment = metadata[url]?.duration,
                  segment.isFinite, segment >= 0, (total + segment).isFinite else {
                duration = nil
                break
            }
            duration = total + segment
        }
        return .init(
            urls: urls,
            cameraDate: first.flatMap { cameraMetadata[$0]?.creationDate },
            containerDate: first.flatMap { metadata[$0]?.containerCreationDate },
            duration: duration
        )
    }

    /// Missing probe results or required format fields are never compatible by
    /// virtue of matching nil values. Every segment and audio track is checked.
    static func compatibility(
        for urls: [URL], metadata: [URL: VideoMetadata]
    ) -> CameraCardRecordingGrouping.Compatibility {
        guard !urls.isEmpty else { return .unknown }
        var probes: [VideoMetadata] = []
        for url in urls {
            guard let probe = metadata[url] else { return .unknown }
            guard !probe.videoStreams.isEmpty else { return .incompatible }
            guard probe.videoStreams.allSatisfy({ video in
                !(video.codec?.isEmpty ?? true) && (video.width ?? 0) > 0 &&
                (video.height ?? 0) > 0 && (video.frameRate?.value ?? 0) > 0 &&
                video.frameRate?.value?.isFinite == true &&
                !(video.pixelFormat?.isEmpty ?? true) && video.isInterlaced != nil
            }), probe.audioStreams.allSatisfy({ audio in
                !(audio.codec?.isEmpty ?? true) && (audio.channels ?? 0) > 0 &&
                (audio.sampleRate ?? 0) > 0 &&
                ((audio.channels ?? 0) <= 2 || !(audio.channelLayout?.isEmpty ?? true))
            }) else { return .unknown }
            probes.append(probe)
        }
        guard let reference = probes.first else { return .unknown }
        for probe in probes.dropFirst() {
            guard probe.audioStreams.count == reference.audioStreams.count,
                  probe.videoStreams.count == reference.videoStreams.count else { return .incompatible }
            for (video, other) in zip(reference.videoStreams, probe.videoStreams) {
                guard video.pixelFormat == other.pixelFormat,
                      video.isInterlaced == other.isInterlaced else { return .incompatible }
            }
            for (audio, other) in zip(reference.audioStreams, probe.audioStreams) {
                guard audio.codec?.lowercased() == other.codec?.lowercased(),
                      audio.channels == other.channels, audio.sampleRate == other.sampleRate,
                      audio.channelLayout == other.channelLayout else { return .incompatible }
            }
        }
        // Reuse the application's codec, dimensions, PAR and frame-rate rules.
        // Two synthetic waiting items also let a complete singleton be checked.
        let checkedURLs = urls.count == 1 ? urls + urls : urls
        let items = checkedURLs.map { url in
            VideoItem(url: url, name: url.lastPathComponent, size: 0, duration: "--:--",
                      thumbnailData: nil, status: .waiting, progress: 0, eta: nil, outputURL: nil)
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, metadata[$0.url]!) })
        switch MergeCompatibilityPolicy.checkMergeCompatibility(items: items, metadata: byID) {
        case .compatible: return .compatible
        case .metadataUnavailable, .cancelled, .insufficientItems: return .unknown
        default: return .incompatible
        }
    }
}
