// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The downloader binary used for one yt-dlp operation.
enum YTDLPEngine: String, Sendable, Equatable {
    /// The native Rust port (beta, bundled).
    case ytdlpRS = "yt-dlp-rs"
    /// Upstream Python yt-dlp.
    case ytdlp = "yt-dlp"
}

/// What the app is about to ask the downloader to do, including the options that
/// decide whether yt-dlp-rs can do it. See docs/ytdlp-rs-integration.md.
enum YTDLPEngineOperation: Sendable, Equatable {
    /// `-j --no-download` for a single video (also Twitter/X post probes).
    case metadata
    /// `--flat-playlist -J` for playlists, channels and single videos.
    case playlistListing
    /// `--flat-playlist --ignore-no-formats-error -J` for multi-video posts.
    case postListing
    case download(Download)

    struct Download: Sendable, Equatable {
        var section: Bool = false
        var audioOnly: Bool = false
        var liveFromStart: Bool = false
        /// An ffmpeg executable is configured (`--ffmpeg-location`).
        var hasFFmpeg: Bool = true
        /// An `ffprobe` executable sits beside ffmpeg.
        var hasFFprobe: Bool = true
    }
}

struct YTDLPEngineDecision: Sendable, Equatable {
    let engine: YTDLPEngine
    /// Diagnostic explanation for the log; not user-facing.
    let reason: String
}

/// Decides between yt-dlp-rs and yt-dlp. Only sites yt-dlp-rs ports fully (and that the
/// app's features work with) are routed to it; everything else uses yt-dlp.
enum YTDLPEngineRouter {
    /// yt-dlp-rs failures for one site after which the rest of the session uses yt-dlp.
    static let sessionFailureLimit = 2

    struct Site: Sendable, Equatable {
        /// Stable key for the per-session failure memory.
        let id: String
        /// Exact hosts.
        let hosts: [String]
        /// Hosts whose subdomains (www., m., music., vm., …) also match.
        let domains: [String]
        /// Playlist/channel/user listings are ported for this site.
        let supportsListing: Bool
    }

    /// yt-dlp-rs 0.3.0 sites ported against upstream without caveats the app relies on.
    /// Dailymotion is excluded: it needs browser impersonation, which yt-dlp-rs lacks.
    static let supportedSites: [Site] = [
        Site(id: "youtube", hosts: ["youtu.be"],
             domains: ["youtube.com", "youtube-nocookie.com"], supportsListing: true),
        Site(id: "instagram", hosts: [], domains: ["instagram.com"], supportsListing: false),
        Site(id: "tiktok", hosts: [], domains: ["tiktok.com"], supportsListing: true),
        Site(id: "twitter", hosts: ["t.co"], domains: ["x.com", "twitter.com"], supportsListing: false),
        Site(id: "facebook", hosts: ["fb.watch", "www.fb.watch"], domains: ["facebook.com"], supportsListing: false),
        Site(id: "reddit", hosts: ["redd.it", "www.redd.it"], domains: ["reddit.com"], supportsListing: false),
        Site(id: "vimeo", hosts: [], domains: ["vimeo.com"], supportsListing: false),
        Site(id: "twitch", hosts: [], domains: ["twitch.tv"], supportsListing: true),
        Site(id: "bluesky", hosts: [], domains: ["bsky.app"], supportsListing: false),
        Site(id: "soundcloud", hosts: [], domains: ["soundcloud.com"], supportsListing: false),
        Site(id: "bandcamp", hosts: [], domains: ["bandcamp.com"], supportsListing: false),
    ]

