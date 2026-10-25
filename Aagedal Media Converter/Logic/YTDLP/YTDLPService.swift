// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol YTDLPUpdating: Sendable {
    func resolveYTDLPPath() async -> String?
    /// The yt-dlp-rs binary, or nil when it is disabled or unavailable.
    func resolveYTDLPRSPath() async -> String?
    func ensureDenoInstalled() async -> String?
}

extension YTDLPUpdateService: YTDLPUpdating {}

/// Per-download cancellation handle. Keeping this outside the service actor lets the UI
/// stop the correct download immediately even while several actor calls are suspended in
/// subprocess work.
final class YTDLPDownloadControl: @unchecked Sendable {
    fileprivate enum StopReason {
        case userRequested
        case liveRecordingStop
        case stalled
    }

    private let lock = NSLock()
    private var executionID: UUID?
    private var cancelAction: (@Sendable () -> Void)?
    private var stopReason: StopReason?
    private var outputPath: String?
    private var initialOutputSignature: OutputSignature?
    private var outputFinalized = false
    /// Every destination reported during the current attempt, for engine-fallback cleanup.
    private var reportedPaths: [String] = []

    private struct OutputSignature: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64

        init?(url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? UInt64,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
            self.size = size
            self.modified = modified
            self.inode = inode
        }
    }

    /// The destination reported by this download, retained after cancellation for recovery.
    func recordOutputPath(_ path: String, in folder: URL, finalized: Bool = false) {
        let destination = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        lock.withLock {
            if !reportedPaths.contains(path) { reportedPaths.append(path) }
            if outputPath != path {
                outputPath = path
                initialOutputSignature = OutputSignature(url: destination)
                outputFinalized = false
            }
            outputFinalized = outputFinalized || finalized
        }
    }

    /// Never infer ownership from a title or from other recently modified files.
    func partialFile(in folder: URL) -> URL? {
        let (recordedPath, initialSignature, finalized) = lock.withLock {
            (outputPath, initialOutputSignature, outputFinalized)
        }
        guard let path = recordedPath, !path.isEmpty else { return nil }
        let destination = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : folder.appendingPathComponent(path)
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedFolder.path.hasSuffix("/") ? resolvedFolder.path : resolvedFolder.path + "/"
        // Prefer an in-progress file when a previous completed destination also exists.
        let candidates = path.hasSuffix(".part")
            ? [destination]
            : [destination.appendingPathExtension("part"), destination]
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(prefix),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // With --no-part a live download writes directly to its destination.
            // A pre-existing, unchanged completed file is not evidence of recovery.
            if candidate == destination, !path.hasSuffix(".part"), !finalized,
               let initialSignature, OutputSignature(url: candidate) == initialSignature { continue }
            return candidate
        }
        return nil
    }

    @discardableResult
    func cancel() -> Bool {
        terminate(reason: .userRequested)
    }

    /// Returns and forgets the destinations of a failed attempt before another engine
    /// retries the same download.
    fileprivate func takeReportedPaths() -> [String] {
        lock.withLock {
            let paths = reportedPaths
            reportedPaths = []
            outputPath = nil
            initialOutputSignature = nil
            outputFinalized = false
            return paths
        }
    }

    @discardableResult
    func stopLiveRecording() -> Bool {
        terminate(reason: .liveRecordingStop)
    }

    fileprivate func install(id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        executionID = id
        cancelAction = cancel
        let shouldCancelImmediately = stopReason != nil
        lock.unlock()
        if shouldCancelImmediately {
            cancel()
        }
    }

    fileprivate func markStalled() -> Bool {
        terminate(reason: .stalled)
    }

    fileprivate func finish(id: UUID) -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        guard executionID == id else { return nil }
        let reason = stopReason
        executionID = nil
        cancelAction = nil
        stopReason = nil
        return reason
    }

    fileprivate func reason(id: UUID) -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        guard executionID == id else { return nil }
        return stopReason
    }

    private func terminate(reason: StopReason) -> Bool {
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        let cancelAction = cancelAction
        lock.unlock()
        cancelAction?()
        return cancelAction != nil
    }
}

/// Metadata fetched from yt-dlp for a video URL
struct YTDLPMetadata: Sendable {
    let title: String
    let duration: Double?
    let thumbnailURL: URL?
    let uploader: String?
    let description: String?
    /// Streams the clip picker can play, best first; later entries are
    /// fallbacks if a format URL won't load. Empty when none is playable.
    var previewStreams: [YTDLPPreviewStream] = []
    /// The downloader that answered the probe; downloads of the same URL
    /// normally use it too.
    var engine: YTDLPEngine = .ytdlp
}

/// Result of a successful download
struct YTDLPDownloadResult: Sendable {
    let outputURL: URL
    let title: String
    /// Full length of the source video as reported by the extractor, when known.
    var sourceDuration: Double? = nil
    /// The downloader that produced the file.
    var engine: YTDLPEngine = .ytdlp
    /// Why yt-dlp-rs was abandoned for yt-dlp, when it was.
    var engineFallbackReason: String? = nil
}

/// A time range of the source video to download instead of the whole thing.
///
/// yt-dlp's `--download-sections` stream-copies, so cuts snap to keyframes. We
/// therefore fetch `padding` extra seconds on each side and express the exact
/// in/out points as trim points on the downloaded file (see `trimRange`).
struct DownloadSection: Codable, Equatable, Sendable {
    /// Requested in-point in source seconds.
    let start: Double
    /// Requested out-point in source seconds; nil means "to the end".
    let end: Double?

    static let padding: Double = 5

    init?(start: Double, end: Double?) {
        guard start.isFinite, start >= 0 else { return nil }
        if let end {
            guard end.isFinite, end > start else { return nil }
        }
        // A range starting at zero and running to the end is the whole video.
        guard start > 0 || end != nil else { return nil }
        self.start = start
        self.end = end
    }

    var paddedStart: Double { max(0, start - Self.padding) }
    var paddedEnd: Double? { end.map { $0 + Self.padding } }

    /// Value for yt-dlp's `--download-sections`.
    var ytdlpArgument: String {
        let endValue = paddedEnd.map { Self.secondsArgument($0) } ?? "inf"
        return "*\(Self.secondsArgument(paddedStart))-\(endValue)"
    }

    /// Filename-safe label so clips of the same video don't collide with each
    /// other or with a full download (`--no-overwrites` would otherwise skip them).
    var fileNameLabel: String {
        let endLabel = end.map { Self.compactTime($0) } ?? "end"
        return "clip \(Self.compactTime(start))-\(endLabel)"
    }

