// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A modest-resolution stream the clip picker plays while in and out points are
/// set. It is chosen from the `formats` of the metadata probe, so the preview
/// costs no extra downloader run. Format URLs expire (YouTube after ~6 hours),
/// which is fine for a sheet that is open for minutes.
struct YTDLPPreviewStream: Sendable, Equatable {
    let videoURL: URL
    /// Separate audio for adaptive (video-only) formats; nil when muxed or silent.
    let audioURL: URL?
    /// Headers the extractor says the URLs need (User-Agent, Referer, …).
    let httpHeaders: [String: String]
    let width: Int?
    let height: Int?
    let frameRate: Double?

    /// Preview streams stay at or below this height to start quickly.
    static let maximumHeight = 720

    private static let playableProtocols: Set<String> = ["https", "http", "m3u8", "m3u8_native"]

    /// Picks the preview stream from a `-j` metadata object, or nil when no
    /// format can be played directly (storyboards, DASH segment lists, RTMP …).
    static func select(fromMetadata json: [String: Any]) -> YTDLPPreviewStream? {
        var formats = (json["formats"] as? [[String: Any]] ?? []).compactMap(Format.init)
        // Single-format extractors put the URL on the info dict itself.
        if formats.isEmpty, let single = Format(json) { formats = [single] }
        let playable = formats.filter { playableProtocols.contains($0.protocolName) }

        let muxed = playable.filter { $0.hasVideo && $0.hasAudio }.max(by: Format.videoOrder)
        let videoOnly = playable.filter { $0.hasVideo && !$0.hasAudio }.max(by: Format.videoOrder)
        let audioOnly = playable.filter { !$0.hasVideo && $0.hasAudio }.max(by: Format.audioOrder)

        let chosenVideo: Format
        var chosenAudio: Format?
        switch (muxed, videoOnly) {
        case let (muxed?, video?):
            // One stream is simpler; take it unless the adaptive pair looks clearly better.
            if audioOnly != nil, Format.videoOrder(muxed, video), video.height ?? 0 > muxed.height ?? 0 {
                chosenVideo = video
                chosenAudio = audioOnly
            } else {
                chosenVideo = muxed
            }
        case let (muxed?, nil):
            chosenVideo = muxed
        case let (nil, video?):
            chosenVideo = video
            chosenAudio = audioOnly
        case (nil, nil):
            return nil
        }

        let fallbackRate = (json["fps"] as? NSNumber)?.doubleValue
        return YTDLPPreviewStream(
            videoURL: chosenVideo.url,
            audioURL: chosenAudio?.url,
            httpHeaders: chosenVideo.headers,
            width: chosenVideo.width,
            height: chosenVideo.height,
            frameRate: chosenVideo.fps ?? fallbackRate
        )
    }

    private struct Format {
        let url: URL
        let protocolName: String
        let hasVideo: Bool
        let hasAudio: Bool
        let videoCodec: String
        let audioCodec: String
        let width: Int?
        let height: Int?
        let fps: Double?
        let bitrate: Double
        let languagePreference: Int
        let isDynamicRangeCompressed: Bool
        let headers: [String: String]

        init?(_ json: [String: Any]) {
            guard let string = json["url"] as? String, let url = URL(string: string),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self.url = url
            protocolName = (json["protocol"] as? String)?.lowercased() ?? url.scheme?.lowercased() ?? ""
            let vcodec = (json["vcodec"] as? String)?.lowercased()
            let acodec = (json["acodec"] as? String)?.lowercased()
            width = (json["width"] as? NSNumber)?.intValue
            height = (json["height"] as? NSNumber)?.intValue
            // Missing codecs mean "unknown": trust the dimensions for video, and
            // treat an unknown audio codec beside known video as muxed audio.
            hasVideo = vcodec.map { $0 != "none" } ?? (height != nil || width != nil)
            hasAudio = acodec.map { $0 != "none" } ?? (vcodec == nil && hasVideo)
            guard hasVideo || hasAudio else { return nil }
            videoCodec = vcodec ?? ""
            audioCodec = acodec ?? ""
            fps = (json["fps"] as? NSNumber)?.doubleValue
            bitrate = (json["tbr"] as? NSNumber)?.doubleValue
                ?? (json["abr"] as? NSNumber)?.doubleValue ?? 0
            languagePreference = (json["language_preference"] as? NSNumber)?.intValue ?? 0
            isDynamicRangeCompressed = (json["format_id"] as? String)?.hasSuffix("-drc") == true
            headers = (json["http_headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        }

        /// H.264 decodes in hardware everywhere; AV1 only on recent Macs.
        private var codecRank: Int {
            if videoCodec.hasPrefix("avc") || videoCodec.hasPrefix("h264") { return 3 }
            if videoCodec.hasPrefix("hev") || videoCodec.hasPrefix("hvc") || videoCodec.hasPrefix("h265") { return 2 }
            if videoCodec.hasPrefix("vp9") || videoCodec.hasPrefix("vp09") { return 1 }
            return 0
        }

        /// Plain HTTP seeks with range requests; HLS needs a playlist round trip.
        private var protocolRank: Int { protocolName.hasPrefix("http") ? 1 : 0 }

        /// Within the height limit taller wins; above it shorter wins.
        private var heightRank: Int {
            guard let height else { return 0 }
            return height <= YTDLPPreviewStream.maximumHeight ? 10_000 + height : 10_000 - height
        }

        /// `a < b` when b is the better preview video.
        static func videoOrder(_ a: Format, _ b: Format) -> Bool {
            (a.heightRank, a.codecRank, a.protocolRank, -a.bitrate)
                < (b.heightRank, b.codecRank, b.protocolRank, -b.bitrate)
        }

        /// `a < b` when b is the better preview audio: original language, AAC
        /// (plays with any video container), uncompressed dynamics, ~128 kbps.
        static func audioOrder(_ a: Format, _ b: Format) -> Bool {
            func key(_ f: Format) -> (Int, Int, Int, Int, Double) {
                (f.languagePreference, f.audioCodec.hasPrefix("mp4a") ? 1 : 0,
                 f.isDynamicRangeCompressed ? 0 : 1, f.protocolRank, -abs(f.bitrate - 128))
            }
            return key(a) < key(b)
        }
    }
}
