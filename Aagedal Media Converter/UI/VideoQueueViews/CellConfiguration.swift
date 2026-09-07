// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// MARK: - VideoFileCellConfiguration

/// Snapshot of all data a VideoFileCellView needs to render.
/// Built by the Coordinator from the current VideoItem and display state.
/// The cell receives this as a read-only value — no SwiftUI Bindings.
struct VideoFileCellConfiguration: Equatable {
    // Item identity
    let itemID: UUID

    // Core display data
    let name: String
    let duration: String
    let durationSeconds: Double
    let formattedSize: String
    /// Pre-formatted resolution string (e.g. "1920×1080"). Nil when metadata unavailable.
    let videoResolution: String?
    /// Pre-formatted frame rate string (e.g. "25 fps", "29.97 fps"). Nil when metadata unavailable.
    let videoFrameRate: String?
    /// True only when the source video stream is confirmed interlaced.
    let videoIsInterlaced: Bool
    let status: ConversionManager.ConversionStatus
    let progress: Double
    let eta: String?
    /// Stage label for multi-phase operations (e.g. "Wrapping audio essence 42%").
    /// When set, takes visual precedence over `eta` in the progress label.
    let statusMessage: String?
    let conversionError: String?
    let comment: String
    let includeDateTag: Bool
    let outputURL: URL?
    let url: URL

    // Thumbnail
    let thumbnailImage: NSImage?
    let hasVideoStream: Bool

    // Flags
    let isSelected: Bool
    let isCompactMode: Bool
    let showCommentField: Bool
    let showDateTagButton: Bool
    let isFocusedComment: Bool

    // Preset & merge
    let preset: ExportPreset
    let mergeClipsEnabled: Bool
    let mergeClipsAvailable: Bool

    // Output file state (cached, no filesystem access)
    let outputFileExists: Bool
    let outputFileNameOverride: String?

    // Download state
    let isDownloading: Bool
    let downloadProgress: Double
    let downloadHasProgress: Bool
    let downloadSpeed: String?
    let downloadError: String?
    let fileAlreadyExistsPath: String?
    let sourceURL: String?
    let scheduledDownloadTime: Date?
    let autoEncodeAfterDownload: Bool
    let isLiveStreamRecording: Bool
    let downloadStopping: Bool

    // Upload state
    let uploadEnabled: Bool
    let uploadSourceFile: Bool
    let uploadStatus: UploadStatus
    let uploadProgress: Double

    // Subtitle state
    let subtitleEnabled: Bool
    let subtitleStatus: SubtitleStatus
    let subtitleProgress: Double
    let subtitleFilePath: URL?
    let subtitleMethod: SubtitleConversionMethod
    let hasBitmapSubtitles: Bool
    let audioStreamCount: Int

    // Analytics state
    let analyticsEnabled: Bool
    let analyticsStatus: AnalyticsStatus
    let analyticsProgress: Double
    let hasAnalyticsResults: Bool
    let isReadyForAnalytics: Bool
    let canRunAnalyticsWithFilePicker: Bool

    // Audio/video config state (for badge display)
    let isMuted: Bool
    let hasCustomAudioRouting: Bool
    let hasSurroundAudio: Bool
    let hasDownmix: Bool
    let audioTrackCount: Int
    let hasOutputSurroundWithoutDownmix: Bool
    let hasTrim: Bool
    let trimmedDuration: Double
    let hasCrop: Bool
    let cropPercentage: Int
    let hasTimecodeConfig: Bool
    let timecodeMode: String? // "MAN", "SRC", "No TC"
    let loopPlayback: Bool
    let waveformVideoEnabled: Bool
    let isImageSequence: Bool

    // Encoding group membership
    let isGroupChild: Bool

    // DCP
    let isDCPPreset: Bool
    let dcpMetadataTitle: String?
    let showDCPAudioWarning: Bool

    // IMF
    let isIMFPreset: Bool
    let imfMetadataTitle: String?

    // Formatted output size (for done items)
    let formattedOutputSize: String?

    // Transcription availability (cached, no service calls)
    let isTranscriptionAvailable: Bool
    let isUploadConfigured: Bool
}

// MARK: - Queue failure diagnostics

extension VideoFileCellConfiguration {
    /// Preserve every failed stage, including follow-up failures after a successful encode.
    var failureDetails: String? {
        QueueFailureDiagnostics.details(
            downloadError: downloadError,
            conversionFailed: status == .failed,
            conversionError: conversionError,
            subtitleStatus: subtitleStatus,
            uploadStatus: uploadStatus,
            analyticsStatus: analyticsStatus
        )
    }

    var diagnosticReport: String? {
        guard let failureDetails else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return QueueFailureDiagnostics.report(
            details: failureDetails,
            appVersion: "\(version) (\(build))",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            preset: preset.rawValue,
            privateValues: [url.path, url.absoluteString, url.lastPathComponent,
                            outputURL?.path ?? "", outputURL?.absoluteString ?? "",
                            outputURL?.lastPathComponent ?? "", sourceURL ?? "", name,
                            NSHomeDirectory()]
        )
    }
}

enum QueueFailureDiagnostics {
    static func details(
        downloadError: String?,
        conversionFailed: Bool,
        conversionError: String?,
        subtitleStatus: SubtitleStatus,
        uploadStatus: UploadStatus,
        analyticsStatus: AnalyticsStatus
    ) -> String? {
        var failures: [String] = []
        func append(_ title: String, _ detail: String?) {
            let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            failures.append(title + (message.isEmpty ? "" : "\n" + message))
        }
        if let downloadError { append(String(localized: "Download failed"), downloadError) }
        if conversionFailed { append(String(localized: "Conversion failed"), conversionError) }
        if case .failed(let error) = subtitleStatus { append(String(localized: "Subtitle generation failed"), error) }
        if case .failed(let error) = uploadStatus { append(String(localized: "Upload failed"), error) }
        if case .failed(let error) = analyticsStatus { append(String(localized: "Analysis failed"), error) }
        return failures.isEmpty ? nil : failures.joined(separator: "\n\n")
    }

