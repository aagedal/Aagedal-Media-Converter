// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads filename preferences without changing either schema. The legacy boolean
/// remains a fallback until an explicit mode is saved by Settings.
struct FileNameSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var snapshot: FileNamePreferences {
        FileNamePreferences(
            isEnabled: defaults.object(forKey: AppConstants.enableFileNameProcessingKey) as? Bool ?? true,
            replaceSpaces: defaults.object(forKey: AppConstants.fileNameReplaceSpacesKey) as? Bool ?? AppConstants.defaultFileNameReplaceSpaces,
            replaceScandinavianCharacters: defaults.object(forKey: AppConstants.fileNameReplaceScandinavianCharsKey) as? Bool ?? AppConstants.defaultFileNameReplaceScandinavianChars,
            specialCharacterRemovalMode: specialCharacterRemovalMode,
            includePresetSuffix: defaults.object(forKey: AppConstants.fileNameIncludePresetSuffixKey) as? Bool ?? AppConstants.defaultFileNameIncludePresetSuffix,
            customTemplateEnabled: defaults.object(forKey: AppConstants.enableCustomFileNameTemplateKey) as? Bool ?? AppConstants.defaultEnableCustomFileNameTemplate,
            template: defaults.string(forKey: AppConstants.customFileNameTemplateKey) ?? AppConstants.defaultCustomFileNameTemplate,
            dateFormat: defaults.string(forKey: AppConstants.customFileNameDateFormatKey) ?? AppConstants.defaultCustomFileNameDateFormat,
            counterPadding: min(6, max(1, defaults.object(forKey: AppConstants.customFileNameCounterPaddingKey) as? Int ?? AppConstants.defaultCustomFileNameCounterPadding))
        )
    }

    /// Queue insertion serializes reservations on the main actor, where preference
    /// observers also run. Holding a lock while UserDefaults notifies those observers
    /// can deadlock a concurrent import. At Int.max, output collision checks still apply.
    @MainActor
    func nextCounterValue() -> Int {
        let stored = defaults.object(forKey: AppConstants.customFileNameCounterValueKey) as? Int
            ?? AppConstants.defaultCustomFileNameCounterValue
        defaults.set(stored == Int.max ? stored : stored + 1, forKey: AppConstants.customFileNameCounterValueKey)
        return stored
    }

    var specialCharacterRemovalMode: SpecialCharacterRemovalMode {
        if let raw = defaults.string(forKey: AppConstants.fileNameSpecialCharRemovalModeKey),
           let mode = SpecialCharacterRemovalMode(rawValue: raw) {
            return mode
        }
        // Preserve the original boolean's behavior: true → strict, false → off.
        if let legacy = defaults.object(forKey: AppConstants.fileNameRemoveSpecialCharsKey) as? Bool {
            return legacy ? .strict : .off
        }
        return SpecialCharacterRemovalMode(rawValue: AppConstants.defaultFileNameSpecialCharRemovalMode) ?? .loose
    }
}

/// One immutable set of rules for sanitizing, templating, and appending a suffix.
struct FileNamePreferences: Sendable {
    let isEnabled: Bool
    let replaceSpaces: Bool
    let replaceScandinavianCharacters: Bool
    let specialCharacterRemovalMode: SpecialCharacterRemovalMode
    let includePresetSuffix: Bool
    let customTemplateEnabled: Bool
    let template: String
    let dateFormat: String
    let counterPadding: Int

    var customTemplateUsesCounter: Bool {
        customTemplateEnabled && template.contains("{counter}")
    }

    var customTemplateUsesPresetSuffix: Bool {
        customTemplateEnabled && template.contains("{presetSuffix}")
    }
}

/// Resolved preset labels, captured once before rendering the filename.
struct FileNameTemplateContext: Sendable {
    let presetSuffix: String
    let resolution: String
    let framerate: String

    init(presetSuffix: String = "", resolution: String = "", framerate: String = "") {
        self.presetSuffix = presetSuffix
        self.resolution = resolution
        self.framerate = framerate
    }

    init(
        preset: ExportPreset?, defaults: UserDefaults = .standard,
        av2Settings: AV2Settings? = nil, dcpSettings: DCPSettings? = nil, imfSettings: IMFSettings? = nil
    ) {
        presetSuffix = preset?.fileSuffix(defaults: defaults) ?? ""
        if preset == .dcp, let dcpSettings {
            resolution = ExportPreset.dcpResolutionLabel(from: dcpSettings.resolution.rawValue) ?? ""
            framerate = dcpSettings.frameRate.ffmpegValue
        } else if preset == .imfJ2K || preset == .imfProRes, let imfSettings {
            resolution = imfSettings.resolution.shortTier
            framerate = imfSettings.frameRate.folderTag
        } else {
            if preset == .av2, let av2Settings {
                resolution = ExportPreset.label(for: av2Settings.resolutionLimit) ?? ""
            } else {
                resolution = preset?.resolutionLabel(defaults: defaults) ?? ""
            }
            framerate = preset?.framerateLabel(defaults: defaults) ?? ""
        }
    }
}
