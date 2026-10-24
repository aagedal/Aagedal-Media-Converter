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
        // UI tests get an isolated store in the app-owned fixture directory so
        // they never touch (or leave folders inside) the real history.
        let environment = ProcessInfo.processInfo.environment
        let storeID = environment["AMC_UI_TEST_HISTORY_STORE_ID"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["AMC_UI_TEST_SESSION"] == "1" ? "session" : nil)
        if let storeID {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AagedalMediaConverterUITestFixtures", isDirectory: true)
                .appendingPathComponent("history-\(storeID)", isDirectory: true)
        }
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
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

    init() {}

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
    /// 2: adds `rollups`. Version 1 files decode unchanged (no rollups yet).
    static let currentVersion = 2

    var version: Int = EncodeHistoryFile.currentVersion
    var sessions: [HistorySession] = []
    var records: [EncodeRecord] = []
    /// Statistics for detailed records that retention already pruned.
    var rollups: [MonthlyRollup] = []
    /// Elements that couldn't be decoded and were dropped. Not persisted.
    var droppedElementCount = 0

    private enum CodingKeys: String, CodingKey {
        case version, sessions, records, rollups
    }

    init(version: Int = EncodeHistoryFile.currentVersion, sessions: [HistorySession] = [],
         records: [EncodeRecord] = [], rollups: [MonthlyRollup] = []) {
        self.version = version
        self.sessions = sessions
        self.records = records
        self.rollups = rollups
    }

    /// Element-by-element: one damaged record is dropped instead of the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        var dropped = 0
        sessions = container.decodeLossyArray(HistorySession.self, forKey: .sessions, dropped: &dropped)
        records = container.decodeLossyArray(EncodeRecord.self, forKey: .records, dropped: &dropped)
        rollups = container.decodeLossyArray(MonthlyRollup.self, forKey: .rollups, dropped: &dropped)
        droppedElementCount = dropped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(records, forKey: .records)
        try container.encode(rollups, forKey: .rollups)
    }
}

// MARK: - Statistics rollups

/// Aggregated statistics for one calendar month on one device. Detailed
/// records are folded in right before retention deletes them, so long-term
/// statistics survive pruning. Live records are never part of a rollup.
struct MonthlyRollup: Codable, Equatable, Sendable {
    /// `yyyy-MM` in the calendar used when folding (the user's calendar).
    var month: String
    var deviceName: String
    var encodeCount = 0
    /// Keyed by `EncodeOutcome.rawValue`.
    var outcomeCounts: [String: Int] = [:]
    /// Keyed by the preset display name recorded with each encode.
    var presetCounts: [String: Int] = [:]
    var videoCodecCounts: [String: Int] = [:]
    var containerCounts: [String: Int] = [:]
    /// Keyed by `ResolutionBucket.rawValue`.
    var resolutionCounts: [String: Int] = [:]
    /// Media seconds of completed encodes (trimmed length when trimmed).
    var mediaSecondsEncoded: Double = 0
    /// Wall-clock seconds spent on completed encodes.
    var encodeWallSeconds: Double = 0
    /// Media and wall seconds of completed encodes where both are known; the
    /// ratio is the speed relative to realtime.
    var speedMediaSeconds: Double = 0
    var speedWallSeconds: Double = 0
    /// Source and output sizes of completed encodes where both are known.
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var sessionCount = 0
    var unexpectedExitCount = 0