    /// Maps the requested range onto the downloaded file.
    ///
    /// The file starts at (or slightly before) `paddedStart`. MP4 output uses an
    /// edit list so time zero is exactly `paddedStart`; Matroska/WebM instead shifts
    /// the keyframe pre-roll to non-negative timestamps, putting `paddedStart` a few
    /// seconds in. Because the cut end is exact in both cases, the pre-roll ("lead")
    /// is whatever the file holds beyond the requested padded length.
    func trimRange(fileDuration: Double, sourceDuration: Double?) -> (start: Double?, end: Double?) {
        guard fileDuration > 0 else { return (nil, nil) }
        let sourceEnd = sourceDuration.flatMap { $0 > 0 ? $0 : nil }
        let effectiveEnd: Double? = {
            switch (paddedEnd, sourceEnd) {
            case let (end?, source?): return min(end, source)
            case let (end?, nil): return end
            case let (nil, source?): return source
            case (nil, nil): return nil
            }
        }()

        var lead: Double = 0
        if let effectiveEnd {
            let expectedLength = effectiveEnd - paddedStart
            let measured = fileDuration - expectedLength
            // Pre-roll never exceeds a GOP; anything larger means the estimate is off.
            if measured > 0, measured < 15 { lead = measured }
        }

        let trimStart = lead + (start - paddedStart)
        let trimEnd = end.map { lead + ($0 - paddedStart) }
        return (
            trimStart > 0.05 ? min(trimStart, fileDuration) : nil,
            trimEnd.flatMap { $0 < fileDuration - 0.05 ? $0 : nil }
        )
    }

    /// Parses "90", "1:30", "1:02:03" or "1:30.5" into seconds.
    static func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                  let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds after a colon must stay below 60.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Formats seconds as "m:ss" or "h:mm:ss", keeping fractional seconds if present.
    static func formatTime(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let fraction = seconds - Double(whole)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        var result = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if fraction >= 0.005 {
            result += String(format: ".%02d", Int((fraction * 100).rounded()) % 100)
        }
        return result
    }

    private static func compactTime(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
        if m > 0 { return String(format: "%dm%02ds", m, s) }
        return "\(s)s"
    }

    private static func secondsArgument(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}

/// One entry from a flat-playlist probe — enough to populate a queue row before
/// the actual video is downloaded. Fields beyond `url` are best-effort: yt-dlp
/// often omits duration/thumbnail in flat-playlist mode for performance.
struct YTDLPPlaylistEntry: Sendable {
    let url: String
    let title: String
    let duration: Double?
    let thumbnailURL: URL?
    /// Set when the probe reports the entry can't be downloaded (private,
    /// deleted, members-only …). Such entries stay visible in the picker but
    /// are never queued.
    var unavailability: Unavailability? = nil

    var isAvailable: Bool { unavailability == nil }

    enum Unavailability: String, Sendable, Equatable {
        case privateVideo
        case deleted
        case membersOnly
        case premiumOnly
        case needsAuth
    }

    /// Classifies a flat-playlist entry. yt-dlp keeps placeholder titles like
    /// "[Private video]" for entries YouTube hides, and reports `availability`
    /// when the extractor knows it.
    static func unavailability(title: String?, availability: String?) -> Unavailability? {
        switch availability {
        case "private": return .privateVideo
        case "subscriber_only": return .membersOnly
        case "premium_only": return .premiumOnly
        case "needs_auth": return .needsAuth
        default: break
        }
        switch title?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "[private video]": return .privateVideo
        case "[deleted video]": return .deleted
        default: return nil
        }
    }

    /// Parses a `--flat-playlist -J` response. yt-dlp's flat-playlist sometimes
    /// uses `url` and sometimes `webpage_url` depending on the extractor.
    /// Single-video responses become a one-element list.
    static func parse(playlistJSON json: [String: Any]) -> [YTDLPPlaylistEntry] {
        func makeEntry(from obj: [String: Any]) -> YTDLPPlaylistEntry? {
            let entryURL = (obj["webpage_url"] as? String) ?? (obj["url"] as? String)
            guard let entryURL else { return nil }
            let rawTitle = obj["title"] as? String
            let title = rawTitle ?? "Untitled"
            let duration = obj["duration"] as? Double
            let thumbnailURL: URL? = {
                if let thumbStr = obj["thumbnail"] as? String,
                   let u = URL(string: thumbStr) {
                    return u
                }
                if let thumbnails = obj["thumbnails"] as? [[String: Any]],
                   let last = thumbnails.last,
                   let thumbStr = last["url"] as? String {
                    return URL(string: thumbStr)
                }
                return nil
            }()
            return YTDLPPlaylistEntry(
                url: entryURL, title: title, duration: duration, thumbnailURL: thumbnailURL,
                unavailability: unavailability(title: rawTitle, availability: obj["availability"] as? String)
            )
        }
        if let entries = json["entries"] as? [[String: Any]] {
            return entries.compactMap { makeEntry(from: $0) }
        }
        return makeEntry(from: json).map { [$0] } ?? []
    }
}

/// How aggressively yt-dlp should sanitize downloaded filenames.
enum YTDLPFilenameRestrictionMode: String, CaseIterable, Identifiable {
    /// Default — yt-dlp only strips characters illegal on the current OS (just `/` and NUL on macOS).
    case off
    /// Adds `--windows-filenames` so filenames are also safe on Windows / NTFS / cloud sync.
    /// Strips `< > : " / \ | ? *`, control chars, and trailing space/period. Keeps Unicode letters.
    case windowsSafe = "windows_safe"
    /// Adds `--restrict-filenames` — ASCII letters/digits/`_.-` only. Drops non-Latin scripts and many accents.
    case asciiOnly = "ascii_only"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .windowsSafe: return "Windows-safe (keeps Unicode letters)"
        case .asciiOnly: return "ASCII only (strips non-Latin scripts)"
        }
    }

    static var current: YTDLPFilenameRestrictionMode {
        let raw = UserDefaults.standard.string(forKey: AppConstants.ytdlpFilenameRestrictionModeKey)
            ?? AppConstants.defaultYTDLPFilenameRestrictionMode
        return YTDLPFilenameRestrictionMode(rawValue: raw) ?? .off
    }
}

struct PostDownloadVideo: Identifiable, Sendable {
    let slideIndex: Int
    let url: String
    let title: String
    let thumbnailURL: URL?
    /// Known for playlist entries; posts leave it unset.
    var duration: Double? = nil
    /// Playlist entries the probe flagged as not downloadable.
    var unavailability: YTDLPPlaylistEntry.Unavailability? = nil
    var isAvailable: Bool { unavailability == nil }
    var id: Int { slideIndex }
}

/// Instagram's extractor ignores img_index and may return either all carousel
/// slides (including photos without formats), or only videos titled "Video N".
struct InstagramCarouselSelection {
    let metadata: [String: Any]
    let playlistIndex: Int?

