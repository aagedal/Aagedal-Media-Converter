import Foundation

/// Pure merge eligibility, compatibility, grouping, and conformance decisions.
/// Metadata loading, caching, and conversion execution remain in ConversionManager.
enum MergeCompatibilityPolicy {
    static func eligibleItems(_ items: [VideoItem]) -> [VideoItem] {
        items.filter {
            $0.status == .waiting &&
            !$0.isDownloading &&
            $0.scheduledDownloadTime == nil &&
            !$0.isImageSequence
        }
    }

    /// Captures the reference clip's format that non-matching clips must conform to.
    struct ConformanceTarget: Sendable {
        let referenceItemID: UUID
        let referenceURL: URL
        // Video
        let videoCodec: String
        let width: Int
        let height: Int
        let frameRate: Double?
        let pixelFormat: String?
        let pixelAspectRatio: String?
        let isInterlaced: Bool
        // Audio
        let audioCodec: String?
        let audioChannels: Int?
        let audioSampleRate: Int?
        // Container
        let containerExtension: String

        /// Builds a ConformanceTarget from a clip's metadata and URL.
        static func from(metadata: VideoMetadata, url: URL) -> ConformanceTarget? {
            guard let video = metadata.primaryVideoStream,
                  let codec = video.codec,
                  let width = video.width,
                  let height = video.height else { return nil }

            let audio = metadata.audioStreams.first
            return ConformanceTarget(
                referenceItemID: UUID(), // Caller should set this properly
                referenceURL: url,
                videoCodec: codec,
                width: width,
                height: height,
                frameRate: video.frameRate?.value,
                pixelFormat: video.pixelFormat,
                pixelAspectRatio: video.pixelAspectRatio?.stringValue,
                isInterlaced: video.isInterlaced ?? false,
                audioCodec: audio?.codec,
                audioChannels: audio?.channels,
                audioSampleRate: audio?.sampleRate,
                containerExtension: url.pathExtension.lowercased()
            )
        }

