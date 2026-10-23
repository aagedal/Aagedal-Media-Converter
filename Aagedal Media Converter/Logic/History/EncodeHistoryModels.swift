//
//  EncodeHistoryModels.swift
//  Aagedal Media Converter
//
//  Codable models for the encode history (archive) and the last-session
//  snapshot. No media is stored — only source facts, settings and outcomes.
//

import Foundation

extension AppConstants {
    /// Whether started encodes are recorded in the encode history.
    static let encodeHistoryEnabledKey = "encodeHistoryEnabled"
    static let defaultEncodeHistoryEnabled = true
    /// Days of detailed history to keep. 0 keeps everything.
    static let encodeHistoryRetentionDaysKey = "encodeHistoryRetentionDays"
    static let defaultEncodeHistoryRetentionDays = 90
    /// Whether unfinished queue items are offered for restore on the next launch.
    static let lastSessionRestoreEnabledKey = "lastSessionRestoreEnabled"
    static let defaultLastSessionRestoreEnabled = true
    /// Whether quitting while an encode is running asks for confirmation.
    static let confirmQuitWhileEncodingKey = "confirmQuitWhileEncoding"
    static let defaultConfirmQuitWhileEncoding = true

    /// `~/Library/Application Support/AagedalMediaConverter/History`
    static var encodeHistoryDirectory: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let base = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        // UI tests get an isolated store so they never touch real history.
        if let storeID = ProcessInfo.processInfo.environment["AMC_UI_TEST_HISTORY_STORE_ID"], !storeID.isEmpty {
            return base.appendingPathComponent("UITest-\(storeID)", isDirectory: true)
        }
        return base
    }
}

// MARK: - Recipe

/// Per-item settings that can be re-applied to a fresh queue row.
struct EncodeRecipe: Codable, Equatable, Sendable {
    enum TimecodeMode: String, Codable, Sendable {
        case preserveSource
        case manual
    }

    var trimStart: Double?
    var trimEnd: Double?
    var cropConfig: CropConfig?
    var audioRoutingConfig: AudioRoutingConfig?
    var timecodeMode: TimecodeMode?
    var manualTimecode: String?
    var isMuted: Bool = false
    var comment: String = ""
    var metadataEditorSettings: MetadataEditorSettings?
    var includeDateTag: Bool = true
    var outputFileNameOverride: String?
    var recursiveEncodingGenerations: Int?
    var uploadEnabled: Bool = false
    var uploadSourceFile: Bool = false
    var subtitleEnabled: Bool = false
    var analyticsEnabled: Bool = false
    var selectedAudioStreamIndex: Int?
    var waveformBackgroundImagePath: String?
    /// Per-item preset chosen on an ungrouped row (`VideoItem.presetOverride`).
    var presetOverrideRawValue: String?

    init() {}

    init(item: VideoItem) {
        trimStart = item.trimStart
        trimEnd = item.trimEnd
        cropConfig = item.cropConfig
        audioRoutingConfig = item.audioRoutingConfig
        switch item.timecodeConfig?.mode {
        case .preserveSource:
            timecodeMode = .preserveSource
        case .manual(let value):
            timecodeMode = .manual
            manualTimecode = value
        case nil:
            timecodeMode = nil
        }
        isMuted = item.isMuted
        comment = item.comment
        metadataEditorSettings = item.metadataEditorSettings
        includeDateTag = item.includeDateTag
        outputFileNameOverride = item.outputFileNameOverride
        recursiveEncodingGenerations = item.recursiveEncodingGenerations
        uploadEnabled = item.uploadEnabled
        uploadSourceFile = item.uploadSourceFile
        subtitleEnabled = item.subtitleEnabled
        analyticsEnabled = item.analyticsEnabled
        selectedAudioStreamIndex = item.selectedAudioStreamIndex
        waveformBackgroundImagePath = item.waveformBackgroundImageURL?.path
        presetOverrideRawValue = item.presetOverride?.rawValue
    }

    var timecodeConfig: TimecodeConfig? {
        switch timecodeMode {
        case .preserveSource: return TimecodeConfig(mode: .preserveSource)
        case .manual: return TimecodeConfig(mode: .manual(manualTimecode ?? ""))
        case nil: return nil
        }
    }

    /// Applies the recipe to a freshly created placeholder row. The caller is
    /// responsible for recomputing `outputURL` when a name or preset override is set.
    func apply(to item: inout VideoItem) {
        item.trimStart = trimStart
        item.trimEnd = trimEnd
        item.cropConfig = cropConfig
        item.audioRoutingConfig = audioRoutingConfig
        item.timecodeConfig = timecodeConfig
        item.isMuted = isMuted
        item.comment = comment
        item.metadataEditorSettings = metadataEditorSettings
        item.includeDateTag = includeDateTag
        item.outputFileNameOverride = outputFileNameOverride
        item.recursiveEncodingGenerations = recursiveEncodingGenerations
        item.uploadEnabled = uploadEnabled
        item.uploadSourceFile = uploadSourceFile
        item.subtitleEnabled = subtitleEnabled
        item.analyticsEnabled = analyticsEnabled
        item.selectedAudioStreamIndex = selectedAudioStreamIndex
        item.waveformBackgroundImageURL = waveformBackgroundImagePath.map { URL(fileURLWithPath: $0) }
        item.presetOverride = presetOverrideRawValue.flatMap(ExportPreset.init(rawValue:))
    }

