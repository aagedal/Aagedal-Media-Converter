// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

enum AppConstants {
    // Default output directory for encoded exports
    static let defaultOutputDirectory: URL = {
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let defaultDir = moviesDir.appendingPathComponent("Media_Exports")

        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        return defaultDir
    }()

    // Default download directory (Downloads)
    static let defaultDownloadDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let downloadFolderKey = "downloadFolder"

    // Settings window tab to open (used for opening Settings to a specific tab from main window)
    static let settingsTabToOpenKey = "settingsTabToOpen"

    // Local MCP access remains off until the user explicitly enables it.
    static let localAgentAccessEnabledKey = "localAgentAccessEnabled"

    static let defaultScreenshotDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let defaultCaptureDirectory: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let base = movies ?? fallback
        let directory = base.appendingPathComponent("ScreenCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let captureDisplayIDKey = "captureDisplayID"
    /// Selected displays for multi-screen recording, stored as a comma-separated list of
    /// `CGDirectDisplayID`s (e.g. "69733382,724...""). `@AppStorage` can't hold arrays natively, so
    /// the overlay parses/joins this string. Empty == none selected (falls back to the main display).
    /// The first entry is the "primary" display (drives preview position, meters, and overlay screen).
    static let captureDisplayIDsKey = "captureDisplayIDs"
    /// One-time flag: seed `captureDisplayIDsKey` from the legacy single `captureDisplayID` so users
    /// upgrading keep their previously chosen display selected.
    static let captureDisplayIDsMigratedKey = "captureDisplayIDsMigrated"
    static let captureHideCursorKey = "captureHideCursor"
    static let captureExcludeCurrentAppKey = "captureExcludeCurrentApp"
    static let captureFrameRateKey = "captureFrameRate"
    static let captureDynamicRangeKey = "captureDynamicRange"
    static let captureIncludeSystemAudioKey = "captureIncludeSystemAudio"
    static let captureIncludeMicrophoneKey = "captureIncludeMicrophone"
    static let captureMicrophoneDeviceIDKey = "captureMicrophoneDeviceID"
    static let defaultCaptureHideCursor = false
    static let defaultCaptureExcludeCurrentApp = true
    static let defaultCaptureFrameRate = "auto"
    static let defaultCaptureDynamicRange = "sdr"
    static let defaultCaptureIncludeSystemAudio = true
    static let defaultCaptureIncludeMicrophone = false
    static let defaultCaptureMicrophoneDeviceID = ""
    /// Lifetime policy for virtual displays created from the recording overlay. When false (the
    /// default), a virtual display is torn down as soon as it's removed from the recording grid or
    /// when record mode closes — it only exists for the recording session that needed it. When true,
    /// virtual displays persist until the app quits (so they survive closing and reopening the
    /// overlay), and are only removed via the explicit "Remove Virtual Display" menu action.
    static let captureKeepVirtualDisplaysAliveKey = "captureKeepVirtualDisplaysAlive"
    static let defaultCaptureKeepVirtualDisplaysAlive = false

    static let captureRegionModeKey = "captureRegionMode"
    static let captureRegionXKey = "captureRegionX"
    static let captureRegionYKey = "captureRegionY"
    static let captureRegionWidthKey = "captureRegionWidth"
    static let captureRegionHeightKey = "captureRegionHeight"
    static let defaultCaptureRegionMode = false

    /// Whether the floating capture overlay panel is in its expanded (large) state.
    /// Compact (false) is the default; expanded fits the capture aspect within ~90% of the screen.
    static let captureOverlayExpandedKey = "captureOverlayExpanded"

    /// Paths of growing-file recordings that currently carry the Blackmagic "recording"
    /// xattr. Tracked so a crash/quit mid-recording can be cleaned up on next launch —
    /// otherwise the file stays tagged and DaVinci Resolve shows a phantom red REC overlay.
    static let pendingGrowingRecordingPathsKey = "pendingGrowingRecordingPaths"

    // DCP / IMF metadata: remember the last `contentKind` the user picked so a
    // fresh queue item opening the editor lands on the same kind they last used
    // (per format) instead of always reverting to "feature".
    static let lastDCPContentKindKey = "lastDCPContentKind"
    static let lastIMFContentKindKey = "lastIMFContentKind"
    
    // Directory for cached preview assets (thumbnails, waveforms, etc.)
    static let previewCacheDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let cacheDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("PreviewAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()
    
    // Supported media file extensions (lowercase)
    static let supportedVideoExtensions: Set<String> = [
        "3g2", "3gp", "3gp2", "3gpp",
        "aac", "aif", "aiff", "alac", "amv",
        "asf", "avi", "apv", "avs", "drc",
        "dv", "f4v", "flac", "flv", "gxf",
        "ismv", "m1v", "m2p", "m2t", "m2ts",
        "m2v", "m4a", "m4b", "m4v", "mk3d",
        "mkv", "mod", "mov", "mp2", "mp2v",
        "mp3", "mp4", "mp4v", "mpe", "mpeg",
        "mpg", "mpv", "mts", "mxf", "oga",
        "ogg", "ogm", "ogv", "opus", "qt",
        "rm", "rmvb", "roq", "svi", "tod",
        "trp", "ts", "vob", "wav", "webm",
        "wma", "wmv", "wtv", "y4m", "ivf"
    ]

    /// Input extensions the app accepts but cannot play back in the interactive trim/preview
    /// player, because none of its decoders (AVFoundation, VLCKit, MPV) support the codec.
    /// Currently AV2 `.ivf`: these can be queued, transcoded, and thumbnailed (via the bundled
    /// avmdec), but the trim view shows a "format not previewable" message instead of a player.
    static let previewUnsupportedExtensions: Set<String> = ["ivf"]

    // Supported image sequence file extensions (lowercase)
    static let supportedImageSequenceExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff",
        "exr", "dpx", "bmp", "tga", "sgi", "jxl",
        "jp2", "j2k", "j2c"
    ]

    // Supported UTType identifiers for file picker
    static let supportedVideoTypes: [String] = [
        "public.movie",
        "public.video",
        "public.mpeg-4",
        "com.apple.quicktime-movie",
        "com.apple.m4v-video",
        "public.avi",
        "com.apple.m4v-video",
        "public.mpeg-4-audio",
        "public.audio",
        "com.apple.coreaudio-format",
        "com.microsoft.waveform-audio",
        "com.apple.protected-mpeg-4-audio"
    ]

    // Audio waveform rendering defaults
    static let audioWaveformVideoDefaultEnabledKey = "audioWaveformVideoDefaultEnabled"
    static let audioWaveformResolutionKey = "audioWaveformResolution"
    static let audioWaveformBackgroundColorKey = "audioWaveformBackgroundColor"
    static let audioWaveformForegroundColorKey = "audioWaveformForegroundColor"
    static let audioWaveformNormalizeKey = "audioWaveformNormalize"
    static let audioWaveformStyleKey = "audioWaveformStyle"
    static let defaultAudioWaveformStyleRaw = "fisheye"
    static let audioWaveformFrameRateKey = "audioWaveformFrameRate"
    static let defaultAudioWaveformFrameRate: Double = 25
    static let audioWaveformLineThicknessKey = "audioWaveformLineThickness"
    static let audioWaveformDetailLevelKey = "audioWaveformDetailLevel"
    static let defaultAudioWaveformLineThickness = 2.0
    static let defaultAudioWaveformDetailLevel = 1.0
    static let audioWaveformAspectRatioKey = "audioWaveformAspectRatio"
    static let audioWaveformShortEdgeKey = "audioWaveformShortEdge"
    static let defaultAudioWaveformAspectRatio = "ratio16_9"
    static let defaultAudioWaveformShortEdge = 1080
    static let audioWaveformRenderingEngineKey = "audioWaveformRenderingEngine"
    static let audioWaveformSwiftStyleKey = "audioWaveformSwiftStyle"
    static let audioWaveformBandCountKey = "audioWaveformBandCount"
    static let audioWaveformFrequencyDistributionKey = "audioWaveformFrequencyDistribution"
    static let audioWaveformForegroundGradientEnabledKey = "audioWaveformForegroundGradientEnabled"
    static let audioWaveformForegroundGradientEndColorKey = "audioWaveformForegroundGradientEndColor"
    static let audioWaveformBackgroundGradientEnabledKey = "audioWaveformBackgroundGradientEnabled"
    static let audioWaveformBackgroundGradientEndColorKey = "audioWaveformBackgroundGradientEndColor"
    static let audioWaveformOpacityKey = "audioWaveformOpacity"

    // Maximum thumbnail dimensions
    static let maxThumbnailSize = CGSize(width: 320, height: 320)
    static let includeDateTagPreferenceKey = "includeDateTagByDefault"
    static let preserveMetadataPreferenceKey = "preserveMetadataByDefault"
    static let commentPrefixKey = "commentPrefix"
    static let commentSuffixKey = "commentSuffix"
    static let commentSeparatorKey = "commentSeparator"
    static let defaultCommentSeparator = " | "
    static let commentDateFormatKey = "commentDateFormat"
    static let defaultCommentDateFormat = "yyyyMMdd"
    static let dateTagPrefixKey = "dateTagPrefix"
    static let defaultDateTagPrefix = "Date generated"
    static let showCommentFieldKey = "showCommentField"
    static let showDateTagButtonKey = "showDateTagButton"
    static let enableFileNameProcessingKey = "enableFileNameProcessing"
    static let fileNameReplaceSpacesKey = "fileNameReplaceSpaces"
    static let fileNameReplaceScandinavianCharsKey = "fileNameReplaceScandinavianChars"
    // Legacy boolean toggle, retained for migration. New code should use fileNameSpecialCharRemovalModeKey.
    static let fileNameRemoveSpecialCharsKey = "fileNameRemoveSpecialChars"
    static let fileNameSpecialCharRemovalModeKey = "fileNameSpecialCharRemovalMode"
    static let fileNameIncludePresetSuffixKey = "fileNameIncludePresetSuffix"
    static let defaultFileNameReplaceSpaces = true
    static let defaultFileNameReplaceScandinavianChars = true
    static let defaultFileNameRemoveSpecialChars = true
    // Default for new installs: only strip filesystem-unsafe punctuation, preserve Unicode letters.
    static let defaultFileNameSpecialCharRemovalMode = "loose"
    static let defaultFileNameIncludePresetSuffix = true

    // Custom file name template
    static let enableCustomFileNameTemplateKey = "enableCustomFileNameTemplate"
    static let customFileNameTemplateKey = "customFileNameTemplate"
    static let customFileNameDateFormatKey = "customFileNameDateFormat"
    static let customFileNameCounterPaddingKey = "customFileNameCounterPadding"
    static let customFileNameCounterValueKey = "customFileNameCounterValue"
    static let defaultEnableCustomFileNameTemplate = false
    static let defaultCustomFileNameTemplate = "{sourceName}_{date}"
    static let defaultCustomFileNameDateFormat = "yyyyMMdd"
    static let defaultCustomFileNameCounterPadding = 3
    static let defaultCustomFileNameCounterValue = 1

    // Encoding-group defaults applied when a new group is created.
    // Merge and sequential naming are mutually exclusive — the settings UI and
    // toggle handlers enforce that only one can be on at a time.
    static let exportStitchMarkersKey = "exportStitchMarkers"
    static let exportStitchMarkersDefault = true
    static let defaultGroupMergeEnabledKey = "defaultGroupMergeEnabled"
    static let defaultGroupSequentialNamingEnabledKey = "defaultGroupSequentialNamingEnabled"
    static let defaultGroupPresetKey = "defaultGroupPreset"
    static let defaultGroupMergeEnabled = true
    static let defaultGroupSequentialNamingEnabled = false
    static let defaultGroupPreset: String = ExportPreset.streamCopy.rawValue
    static let customPresetCommandKey = "customPresetFFmpegCommand"
    static let customPresetSuffixKey = "customPresetFileSuffix"
    static let customPresetExtensionKey = "customPresetFileExtension"
    static let customPreset1NameKey = "customPreset1DisplayName"
    static let customPreset2NameKey = "customPreset2DisplayName"
    static let customPreset3NameKey = "customPreset3DisplayName"
    static let customPreset1CommandKey = customPresetCommandKey
    static let customPreset1SuffixKey = customPresetSuffixKey
    static let customPreset1ExtensionKey = customPresetExtensionKey
    static let customPreset2CommandKey = "customPreset2FFmpegCommand"
    static let customPreset2SuffixKey = "customPreset2FileSuffix"
    static let customPreset2ExtensionKey = "customPreset2FileExtension"
    static let customPreset3CommandKey = "customPreset3FFmpegCommand"
    static let customPreset3SuffixKey = "customPreset3FileSuffix"
    static let customPreset3ExtensionKey = "customPreset3FileExtension"
    static let defaultPresetKey = "defaultExportPreset"
    static let watchFolderModeKey = "watchFolderModeEnabled"
    static let watchFolderPathKey = "watchFolderPath"
    static let watchFolderAutoActivateOnLaunchKey = "watchFolderAutoActivateOnLaunch"
    static let watchFolderIgnoreOlderThan24hKey = "watchFolderIgnoreOlderThan24h"
    static let watchFolderAutoDeleteOlderThanWeekKey = "watchFolderAutoDeleteOlderThanWeek"
    static let watchFolderIgnoreDurationValueKey = "watchFolderIgnoreDurationValue"
    static let watchFolderIgnoreDurationUnitKey = "watchFolderIgnoreDurationUnit"
    static let watchFolderDeleteDurationValueKey = "watchFolderDeleteDurationValue"
    static let watchFolderDeleteDurationUnitKey = "watchFolderDeleteDurationUnit"
    static let watchFolderKeepAwakeKey = "watchFolderKeepAwake"
    static let defaultWatchFolderKeepAwake = false
    static let previewCacheCleanupPolicyKey = "previewCacheCleanupPolicy"
    static let defaultPreviewCacheCleanupPolicyRaw = PreviewCacheCleanupPolicy.purgeOnLaunch.rawValue
    static let watchFolderDurationValues: [Int] = [1, 3, 5, 7, 10, 14, 24, 31]
    static let defaultWatchFolderIgnoreDurationValue = 24
    static let defaultWatchFolderIgnoreDurationUnitRaw = WatchFolderDurationUnit.hours.rawValue
    static let defaultWatchFolderDeleteDurationValue = 7
    static let defaultWatchFolderDeleteDurationUnitRaw = WatchFolderDurationUnit.days.rawValue
    static let customPresetPrefixes = ["C1:", "C2:", "C3:", "C4:", "C5:", "C6:", "C7:", "C8:", "C9:", "C10:"]
    static let defaultCustomPresetDisplayNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset",
        "C4: Custom Preset",
        "C5: Custom Preset",
        "C6: Custom Preset",
        "C7: Custom Preset",
        "C8: Custom Preset",
        "C9: Custom Preset",
        "C10: Custom Preset"
    ]
    static let defaultCustomPresetNameSuffixes = [
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset"
    ]
    static let defaultCustomPresetFullNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset",
        "C4: Custom Preset",
        "C5: Custom Preset",
        "C6: Custom Preset",
        "C7: Custom Preset",
        "C8: Custom Preset",
        "C9: Custom Preset",
        "C10: Custom Preset"
    ]
    static let defaultCustomPresetCommands = ["-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy"]
    static let defaultCustomPresetSuffixes = ["_c1", "_c2", "_c3", "_c4", "_c5", "_c6", "_c7", "_c8", "_c9", "_c10"]
    static let defaultCustomPresetExtensions = ["mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4"]
    // Default activation states: all custom presets inactive by default
    static let defaultCustomPresetActive = [false, false, false, false, false, false, false, false, false, false]

    // MARK: - Dynamic custom preset key generation

    static func customPresetCommandKey(for slot: Int) -> String {
        // Slot 0 uses legacy unnumbered key
        slot == 0 ? "customPresetFFmpegCommand" : "customPreset\(slot + 1)FFmpegCommand"
    }

    static func customPresetSuffixKey(for slot: Int) -> String {
        slot == 0 ? "customPresetFileSuffix" : "customPreset\(slot + 1)FileSuffix"
    }

    static func customPresetExtensionKey(for slot: Int) -> String {
        slot == 0 ? "customPresetFileExtension" : "customPreset\(slot + 1)FileExtension"
    }

    static func customPresetNameKey(for slot: Int) -> String {
        "customPreset\(slot + 1)DisplayName"
    }

    static func customPresetActiveKey(for slot: Int) -> String {
        "customPreset\(slot + 1)Active"
    }

    static func customPresetApplyCropKey(for slot: Int) -> String {
        "customPreset\(slot + 1)ApplyCrop"
    }

    static func customPresetApplyAudioRoutingKey(for slot: Int) -> String {
        "customPreset\(slot + 1)ApplyAudioRouting"
    }

    static let screenshotDirectoryKey = "screenshotDirectory"
    static let screenshot8BitFormatKey = "screenshot8BitFormat"
    static let screenshot10BitFormatKey = "screenshot10BitFormat"
    static let screenshotHighBitFormatKey = "screenshotHighBitFormat"
    static let defaultScreenshotFormat = "JPEG XL" // Default to JPEG XL for all bit depths (must match ScreenshotFormat.jpegXL.rawValue)
    static let screenshotAlphaHandlingKey = "screenshotAlphaHandling"
    static let defaultScreenshotAlphaHandling = "auto" // auto, useSelectedFormat
    static let captureDirectoryKey = "captureDirectory"
    static let capturePresetKey = "capturePreset"
    static let proResProfileKey = "proResProfile"
    
    // Update checking
    static let checkForUpdatesKey = "checkForUpdates"
    static let updateCheckFrequencyKey = "updateCheckFrequency"
    static let lastUpdateCheckDateKey = "lastUpdateCheckDate"
    /// Tracks whether the one-time "automatic updates are on" notice has been
    /// shown. Stored in `UserDefaults.standard` so it survives every app /
    /// Sparkle update. **Do not rename this string** — changing it would
    /// invalidate every existing user's flag and cause the notice to re-fire.
    static let didShowAutoUpdateNoticeKey = "didShowAutoUpdateNotice"

    static let ignoreStitchTimecodeTrimOffsetKey = "ignoreStitchTimecodeTrimOffset"

    // Timecode defaults
    static let defaultTimecodeModeKey = "defaultTimecodeMode"
    static let defaultTimecodeValueKey = "defaultTimecodeValue"
    static let defaultTimecodeModeRaw = "preserveSource" // preserveSource, manual, disabled
    static let defaultTimecodeValue = "00:00:00:00"

    // Custom preset feature toggles
    static let customPreset1ApplyCropKey = "customPreset1ApplyCrop"
    static let customPreset1ApplyAudioRoutingKey = "customPreset1ApplyAudioRouting"
    static let customPreset2ApplyCropKey = "customPreset2ApplyCrop"
    static let customPreset2ApplyAudioRoutingKey = "customPreset2ApplyAudioRouting"
    static let customPreset3ApplyCropKey = "customPreset3ApplyCrop"
    static let customPreset3ApplyAudioRoutingKey = "customPreset3ApplyAudioRouting"
    static let customPreset4ApplyCropKey = "customPreset4ApplyCrop"
    static let customPreset4ApplyAudioRoutingKey = "customPreset4ApplyAudioRouting"
    static let customPreset5ApplyCropKey = "customPreset5ApplyCrop"
    static let customPreset5ApplyAudioRoutingKey = "customPreset5ApplyAudioRouting"
    static let customPreset6ApplyCropKey = "customPreset6ApplyCrop"
    static let customPreset6ApplyAudioRoutingKey = "customPreset6ApplyAudioRouting"
    static let customPreset7ApplyCropKey = "customPreset7ApplyCrop"
    static let customPreset7ApplyAudioRoutingKey = "customPreset7ApplyAudioRouting"
    static let customPreset8ApplyCropKey = "customPreset8ApplyCrop"
    static let customPreset8ApplyAudioRoutingKey = "customPreset8ApplyAudioRouting"
    static let customPreset9ApplyCropKey = "customPreset9ApplyCrop"
    static let customPreset9ApplyAudioRoutingKey = "customPreset9ApplyAudioRouting"
    static let customPreset10ApplyCropKey = "customPreset10ApplyCrop"
    static let customPreset10ApplyAudioRoutingKey = "customPreset10ApplyAudioRouting"

    // Custom preset 4-10 individual keys
    static let customPreset4NameKey = "customPreset4DisplayName"
    static let customPreset4CommandKey = "customPreset4FFmpegCommand"
    static let customPreset4SuffixKey = "customPreset4FileSuffix"
    static let customPreset4ExtensionKey = "customPreset4FileExtension"
    static let customPreset4ActiveKey = "customPreset4Active"

    static let customPreset5NameKey = "customPreset5DisplayName"
    static let customPreset5CommandKey = "customPreset5FFmpegCommand"
    static let customPreset5SuffixKey = "customPreset5FileSuffix"
    static let customPreset5ExtensionKey = "customPreset5FileExtension"
    static let customPreset5ActiveKey = "customPreset5Active"

    static let customPreset6NameKey = "customPreset6DisplayName"
    static let customPreset6CommandKey = "customPreset6FFmpegCommand"
    static let customPreset6SuffixKey = "customPreset6FileSuffix"
    static let customPreset6ExtensionKey = "customPreset6FileExtension"
    static let customPreset6ActiveKey = "customPreset6Active"

    static let customPreset7NameKey = "customPreset7DisplayName"
    static let customPreset7CommandKey = "customPreset7FFmpegCommand"
    static let customPreset7SuffixKey = "customPreset7FileSuffix"
    static let customPreset7ExtensionKey = "customPreset7FileExtension"
    static let customPreset7ActiveKey = "customPreset7Active"

    static let customPreset8NameKey = "customPreset8DisplayName"
    static let customPreset8CommandKey = "customPreset8FFmpegCommand"
    static let customPreset8SuffixKey = "customPreset8FileSuffix"
    static let customPreset8ExtensionKey = "customPreset8FileExtension"
    static let customPreset8ActiveKey = "customPreset8Active"

    static let customPreset9NameKey = "customPreset9DisplayName"
    static let customPreset9CommandKey = "customPreset9FFmpegCommand"
    static let customPreset9SuffixKey = "customPreset9FileSuffix"
    static let customPreset9ExtensionKey = "customPreset9FileExtension"
    static let customPreset9ActiveKey = "customPreset9Active"

    static let customPreset10NameKey = "customPreset10DisplayName"
    static let customPreset10CommandKey = "customPreset10FFmpegCommand"
    static let customPreset10SuffixKey = "customPreset10FileSuffix"
    static let customPreset10ExtensionKey = "customPreset10FileExtension"
    static let customPreset10ActiveKey = "customPreset10Active"

    // Custom preset activation keys
    static let customPreset1ActiveKey = "customPreset1Active"
    static let customPreset2ActiveKey = "customPreset2Active"
    static let customPreset3ActiveKey = "customPreset3Active"

    // Animated Still preset settings
    static let animatedStillFormatKey = "animatedStillFormat"
    static let defaultAnimatedStillFormat = "AVIF"

    // TV preset settings
    static let tvFramerateModeKey = "tvFramerateMode"
    static let defaultTVFramerateMode = "50p"
    static let tvResolutionLimitKey = "tvResolutionLimit"
    static let defaultTVResolutionLimit = "1080p"

    // AVC-Intra preset settings
    static let avcIntraClassKey = "avcIntraClass"
    static let defaultAVCIntraClass = "AVC-Intra 100"
    static let avcIntraAudioChannelsKey = "avcIntraAudioChannels"
    static let defaultAVCIntraAudioChannels = "8 Channels"

    // AVC-Intra default MCA labels (per channel count). Stored value is
    // MCAStandardSoundfield.rawValue, or "" for "None — emit no labels".
    static let avcIntraDefaultMCASoundfield1ChKey = "avcIntraDefaultMCASoundfield1Ch"
    static let avcIntraDefaultMCASoundfield2ChKey = "avcIntraDefaultMCASoundfield2Ch"
    static let avcIntraDefaultMCASoundfield6ChKey = "avcIntraDefaultMCASoundfield6Ch"
    static let avcIntraDefaultMCASoundfield8ChKey = "avcIntraDefaultMCASoundfield8Ch"

    // DCP preset settings
    static let dcpResolutionKey = "dcpResolution"
    static let defaultDCPResolution = "2K Full (2048x1080)"
    static let dcpFrameRateKey = "dcpFrameRate"
    static let defaultDCPFrameRate = "24 fps"
    static let dcpBitrateKey = "dcpBitrate"
    static let defaultDCPBitrate = "200 Mbps"
    static let dcpScalingModeKey = "dcpScalingMode"
    static let defaultDCPScalingMode = "Fill (crop to fill)"
    static let dcpKeepJP2ImagesKey = "dcpKeepJP2Images"

    // IMF preset settings (App #2e and RDD 45 share these unless suffixed)
    static let imfApplicationKey = "imfApplication"
    static let defaultIMFApplication = "app2e"          // IMFApplication.rawValue
    static let imfResolutionKey = "imfResolution"
    static let defaultIMFResolution = "HD 1920x1080"
    static let imfFrameRateKey = "imfFrameRate"
    static let defaultIMFFrameRate = "24 fps"
    static let imfScalingModeKey = "imfScalingMode"
    static let defaultIMFScalingMode = "Fit (letterbox/pillarbox)"
    static let imfJ2KColorEncodingKey = "imfJ2KColorEncoding"
    static let defaultIMFJ2KColorEncoding = "Rec. 709 (HD SDR)"
    static let imfJ2KBitrateKey = "imfJ2KBitrate"
    static let defaultIMFJ2KBitrate = "200 Mbps"
    static let imfProResProfileKey = "imfProResProfile"
    static let defaultIMFProResProfile = "ProRes 422 HQ"
    static let imfAudioBitDepthKey = "imfAudioBitDepth"
    static let defaultIMFAudioBitDepth = "24-bit"
    static let imfKeepIntermediatesKey = "imfKeepIntermediates"

    // Stream Copy container settings
    static let streamCopyContainerKey = "streamCopyContainer"
    static let defaultStreamCopyContainer = "Keep Current"

    // Proxy preset settings
    static let proxyCodecKey = "proxyCodec"
    static let defaultProxyCodec = "HEVC"
    static let proxyResolutionLimitKey = "proxyResolutionLimit"
    static let defaultProxyResolutionLimit = "1080p"

    // H.264 preset settings
    static let h264EncoderKey = "h264Encoder"
    static let defaultH264Encoder = "Software (libx264)"
    static let h264ContainerKey = "h264Container"
    static let defaultH264Container = "MP4"
    static let h264QualityKey = "h264Quality"
    static let defaultH264Quality = "Good (23)"
    static let h264SpeedKey = "h264Speed"
    static let defaultH264Speed = "Medium"
    static let h264ResolutionLimitKey = "h264ResolutionLimit"
    static let defaultH264ResolutionLimit = "Unlimited"
    static let h264BitrateKey = "h264Bitrate"
    static let defaultH264Bitrate = "10M"
    static let h264AudioFormatKey = "h264AudioFormat"
    static let defaultH264AudioFormat = "AAC"
    static let h264AudioBitrateKey = "h264AudioBitrate"
    static let defaultH264AudioBitrate = "192 kbps"

    // H.265 preset settings
    static let h265EncoderKey = "h265Encoder"
    static let defaultH265Encoder = "Software (libx265)"
    static let h265ContainerKey = "h265Container"
    static let defaultH265Container = "MP4"
    static let h265QualityKey = "h265Quality"
    static let defaultH265Quality = "Balanced (28)"
    static let h265SpeedKey = "h265Speed"
    static let defaultH265Speed = "Medium"
    static let h265ResolutionLimitKey = "h265ResolutionLimit"
    static let defaultH265ResolutionLimit = "Unlimited"
    static let h265BitrateKey = "h265Bitrate"
    static let defaultH265Bitrate = "8M"
    static let h265AudioFormatKey = "h265AudioFormat"
    static let defaultH265AudioFormat = "AAC"
    static let h265AudioBitrateKey = "h265AudioBitrate"
    static let defaultH265AudioBitrate = "192 kbps"

    // AV1 preset settings
    static let av1ContainerKey = "av1Container"
    static let defaultAV1Container = "MP4"
    static let av1QualityKey = "av1Quality"
    static let defaultAV1Quality = "Good (30)"
    static let av1SpeedKey = "av1Speed"
    static let defaultAV1Speed = 6
    static let av1ResolutionLimitKey = "av1ResolutionLimit"
    static let defaultAV1ResolutionLimit = "Unlimited"
    static let av1AudioFormatKey = "av1AudioFormat"
    static let defaultAV1AudioFormat = "AAC"
    static let av1AudioBitrateKey = "av1AudioBitrate"
    static let defaultAV1AudioBitrate = "192 kbps"
    static let av1TuneKey = "av1Tune"
    static let defaultAV1Tune = "Default"
    static let av1FilmGrainKey = "av1FilmGrain"
    static let defaultAV1FilmGrain = "Off"
    static let av1FilmGrainDenoiseKey = "av1FilmGrainDenoise"
    static let av1SharpnessKey = "av1Sharpness"
    static let defaultAV1Sharpness = "Off"
    static let av1FastDecodeKey = "av1FastDecode"
    static let av1VarianceBoostKey = "av1VarianceBoost"
    static let defaultAV1VarianceBoost = "Off"
    static let av1VarianceBoostCurveKey = "av1VarianceBoostCurve"
    static let defaultAV1VarianceBoostCurve = "Linear (0)"

    // AV2 (experimental) preset settings — encoded by the bundled external `avmenc` (AOM AVM
    // reference encoder), not FFmpeg. Output is a video-only `.ivf` AV2 bitstream.
    static let av2RateControlModeKey = "av2RateControlMode"
    static let defaultAV2RateControlMode = "Constant Quality"   // AV2RateControlMode raw value
    static let av2QualityKey = "av2Quality"                     // avmenc --qp (0–255, lower = better)
    static let defaultAV2Quality = 110
    static let av2TargetBitrateKey = "av2TargetBitrate"         // avmenc --target-bitrate (kbps, VBR mode)
    static let defaultAV2TargetBitrate = 4000
    static let av2SpeedKey = "av2Speed"                         // avmenc --cpu-used (0 slow/best … 9 fast)
    static let defaultAV2Speed = 9                             // AVM is extremely slow; default to the fastest
    static let av2BitDepthKey = "av2BitDepth"                   // AV2BitDepthOption raw value
    static let defaultAV2BitDepth = "Auto"
    static let av2ThreadsKey = "av2Threads"                     // avmenc -t (0 = auto / all cores)
    static let defaultAV2Threads = 0
    static let av2TileColumnsKey = "av2TileColumns"             // avmenc --tile-columns log2 (0 = auto)
    static let defaultAV2TileColumns = 0
    static let av2TileRowsKey = "av2TileRows"                   // avmenc --tile-rows log2 (0 = auto)
    static let defaultAV2TileRows = 0
    static let av2ResolutionLimitKey = "av2ResolutionLimit"     // CodecResolutionLimit raw value
    static let defaultAV2ResolutionLimit = "Unlimited"
    static let av2ParallelChunksKey = "av2ParallelChunks"       // 0 = auto (all cores), 1 = single-process, N = explicit
    static let defaultAV2ParallelChunks = 0                     // auto-on: split into one chunk per core
    static let av2ContainerKey = "av2Container"                 // AV2Container raw value (ivf video-only / mkv with audio)
    static let defaultAV2Container = "IVF (video only)"
    static let av2AudioCodecKey = "av2AudioCodec"               // AV2AudioCodec raw value (used by the .mkv muxer)
    static let defaultAV2AudioCodec = "AAC"
    static let av2AudioBitrateKey = "av2AudioBitrate"           // AudioBitrate raw value for the muxed audio track
    static let defaultAV2AudioBitrate = "192 kbps"

    // Subtitle preservation
    static let keepSubtitlesKey = "keepSubtitles"
    static let defaultKeepSubtitles = false

    // VideoLoop mute settings
    static let videoLoopDefaultMutedKey = "videoLoopDefaultMuted"
    static let defaultVideoLoopMuted = true

    // Built-in preset visibility keys (all visible by default)
    static let videoLoopVisibleKey = "videoLoopVisible"
    static let videoLoopWithSoundVisibleKey = "videoLoopWithSoundVisible"
    static let animatedStillVisibleKey = "animatedStillVisible"
    static let h264VisibleKey = "h264Visible"
    static let h265VisibleKey = "h265Visible"
    static let av1VisibleKey = "av1Visible"
    static let av2VisibleKey = "av2Visible"
    static let tvHEVCVisibleKey = "tvHEVCVisible"
    static let tvAVCIntraVisibleKey = "tvAVCIntraVisible"
    static let proresVisibleKey = "proresVisible"
    static let proxyVisibleKey = "proxyVisible"
    static let streamCopyVisibleKey = "streamCopyVisible"
    static let audioWAVVisibleKey = "audioWAVVisible"       // Legacy — kept for migration
    static let audioAACVisibleKey = "audioAACVisible"       // Legacy — kept for migration
    static let audioMP4VisibleKey = "audioMP4Visible"       // Legacy — kept for migration
    static let audioOnlyVisibleKey = "audioOnlyVisible"

    // Audio Only preset settings
    static let audioOnlyFormatKey = "audioOnlyFormat"
    static let defaultAudioOnlyFormat = "WAV"
    static let audioOnlyBitDepthKey = "audioOnlyBitDepth"
    static let defaultAudioOnlyBitDepth = "24-bit"
    static let audioOnlyAACBitrateKey = "audioOnlyAACBitrate"
    static let defaultAudioOnlyAACBitrate = "192 kbps"
    static let audioOnlyMP4CodecKey = "audioOnlyMP4Codec"
    static let defaultAudioOnlyMP4Codec = "AAC"
    static let audioOnlyMP4BitrateKey = "audioOnlyMP4Bitrate"
    static let defaultAudioOnlyMP4Bitrate = "192 kbps"
    static let imageSequenceVisibleKey = "imageSequenceVisible"
    static let dcpVisibleKey = "dcpVisible"
    static let imfJ2KVisibleKey = "imfJ2KVisible"
    static let imfProResVisibleKey = "imfProResVisible"

    // Image sequence preset settings
    static let imageSequenceExportFormatKey = "imageSequenceExportFormat"
    static let defaultImageSequenceExportFormat = "PNG"
    static let imageSequenceExportQualityKey = "imageSequenceExportQuality"
    static let defaultImageSequenceExportQuality = 2 // JPEG quality (1=best, 31=worst)
    static let imageSequenceNumberingPaddingKey = "imageSequenceNumberingPadding"
    static let defaultImageSequenceNumberingPadding = 6
    static let imageSequenceFrameRateKey = "imageSequenceFrameRate"
    static let defaultImageSequenceFrameRate: Double = 24.0

    // Image sequence metadata sidecar
    static let imageSequenceMetadataSidecarEnabledKey = "imageSequenceMetadataSidecarEnabled"
    static let defaultImageSequenceMetadataSidecarEnabled = true
    static let imageSequenceMetadataSidecarFormatKey = "imageSequenceMetadataSidecarFormat"
    static let defaultImageSequenceMetadataSidecarFormat = "Markdown"

    // Reset behavior
    static let resetClearsSettingsKey = "resetClearsSettings"
    static let defaultResetClearsSettings = false // false = only reset status, true = also clear trim/crop/audio routing

    // Queue display settings
    static let queueViewModeKey = "queueViewMode"
    static let defaultQueueViewMode = "standard" // "standard" or "compact"

    // Sound settings
    static let playSoundOnSuccessKey = "playSoundOnSuccess"
    static let playSoundOnErrorKey = "playSoundOnError"
    static let defaultPlaySoundOnSuccess = true
    static let defaultPlaySoundOnError = true

    // Timecode display settings
    static let preferredTimecodeDisplayModeKey = "preferredTimecodeDisplayMode"
    static let defaultPreferredTimecodeDisplayMode = "relative" // relative, source, frames

    // yt-dlp settings
    static let ytdlpToolsDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let toolsDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        return toolsDir
    }()
    static let ytdlpCacheDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let cacheDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("yt-dlp-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()

    static let ytdlpVersionKey = "ytdlpInstalledVersion"
    static let ytdlpLastUpdateCheckKey = "ytdlpLastUpdateCheck"
    static let ytdlpGitHubReleasesURL = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    static let ytdlpMacOSAssetName = "yt-dlp_macos"
    static let ytdlpBinarySourceKey = "ytdlpBinarySource"

    static let denoVersionKey = "denoInstalledVersion"
    static let denoLastUpdateCheckKey = "denoLastUpdateCheck"
    static let denoGitHubReleasesURL = "https://api.github.com/repos/denoland/deno/releases/latest"
    static let denoBinarySourceKey = "denoBinarySource"
    static let denoCustomPathKey = "denoCustomPath"

    // Custom binary paths (no longer need security-scoped bookmarks without sandbox)
    static let ytdlpCustomPathKey = "ytdlpCustomPath"
    static let ffmpegBinarySourceKey = "ffmpegBinarySource"
    static let customFFmpegPathKey = "customFFmpegPath"

    // Legacy keys (for migration)
    static let ytdlpUserPathBookmarkKey = "ytdlpUserPathBookmark"
    static let ytdlpUserPathKey = "ytdlpUserPath"

    // Download history
    static let downloadHistoryKey = "downloadHistory"
    static let downloadHistoryMaxItems = 10

    // Download automation defaults
    static let autoEncodeAfterDownloadKey = "autoEncodeAfterDownload"
    static let autoUploadAfterDownloadKey = "autoUploadAfterDownload"

    // yt-dlp authentication
    static let ytdlpCookiesBrowserKey = "ytdlpCookiesBrowser"
    static let ytdlpLiveFromStartKey = "ytdlpLiveFromStart"
    static let ytdlpAudioOnlyKey = "ytdlpAudioOnly"
    static let ytdlpDownloadPlaylistKey = "ytdlpDownloadPlaylist"

    // Filename restriction mode for yt-dlp downloads. See YTDLPFilenameRestrictionMode.
    static let ytdlpFilenameRestrictionModeKey = "ytdlpFilenameRestrictionMode"
    static let defaultYTDLPFilenameRestrictionMode = "off"

    // When false (default), URLs whose host is a private/loopback/link-local IP or
    // a `.local`/localhost name are rejected before reaching yt-dlp. Power users
    // pulling from a LAN media server can flip this on in Settings > Download.
    static let allowPrivateNetworkDownloadsKey = "allowPrivateNetworkDownloads"

    // MARK: - Upload Settings

    // Unified profile storage (one list, each profile carries its own backend).
    static let uploadProfilesKey = "uploadProfiles"
    static let uploadSelectedProfileIDKey = "uploadSelectedProfileID"
    static let uploadProfileMigrationV2Key = "uploadProfileMigrationV2"

    static let uploadDefaultEnabledKey = "uploadDefaultEnabled"
    static let uploadRetryCountKey = "uploadRetryCount"
    static let defaultUploadPort = 21
    static let defaultUploadRetryCount = 3
    static let defaultSFTPPort = 22
    static let defaultSMBPort = 445

    // rclone binary management
    static let rcloneBinarySourceKey = "rcloneBinarySource"
    static let rcloneCustomPathKey = "rcloneCustomPath"

    // C2PA (Content Authenticity) settings
    static let c2paCheckEnabledKey = "c2paCheckEnabled"
    static let defaultC2PACheckEnabled = true

    // Auto-delete old encodes from default output folder
    static let autoDeleteOldEncodesKey = "autoDeleteOldEncodes"
    static let autoDeleteOldEncodesDaysKey = "autoDeleteOldEncodesDays"
    static let defaultAutoDeleteOldEncodes = false
    static let defaultAutoDeleteOldEncodesDays = 7
    static let autoDeleteOldEncodesDaysOptions = [1, 3, 7, 14, 31]

    // Output location settings
    static let saveNextToOriginalKey = "saveNextToOriginal"
    static let saveNextToOriginalSubfolderKey = "saveNextToOriginalSubfolder"
    static let saveNextToOriginalSubfolderModeKey = "saveNextToOriginalSubfolderMode" // "custom" or "presetSuffix"
    static let saveNextToOriginalSubfolderNameKey = "saveNextToOriginalSubfolderName"
    static let defaultSaveNextToOriginal = false
    static let defaultSaveNextToOriginalSubfolder = false
    static let defaultSaveNextToOriginalSubfolderMode = "custom" // "custom" or "presetSuffix"
    static let defaultSaveNextToOriginalSubfolderName = "Encoded"

    // MARK: - Whisper Settings

    // Whisper binary management
    static let whisperVersionKey = "whisperInstalledVersion"
    static let whisperLastUpdateCheckKey = "whisperLastUpdateCheck"
    static let whisperGitHubReleasesURL = "https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest"
    static let whisperCustomPathKey = "whisperCustomPath"

    // Whisper model management
    static let whisperModelKey = "whisperSelectedModel"
    static let whisperCustomModelPathKey = "whisperCustomModelPath"
    static let whisperModelsDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let modelsDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("whisper-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }()
    static let defaultWhisperModel = "base"

    // Whisper generation settings
    static let whisperDefaultEnabledKey = "whisperDefaultEnabled"
    static let whisperLanguageKey = "whisperLanguage"
    static let defaultWhisperLanguage = "auto"
    static let whisperMaxLineLengthKey = "whisperMaxLineLength"
    static let defaultWhisperMaxLineLength = 42  // Characters per subtitle line
    static let embedSubtitlesKey = "embedSubtitles"
    static let defaultEmbedSubtitles = false

    // Default transcription engine (shared)
    static let defaultTranscriptionEngineKey = "defaultTranscriptionEngine"
    static let defaultTranscriptionEngine = "whisper" // "whisper" or "parakeet"

    // MARK: - Parakeet Settings

    // Parakeet binary management
    static let parakeetCustomPathKey = "parakeetCustomPath"

    // Parakeet model management
    static let parakeetModelKey = "parakeetSelectedModel"
    static let defaultParakeetModel = "mlx-community/parakeet-tdt-0.6b-v3"

    // Parakeet generation settings
    static let parakeetLanguageKey = "parakeetLanguage"
    static let defaultParakeetLanguage = "en"
    static let parakeetChunkDurationKey = "parakeetChunkDuration"
    static let defaultParakeetChunkDuration = 300 // seconds
    static let parakeetOverlapDurationKey = "parakeetOverlapDuration"
    static let defaultParakeetOverlapDuration = 15 // seconds

    // HuggingFace Hub cache directory (used by parakeet-mlx for model storage)
    static var huggingFaceCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    // MARK: - OCR (Bitmap Subtitle) Settings

    // Engine selection — values match `OCREngineKind.rawValue`
    static let ocrEngineKey = "ocrEngineSelection"
    static let defaultOCREngine = "appleVision"

    // Apple Vision recognition language (BCP-47, e.g. "en-US")
    static let visionLanguageKey = "visionRecognitionLanguage"
    static let defaultVisionLanguage = "en-US"

    // MARK: - Tesseract Settings

    // Tesseract binary management
    static let tesseractBinarySourceKey = "tesseractBinarySource"
    static let tesseractCustomPathKey = "tesseractCustomPath"

    // Tesseract language / tessdata
    static let tesseractLanguageKey = "tesseractLanguage"
    static let defaultTesseractLanguage = "eng"

    // tessdata directory in Application Support (user can add extra .traineddata files here)
    static let tesseractTessdataDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("tessdata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Analytics Settings
    static let analyticsEnabledMetricsKey = "analyticsEnabledMetrics"
    static let analyticsVMAFModelKey = "analyticsVMAFModel"
    static let analyticsExportFormatKey = "analyticsExportFormat"
    static let analyticsAutoRunKey = "analyticsAutoRunAfterConversion"
    static let defaultAnalyticsEnabledMetrics: [String] = ["vmaf"]
    static let defaultAnalyticsVMAFModel = "vmaf_v0.6.1"
    static let defaultAnalyticsExportFormat = "json"

    static let analyticsAutoExportKey = "analyticsAutoExport"
    static let analyticsAutoExportFormatKey = "analyticsAutoExportFormat"
    static let defaultAnalyticsAutoExportFormat = "json"

    // MARK: - SSIMULACRA2 Settings
    static let ssimulacra2CustomPathKey = "ssimulacra2CustomPath"
    static let ssimulacra2MaxFramesKey = "ssimulacra2MaxFrames"
    static let defaultSSIMULACRA2MaxFrames: Int = 50

    // MARK: - Settings Sync

    /// Whether automatic two-way settings sync is enabled.
    static let settingsSyncEnabledKey = "settingsSyncEnabled"
    /// Where the sync snapshot lives — `SettingsSyncLocationMode.rawValue`
    /// ("iCloudDrive" or "customFolder").
    static let settingsSyncLocationModeKey = "settingsSyncLocationMode"
    /// `URL.path` of the user-chosen custom sync folder (a security-scoped
    /// bookmark for it is stored separately via `SecurityScopedBookmarkManager`).
    static let settingsSyncCustomFolderPathKey = "settingsSyncCustomFolderPath"
    /// `modifiedAt` of the most recent snapshot this Mac wrote or applied, used to
    /// avoid re-importing our own writes and to drive newest-wins. Stored as a
    /// `Date` (timeIntervalSinceReferenceDate).
    static let lastSettingsSyncDateKey = "lastSettingsSyncDate"

    /// File name used for the settings snapshot in whichever sync folder is active.
    static let settingsSyncFileName = "settings.json"
    /// Subfolder created inside the sync location to hold the snapshot.
    static let settingsSyncFolderName = "Aagedal Media Converter"
}