    init(month: String, deviceName: String) {
        self.month = month
        self.deviceName = deviceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        deviceName = c.decodeTolerant(String.self, forKey: .deviceName) ?? ""
        encodeCount = c.decodeTolerant(Int.self, forKey: .encodeCount) ?? 0
        outcomeCounts = c.decodeTolerant([String: Int].self, forKey: .outcomeCounts) ?? [:]
        presetCounts = c.decodeTolerant([String: Int].self, forKey: .presetCounts) ?? [:]
        videoCodecCounts = c.decodeTolerant([String: Int].self, forKey: .videoCodecCounts) ?? [:]
        containerCounts = c.decodeTolerant([String: Int].self, forKey: .containerCounts) ?? [:]
        resolutionCounts = c.decodeTolerant([String: Int].self, forKey: .resolutionCounts) ?? [:]
        mediaSecondsEncoded = c.decodeTolerant(Double.self, forKey: .mediaSecondsEncoded) ?? 0
        encodeWallSeconds = c.decodeTolerant(Double.self, forKey: .encodeWallSeconds) ?? 0
        speedMediaSeconds = c.decodeTolerant(Double.self, forKey: .speedMediaSeconds) ?? 0
        speedWallSeconds = c.decodeTolerant(Double.self, forKey: .speedWallSeconds) ?? 0
        bytesIn = c.decodeTolerant(Int64.self, forKey: .bytesIn) ?? 0
        bytesOut = c.decodeTolerant(Int64.self, forKey: .bytesOut) ?? 0
        sessionCount = c.decodeTolerant(Int.self, forKey: .sessionCount) ?? 0
        unexpectedExitCount = c.decodeTolerant(Int.self, forKey: .unexpectedExitCount) ?? 0
    }
}

// MARK: - Last session

/// Status a row had when the last-session snapshot was taken. Persisted raw
/// and localized at display time.
enum SnapshotItemStatus: String, Codable, Sendable {
    case waiting
    /// Was encoding when the app closed.
    case interrupted
    case done
    case failed
    case cancelled

    init(_ status: ConversionManager.ConversionStatus) {
        switch status {
        case .waiting: self = .waiting
        case .converting: self = .interrupted
        case .done: self = .done
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }

    var label: String {
        switch self {
        case .waiting: return String(localized: "Waiting", comment: "Last session item status.")
        case .interrupted: return String(localized: "Interrupted", comment: "Encode history outcome: the app quit or crashed during the encode.")
        case .done: return String(localized: "Done", comment: "Last session item status.")
        case .failed: return String(localized: "Failed", comment: "Encode history outcome.")
        case .cancelled: return String(localized: "Cancelled", comment: "Encode history outcome.")
        }
    }
}

struct SnapshotItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var source: HistoryFileReference
    var recipe: EncodeRecipe
    /// Status the row had when the snapshot was taken (waiting/converting/failed/cancelled).
    var status: SnapshotItemStatus?
    /// Already-localized label written by snapshots from before `status`
    /// existed (4.6 betas). Only read, never written for new snapshots.
    var legacyStatusLabel: String?

    private enum CodingKeys: String, CodingKey {
        case id, source, recipe, status
        case legacyStatusLabel = "statusLabel"
    }

    init(id: UUID = UUID(), source: HistoryFileReference, recipe: EncodeRecipe, status: SnapshotItemStatus?) {
        self.id = id
        self.source = source
        self.recipe = recipe
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeTolerant(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(HistoryFileReference.self, forKey: .source)
        recipe = c.decodeTolerant(EncodeRecipe.self, forKey: .recipe) ?? EncodeRecipe()
        status = c.decodeTolerant(SnapshotItemStatus.self, forKey: .status)
        legacyStatusLabel = c.decodeTolerant(String.self, forKey: .legacyStatusLabel)
    }

    /// Localized status for display; empty when unknown.
    var statusLabel: String { status?.label ?? legacyStatusLabel ?? "" }
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

    init(id: UUID = UUID(), name: String, presetRawValue: String?, concatEnabled: Bool, uploadEnabled: Bool,
         transcriptionEnabled: Bool, analyticsEnabled: Bool, sequentialNamingEnabled: Bool, items: [SnapshotItem]) {
        self.id = id
        self.name = name
        self.presetRawValue = presetRawValue
        self.concatEnabled = concatEnabled
        self.uploadEnabled = uploadEnabled
        self.transcriptionEnabled = transcriptionEnabled
        self.analyticsEnabled = analyticsEnabled
        self.sequentialNamingEnabled = sequentialNamingEnabled
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeTolerant(UUID.self, forKey: .id) ?? UUID()
        name = c.decodeTolerant(String.self, forKey: .name) ?? ""
        presetRawValue = c.decodeTolerant(String.self, forKey: .presetRawValue)
        concatEnabled = c.decodeTolerant(Bool.self, forKey: .concatEnabled) ?? false
        uploadEnabled = c.decodeTolerant(Bool.self, forKey: .uploadEnabled) ?? false
        transcriptionEnabled = c.decodeTolerant(Bool.self, forKey: .transcriptionEnabled) ?? false
        analyticsEnabled = c.decodeTolerant(Bool.self, forKey: .analyticsEnabled) ?? false
        sequentialNamingEnabled = c.decodeTolerant(Bool.self, forKey: .sequentialNamingEnabled) ?? false
        var dropped = 0
        items = c.decodeLossyArray(SnapshotItem.self, forKey: .items, dropped: &dropped)
    }
}

struct LastSessionSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2

