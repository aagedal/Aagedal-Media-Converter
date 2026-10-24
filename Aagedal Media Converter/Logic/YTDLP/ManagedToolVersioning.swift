// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Download helpers whose app-managed copies are versioned under
/// `AppConstants.ytdlpToolsDirectory/versions/<tool>/<version>/<executable>`.
enum ManagedTool: String, CaseIterable, Sendable, Identifiable {
    case ytdlp = "yt-dlp"
    case deno = "deno"
    case ytdlpRS = "yt-dlp-rs"

    var id: String { rawValue }

    var executableName: String { rawValue }

    var displayName: String { rawValue }

    /// yt-dlp-rs ships inside the app; that copy is always selectable.
    var hasBundledBaseline: Bool { self == .ytdlpRS }

    /// yt-dlp and deno keep a stable `tools/<executable>` symlink pointing at
    /// the active version so existing resolution and running processes keep
    /// working while the target is switched atomically.
    var usesStableLink: Bool { self != .ytdlpRS }

    var autoUpdateKey: String {
        switch self {
        case .ytdlp: return AppConstants.ytdlpAutoUpdateKey
        case .deno: return AppConstants.denoAutoUpdateKey
        case .ytdlpRS: return AppConstants.ytdlpRSAutoUpdateKey
        }
    }

    var pinKey: String {
        switch self {
        case .ytdlp: return AppConstants.ytdlpPinnedVersionKey
        case .deno: return AppConstants.denoPinnedVersionKey
        case .ytdlpRS: return AppConstants.ytdlpRSPinnedVersionKey
        }
    }

    var lastCheckKey: String {
        switch self {
        case .ytdlp: return AppConstants.ytdlpLastUpdateCheckKey
        case .deno: return AppConstants.denoLastUpdateCheckKey
        case .ytdlpRS: return AppConstants.ytdlpRSLastUpdateCheckKey
        }
    }

    /// Legacy UserDefaults key recording the installed version (yt-dlp/deno).
    var recordedVersionKey: String? {
        switch self {
        case .ytdlp: return AppConstants.ytdlpVersionKey
        case .deno: return AppConstants.denoVersionKey
        case .ytdlpRS: return nil
        }
    }
}

