// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// The explicit allowlist of `UserDefaults` keys that participate in settings
/// sync / export.
///
/// Deliberately an **allowlist, not a denylist**: a key only crosses devices if
/// it is listed here, so machine-specific data (folder paths, security-scoped
/// bookmarks, binary install versions/paths, update timestamps, capture
/// hardware IDs, upload credentials) can never leak by omission.
///
/// Maintenance note: when you add a new *syncable* user preference, add its key
/// here. New machine-specific keys need no change — they are excluded by default.
enum SettingsSyncKeys {

    /// All keys eligible for sync, computed once.
    static let all: Set<String> = {
        var keys = Set<String>()
        keys.formUnion(customPresetKeys)
        keys.formUnion(staticKeys)
        return keys
    }()

    // MARK: - Custom presets (10 slots × 7 keys, built from the dynamic helpers)

    private static let customPresetKeys: [String] = {
        var keys: [String] = []
        for slot in 0..<10 {
            keys.append(AppConstants.customPresetCommandKey(for: slot))
            keys.append(AppConstants.customPresetSuffixKey(for: slot))
            keys.append(AppConstants.customPresetExtensionKey(for: slot))
            keys.append(AppConstants.customPresetNameKey(for: slot))
            keys.append(AppConstants.customPresetActiveKey(for: slot))
            keys.append(AppConstants.customPresetApplyCropKey(for: slot))
            keys.append(AppConstants.customPresetApplyAudioRoutingKey(for: slot))
        }
        return keys
    }()

    // MARK: - Everything else (grouped by Settings category)