    /// 1 (implicit): localized `statusLabel`; 2: raw `status`.
    var version: Int = LastSessionSnapshot.currentVersion
    var savedAt: Date
    var presetRawValue: String
    var items: [SnapshotItem]
    var groups: [SnapshotGroup]

    init(savedAt: Date, presetRawValue: String, items: [SnapshotItem], groups: [SnapshotGroup]) {
        self.savedAt = savedAt
        self.presetRawValue = presetRawValue
        self.items = items
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeTolerant(Int.self, forKey: .version) ?? 1
        savedAt = c.decodeTolerant(Date.self, forKey: .savedAt) ?? Date()
        presetRawValue = c.decodeTolerant(String.self, forKey: .presetRawValue) ?? ""
        var dropped = 0
        items = c.decodeLossyArray(SnapshotItem.self, forKey: .items, dropped: &dropped)
        groups = c.decodeLossyArray(SnapshotGroup.self, forKey: .groups, dropped: &dropped)
    }

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

// MARK: - Tolerant decoding

/// Decodes to nil instead of throwing, so one bad element in an array can be
/// skipped while the rest of the file still loads.
private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Missing, null or mistyped values become nil. For non-essential fields,
    /// so files written by newer or older versions keep loading.
    func decodeTolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decodes an array element by element, dropping (and counting) the ones
    /// that fail. A missing or non-array value yields an empty array.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key, dropped: inout Int) -> [T] {
        guard let elements = try? decodeIfPresent([LossyElement<T>].self, forKey: key) else { return [] }
        var values: [T] = []
        values.reserveCapacity(elements.count)
        for element in elements {
            if let value = element.value { values.append(value) } else { dropped += 1 }
        }
        return values
    }
}

extension EncodeRecipe {
    /// Every field is optional on read: recipes from older or newer versions
    /// still restore what they can. Embedded types with synthesized decoding
    /// (crop, metadata editor, audio routing) fall back to nil when they no
    /// longer match.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = c.decodeTolerant(Double.self, forKey: .trimStart)
        trimEnd = c.decodeTolerant(Double.self, forKey: .trimEnd)
        cropConfig = c.decodeTolerant(CropConfig.self, forKey: .cropConfig)
        audioRoutingConfig = c.decodeTolerant(AudioRoutingConfig.self, forKey: .audioRoutingConfig)
        timecodeMode = c.decodeTolerant(TimecodeMode.self, forKey: .timecodeMode)
        manualTimecode = c.decodeTolerant(String.self, forKey: .manualTimecode)
        isMuted = c.decodeTolerant(Bool.self, forKey: .isMuted) ?? false
        comment = c.decodeTolerant(String.self, forKey: .comment) ?? ""
        metadataEditorSettings = c.decodeTolerant(MetadataEditorSettings.self, forKey: .metadataEditorSettings)
        includeDateTag = c.decodeTolerant(Bool.self, forKey: .includeDateTag) ?? true
        outputFileNameOverride = c.decodeTolerant(String.self, forKey: .outputFileNameOverride)
        recursiveEncodingGenerations = c.decodeTolerant(Int.self, forKey: .recursiveEncodingGenerations)
        uploadEnabled = c.decodeTolerant(Bool.self, forKey: .uploadEnabled) ?? false
        uploadSourceFile = c.decodeTolerant(Bool.self, forKey: .uploadSourceFile) ?? false
        subtitleEnabled = c.decodeTolerant(Bool.self, forKey: .subtitleEnabled) ?? false
        analyticsEnabled = c.decodeTolerant(Bool.self, forKey: .analyticsEnabled) ?? false
        selectedAudioStreamIndex = c.decodeTolerant(Int.self, forKey: .selectedAudioStreamIndex)
        waveformBackgroundImagePath = c.decodeTolerant(String.self, forKey: .waveformBackgroundImagePath)
        presetOverrideRawValue = c.decodeTolerant(String.self, forKey: .presetOverrideRawValue)
    }
}