/// Orders yt-dlp date versions (`2026.10.21`, nightly `2026.10.21.232415`),
/// deno semver (`v2.5.4`) and yt-dlp-rs semver with pre-release suffixes
/// (`0.3.0-beta.1` < `0.3.0-beta.2` < `0.3.0-rc.1` < `0.3.0`).
struct ManagedToolVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let numeric: [Int]
    let preRelease: [String]
    let description: String

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        guard !text.isEmpty else { return nil }
        let core: Substring
        let pre: Substring?
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            pre = text[text.index(after: dash)...]
        } else {
            core = text[...]
            pre = nil
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        var identifiers: [String] = []
        if let pre {
            identifiers = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        numeric = numbers
        preRelease = identifiers
        description = text
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = numeric
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(preRelease.map { Int($0).map(String.init) ?? $0 })
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private static func compare(_ lhs: Self, _ rhs: Self) -> ComparisonResult {
        let count = max(lhs.numeric.count, rhs.numeric.count)
        for index in 0..<count {
            let left = index < lhs.numeric.count ? lhs.numeric[index] : 0
            let right = index < rhs.numeric.count ? rhs.numeric[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        // A release ranks above any of its pre-releases.
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return left < right ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.preRelease.count == rhs.preRelease.count { return .orderedSame }
        return lhs.preRelease.count < rhs.preRelease.count ? .orderedAscending : .orderedDescending
    }
}

/// The user's version choice for one tool.
enum ManagedToolPin: Equatable, Sendable {
    /// Use the newest available version; automatic updates apply.
    case automatic
    /// Keep the copy bundled with the app (yt-dlp-rs only).
    case bundled
    /// Keep this downloaded version; automatic updates are paused.
    case version(String)

    static let bundledStorageValue = "@bundled"

    init(storageValue: String?) {
        switch storageValue {
        case nil, "": self = .automatic
        case Self.bundledStorageValue: self = .bundled
        case let value?: self = .version(value)
        }
    }

    var storageValue: String? {
        switch self {
        case .automatic: return nil
        case .bundled: return Self.bundledStorageValue
        case .version(let version): return version
        }
    }

    var isPinned: Bool { self != .automatic }
}

/// Which copy of a tool is active.
enum ManagedToolActiveChoice: Equatable, Sendable {
    case bundled
    case installed(String)
    case none
}

enum ManagedToolScheduledCheckDecision: Equatable, Sendable {
    case check
    case skip(SkipReason)

    enum SkipReason: Equatable, Sendable {
        case autoUpdateDisabled
        case pinned
        case notAppManaged
        case toolDisabled
        case checkedRecently
    }
}

enum ManagedToolLegacyMigration: Equatable, Sendable {
    /// Move the legacy `tools/<executable>` into `versions/<tool>/<version>/`.
    case adopt(version: String)
    /// That version is already installed in the versioned layout; replace the
    /// legacy file with the stable link without keeping a duplicate.
    case linkExisting(version: String)
}

/// Pure decisions for versioned tool management. Everything that touches the
/// file system or network lives in `ManagedToolStore` / `YTDLPUpdateService`.
enum ManagedToolPolicy {
    static let legacyVersionName = "legacy"

    /// Directory-safe version label, without a leading "v". Returns nil for
    /// labels that cannot be used as a single path component.
    static func normalizedVersionName(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if (text.first == "v" || text.first == "V"), text.dropFirst().first?.isNumber == true {
            text.removeFirst()
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !text.hasPrefix("."), text.count <= 64,
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    /// Newest first. Unparseable labels (e.g. "legacy") sort after every
    /// parseable version, in a stable alphabetical order.
    static func sortedNewestFirst(_ versions: [String]) -> [String] {
        versions.sorted { lhs, rhs in
            switch (ManagedToolVersion(lhs), ManagedToolVersion(rhs)) {
            case let (l?, r?): return l == r ? lhs > rhs : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs < rhs
            }
        }
    }

    /// Whether `candidate` is strictly newer than `reference`. An unparseable
    /// reference is treated as older than any parseable candidate.
    static func isNewer(_ candidate: String, than reference: String?) -> Bool {
        guard let candidateVersion = ManagedToolVersion(candidate) else { return false }
        guard let reference else { return true }
        guard let referenceVersion = ManagedToolVersion(reference) else { return true }
        return candidateVersion > referenceVersion
    }

    /// Pinned copy if it still exists, otherwise the newest of the installed
    /// versions and the bundled baseline. Ties prefer the bundled copy, which is
    /// signed with the app's identity.
    static func activeChoice(
        installed: [String],
        bundled: String?,
        pin: ManagedToolPin
    ) -> ManagedToolActiveChoice {
        switch pin {
        case .bundled where bundled != nil:
            return .bundled
        case .version(let version) where installed.contains(version):
            return .installed(version)
        default:
            break
        }
        guard let newest = sortedNewestFirst(installed).first else {
            return bundled != nil ? .bundled : .none
        }
        if let bundled, !isNewer(newest, than: bundled) {
            // An unparseable installed label never outranks the bundled copy.
            return .bundled
        }
        return .installed(newest)
    }

    /// Whether a release should be downloaded: it is newer than every installed
    /// version and the bundled baseline, and not already present.
    static func shouldInstall(latest: String, installed: [String], bundled: String?) -> Bool {
        guard let latest = normalizedVersionName(latest), ManagedToolVersion(latest) != nil else { return false }
        if installed.contains(where: { ManagedToolVersion($0) == ManagedToolVersion(latest) }) { return false }
        let newestKnown = sortedNewestFirst(installed + [bundled].compactMap { $0 })
            .first { ManagedToolVersion($0) != nil }
        return isNewer(latest, than: newestKnown)
    }

    /// Versions to delete: keep the `keep` newest plus anything protected
    /// (the active and pinned versions).
    static func versionsToPrune(installed: [String], keep: Int, protected: Set<String>) -> [String] {
        let ordered = sortedNewestFirst(installed)
        var kept = 0
        var removable: [String] = []
        for version in ordered {
            if protected.contains(version) { continue }
            if kept < keep {
                kept += 1
            } else {
                removable.append(version)
            }
        }
        return removable
    }

    static func scheduledCheckDecision(
        autoUpdateEnabled: Bool,
        pin: ManagedToolPin,
        isAppManagedSource: Bool,
        isToolEnabled: Bool,
        lastCheck: Date?,
        now: Date,
        interval: TimeInterval
    ) -> ManagedToolScheduledCheckDecision {
        guard isToolEnabled else { return .skip(.toolDisabled) }
        guard isAppManagedSource else { return .skip(.notAppManaged) }
        guard autoUpdateEnabled else { return .skip(.autoUpdateDisabled) }
        guard !pin.isPinned else { return .skip(.pinned) }
        if let lastCheck, now.timeIntervalSince(lastCheck) < interval, lastCheck <= now {
            return .skip(.checkedRecently)
        }
        return .check
    }

    /// Whether `--version` output reports `expected` (e.g. "2026.10.21",
    /// "deno 2.5.4 (stable, …)", "yt-dlp-rs 0.3.0-beta.1").
    static func versionOutput(_ output: String, matches expected: String) -> Bool {
        guard let expectedVersion = ManagedToolVersion(expected) else { return false }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),"))
        return output.components(separatedBy: separators).contains { token in
            guard let version = ManagedToolVersion(token) else { return false }
            return version == expectedVersion && version.preRelease == expectedVersion.preRelease
        }
    }

    /// How to move a pre-versioning install (a regular file at
    /// `tools/<executable>`) into the versioned layout without re-downloading.
    static func legacyMigration(
        legacyIsRegularFile: Bool,
        recordedVersion: String?,
        versionFileContents: String?,
        installed: [String]
    ) -> ManagedToolLegacyMigration? {
        guard legacyIsRegularFile else { return nil }
        let version = normalizedVersionName(recordedVersion)
            ?? normalizedVersionName(versionFileContents)
            ?? legacyVersionName
        if installed.contains(version) {
            return .linkExisting(version: version)
        }
        return .adopt(version: version)
    }
}

/// State of one managed tool for the settings UI.
struct ManagedToolSnapshot: Equatable, Sendable {
    let tool: ManagedTool
    /// Downloaded versions, newest first.
    let installedVersions: [String]
    let bundledVersion: String?
    let activeChoice: ManagedToolActiveChoice
    let pin: ManagedToolPin
    /// False when Homebrew/custom is selected; versions then do not apply.
    let isAppManaged: Bool
    let autoUpdateEnabled: Bool
    let lastCheck: Date?

    var activeVersion: String? {
        switch activeChoice {
        case .bundled: return bundledVersion
        case .installed(let version): return version
        case .none: return nil
        }
    }
}

/// A yt-dlp-rs GitHub release with its Apple Silicon archive and checksums.
struct YTDLPRSRelease: Equatable, Sendable {
    static let target = "aarch64-apple-darwin"

    let tag: String
    let version: String
    let archiveURL: URL
    let checksumURL: URL

    var assetName: String { Self.assetName(forTag: tag) }
    var archiveDirectoryName: String { "yt-dlp-rs-\(tag)-\(Self.target)" }

    static func assetName(forTag tag: String) -> String {
        "yt-dlp-rs-\(tag)-\(target).tar.gz"
    }
}

enum YTDLPRSReleaseSelector {
    /// Newest non-draft release (pre-releases included) that provides the
    /// Apple Silicon archive and `SHA256SUMS`, from the GitHub releases list.
    static func newest(fromGitHubReleasesJSON data: Data) throws -> YTDLPRSRelease? {
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw YTDLPUpdateError.parseError
        }
        var best: (version: ManagedToolVersion, release: YTDLPRSRelease)?
        for release in releases {
            guard (release["draft"] as? Bool) != true,
                  let tag = release["tag_name"] as? String,
                  let name = ManagedToolPolicy.normalizedVersionName(tag),
                  let version = ManagedToolVersion(name),
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            var archiveURL: URL?
            var checksumURL: URL?
            for asset in assets {
                guard let assetName = asset["name"] as? String,
                      let link = asset["browser_download_url"] as? String,
                      let url = URL(string: link), url.scheme == "https" else { continue }
                if assetName == YTDLPRSRelease.assetName(forTag: tag) {
                    archiveURL = url
                } else if assetName == "SHA256SUMS" {
                    checksumURL = url
                }
            }
            guard let archiveURL, let checksumURL else { continue }
            if best == nil || version > best!.version {
                best = (version, YTDLPRSRelease(tag: tag, version: name, archiveURL: archiveURL, checksumURL: checksumURL))
            }
        }
        return best?.release
    }
}