    /// The supported site for an http(s) URL, matching hosts case-insensitively and
    /// subdomains only on label boundaries (`notyoutube.com` does not match).
    static func site(for url: String) -> Site? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return supportedSites.first { site in
            site.hosts.contains(host)
                || site.domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    static func decide(
        url: String,
        operation: YTDLPEngineOperation,
        rsAvailable: Bool,
        rsSkippedForSite: Bool = false
    ) -> YTDLPEngineDecision {
        func ytdlp(_ reason: String) -> YTDLPEngineDecision { .init(engine: .ytdlp, reason: reason) }
        guard rsAvailable else { return ytdlp("yt-dlp-rs is disabled or unavailable") }
        guard let site = site(for: url) else { return ytdlp("site is not on the yt-dlp-rs list") }
        guard !rsSkippedForSite else {
            return ytdlp("yt-dlp-rs failed \(sessionFailureLimit)+ times for \(site.id) this session")
        }
        // Carousel probes depend on --ignore-no-formats-error, which yt-dlp-rs accepts
        // but ignores, so posts with photo slides would fail outright.
        if site.id == "instagram", isInstagramPost(url) {
            return ytdlp("Instagram posts need --ignore-no-formats-error")
        }
        switch operation {
        case .metadata:
            break
        case .playlistListing:
            guard site.supportsListing else { return ytdlp("listings are not ported for \(site.id)") }
        case .postListing:
            guard site.id == "twitter" else { return ytdlp("post listing is not ported for \(site.id)") }
        case .download(let options):
            if options.liveFromStart { return ytdlp("--live-from-start recordings use yt-dlp") }
            // yt-dlp-rs never looks up ffmpeg itself; merging, -x and --embed-metadata
            // all need --ffmpeg-location.
            if !options.hasFFmpeg { return ytdlp("no ffmpeg for merging and metadata") }
            // yt-dlp-rs -x requires ffprobe (no ffmpeg fallback); the bundled ffmpeg has none.
            if options.audioOnly, !options.hasFFprobe { return ytdlp("audio extraction needs ffprobe") }
        }
        return .init(engine: .ytdlpRS, reason: "\(site.id) is supported by yt-dlp-rs")
    }

    private static func isInstagramPost(_ url: String) -> Bool {
        let parts = URLComponents(string: url)?.path.split(separator: "/") ?? []
        return parts.first == "p"
    }

    /// Whether a failed yt-dlp-rs attempt should be retried once with yt-dlp.
    /// User stops and app-side configuration errors never are.
    static func shouldFallBack(after error: Error) -> Bool {
        if error is CancellationError || error is CookieError { return false }
        guard let error = error as? YTDLPError else { return true }
        switch error {
        case .cancelled, .liveRecordingStopped, .fileAlreadyExists:
            return false
        case .binaryNotFound, .metadataFetchFailed, .downloadFailed, .outputNotFound, .stalled:
            return true
        }
    }
}

/// In-memory, per-session yt-dlp-rs failure counts per site.
actor YTDLPEngineFailureMemory {
    static let shared = YTDLPEngineFailureMemory()

    private let limit: Int
    private var failures: [String: Int] = [:]

    init(limit: Int = YTDLPEngineRouter.sessionFailureLimit) {
        self.limit = limit
    }

    func isSkipped(url: String) -> Bool {
        guard let site = YTDLPEngineRouter.site(for: url) else { return false }
        return failures[site.id, default: 0] >= limit
    }

    /// Returns the site's failure count after recording this one.
    @discardableResult
    func recordFailure(url: String) -> Int {
        guard let site = YTDLPEngineRouter.site(for: url) else { return 0 }
        failures[site.id, default: 0] += 1
        return failures[site.id, default: 0]
    }
}

/// Removes files a failed yt-dlp-rs download left in the output folder, so the yt-dlp
/// retry neither reports them as "already downloaded" nor leaves orphans behind. Only
/// files that did not exist before the attempt and that share a reported destination's
/// stem are removed.
enum YTDLPAttemptCleanup {
    static func snapshot(of folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    @discardableResult
    static func removeLeftovers(in folder: URL, reportedPaths: [String], preexisting: Set<String>) -> [URL] {
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let stems = Set(reportedPaths.compactMap { path -> String? in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                    == resolvedFolder else { return nil }
            return stem(of: url.lastPathComponent)
        }.filter { !$0.isEmpty })
        guard !stems.isEmpty else { return [] }

        var removed: [URL] = []
        for name in snapshot(of: folder).subtracting(preexisting)
        where stems.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) {
            let candidate = folder.appendingPathComponent(name)
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if (try? FileManager.default.removeItem(at: candidate)) != nil {
                removed.append(candidate)
            }
        }
        return removed
    }

    /// "Title.f137.mp4.part" → "Title"; "Title.mp4" → "Title".
    static func stem(of fileName: String) -> String {
        var name = fileName
        while name.hasSuffix(".part") { name.removeLast(5) }
        name = (name as NSString).deletingPathExtension
        if let range = name.range(of: #"\.f[0-9A-Za-z_-]+$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }
}