extension HistoryFileReference {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        bookmark = c.decodeTolerant(Data.self, forKey: .bookmark)
    }
}

extension SourceFacts {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sizeBytes = c.decodeTolerant(Int64.self, forKey: .sizeBytes)
        durationSeconds = c.decodeTolerant(Double.self, forKey: .durationSeconds)
        container = c.decodeTolerant(String.self, forKey: .container)
        videoCodec = c.decodeTolerant(String.self, forKey: .videoCodec)
        width = c.decodeTolerant(Int.self, forKey: .width)
        height = c.decodeTolerant(Int.self, forKey: .height)
        frameRate = c.decodeTolerant(Double.self, forKey: .frameRate)
        audioCodec = c.decodeTolerant(String.self, forKey: .audioCodec)
        audioChannels = c.decodeTolerant(Int.self, forKey: .audioChannels)
    }
}

extension EncodeRecord {
    /// Requires the session, start date and source path; everything else
    /// falls back to a default so new fields never invalidate old records.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeTolerant(UUID.self, forKey: .id) ?? UUID()
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = c.decodeTolerant(Date.self, forKey: .finishedAt)
        // An outcome this version doesn't know is treated as an unfinished encode.
        outcome = c.decodeTolerant(EncodeOutcome.self, forKey: .outcome) ?? .interrupted
        errorMessage = c.decodeTolerant(String.self, forKey: .errorMessage)
        kind = c.decodeTolerant(Kind.self, forKey: .kind) ?? .file
        source = try c.decode(HistoryFileReference.self, forKey: .source)
        sourceFacts = c.decodeTolerant(SourceFacts.self, forKey: .sourceFacts) ?? SourceFacts()
        recipe = c.decodeTolerant(EncodeRecipe.self, forKey: .recipe) ?? EncodeRecipe()
        presetRawValue = c.decodeTolerant(String.self, forKey: .presetRawValue) ?? ""
        presetDisplayName = c.decodeTolerant(String.self, forKey: .presetDisplayName) ?? presetRawValue
        groupName = c.decodeTolerant(String.self, forKey: .groupName)
        merged = c.decodeTolerant(Bool.self, forKey: .merged) ?? false
        outputPath = c.decodeTolerant(String.self, forKey: .outputPath)
        outputSizeBytes = c.decodeTolerant(Int64.self, forKey: .outputSizeBytes)
        deviceName = c.decodeTolerant(String.self, forKey: .deviceName) ?? ""
    }
}

extension HistorySession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = c.decodeTolerant(Date.self, forKey: .endedAt)
        endedCleanly = c.decodeTolerant(Bool.self, forKey: .endedCleanly) ?? false
        deviceName = c.decodeTolerant(String.self, forKey: .deviceName) ?? ""
        appVersion = c.decodeTolerant(String.self, forKey: .appVersion)
    }
}