    private static let staticKeys: [String] = [
        // Preset selection & encoding-group defaults
        AppConstants.defaultPresetKey,
        AppConstants.defaultGroupMergeEnabledKey,
        AppConstants.defaultGroupSequentialNamingEnabledKey,
        AppConstants.defaultGroupPresetKey,

        // Built-in preset visibility
        AppConstants.videoLoopVisibleKey,
        AppConstants.videoLoopWithSoundVisibleKey,
        AppConstants.animatedStillVisibleKey,
        AppConstants.h264VisibleKey,
        AppConstants.h265VisibleKey,
        AppConstants.av1VisibleKey,
        AppConstants.av2VisibleKey,
        AppConstants.tvHEVCVisibleKey,
        AppConstants.tvAVCIntraVisibleKey,
        AppConstants.proresVisibleKey,
        AppConstants.proxyVisibleKey,
        AppConstants.streamCopyVisibleKey,
        AppConstants.audioOnlyVisibleKey,
        AppConstants.imageSequenceVisibleKey,
        AppConstants.dcpVisibleKey,
        AppConstants.imfJ2KVisibleKey,
        AppConstants.imfProResVisibleKey,

        // H.264
        AppConstants.h264EncoderKey,
        AppConstants.h264ContainerKey,
        AppConstants.h264QualityKey,
        AppConstants.h264SpeedKey,
        AppConstants.h264ResolutionLimitKey,
        AppConstants.h264BitrateKey,
        AppConstants.h264AudioFormatKey,
        AppConstants.h264AudioBitrateKey,

        // H.265
        AppConstants.h265EncoderKey,
        AppConstants.h265ContainerKey,
        AppConstants.h265QualityKey,
        AppConstants.h265SpeedKey,
        AppConstants.h265ResolutionLimitKey,
        AppConstants.h265BitrateKey,
        AppConstants.h265AudioFormatKey,
        AppConstants.h265AudioBitrateKey,

        // AV1
        AppConstants.av1ContainerKey,
        AppConstants.av1QualityKey,
        AppConstants.av1SpeedKey,
        AppConstants.av1ResolutionLimitKey,
        AppConstants.av1AudioFormatKey,
        AppConstants.av1AudioBitrateKey,
        AppConstants.av1TuneKey,
        AppConstants.av1FilmGrainKey,
        AppConstants.av1FilmGrainDenoiseKey,
        AppConstants.av1SharpnessKey,
        AppConstants.av1FastDecodeKey,
        AppConstants.av1VarianceBoostKey,
        AppConstants.av1VarianceBoostCurveKey,

        // AV2
        AppConstants.av2RateControlModeKey,
        AppConstants.av2QualityKey,
        AppConstants.av2TargetBitrateKey,
        AppConstants.av2SpeedKey,
        AppConstants.av2BitDepthKey,
        AppConstants.av2ThreadsKey,
        AppConstants.av2TileColumnsKey,
        AppConstants.av2TileRowsKey,
        AppConstants.av2ResolutionLimitKey,

        // ProRes / Proxy / Stream Copy / Animated Still
        AppConstants.proResProfileKey,
        AppConstants.proxyCodecKey,
        AppConstants.proxyResolutionLimitKey,
        AppConstants.streamCopyContainerKey,
        AppConstants.animatedStillFormatKey,

        // TV / AVC-Intra
        AppConstants.tvFramerateModeKey,
        AppConstants.tvResolutionLimitKey,
        AppConstants.avcIntraClassKey,
        AppConstants.avcIntraAudioChannelsKey,
        AppConstants.avcIntraDefaultMCASoundfield1ChKey,
        AppConstants.avcIntraDefaultMCASoundfield2ChKey,
        AppConstants.avcIntraDefaultMCASoundfield6ChKey,
        AppConstants.avcIntraDefaultMCASoundfield8ChKey,

        // DCP
        AppConstants.dcpResolutionKey,
        AppConstants.dcpFrameRateKey,
        AppConstants.dcpBitrateKey,
        AppConstants.dcpScalingModeKey,
        AppConstants.dcpKeepJP2ImagesKey,

        // IMF
        AppConstants.imfApplicationKey,
        AppConstants.imfResolutionKey,
        AppConstants.imfFrameRateKey,
        AppConstants.imfScalingModeKey,
        AppConstants.imfJ2KColorEncodingKey,
        AppConstants.imfJ2KBitrateKey,
        AppConstants.imfProResProfileKey,
        AppConstants.imfAudioBitDepthKey,
        AppConstants.imfKeepIntermediatesKey,

        // Audio Only
        AppConstants.audioOnlyFormatKey,
        AppConstants.audioOnlyBitDepthKey,
        AppConstants.audioOnlyAACBitrateKey,
        AppConstants.audioOnlyMP4CodecKey,
        AppConstants.audioOnlyMP4BitrateKey,

        // Image Sequence
        AppConstants.imageSequenceExportFormatKey,
        AppConstants.imageSequenceExportQualityKey,
        AppConstants.imageSequenceNumberingPaddingKey,
        AppConstants.imageSequenceFrameRateKey,
        AppConstants.imageSequenceMetadataSidecarEnabledKey,
        AppConstants.imageSequenceMetadataSidecarFormatKey,

        // VideoLoop / subtitles
        AppConstants.videoLoopDefaultMutedKey,
        AppConstants.keepSubtitlesKey,

        // File-name processing & templates
        AppConstants.includeDateTagPreferenceKey,
        AppConstants.preserveMetadataPreferenceKey,
        AppConstants.commentPrefixKey,
        AppConstants.commentSuffixKey,
        AppConstants.commentSeparatorKey,
        AppConstants.commentDateFormatKey,
        AppConstants.dateTagPrefixKey,
        AppConstants.showCommentFieldKey,
        AppConstants.showDateTagButtonKey,
        AppConstants.enableFileNameProcessingKey,
        AppConstants.fileNameReplaceSpacesKey,
        AppConstants.fileNameReplaceScandinavianCharsKey,
        AppConstants.fileNameRemoveSpecialCharsKey,
        AppConstants.fileNameSpecialCharRemovalModeKey,
        AppConstants.fileNameIncludePresetSuffixKey,
        AppConstants.enableCustomFileNameTemplateKey,
        AppConstants.customFileNameTemplateKey,
        AppConstants.customFileNameDateFormatKey,
        AppConstants.customFileNameCounterPaddingKey,
        // Note: customFileNameCounterValue is intentionally excluded — the running
        // counter is per-machine output state, not a preference.

        // Audio waveform rendering
        AppConstants.audioWaveformVideoDefaultEnabledKey,
        AppConstants.audioWaveformResolutionKey,
        AppConstants.audioWaveformBackgroundColorKey,
        AppConstants.audioWaveformForegroundColorKey,
        AppConstants.audioWaveformNormalizeKey,
        AppConstants.audioWaveformStyleKey,
        AppConstants.audioWaveformFrameRateKey,
        AppConstants.audioWaveformLineThicknessKey,
        AppConstants.audioWaveformDetailLevelKey,
        AppConstants.audioWaveformAspectRatioKey,
        AppConstants.audioWaveformShortEdgeKey,
        AppConstants.audioWaveformRenderingEngineKey,
        AppConstants.audioWaveformSwiftStyleKey,
        AppConstants.audioWaveformBandCountKey,
        AppConstants.audioWaveformFrequencyDistributionKey,
        AppConstants.audioWaveformForegroundGradientEnabledKey,
        AppConstants.audioWaveformForegroundGradientEndColorKey,
        AppConstants.audioWaveformBackgroundGradientEnabledKey,
        AppConstants.audioWaveformBackgroundGradientEndColorKey,
        AppConstants.audioWaveformOpacityKey,

        // Timecode
        AppConstants.defaultTimecodeModeKey,
        AppConstants.defaultTimecodeValueKey,
        AppConstants.preferredTimecodeDisplayModeKey,

        // Metadata (last-used content kinds)
        AppConstants.lastDCPContentKindKey,
        AppConstants.lastIMFContentKindKey,

        // Screenshots
        AppConstants.screenshot8BitFormatKey,
        AppConstants.screenshot10BitFormatKey,
        AppConstants.screenshotHighBitFormatKey,
        AppConstants.screenshotAlphaHandlingKey,

        // Screen capture (preferences only — excludes display/mic hardware IDs
        // and region coordinates, which are machine-specific)
        AppConstants.captureHideCursorKey,
        AppConstants.captureExcludeCurrentAppKey,
        AppConstants.captureFrameRateKey,
        AppConstants.captureDynamicRangeKey,
        AppConstants.captureIncludeSystemAudioKey,
        AppConstants.captureIncludeMicrophoneKey,
        AppConstants.capturePresetKey,

        // Watch folder behaviour (excludes the folder path itself)
        AppConstants.watchFolderModeKey,
        AppConstants.watchFolderAutoActivateOnLaunchKey,
        AppConstants.watchFolderIgnoreOlderThan24hKey,
        AppConstants.watchFolderAutoDeleteOlderThanWeekKey,
        AppConstants.watchFolderIgnoreDurationValueKey,
        AppConstants.watchFolderIgnoreDurationUnitKey,
        AppConstants.watchFolderDeleteDurationValueKey,
        AppConstants.watchFolderDeleteDurationUnitKey,
        AppConstants.watchFolderKeepAwakeKey,
        AppConstants.previewCacheCleanupPolicyKey,

        // Output handling (modes/names only — not absolute folder paths)
        AppConstants.autoDeleteOldEncodesKey,
        AppConstants.autoDeleteOldEncodesDaysKey,
        AppConstants.saveNextToOriginalKey,
        AppConstants.saveNextToOriginalSubfolderKey,
        AppConstants.saveNextToOriginalSubfolderModeKey,
        AppConstants.saveNextToOriginalSubfolderNameKey,

        // Download automation preferences (no auth, paths, or install state)
        AppConstants.autoEncodeAfterDownloadKey,
        AppConstants.autoUploadAfterDownloadKey,
        AppConstants.ytdlpCookiesBrowserKey,
        AppConstants.ytdlpLiveFromStartKey,
        AppConstants.ytdlpAudioOnlyKey,
        AppConstants.ytdlpDownloadPlaylistKey,
        AppConstants.ytdlpFilenameRestrictionModeKey,
        AppConstants.allowPrivateNetworkDownloadsKey,

        // Transcription / OCR preferences (model & language choices, not paths)
        AppConstants.defaultTranscriptionEngineKey,
        AppConstants.whisperModelKey,
        AppConstants.whisperDefaultEnabledKey,
        AppConstants.whisperLanguageKey,
        AppConstants.whisperFasterTranscriptionKey,
        AppConstants.whisperMaxLineLengthKey,
        AppConstants.embedSubtitlesKey,
        AppConstants.parakeetModelKey,
        AppConstants.parakeetLanguageKey,
        AppConstants.nemotronLanguageKey,
        AppConstants.parakeetChunkDurationKey,
        AppConstants.parakeetOverlapDurationKey,
        AppConstants.ocrEngineKey,
        AppConstants.visionLanguageKey,
        AppConstants.tesseractLanguageKey,

        // Analytics preferences (excludes the SSIMULACRA2 binary path)
        AppConstants.analyticsEnabledMetricsKey,
        AppConstants.analyticsVMAFModelKey,
        AppConstants.analyticsExportFormatKey,
        AppConstants.analyticsAutoRunKey,
        AppConstants.analyticsAutoExportKey,
        AppConstants.analyticsAutoExportFormatKey,
        AppConstants.ssimulacra2MaxFramesKey,

        // Content authenticity
        AppConstants.c2paCheckEnabledKey,

        // General UI & behaviour
        AppConstants.queueViewModeKey,
        AppConstants.resetClearsSettingsKey,
        AppConstants.playSoundOnSuccessKey,
        AppConstants.playSoundOnErrorKey,
    ]
}