    static func isPostURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              ["instagram.com", "www.instagram.com"].contains(components.host?.lowercased() ?? "") else {
            return false
        }
        let path = components.path.split(separator: "/")
        return path.count == 2 && path[0] == "p"
    }

    static func select(from json: [String: Any], url: String) throws -> Self {
        let indexValue = URLComponents(string: url)?.queryItems?.first { $0.name == "img_index" }?.value
        let requestedIndex: Int?
        if let indexValue {
            guard let index = Int(indexValue), index > 0 else {
                throw YTDLPError.metadataFetchFailed("Instagram slide index must be a positive number.")
            }
            requestedIndex = index
        } else {
            requestedIndex = nil
        }
        guard let entries = json["entries"] as? [Any] else {
            guard requestedIndex == nil || requestedIndex == 1 else {
                throw YTDLPError.metadataFetchFailed("The selected Instagram slide was not found.")
            }
            return Self(metadata: json, playlistIndex: nil)
        }

        for (offset, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else { continue }
            if let requestedIndex {
                guard originalIndex(entry, offset: offset) == requestedIndex else { continue }
                guard hasVideo(entry) else {
                    throw YTDLPError.metadataFetchFailed("Instagram slide \(requestedIndex) is a photo, not a video.")
                }
            } else if !hasVideo(entry) {
                continue
            }
            return Self(metadata: entry, playlistIndex: (entry["playlist_index"] as? Int) ?? offset + 1)
        }
        throw YTDLPError.metadataFetchFailed(
            requestedIndex == nil
                ? "This Instagram post contains no downloadable videos."
                : "The selected Instagram slide was not found or is not a video."
        )
    }

    private static func originalIndex(_ entry: [String: Any], offset: Int) -> Int {
        // The GraphQL extractor skips photos but retains their position in
        // the title. playlist_index then counts videos, not original slides.
        if let title = entry["title"] as? String, title.hasPrefix("Video "),
           let index = Int(title.dropFirst(6)), index > 0 {
            return index
        }
        return (entry["playlist_index"] as? Int) ?? offset + 1
    }

    static func hasVideo(_ entry: [String: Any]) -> Bool {
        if let formats = entry["formats"] as? [[String: Any]] {
            return !formats.isEmpty
        }
        // Flat URL entries will be resolved by yt-dlp during download.
        return entry["url"] as? String != nil
    }

    static func videos(from json: [String: Any], url: String) -> [PostDownloadVideo] {
        let entries = (json["entries"] as? [Any]) ?? [json]
        return entries.enumerated().compactMap { offset, value in
            guard let entry = value as? [String: Any], hasVideo(entry),
                  var components = URLComponents(string: url) else { return nil }
            let index = originalIndex(entry, offset: offset)
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "img_index" }
            queryItems.append(URLQueryItem(name: "img_index", value: String(index)))
            components.queryItems = queryItems
            guard let entryURL = components.string else { return nil }
            let thumbnail = (entry["thumbnail"] as? String)
                ?? ((entry["thumbnails"] as? [[String: Any]])?.last?["url"] as? String)
            return PostDownloadVideo(slideIndex: index, url: entryURL,
                                          title: entry["title"] as? String ?? "Video",
                                          thumbnailURL: thumbnail.flatMap { URL(string: $0) })
        }
    }
}

/// The picker selects the extracted video ordinal, which differs from Twitter's
/// /video/N attachment number when photos precede videos. Keep this selection in
/// the saved URL so retries and scheduled downloads retain the user's choice.
struct TwitterPostSelection {
    static let indexQueryName = "amc_video_index"

    static func isPostURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return false }
        let hosts = ["twitter.com", "www.twitter.com", "m.twitter.com", "mobile.twitter.com",
                     "x.com", "www.x.com", "m.x.com", "mobile.x.com"]
        guard hosts.contains(components.host?.lowercased() ?? "") else { return false }
        let parts = components.path.split(separator: "/").map(String.init)
        let idPosition: Int
        if parts.count >= 4, parts[0] == "i", parts[1] == "web", parts[2] == "status" {
            idPosition = 3
        } else if parts.count >= 3, parts[1] == "status" {
            idPosition = 2
        } else if parts.count >= 2, parts[0] == "statuses" {
            idPosition = 1
        } else { return false }
        guard !parts[idPosition].isEmpty, parts[idPosition].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let suffix = Array(parts.dropFirst(idPosition + 1))
        return suffix.isEmpty || (suffix.count == 2 && ["video", "photo"].contains(suffix[0])
                                 && Int(suffix[1]).map { $0 > 0 } == true)
    }

    static func needsPicker(_ url: String) -> Bool {
        isPostURL(url) && !hasAttachmentIndex(url)
            && URLComponents(string: url)?.queryItems?.contains { $0.name == indexQueryName } != true
    }

    static func hasAttachmentIndex(_ url: String) -> Bool {
        let parts = URLComponents(string: url)?.path.split(separator: "/") ?? []
        return parts.count >= 2 && ["video", "photo"].contains(String(parts[parts.count - 2]))
    }

    static func selectedIndex(_ url: String) throws -> Int {
        guard let item = URLComponents(string: url)?.queryItems?.first(where: { $0.name == indexQueryName }) else { return 1 }
        guard let value = item.value, let index = Int(value), index > 0 else {
            throw YTDLPError.metadataFetchFailed("The selected Twitter/X video number is invalid.")
        }
        return index
    }

    static func sourceURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != indexQueryName }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? url
    }

    static func videos(from json: [String: Any], url: String) -> [PostDownloadVideo] {
        let entries = (json["entries"] as? [Any]) ?? [json]
        return entries.enumerated().compactMap { offset, value in
            guard let entry = value as? [String: Any],
                  InstagramCarouselSelection.hasVideo(entry),
                  var components = URLComponents(string: sourceURL(url)) else { return nil }
            let index = entry["playlist_index"] as? Int ?? offset + 1
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: indexQueryName, value: String(index)))
            components.queryItems = items
            guard let entryURL = components.string else { return nil }
            let thumbnail = entry["thumbnail"] as? String
                ?? ((entry["thumbnails"] as? [[String: Any]])?.last?["url"] as? String)
            return PostDownloadVideo(slideIndex: index, url: entryURL,
                                     title: entry["title"] as? String ?? "Video",
                                     thumbnailURL: thumbnail.flatMap { URL(string: $0) })
        }
    }

    static func metadata(from json: [String: Any], index: Int) throws -> [String: Any] {
        guard let entries = json["entries"] as? [Any] else { return json }
        for (offset, value) in entries.enumerated() {
            guard let entry = value as? [String: Any],
                  (entry["playlist_index"] as? Int ?? offset + 1) == index else { continue }
            return entry
        }
        throw YTDLPError.metadataFetchFailed("The selected Twitter/X video was not found.")
    }
}