        /// Human-readable summary of the target format.
        var formatSummary: String {
            var parts: [String] = []
            parts.append("\(width)x\(height)")
            parts.append(videoCodec)
            if let fr = frameRate { parts.append("\(Int(fr.rounded()))fps") }
            if let ac = audioCodec, let ch = audioChannels {
                let sr = audioSampleRate.map { " \($0 / 1000)kHz" } ?? ""
                parts.append("\(ch)ch \(ac)\(sr)")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Per-clip analysis of what needs to change for conformance merge.
    struct ConformanceAnalysis: Sendable, Identifiable {
        let id: UUID  // itemID
        let itemName: String
        let needsVideoReencode: Bool
        let needsAudioReencode: Bool
        let videoMismatches: [String]
        let audioMismatches: [String]

        var needsConformance: Bool { needsVideoReencode || needsAudioReencode }
    }
    enum MergeCompatibilityResult {
        case compatible
        case insufficientItems(Int)
        case metadataUnavailable(VideoItem)
        case missingVideoTrack
        case videoCodecMismatch(VideoItem)
        case resolutionMismatch(VideoItem, expected: VideoMetadata.VideoStream)
        case pixelAspectMismatch(VideoItem)
        case frameRateMismatch(VideoItem)
        case audioPresenceMismatch(VideoItem)
        case audioChannelMismatch(VideoItem)
        case audioSampleRateMismatch(VideoItem)
        case audioCodecMismatch(VideoItem)
        case cancelled

        var tooltip: String {
            switch self {
            case .compatible:
                return "Enable to merge compatible clips into one export."
            case .insufficientItems(let count):
                return count == 0 ? "Add clips to enable merging." : "Need at least two queued clips to merge."
            case .metadataUnavailable(let item):
                return "Metadata is unavailable for \(item.name)."
            case .missingVideoTrack:
                return "All clips must contain a video track for merging."
            case .videoCodecMismatch:
                return "Video codec mismatch between clips."
            case .resolutionMismatch(let item, let expected):
                let expectedRes = "\(expected.width ?? 0)x\(expected.height ?? 0)"
                return "Resolution mismatch involving \(item.name). Expected \(expectedRes)."
            case .pixelAspectMismatch:
                return "Pixel aspect ratio mismatch between clips."
            case .frameRateMismatch:
                return "Frame rate mismatch between clips."
            case .audioPresenceMismatch:
                return "Some clips have audio while others do not."
            case .audioChannelMismatch:
                return "Audio channel count mismatch between clips."
            case .audioSampleRateMismatch:
                return "Audio sample rate mismatch between clips."
            case .audioCodecMismatch:
                return "Audio codec mismatch between clips."
            case .cancelled:
                return "Compatibility check cancelled."
            }
        }
    }

    /// Pure compatibility check that doesn't mutate actor state.
    /// Use this from UI code (e.g. card import dialog) where you already have metadata loaded.
    static func checkMergeCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> MergeCompatibilityResult {
        let waitingItems = eligibleItems(items)
        guard waitingItems.count >= 2 else {
            return .insufficientItems(waitingItems.count)
        }

        guard let firstItem = waitingItems.first else {
            return .insufficientItems(0)
        }
        guard let referenceMetadata = metadata[firstItem.id] else {
            return .metadataUnavailable(firstItem)
        }
        guard !referenceMetadata.videoStreams.isEmpty else {
            return .missingVideoTrack
        }

        let referenceVideoStreams = referenceMetadata.videoStreams
        let referenceAudio = referenceMetadata.audioStreams.first

        for item in waitingItems {
            guard let meta = metadata[item.id] else {
                return .metadataUnavailable(item)
            }
            guard !meta.videoStreams.isEmpty else {
                return .missingVideoTrack
            }

            if meta.videoStreams.count != referenceVideoStreams.count {
                if meta.primaryVideoStream != nil && !referenceVideoStreams.isEmpty {
                    return .videoCodecMismatch(item)
                }
                return .missingVideoTrack
            }

            for (video, referenceVideo) in zip(meta.videoStreams, referenceVideoStreams) {
                if (video.codec?.lowercased() ?? "") != (referenceVideo.codec?.lowercased() ?? "") {
                    return .videoCodecMismatch(item)
                }
                if video.width != referenceVideo.width || video.height != referenceVideo.height {
                    return .resolutionMismatch(item, expected: referenceVideo)
                }
                // PAR check
                let parEqual: Bool = {
                    switch (video.pixelAspectRatio, referenceVideo.pixelAspectRatio) {
                    case (nil, nil): return true
                    case let (l?, r?):
                        if let lv = l.doubleValue, let rv = r.doubleValue { return abs(lv - rv) <= 0.001 }
                        return l.stringValue == r.stringValue
                    case (nil, let r?):
                        if let v = r.doubleValue { return abs(v - 1.0) <= 0.001 }
                        let n = r.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
                        return n == "1:1" || n == "1" || n == "0:1"
                    case (let l?, nil):
                        if let v = l.doubleValue { return abs(v - 1.0) <= 0.001 }
                        let n = l.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
                        return n == "1:1" || n == "1" || n == "0:1"
                    }
                }()
                if !parEqual { return .pixelAspectMismatch(item) }

                // Frame rate check
                let frEqual: Bool = {
                    switch (video.frameRate?.value, referenceVideo.frameRate?.value) {
                    case (nil, nil): return true
                    case let (l?, r?): return abs(l - r) <= 0.01
                    default: return video.frameRate?.stringValue == referenceVideo.frameRate?.stringValue
                    }
                }()
                if !frEqual { return .frameRateMismatch(item) }
            }

            switch (referenceAudio, meta.audioStreams.first) {
            case (nil, nil): break
            case (nil, .some), (.some, nil):
                return .audioPresenceMismatch(item)
            case let (.some(refAudio), .some(audio)):
                if audio.channels != refAudio.channels { return .audioChannelMismatch(item) }
                if audio.sampleRate != refAudio.sampleRate { return .audioSampleRateMismatch(item) }
                if (audio.codec?.lowercased() ?? "") != (refAudio.codec?.lowercased() ?? "") {
                    return .audioCodecMismatch(item)
                }
            }
        }

        return .compatible
    }

    /// Groups items into clusters where all items in a cluster are merge-compatible.
    static func groupByCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> [[VideoItem]] {
        guard !items.isEmpty else { return [] }

        var groups: [[VideoItem]] = []

        for item in items {
            guard let itemMeta = metadata[item.id],
                  !itemMeta.videoStreams.isEmpty else {
                groups.append([item])
                continue
            }

            var placed = false
            for groupIndex in groups.indices {
                guard let first = groups[groupIndex].first,
                      let firstMeta = metadata[first.id] else { continue }

                let twoItems = [first, item]
                let twoMeta = [first.id: firstMeta, item.id: itemMeta]
                if case .compatible = checkMergeCompatibility(items: twoItems, metadata: twoMeta) {
                    groups[groupIndex].append(item)
                    placed = true
                    break
                }
            }

            if !placed {
                groups.append([item])
            }
        }

        return groups
    }

    /// Analyzes what each clip needs to change to conform to a reference clip's format.
    static func analyzeConformance(
        items: [VideoItem],
        referenceItemID: UUID,
        metadata: [UUID: VideoMetadata]
    ) -> [ConformanceAnalysis] {
        guard let refMeta = metadata[referenceItemID],
              let refVideo = refMeta.primaryVideoStream else { return [] }
        let refAudio = refMeta.audioStreams.first

        return items.map { item in
            guard let itemMeta = metadata[item.id],
                  let itemVideo = itemMeta.primaryVideoStream else {
                return ConformanceAnalysis(
                    id: item.id, itemName: item.name,
                    needsVideoReencode: true, needsAudioReencode: true,
                    videoMismatches: ["No video metadata"], audioMismatches: []
                )
            }
            let itemAudio = itemMeta.audioStreams.first

            var videoMismatches: [String] = []
            if (itemVideo.codec?.lowercased() ?? "") != (refVideo.codec?.lowercased() ?? "") {
                videoMismatches.append("Codec: \(itemVideo.codec ?? "?") → \(refVideo.codec ?? "?")")
            }
            if itemVideo.width != refVideo.width || itemVideo.height != refVideo.height {
                videoMismatches.append("Resolution: \(itemVideo.width ?? 0)x\(itemVideo.height ?? 0) → \(refVideo.width ?? 0)x\(refVideo.height ?? 0)")
            }
            let itemFR = itemVideo.frameRate?.value
            let refFR = refVideo.frameRate?.value
            if let i = itemFR, let r = refFR, abs(i - r) > 0.01 {
                videoMismatches.append("Frame rate: \(String(format: "%.2f", i)) → \(String(format: "%.2f", r))")
            } else if (itemFR == nil) != (refFR == nil) {
                videoMismatches.append("Frame rate mismatch")
            }

            var audioMismatches: [String] = []
            switch (itemAudio, refAudio) {
            case (nil, .some(let r)):
                audioMismatches.append("No audio → \(r.codec ?? "?") \(r.channels ?? 0)ch")
            case (.some, nil):
                audioMismatches.append("Audio will be removed")
            case let (.some(a), .some(r)):
                if (a.codec?.lowercased() ?? "") != (r.codec?.lowercased() ?? "") {
                    audioMismatches.append("Codec: \(a.codec ?? "?") → \(r.codec ?? "?")")
                }
                if a.channels != r.channels {
                    audioMismatches.append("Channels: \(a.channels ?? 0) → \(r.channels ?? 0)")
                }
                if a.sampleRate != r.sampleRate {
                    audioMismatches.append("Sample rate: \(a.sampleRate ?? 0) → \(r.sampleRate ?? 0)")
                }
            case (nil, nil):
                break
            }

            return ConformanceAnalysis(
                id: item.id,
                itemName: item.name,
                needsVideoReencode: !videoMismatches.isEmpty,
                needsAudioReencode: !audioMismatches.isEmpty,
                videoMismatches: videoMismatches,
                audioMismatches: audioMismatches
            )
        }
    }

}
