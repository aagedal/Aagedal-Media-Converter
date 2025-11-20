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
    // Default output directory
    static let defaultOutputDirectory: URL = {
        let defaultDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoLoopExports")
        
        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        return defaultDir
    }()

    static let defaultScreenshotDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    
    // Directory for cached preview assets (thumbnails, waveforms, etc.)
    static let previewCacheDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        "wma", "wmv", "wtv", "y4m"
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
    
    // Maximum thumbnail dimensions
    static let maxThumbnailSize = CGSize(width: 320, height: 320)
    static let includeDateTagPreferenceKey = "includeDateTagByDefault"
    static let preserveMetadataPreferenceKey = "preserveMetadataByDefault"
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
    static let watchFolderIgnoreOlderThan24hKey = "watchFolderIgnoreOlderThan24h"
    static let watchFolderAutoDeleteOlderThanWeekKey = "watchFolderAutoDeleteOlderThanWeek"
    static let watchFolderIgnoreDurationValueKey = "watchFolderIgnoreDurationValue"
    static let watchFolderIgnoreDurationUnitKey = "watchFolderIgnoreDurationUnit"
    static let watchFolderDeleteDurationValueKey = "watchFolderDeleteDurationValue"
    static let watchFolderDeleteDurationUnitKey = "watchFolderDeleteDurationUnit"
    static let previewCacheCleanupPolicyKey = "previewCacheCleanupPolicy"
    static let defaultPreviewCacheCleanupPolicyRaw = PreviewCacheCleanupPolicy.purgeOnLaunch.rawValue
    static let watchFolderDurationValues: [Int] = [1, 3, 5, 7, 10, 14, 24, 31]
    static let defaultWatchFolderIgnoreDurationValue = 24
    static let defaultWatchFolderIgnoreDurationUnitRaw = WatchFolderDurationUnit.hours.rawValue
    static let defaultWatchFolderDeleteDurationValue = 7
    static let defaultWatchFolderDeleteDurationUnitRaw = WatchFolderDurationUnit.days.rawValue
    static let customPresetPrefixes = ["C1:", "C2:", "C3:"]
    static let defaultCustomPresetDisplayNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset"
    ]
    static let defaultCustomPresetNameSuffixes = [
        "Custom Preset",
        "Custom Preset",
        "Custom Preset"
    ]
    static let defaultCustomPresetFullNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset"
    ]
    static let defaultCustomPresetCommands = ["-c copy", "-c copy", "-c copy"]
    static let defaultCustomPresetSuffixes = ["_c1", "_c2", "_c3"]
    static let defaultCustomPresetExtensions = ["mp4", "mp4", "mp4"]

    static let screenshotDirectoryKey = "screenshotDirectory"
    static let proResProfileKey = "proResProfile"
}