/// Service for executing yt-dlp downloads
actor YTDLPService {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "YTDLPService")
    private let updateService: any YTDLPUpdating
    private let subprocessRunner: any SubprocessRunning
    private let engineFailures: YTDLPEngineFailureMemory

    private static let probeTimeout: Duration = .seconds(300)
    private static let probeOutputLimit = 16 * 1024 * 1024

    private struct ProbeResult {
        let subprocess: SubprocessResult
        let safeStandardError: String
    }

    init(
        updateService: any YTDLPUpdating = YTDLPUpdateService.shared,
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        engineFailures: YTDLPEngineFailureMemory = .shared
    ) {
        self.updateService = updateService
        self.subprocessRunner = subprocessRunner
        self.engineFailures = engineFailures
    }

    /// Runs `body` with the engine the router picks. A failed yt-dlp-rs attempt is retried
    /// once with yt-dlp (after `beforeFallback`), unless the user stopped it. `onAttempt`
    /// reports each engine (and the fallback reason, if any) just before it runs.
    private func withEngineFallback<T>(
        url: String,
        operation: YTDLPEngineOperation,
        beforeFallback: () -> Void = {},
        onAttempt: (YTDLPEngine, String?) -> Void = { _, _ in },
        _ body: (YTDLPEngine, String) async throws -> T
    ) async throws -> (value: T, engine: YTDLPEngine, fallbackReason: String?) {
        let rsPath = await updateService.resolveYTDLPRSPath()
        let decision = YTDLPEngineRouter.decide(
            url: url, operation: operation, rsAvailable: rsPath != nil,
            rsSkippedForSite: await engineFailures.isSkipped(url: url)
        )
        logger.info("[Engine] \(decision.engine.rawValue, privacy: .public) for \(String(describing: operation), privacy: .public): \(decision.reason, privacy: .public)")

        if decision.engine == .ytdlpRS, let rsPath {
            do {
                onAttempt(.ytdlpRS, nil)
                return (try await body(.ytdlpRS, rsPath), .ytdlpRS, nil)
            } catch {
                guard YTDLPEngineRouter.shouldFallBack(after: error), !Task.isCancelled else { throw error }
                let failures = await engineFailures.recordFailure(url: url)
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                logger.warning("[Engine] yt-dlp-rs failed (\(failures, privacy: .public) this session for this site), retrying with yt-dlp: \(reason, privacy: .public)")
                guard let ytdlpPath = await updateService.resolveYTDLPPath() else { throw error }
                beforeFallback()
                onAttempt(.ytdlp, reason)
                return (try await body(.ytdlp, ytdlpPath), .ytdlp, reason)
            }
        }
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        onAttempt(.ytdlp, nil)
        return (try await body(.ytdlp, ytdlpPath), .ytdlp, nil)
    }

    /// Arguments shared by every invocation. yt-dlp-rs bundles its EJS solver and caches
    /// nothing, so the remote-component and cache options only go to yt-dlp. Both get
    /// --ignore-config so neither picks up the user's own config files.
    private func commonArguments(engine: YTDLPEngine) async -> [String] {
        var arguments = ["--ignore-config"]
        if engine == .ytdlp {
            arguments += ["--remote-components", "ejs:github", "--cache-dir", AppConstants.ytdlpCacheDirectory.path]
        }
        if let denoPath = await updateService.ensureDenoInstalled() {
            arguments += ["--js-runtimes", "deno:\(denoPath)"]
        }
        return arguments
    }

    /// How long yt-dlp may produce no output before the stall watchdog kills it.
    /// Generous enough to cover slow Python startup and post-processing lulls.
    private static let stallThresholdSeconds: TimeInterval = 300
    private static let stallCheckIntervalNanos: UInt64 = 30_000_000_000 // 30s

    private final class DateBox: @unchecked Sendable {
        var value: Date

        init(value: Date) {
            self.value = value
        }
    }

    /// Reassembles arbitrary runner chunks into complete UTF-8 lines independently for
    /// stdout and stderr. yt-dlp progress lines can be split across pipe reads.
    private final class LineAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()

        func consume(
            _ chunk: SubprocessOutputChunk,
            handler: (String, Bool) -> Void
        ) {
            lock.lock()
            let lines: [String]
            switch chunk.stream {
            case .standardOutput:
                standardOutput.append(chunk.data)
                lines = Self.removeCompleteLines(from: &standardOutput)
            case .standardError:
                standardError.append(chunk.data)
                lines = Self.removeCompleteLines(from: &standardError)
            }
            lock.unlock()
            for line in lines {
                handler(line, chunk.stream == .standardError)
            }
        }

        func finish(handler: (String, Bool) -> Void) {
            lock.lock()
            let remaining = [
                (String(decoding: standardOutput, as: UTF8.self), false),
                (String(decoding: standardError, as: UTF8.self), true)
            ].filter { !$0.0.isEmpty }
            standardOutput.removeAll()
            standardError.removeAll()
            lock.unlock()
            for (line, isStandardError) in remaining {
                handler(line, isStandardError)
            }
        }

        /// Splits on CR as well as LF: ffmpeg (used for section and HLS downloads)
        /// redraws its stats line with bare carriage returns, which would otherwise
        /// stay buffered and starve both progress and the stall watchdog.
        private static func removeCompleteLines(from buffer: inout Data) -> [String] {
            var lines: [String] = []
            while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
                buffer.removeSubrange(...newline)
            }
            return lines
        }
    }

    /// Path to ffmpeg for post-processing
    private var ffmpegPath: String? {
        BinaryPathResolver.ffmpegPath
    }

    private func runProbe(ytdlpPath: String, arguments: [String], control: YTDLPDownloadControl? = nil) async throws -> ProbeResult {
        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: ytdlpPath,
            arguments: arguments
        )

        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            timeout: Self.probeTimeout,
            standardOutputCaptureLimit: Self.probeOutputLimit,
            standardErrorCaptureLimit: SubprocessRequest.defaultCaptureLimit,
            sensitiveArgumentNames: ["--cookies", "--cookies-from-browser"]
        )

        let executionID = UUID()
        let task = Task { [subprocessRunner] in
            try await subprocessRunner.run(request)
        }
        control?.install(id: executionID) { task.cancel() }
        defer { _ = control?.finish(id: executionID) }

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if control?.reason(id: executionID) != nil {
                throw YTDLPError.cancelled
            }
            return ProbeResult(
                subprocess: result,
                safeStandardError: request.redactedDiagnostic(result.standardErrorText)
            )
        } catch is CancellationError {
            if control?.reason(id: executionID) != nil {
                throw YTDLPError.cancelled
            }
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw YTDLPError.metadataFetchFailed("yt-dlp request timed out after five minutes")
            case .failedToStart:
                throw YTDLPError.metadataFetchFailed(error.localizedDescription)
            }
        }
    }

    private func probePostJSON(url: String, ytdlpPath: String, arguments: [String], control: YTDLPDownloadControl? = nil) async throws -> [String: Any] {
        let probe = try await runProbe(
            ytdlpPath: ytdlpPath,
            arguments: arguments + ["--flat-playlist", "--ignore-no-formats-error", "-J", "--no-warnings", "--", url],
            control: control
        )
        guard probe.subprocess.succeeded else {
            throw YTDLPError.metadataFetchFailed(probe.safeStandardError.isEmpty ? "Unknown error" : probe.safeStandardError)
        }
        guard probe.subprocess.discardedStandardOutputBytes == 0 else {
            throw YTDLPError.metadataFetchFailed("yt-dlp metadata response exceeded the 16 MB safety limit")
        }
        guard let json = try? JSONSerialization.jsonObject(with: probe.subprocess.standardOutput) as? [String: Any] else {
            throw YTDLPError.metadataFetchFailed("Failed to parse post metadata")
        }
        return json
    }

    private func probeInstagramPost(url: String, ytdlpPath: String, arguments: [String], control: YTDLPDownloadControl? = nil) async throws -> InstagramCarouselSelection {
        let json = try await probePostJSON(url: url, ytdlpPath: ytdlpPath, arguments: arguments, control: control)
        return try InstagramCarouselSelection.select(from: json, url: url)
    }

    func fetchPostVideos(url: String) async throws -> [PostDownloadVideo] {
        guard InstagramCarouselSelection.isPostURL(url) || TwitterPostSelection.isPostURL(url) else {
            throw YTDLPError.metadataFetchFailed("Enter an Instagram or Twitter/X post URL.")
        }
        let cookies = try YTDLPCookieSource.configured()
        defer { cookies.cleanup() }
        let json = try await withEngineFallback(url: url, operation: .postListing) { engine, path in
            let arguments = await commonArguments(engine: engine) + cookies.arguments
            return try await probePostJSON(url: url, ytdlpPath: path, arguments: arguments)
        }.value
        return TwitterPostSelection.isPostURL(url)
            ? TwitterPostSelection.videos(from: json, url: url)
            : InstagramCarouselSelection.videos(from: json, url: url)
    }

    private func probeMetadataJSON(url: String, ytdlpPath: String, arguments: [String]) async throws -> [String: Any] {
        if InstagramCarouselSelection.isPostURL(url) {
            return try await probeInstagramPost(url: url, ytdlpPath: ytdlpPath, arguments: arguments).metadata
        }
        if TwitterPostSelection.isPostURL(url) {
            let index = try TwitterPostSelection.selectedIndex(url)
            var probeArguments = arguments + ["--no-playlist"]
            if !TwitterPostSelection.hasAttachmentIndex(url) {
                probeArguments += ["--playlist-items", String(index)]
            }
            let post = try await probePostJSON(url: TwitterPostSelection.sourceURL(url), ytdlpPath: ytdlpPath, arguments: probeArguments)
            return try TwitterPostSelection.metadata(from: post, index: index)
        }
        let processStartTime = Date()
        let probe = try await runProbe(
            ytdlpPath: ytdlpPath,
            arguments: arguments + ["-j", "--no-download", "--no-warnings", "--", url]
        )
        let result = probe.subprocess

        let processElapsed = Date().timeIntervalSince(processStartTime)
        logger.info("[TIMING] yt-dlp metadata process completed in \(String(format: "%.2f", processElapsed))s, exit status: \(result.terminationStatus)")

        guard result.succeeded else {
            let errorMessage = probe.safeStandardError.isEmpty ? "Unknown error" : probe.safeStandardError
            logger.error("yt-dlp metadata fetch failed: \(errorMessage)")
            throw YTDLPError.metadataFetchFailed(errorMessage)
        }
        guard result.discardedStandardOutputBytes == 0 else {
            throw YTDLPError.metadataFetchFailed("yt-dlp metadata response exceeded the 16 MB safety limit")
        }
        guard let parsedJSON = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            throw YTDLPError.metadataFetchFailed("Failed to parse JSON response")
        }
        return parsedJSON
    }

    /// Fetches video metadata without downloading
    func fetchMetadata(url: String) async throws -> YTDLPMetadata {
        let startTime = Date()
        logger.info("[TIMING] fetchMetadata started")

        let cookies = try YTDLPCookieSource.configured()
        defer { cookies.cleanup() }
        let probe = try await withEngineFallback(url: url, operation: .metadata) { engine, ytdlpPath in
            let json = try await probeMetadataJSON(
                url: url, ytdlpPath: ytdlpPath,
                arguments: await commonArguments(engine: engine) + cookies.arguments
            )
            // A yt-dlp-rs result without formats points at an incomplete port; let yt-dlp try.
            if engine == .ytdlpRS, !InstagramCarouselSelection.hasVideo(json) {
                throw YTDLPError.metadataFetchFailed("yt-dlp-rs returned no formats")
            }
            return json
        }
        let json = probe.value
        let title = json["title"] as? String ?? "Unknown Title"
        let duration = json["duration"] as? Double
        let thumbnailURLString = json["thumbnail"] as? String
        let thumbnailURL = thumbnailURLString.flatMap { URL(string: $0) }
        let uploader = json["uploader"] as? String
        let description = json["description"] as? String

        let totalElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] fetchMetadata completed in \(String(format: "%.2f", totalElapsed))s for: \(title)")

        return YTDLPMetadata(
            title: title,
            duration: duration,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            description: description,
            previewStreams: YTDLPPreviewStream.candidates(fromMetadata: json),
            engine: probe.engine
        )
    }

    /// Probes a URL with `--flat-playlist -J` and returns its entries. Works for
    /// playlists, channels, and single-video URLs (the latter returns a single entry).
    func fetchPlaylistEntries(url: String) async throws -> [YTDLPPlaylistEntry] {
        let cookies = try YTDLPCookieSource.configured()
        defer { cookies.cleanup() }
        let json = try await withEngineFallback(url: url, operation: .playlistListing) { engine, ytdlpPath in
            let arguments = await commonArguments(engine: engine) + cookies.arguments
                + ["--flat-playlist", "-J", "--no-warnings", "--", url]
            let probe = try await runProbe(ytdlpPath: ytdlpPath, arguments: arguments)
            let result = probe.subprocess

            guard result.succeeded else {
                let errorMessage = probe.safeStandardError.isEmpty ? "Unknown error" : probe.safeStandardError
                throw YTDLPError.metadataFetchFailed(errorMessage)
            }

            guard result.discardedStandardOutputBytes == 0 else {
                throw YTDLPError.metadataFetchFailed("yt-dlp playlist response exceeded the 16 MB safety limit")
            }

            guard let json = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
                throw YTDLPError.metadataFetchFailed("Failed to parse playlist JSON")
            }
            if engine == .ytdlpRS, YTDLPPlaylistEntry.parse(playlistJSON: json).isEmpty {
                throw YTDLPError.metadataFetchFailed("yt-dlp-rs returned no playlist entries")
            }
            return json
        }.value

        let parsed = YTDLPPlaylistEntry.parse(playlistJSON: json)
        let unavailable = parsed.filter { !$0.isAvailable }.count
        logger.info("[YTDLPService] Playlist probe returned \(parsed.count) entries (\(unavailable) unavailable)")
        return parsed
    }

    /// Downloads a video using yt-dlp
    /// - Parameters:
    ///   - url: The video URL to download
    ///   - outputFolder: The folder to save the downloaded video
    ///   - forceOverwrite: If true, overwrites existing files instead of skipping
    ///   - liveFromStart: Whether to rewind live streams to the beginning
    ///   - audioOnly: Whether to download only the audio track (no video)
    ///   - section: Optional time range to download instead of the whole video
    ///   - progress: Callback for progress updates (progress 0-1, speed string, isLiveStream)
    ///   - titleUpdate: Callback when video title is discovered
    ///   - engineUpdate: Callback with the downloader about to run (and, after a yt-dlp-rs
    ///     failure, the fallback reason)
    /// - Returns: The path to the downloaded file
    func download(
        url: String,
        outputFolder: URL,
        forceOverwrite: Bool = false,
        liveFromStart: Bool = false,
        audioOnly: Bool = false,
        section: DownloadSection? = nil,
        control: YTDLPDownloadControl = YTDLPDownloadControl(),
        progress: @escaping @Sendable (Double, String?, Bool) -> Void,
        titleUpdate: @escaping @Sendable (String) -> Void = { _ in },
        engineUpdate: @escaping @Sendable (YTDLPEngine, String?) -> Void = { _, _ in }
    ) async throws -> YTDLPDownloadResult {
        let ffmpegPath = BinaryPathResolver.ffmpegPath
        let ffprobeExists = ffmpegPath.map {
            FileManager.default.isExecutableFile(
                atPath: (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ffprobe")
            )
        } ?? false
        let operation = YTDLPEngineOperation.download(.init(
            section: section != nil, audioOnly: audioOnly, liveFromStart: liveFromStart,
            hasFFmpeg: ffmpegPath != nil, hasFFprobe: ffprobeExists
        ))
        // Files present before the yt-dlp-rs attempt are never removed by its cleanup.
        let preexisting = YTDLPAttemptCleanup.snapshot(of: outputFolder)
        let outcome = try await withEngineFallback(url: url, operation: operation, beforeFallback: { [logger] in
            let removed = YTDLPAttemptCleanup.removeLeftovers(
                in: outputFolder, reportedPaths: control.takeReportedPaths(), preexisting: preexisting
            )
            if !removed.isEmpty {
                logger.info("[Engine] Removed \(removed.count, privacy: .public) partial file(s) from the yt-dlp-rs attempt")
            }
        }, onAttempt: engineUpdate) { engine, executablePath in
            try await runDownload(
                engine: engine, executablePath: executablePath, url: url, outputFolder: outputFolder,
                forceOverwrite: forceOverwrite, liveFromStart: liveFromStart, audioOnly: audioOnly,
                section: section, hasFFprobe: ffprobeExists, control: control,
                progress: progress, titleUpdate: titleUpdate
            )
        }
        var result = outcome.value
        result.engine = outcome.engine
        result.engineFallbackReason = outcome.fallbackReason
        return result
    }

    private func runDownload(
        engine: YTDLPEngine,
        executablePath ytdlpPath: String,
        url: String,
        outputFolder: URL,
        forceOverwrite: Bool,
        liveFromStart: Bool,
        audioOnly: Bool,
        section: DownloadSection?,
        hasFFprobe: Bool,
        control: YTDLPDownloadControl,
        progress: @escaping @Sendable (Double, String?, Bool) -> Void,
        titleUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> YTDLPDownloadResult {
        let downloadStartTime = Date()
        logger.info("[TIMING] download() started with \(engine.rawValue, privacy: .public)")

        // Note: --ignore-config prevents yt-dlp from reading user config files
        // Note: --remote-components ejs:github is required for YouTube JS challenge solving
        var args = await commonArguments(engine: engine)

        // Add ffmpeg location if available
        let ffmpegResolveStart = Date()
        let resolvedFFmpegPath = BinaryPathResolver.ffmpegPath
        let ffmpegResolveElapsed = Date().timeIntervalSince(ffmpegResolveStart)
        logger.info("[TIMING] ffmpeg path resolved in \(String(format: "%.3f", ffmpegResolveElapsed))s: \(resolvedFFmpegPath ?? "nil")")
        if let ffmpegPath = resolvedFFmpegPath {
            // yt-dlp needs the directory containing ffmpeg, not the binary itself
            let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
            logger.debug("Using ffmpeg dir: \(ffmpegDir)")
            args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        } else {
            logger.warning("No ffmpeg path available for yt-dlp postprocessing")
        }

        // Add browser cookies if configured
        let cookies = try YTDLPCookieSource.configured()
        defer { cookies.cleanup() }
        args.append(contentsOf: cookies.arguments)

        var outputTemplate = "%(title)s.%(ext)s"
        if InstagramCarouselSelection.isPostURL(url) {
            let selection = try await probeInstagramPost(url: url, ytdlpPath: ytdlpPath, arguments: args, control: control)
            if let index = selection.playlistIndex {
                args.append(contentsOf: ["--playlist-items", String(index)])
                // Carousel videos often share a title; keep each slide's file distinct.
                outputTemplate = "%(title)s [%(id)s].%(ext)s"
            }
        } else if TwitterPostSelection.isPostURL(url) {
            if !TwitterPostSelection.hasAttachmentIndex(url) {
                args.append(contentsOf: ["--playlist-items", String(try TwitterPostSelection.selectedIndex(url))])
            }
            outputTemplate = "%(title)s [%(id)s].%(ext)s"
        }

        if let section {
            args.append(contentsOf: ["--download-sections", section.ytdlpArgument])
            // `--print` implies `--quiet`, which makes yt-dlp (and yt-dlp-rs) run
            // ffmpeg with `-loglevel quiet`. Its stats lines are the only progress
            // for section downloads, so keep quiet mode off explicitly.
            args.append("--no-quiet")
            // yt-dlp-rs extension: tag the clip with the timecode its first frame
            // has in the whole video, so it lines up with full downloads. The frame
            // rate comes from ffprobe; without one it would only print a warning.
            if engine == .ytdlpRS, hasFFprobe {
                args.append("--section-timecode")
            }
            outputTemplate = outputTemplate.replacingOccurrences(
                of: ".%(ext)s", with: " (\(section.fileNameLabel)).%(ext)s"
            )
            logger.info("[YTDLPService] Downloading section \(section.ytdlpArgument, privacy: .public)")
        }

        if liveFromStart {
            args.append(contentsOf: ["--live-from-start", "--no-part"])
            logger.info("[YTDLPService] Downloading live stream from start (no-part)")
        }

        switch YTDLPFilenameRestrictionMode.current {
        case .off:
            break
        case .windowsSafe:
            args.append("--windows-filenames")
            logger.info("[YTDLPService] Filename restriction: windows-safe")
        case .asciiOnly:
            args.append("--restrict-filenames")
            logger.info("[YTDLPService] Filename restriction: ASCII only")
        }

        // Format selector: prefer audio-only stream when in audio-only mode, otherwise
        // grab best video+audio. `-x` (--extract-audio) makes yt-dlp post-process to a
        // standalone audio file when the chosen stream is muxed; with `--audio-format
        // best` the original codec is preserved (no re-encoding when avoidable).
        let formatSelector = audioOnly ? "bestaudio/best" : "bestvideo+bestaudio/best"
        args.append(contentsOf: ["-f", formatSelector])
        if audioOnly {
            args.append(contentsOf: ["-x", "--audio-format", "best"])
            logger.info("[YTDLPService] Audio-only download requested")
        }

        // yt-dlp maps the post text/video description to description and synopsis,
        // and the canonical source page URL to comment and purl. Its metadata
        // postprocessor copies the media streams without re-encoding them.
        args.append(contentsOf: [
            "--embed-metadata",
            "--no-embed-info-json",
            "--no-embed-chapters"
        ])

        args.append(contentsOf: [
            "--no-playlist",
            "--trim-filenames", "200",
            "--newline",
            "--progress",
            "--verbose",  // Enable verbose output to ensure we get stderr
            forceOverwrite ? "--force-overwrites" : "--no-overwrites",
            "--print", "before_dl:\(YTDLPProgressParser.liveStatusPrefix)%(live_status)s",
            "--print", "before_dl:\(YTDLPProgressParser.sourceDurationPrefix)%(duration)s",
            "--print", "after_move:filepath",
            "-o", outputTemplate,
            // "--" ends flag parsing so a URL that somehow starts with "-" can't be
            // interpreted as an option.
            "--",
            TwitterPostSelection.isPostURL(url) ? TwitterPostSelection.sourceURL(url) : url
        ])

        let configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(
            scriptPath: ytdlpPath,
            arguments: args
        )
        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            currentDirectoryURL: outputFolder,
            sensitiveArgumentNames: ["--cookies", "--cookies-from-browser"]
        )

        // Use a class to hold mutable state for thread-safe access from the handler
        final class ParsedState: @unchecked Sendable {
            var outputPath: String?
            var videoTitle: String = "Downloaded Video"
            var firstError: String?
            var fileAlreadyExists: Bool = false
            var existingFilePath: String?
            var sourceDuration: Double?
            var firstStdoutLogged: Bool = false
            var firstStderrLogged: Bool = false
            var firstProgressLogged: Bool = false
            /// Timestamp of the last non-empty line seen on stdout/stderr.
            /// The stall watchdog compares against this to decide whether yt-dlp
            /// has gone silent.
            var lastActivity: Date = Date()
            let lock = NSLock()

            func read<T>(_ block: (ParsedState) -> T) -> T {
                lock.lock()
                defer { lock.unlock() }
                return block(self)
            }

            func markActivity() {
                lock.lock()
                lastActivity = Date()
                lock.unlock()
            }

            func markFirstStdout() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStdoutLogged {
                    return false
                }
                firstStdoutLogged = true
                return true
            }

            func markFirstStderr() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStderrLogged {
                    return false
                }
                firstStderrLogged = true
                return true
            }

            func markFirstProgress() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstProgressLogged {
                    return false
                }
                firstProgressLogged = true
                return true
            }
        }
        let parsedState = ParsedState()
        let lineAccumulator = LineAccumulator()
        let processStartBox = DateBox(value: Date())

        // Capture logger for use in @Sendable closures and local functions
        let logger = self.logger

        // Helper to process a line of output
        @Sendable func processLine(_ trimmed: String, isStderr: Bool) {
            guard !trimmed.isEmpty else { return }

            // Feed the stall watchdog: any non-empty stdout/stderr line counts
            // as activity, including fragment-download progress for live streams.
            parsedState.markActivity()

            if isStderr {
                if parsedState.markFirstStderr() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stderr after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stderr: \(request.redactedDiagnostic(trimmed), privacy: .public)")
            } else {
                if parsedState.markFirstStdout() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stdout after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stdout: \(request.redactedDiagnostic(trimmed), privacy: .public)")
            }

            // Use extractor metadata as the source of truth. Fragmented HLS/DASH
            // and ffmpeg-backed VOD downloads otherwise look deceptively live in
            // yt-dlp's human-readable progress output.
            if YTDLPProgressParser.parseLiveStatus(trimmed) == true {
                progress(0.1, nil, true)
            }

            if let duration = YTDLPProgressParser.parseSourceDuration(trimmed) {
                parsedState.lock.lock()
                parsedState.sourceDuration = duration
                parsedState.lock.unlock()
            }

            // Section downloads run through ffmpeg; derive progress from its output
            // position relative to the padded range being fetched.
            if let section, let position = YTDLPProgressParser.parseFFmpegTime(trimmed) {
                let sourceDuration = parsedState.read { $0.sourceDuration }
                let rangeEnd = section.paddedEnd.map { end in sourceDuration.map { min(end, $0) } ?? end }
                    ?? sourceDuration
                if let rangeEnd, rangeEnd > section.paddedStart {
                    progress(min(position / (rangeEnd - section.paddedStart), 0.99), nil, false)
                }
            }

            // Parse progress from either stream
            if let progressInfo = YTDLPProgressParser.parse(trimmed) {
                logger.debug("Progress parsed: \(progressInfo.progress * 100)%, isLive: \(progressInfo.isLiveStream)")
                if parsedState.markFirstProgress() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp progress after \(String(format: "%.3f", delta))s")
                }
                var reported = progressInfo.progress
                // Setup lines map to coarse steps (e.g. 50% when ffmpeg starts). For
                // section downloads ffmpeg's position is the real progress, so keep
                // those steps low instead of jumping back once it reports.
                if section != nil, progressInfo.total == nil, progressInfo.speed == nil, reported < 1 {
                    reported = min(reported, 0.05)
                }
                progress(reported, progressInfo.speed, progressInfo.isLiveStream)
            }

            // Parse title from either stream
            if let title = YTDLPProgressParser.parseTitle(trimmed) {
                parsedState.lock.lock()
                let previousTitle = parsedState.videoTitle
                parsedState.videoTitle = title
                parsedState.lock.unlock()
                if title != previousTitle && title != "Downloaded Video" {
                    logger.info("Title discovered: \(title, privacy: .public)")
                    titleUpdate(title)
                }
            }

            // Parse output path (from merger or download destination)
            if let path = YTDLPProgressParser.parseOutputPath(trimmed) {
                control.recordOutputPath(path, in: outputFolder)
                parsedState.lock.lock()
                parsedState.outputPath = path
                parsedState.lock.unlock()
            }

            // Capture the FIRST error line we see — yt-dlp's initial ERROR: message
            // is the actionable summary ("Sign in to confirm you're not a bot",
            // "Video unavailable", etc.); subsequent lines are stack/detail that
            // look more alarming than they are in the UI.
            if let error = YTDLPProgressParser.parseError(trimmed) {
                parsedState.lock.lock()
                if parsedState.firstError == nil {
                    parsedState.firstError = request.redactedDiagnostic(error, limit: 2 * 1024)
                }
                parsedState.lock.unlock()
            }

            // Check for "already been downloaded" message (stdout only)
            if !isStderr && trimmed.contains("has already been downloaded") {
                logger.info("File already exists detected")
                parsedState.lock.lock()
                parsedState.fileAlreadyExists = true
                if let range = trimmed.range(of: "] "),
                   let endRange = trimmed.range(of: " has already been downloaded") {
                    let filename = String(trimmed[range.upperBound..<endRange.lowerBound])
                    parsedState.existingFilePath = filename
                }
                parsedState.lock.unlock()
            }

            // Parse output path from stdout (--print after_move:filepath).
            // yt-dlp prints an absolute path here, so require a leading slash.
            // This avoids capturing stray verbose/debug stdout (e.g. a raw title or
            // a warning line that happens to lack a "[" prefix) as the output path.
            if !isStderr && trimmed.hasPrefix("/") {
                control.recordOutputPath(trimmed, in: outputFolder, finalized: true)
                parsedState.lock.lock()
                parsedState.outputPath = trimmed
                parsedState.lock.unlock()
            }
        }

        let processSetupElapsed = Date().timeIntervalSince(downloadStartTime)
        logger.info("[TIMING] Process setup completed in \(String(format: "%.3f", processSetupElapsed))s, starting download process...")

        processStartBox.value = Date()
        parsedState.markActivity()

        let executionID = UUID()
        let subprocessTask = Task { [subprocessRunner] in
            try await subprocessRunner.run(request) { chunk in
                lineAccumulator.consume(chunk) { line, isStandardError in
                    processLine(
                        line.trimmingCharacters(in: .whitespacesAndNewlines),
                        isStderr: isStandardError
                    )
                }
            }
        }
        control.install(id: executionID) {
            subprocessTask.cancel()
        }
        defer { _ = control.finish(id: executionID) }

        // Stall watchdog: if yt-dlp produces no output for `stallThresholdSeconds`,
        // terminate it so the UI isn't stuck forever on a dead connection. Fragment
        // progress for live streams keeps feeding the watchdog, so legitimate live
        // recordings are unaffected.
        let stallThreshold = Self.stallThresholdSeconds
        let stallCheckInterval = Self.stallCheckIntervalNanos
        let watchdogControl = control
        let watchdogState = parsedState
        let watchdogLogger = logger
        let watchdogTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: stallCheckInterval)
                if Task.isCancelled { break }
                let last = watchdogState.read { $0.lastActivity }
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > stallThreshold {
                    watchdogLogger.warning("yt-dlp appears stalled (no output for \(Int(elapsed))s) — terminating")
                    _ = watchdogControl.markStalled()
                    break
                }
            }
        }
        defer { watchdogTask.cancel() }

        func throwCancellation(_ reason: YTDLPDownloadControl.StopReason) throws -> Never {
            switch reason {
            case .userRequested:
                logger.info("Download cancelled")
                throw YTDLPError.cancelled
            case .liveRecordingStop:
                logger.info("Live stream recording stopped")
                throw YTDLPError.liveRecordingStopped
            case .stalled:
                logger.warning("Download terminated due to stall")
                throw YTDLPError.stalled
            }
        }

        let subprocessResult: SubprocessResult
        do {
            subprocessResult = try await withTaskCancellationHandler {
                try await subprocessTask.value
            } onCancel: {
                _ = control.cancel()
            }
            lineAccumulator.finish { line, isStandardError in
                processLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines),
                    isStderr: isStandardError
                )
            }
        } catch {
            lineAccumulator.finish { line, isStandardError in
                processLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines),
                    isStderr: isStandardError
                )
            }
            if let reason = control.reason(id: executionID) {
                try throwCancellation(reason)
            }
            if error is CancellationError {
                throw error
            }
            throw YTDLPError.downloadFailed(request.redactedDiagnostic(error.localizedDescription))
        }

        let processRunElapsed = Date().timeIntervalSince(processStartBox.value)
        logger.info("[TIMING] Download process completed in \(String(format: "%.2f", processRunElapsed))s")

        if let reason = control.reason(id: executionID) {
            try throwCancellation(reason)
        }

        let terminationStatus = subprocessResult.terminationStatus

        // Read final state
        let firstError = parsedState.read { $0.firstError }
        let outputPath = parsedState.read { $0.outputPath }
        let videoTitle = parsedState.read { $0.videoTitle }
        let fileAlreadyExists = parsedState.read { $0.fileAlreadyExists }
        let existingFilePath = parsedState.read { $0.existingFilePath }
        let sourceDuration = parsedState.read { $0.sourceDuration }

        // Check if file already exists (detected via --no-overwrites)
        if fileAlreadyExists {
            let existingPath = existingFilePath ?? outputFolder.appendingPathComponent(videoTitle).path
            logger.info("File already exists at: \(existingPath, privacy: .auto)")
            throw YTDLPError.fileAlreadyExists(path: existingPath, title: videoTitle)
        }

        // Check exit status
        guard terminationStatus == 0 else {
            let diagnostic = request.redactedDiagnostic(subprocessResult.standardErrorText)
            let errorMessage = firstError
                ?? (diagnostic.isEmpty ? "Download failed with exit code \(terminationStatus)" : diagnostic)
            throw YTDLPError.downloadFailed(errorMessage)
        }

        // Note: Output path is captured from stdout via the readabilityHandler above
        // The --print after_move:filepath outputs the final path which we parse there
        logger.info("Final output path from parsing: \(outputPath ?? "nil", privacy: .auto)")

        // Verify output file exists
        guard let finalPath = outputPath else {
            throw YTDLPError.outputNotFound
        }

        let outputURL: URL
        if finalPath.hasPrefix("/") {
            outputURL = URL(fileURLWithPath: finalPath)
        } else {
            outputURL = outputFolder.appendingPathComponent(finalPath)
        }

        // Defense-in-depth: yt-dlp normally sanitizes %(title)s and would not emit a path
        // outside outputFolder, but the post-download path here is whatever the subprocess
        // printed — confine it to the user's chosen folder before we touch the filesystem.
        let resolvedOutput = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFolder = outputFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedOutput.path == resolvedFolder.path
            || resolvedOutput.path.hasPrefix(resolvedFolder.path + "/") else {
            logger.error("yt-dlp output path \(resolvedOutput.path, privacy: .public) is outside chosen folder \(resolvedFolder.path, privacy: .public)")
            throw YTDLPError.outputNotFound
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw YTDLPError.outputNotFound
        }

        if Task.isCancelled {
            _ = control.cancel()
        }
        if let reason = control.reason(id: executionID) {
            try throwCancellation(reason)
        }

        // Report 100% progress
        progress(1.0, nil, false)

        return YTDLPDownloadResult(outputURL: outputURL, title: videoTitle, sourceDuration: sourceDuration)
    }

}

enum YTDLPError: Error, LocalizedError {
    case binaryNotFound
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case outputNotFound
    case cancelled
    case liveRecordingStopped
    case fileAlreadyExists(path: String, title: String)
    case stalled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "yt-dlp binary not found"
        case .metadataFetchFailed(let message):
            return "Failed to fetch metadata: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .outputNotFound:
            return "Downloaded file not found"
        case .cancelled:
            return "Download was cancelled"
        case .liveRecordingStopped:
            return "Live stream recording stopped"
        case .fileAlreadyExists(let path, _):
            return "File already exists: \(path)"
        case .stalled:
            return "Download stalled — no activity for several minutes"
        }
    }
}