    /// Short human-readable list of the non-default settings, for history details.
    var summaryLines: [String] {
        var lines: [String] = []
        if trimStart != nil || trimEnd != nil {
            let start = trimStart.map(EncodeHistoryFormat.timecode)
                ?? String(localized: "start", comment: "Open trim start in a history settings summary.")
            let end = trimEnd.map(EncodeHistoryFormat.timecode)
                ?? String(localized: "end", comment: "Open trim end in a history settings summary.")
            lines.append(String(localized: "Trim \(start) – \(end)", comment: "History settings summary: trim range."))
        }
        if cropConfig != nil { lines.append(String(localized: "Crop", comment: "History settings summary.")) }
        if audioRoutingConfig != nil { lines.append(String(localized: "Audio routing", comment: "History settings summary.")) }
        if isMuted { lines.append(String(localized: "Muted", comment: "History settings summary.")) }
        if let timecodeMode {
            lines.append(timecodeMode == .manual
                ? String(localized: "Timecode \(manualTimecode ?? "")", comment: "History settings summary: manual start timecode.")
                : String(localized: "Timecode from source", comment: "History settings summary."))
        }
        if let outputFileNameOverride {
            lines.append(String(localized: "Name “\(outputFileNameOverride)”", comment: "History settings summary: custom output name."))
        }
        if let recursiveEncodingGenerations {
            lines.append(String(localized: "Recursive ×\(recursiveEncodingGenerations)", comment: "History settings summary: number of recursive encode generations."))
        }
        if metadataEditorSettings != nil { lines.append(String(localized: "Edited metadata", comment: "History settings summary.")) }
        if !comment.isEmpty { lines.append(String(localized: "Comment", comment: "History settings summary.")) }
        if subtitleEnabled { lines.append(String(localized: "Subtitles", comment: "History settings summary.")) }
        if analyticsEnabled { lines.append(String(localized: "Analytics", comment: "History settings summary.")) }
        if uploadEnabled {
            lines.append(uploadSourceFile
                ? String(localized: "Upload source", comment: "History settings summary.")
                : String(localized: "Upload", comment: "History settings summary."))
        }
        return lines
    }
}

// MARK: - Source

/// A file reference that survives moves where possible (bookmark) and falls
/// back to the recorded path.
struct HistoryFileReference: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data?

    /// Captures a bookmark so a later move on the same volume can be followed.
    init(url: URL) {
        path = url.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { url.lastPathComponent }

    /// The current location of the file, or nil when it can't be found.
    func resolve() -> URL? {
        if FileManager.default.fileExists(atPath: path) { return url }
        guard let bookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }
}

/// Probe facts about the source captured at encode start, for details and stats.
struct SourceFacts: Codable, Equatable, Sendable {
    var sizeBytes: Int64?
    var durationSeconds: Double?
    var container: String?
    var videoCodec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var audioCodec: String?
    var audioChannels: Int?

    init(item: VideoItem) {
        sizeBytes = item.size > 0 ? item.size : nil
        durationSeconds = item.durationSeconds > 0 ? item.durationSeconds : nil
        let metadata = item.metadata
        container = metadata?.formatName ?? (item.url.pathExtension.isEmpty ? nil : item.url.pathExtension.lowercased())
        let video = item.hasVideoStream ? metadata?.primaryVideoStream : nil
        videoCodec = video?.codec
        width = video?.width
        height = video?.height
        frameRate = video?.frameRate?.value
        let audio = metadata?.audioStreams.first
        audioCodec = audio?.codec
        audioChannels = audio?.channels
    }

    var resolutionLabel: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }
}

// MARK: - History

enum EncodeOutcome: String, Codable, Sendable, CaseIterable {
    case running
    case completed
    case failed
    case cancelled
    /// Was running when the app quit or crashed.
    case interrupted
}

struct EncodeRecord: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case imageSequence
    }

    var id: UUID = UUID()
    var sessionID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var outcome: EncodeOutcome = .running
    var errorMessage: String?
    var kind: Kind = .file
    var source: HistoryFileReference
    var sourceFacts: SourceFacts
    var recipe: EncodeRecipe
    var presetRawValue: String
    var presetDisplayName: String
    var groupName: String?
    /// Part of a merge/concat output shared with other records.
    var merged: Bool = false
    var outputPath: String?
    var outputSizeBytes: Int64?
    var deviceName: String

    var preset: ExportPreset? { ExportPreset(rawValue: presetRawValue) }
    var sourceName: String { source.fileName }
    var outputURL: URL? { outputPath.map { URL(fileURLWithPath: $0) } }

    var encodeDuration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

struct HistorySession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
    /// False when the app exited without a normal quit (crash, force quit, power loss).
    var endedCleanly: Bool = false
    var deviceName: String
    var appVersion: String?
}

struct EncodeHistoryFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = EncodeHistoryFile.currentVersion
    var sessions: [HistorySession] = []
    var records: [EncodeRecord] = []
}

// MARK: - Last session

struct SnapshotItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var source: HistoryFileReference
    var recipe: EncodeRecipe
    /// Status the row had when the snapshot was taken (waiting/converting/failed/cancelled).
    var statusLabel: String
}

struct SnapshotGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var presetRawValue: String?
    var concatEnabled: Bool
    var uploadEnabled: Bool
    var transcriptionEnabled: Bool
    var analyticsEnabled: Bool
    var sequentialNamingEnabled: Bool
    var items: [SnapshotItem]
}

struct LastSessionSnapshot: Codable, Equatable, Sendable {
    var savedAt: Date
    var presetRawValue: String
    var items: [SnapshotItem]
    var groups: [SnapshotGroup]

    var isEmpty: Bool { items.isEmpty && groups.allSatisfy(\.items.isEmpty) }
    var itemCount: Int { items.count + groups.reduce(0) { $0 + $1.items.count } }
}

// MARK: - Formatting

enum EncodeHistoryFormat {
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Cached: `Host.current()` can be slow.
    static let deviceName: String = Host.current().localizedName ?? "Unknown Mac"

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