    /// Share the subprocess redactor so URLs and known source/output paths are not copied.
    /// This report intentionally contains only captured errors, never a reconstructed command.
    static func report(
        details: String,
        appVersion: String,
        systemVersion: String,
        preset: String,
        privateValues: Set<String>
    ) -> String {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/diagnostics"),
            sensitiveValues: privateValues
        )
        return """
        Aagedal Media Converter \(appVersion)
        \(systemVersion)
        Preset: \(preset)

        \(request.redactedDiagnostic(details, limit: 32 * 1024))
        """
    }
}

// MARK: - EncodingGroupCellConfiguration

/// Snapshot of all data an EncodingGroupHeaderCellView needs to render.
/// Mirrors VideoFileCellConfiguration: immutable, Equatable, built from the
/// current EncodingGroup plus global state by the Coordinator.
/// Compact summary of a single child item used for the stacked-thumbnail
/// preview and the inline expanded mini-row list inside the group card.
struct EncodingGroupChildSummary: Equatable {
    let itemID: UUID
    let name: String
    let status: ConversionManager.ConversionStatus
    let progress: Double
    let hasVideoStream: Bool
    let durationSeconds: Double
    let isDownloading: Bool
}

struct EncodingGroupCellConfiguration: Equatable {
    let groupID: UUID
    let name: String
    let itemCount: Int
    let isSelected: Bool
    /// True while a drag is hovering over this group as a potential drop target.
    /// Used to paint a bright solid-blue border so the user can see where the drop
    /// will land (distinct from selection, which is slightly dimmer).
    let isDropTargetHover: Bool
    let isCompactMode: Bool
    let globalPreset: ExportPreset

    /// Up to three first children, used for the stacked-thumbnail preview.
    let stackedChildren: [EncodingGroupChildSummary]

    // Group-level settings
    let groupPreset: ExportPreset?
    let concatEnabled: Bool
    let uploadEnabled: Bool
    let transcriptionEnabled: Bool
    let analyticsEnabled: Bool
    let sequentialNamingEnabled: Bool
    let isUploadConfigured: Bool

    // Status
    let status: ConversionManager.ConversionStatus
    let progress: Double
    let totalDuration: String
    let totalSize: String

    // Concat output
    let concatOutputURL: URL?
    let concatOutputAlreadyExists: Bool
    let concatOutputExistingURL: URL?

    // Upload summary (shown below progress bar when any item is uploading / has uploaded)
    enum UploadSummaryState: Equatable {
        case hidden
        case uploaded(count: Int, total: Int)
        case failed(count: Int, total: Int)
        case uploading(completed: Int, total: Int, progress: Double, speed: String?)
        case pending(uploaded: Int, total: Int)
    }
    let uploadSummary: UploadSummaryState
}

// MARK: - CellAction

/// All actions a cell can send to the Coordinator.
enum CellAction {
    // Item lifecycle
    case delete
    case reset(optionKeyPressed: Bool)
    case cancel

    // Download management
    case cancelDownload
    case stopLiveRecording
    case retryDownload
    case forceRedownload
    case cancelScheduledDownload

    // Encode
    case encodeNow(optionPressed: Bool)

    // Toggles
    case toggleUpload(optionPressed: Bool)
    case toggleTranscription(optionPressed: Bool)
    case toggleOCR(optionPressed: Bool)
    case toggleAnalytics(optionPressed: Bool)
    case toggleAutoEncode
    case toggleWaveform
    case toggleDateTag
    case toggleMute
    case toggleSubtitleEnabled(Bool)

    // Comment
    case commentChanged(String)
    case commentFocusChanged(Bool)
    /// Raised when the user presses Tab / Shift-Tab inside the comment popover
    /// so the coordinator can move focus to the next/previous row's comment.
    case tabCommentField(forward: Bool)

    // Output filename
    case beginRename
    case commitRename(String?)

    // Sheet/popover requests
    case showPreview
    case showMetadata
    case showAudioRouting
    case showTimecode
    case showDCPMetadata
    case showIMFMetadata
    case showAnalyticsResults
    case showAnalyticsFilePicker
    case showSubtitleTrackSheet
    case showAudioTrackSheet
    case showBackgroundImagePicker
    case showAudioFilePicker
    case attachSubtitleFile

    // Open Settings window on a specific tab (e.g. "upload", "whisper", "analytics").
    case openSettingsTab(String)

    // Navigation
    case playFullscreen
    case showInFinder
    case showOutputInFinder
    case showSubtitleInFinder
    case showDownloadedInFinder

    // Cancel subtitle/analytics
    case cancelSubtitleGeneration
    case cancelAnalytics

    // Group-specific actions
    case groupNameChanged(String)
    case toggleConcat
    case toggleGroupUpload(optionPressed: Bool)
    case toggleGroupTranscription
    case toggleGroupAnalytics
    case toggleSequentialNaming
    case setGroupPreset(ExportPreset?)
    case deleteGroup
    case addFilesToGroup
    case resetGroup
    /// Cancels all active uploads belonging to a group without deleting the group.
    case cancelGroupUpload
    /// Cycles the group's internal sort mode (filename A–Z → Z–A → date old–new → new–old).
    case cycleGroupSort
    /// Opens the standalone group editor window for the current group.
    case openGroupEditor
}
