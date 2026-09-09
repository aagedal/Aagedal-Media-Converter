// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Queue defaults captured before an import crosses actors or loads metadata.
/// The settings editor's manual timecode text is preserved for existing validation.
struct VideoImportSettings: Sendable {
    let includeDateTag: Bool
    let waveformVideoEnabled: Bool
    let timecode: TimecodeConfig?

    init(defaults: UserDefaults = .standard) {
        includeDateTag = defaults.bool(forKey: AppConstants.includeDateTagPreferenceKey)
        waveformVideoEnabled = defaults.bool(forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)
        let mode = defaults.string(forKey: AppConstants.defaultTimecodeModeKey)
            ?? AppConstants.defaultTimecodeModeRaw
        switch mode {
        case "preserveSource":
            timecode = TimecodeConfig(mode: .preserveSource)
        case "manual":
            timecode = TimecodeConfig(mode: .manual(
                defaults.string(forKey: AppConstants.defaultTimecodeValueKey) ?? AppConstants.defaultTimecodeValue
            ))
        default:
            timecode = nil
        }
    }
}

/// Naming preferences captured before import metadata work suspends.
struct VideoImportNamingSettings: Sendable {
    let fileName: FileNamePreferences
    let destination: OutputDestinationSettings
    let context: FileNameTemplateContext
    let date: Date
    private let codec: CodecExportSettings?
    private let fileExtension: String

    init(preset: ExportPreset, defaults: UserDefaults = .standard, date: Date = Date()) {
        fileName = FileNameSettings(defaults: defaults).snapshot
        destination = OutputDestinationSettings(defaults: defaults)
        context = FileNameTemplateContext(preset: preset, defaults: defaults)
        self.date = date
        codec = CodecExportSettings(preset: preset, defaults: defaults)
        switch preset {
        case .av2: fileExtension = AV2Settings(defaults: defaults).container.fileExtension
        case .audioOnly: fileExtension = AudioOnlySettings(defaults: defaults).format.fileExtension
        case .imageSequence: fileExtension = ImageSequenceSettings(defaults: defaults).format.primaryExtension
        case .dcp, .imfJ2K, .imfProRes: fileExtension = "mxf"
        default: fileExtension = codec?.fileExtension ?? "mp4"
        }
    }

    func outputExtension(for sourceURL: URL) -> String {
        codec?.outputExtension(for: sourceURL) ?? fileExtension
    }

    func namingContext(preset: ExportPreset, imageSequenceFrameRate: Double?) -> FileNameTemplateContext {
        guard preset == .imageSequence else { return context }
        return FileNameTemplateContext(
            presetSuffix: context.presetSuffix, resolution: context.resolution,
            framerate: FileNameTemplateContext.imageSequenceFramerateLabel(imageSequenceFrameRate)
        )
    }
}

/// Preferences shared by request preparation, output naming, and execution.
/// Capture before metadata or merge preparation suspends; item metadata can then
/// select a generated-video request without consulting preferences again.
struct ConversionPreparationSettings: Sendable {
    let av2: AV2Settings?
    let dcp: DCPSettings?
    let imf: IMFSettings?
    let audioOnly: AudioOnlySettings?
    let imageSequence: ImageSequenceSettings?
    let codec: CodecExportSettings?
    let subtitles: SubtitleExportSettings
    let comment: CommentSettings
    let packageMetadata: PackageMetadataSettings
    let generatedVideo: GeneratedVideoSettings
    let fileName: FileNamePreferences
    let fileNameContext: FileNameTemplateContext
    let outputDestination: OutputDestinationSettings

    init(preset: ExportPreset, defaults: UserDefaults = .standard) {
        av2 = preset == .av2 ? AV2Settings(defaults: defaults) : nil
        dcp = preset == .dcp ? DCPSettings(defaults: defaults) : nil
        imf = (preset == .imfJ2K || preset == .imfProRes) ? IMFSettings(defaults: defaults) : nil
        audioOnly = preset == .audioOnly ? AudioOnlySettings(defaults: defaults) : nil
        imageSequence = preset == .imageSequence ? ImageSequenceSettings(defaults: defaults) : nil
        codec = CodecExportSettings(preset: preset, defaults: defaults)
        subtitles = SubtitleExportSettings(defaults: defaults)
        comment = CommentSettings(defaults: defaults)
        packageMetadata = PackageMetadataSettings(defaults: defaults)
        generatedVideo = GeneratedVideoSettings(preset: preset, defaults: defaults)
        fileName = FileNameSettings(defaults: defaults).snapshot
        fileNameContext = codec?.fileNameContext ?? FileNameTemplateContext(
            preset: preset, defaults: defaults, av2Settings: av2, dcpSettings: dcp, imfSettings: imf
        )
        outputDestination = OutputDestinationSettings(defaults: defaults)
    }

    func namingContext(preset: ExportPreset, imageSequenceFrameRate: Double?) -> FileNameTemplateContext {
        guard preset == .imageSequence else { return fileNameContext }
        return FileNameTemplateContext(
            presetSuffix: fileNameContext.presetSuffix, resolution: fileNameContext.resolution,
            framerate: FileNameTemplateContext.imageSequenceFramerateLabel(imageSequenceFrameRate)
        )
    }
}

/// Destination preferences contain no bookmarks or machine-specific output path.
/// Preset-based subfolders use the same captured suffix as the output filename.
struct OutputDestinationSettings: Sendable {
    let saveNextToOriginal: Bool
    let useSubfolder: Bool
    let usePresetSuffix: Bool
    let customSubfolderName: String

    init(defaults: UserDefaults = .standard) {
        saveNextToOriginal = defaults.bool(forKey: AppConstants.saveNextToOriginalKey)
        useSubfolder = defaults.bool(forKey: AppConstants.saveNextToOriginalSubfolderKey)
        usePresetSuffix = defaults.string(forKey: AppConstants.saveNextToOriginalSubfolderModeKey) == "presetSuffix"
        customSubfolderName = defaults.string(forKey: AppConstants.saveNextToOriginalSubfolderNameKey)
            ?? AppConstants.defaultSaveNextToOriginalSubfolderName
    }

    func resolveFolder(for sourceURL: URL, defaultOutputFolder: String?, presetSuffix: String) -> String? {
        guard saveNextToOriginal else { return defaultOutputFolder }
        var directory = sourceURL.deletingLastPathComponent()
        if useSubfolder {
            let name = usePresetSuffix
                ? String(presetSuffix.dropFirst(presetSuffix.hasPrefix("_") ? 1 : 0))
                : customSubfolderName
            if !name.isEmpty { directory.appendPathComponent(name) }
        }
        return directory.path
    }
}
