// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// How aggressively to strip "special" characters when sanitizing a filename.
enum SpecialCharacterRemovalMode: String, CaseIterable, Identifiable {
    /// Preserve every character — no removal step at all.
    case off
    /// Strip only filesystem-unsafe punctuation (`/ \ : * ? " < > |`) and control characters.
    /// Letters with diacritics (é, ü), Nordic letters (æ, ø, å), and other Unicode letters survive.
    case loose
    /// Keep only ASCII letters, digits, underscore, hyphen, and space. Drops everything else.
    case strict

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Don't remove any characters"
        case .loose: return "Only filesystem-unsafe characters (/ \\ : * ? \" < > |)"
        case .strict: return "All non-ASCII (only A–Z, 0–9, _, -)"
        }
    }
}

/// Utility for processing and sanitizing file names.
struct FileNameProcessor {
    /// Resolves the user's current special-character removal mode, falling back to the legacy
    /// boolean toggle if the new key has not been set yet.
    static var specialCharRemovalMode: SpecialCharacterRemovalMode {
        FileNameSettings().specialCharacterRemovalMode
    }

    /// Processes a file name to ensure it's safe for use in file systems.
    /// - Parameter input: The input file name to process
    /// - Returns: A sanitized version of the input string with spaces replaced by underscores,
    ///   special characters removed, and other sanitization applied. If filename processing is disabled
    ///   in user preferences, returns the input unchanged.
    static func processFileName(_ input: String) -> String {
        let isEnabled = UserDefaults.standard.object(forKey: AppConstants.enableFileNameProcessingKey) as? Bool ?? true
        guard isEnabled else { return input }

        let replaceSpaces = UserDefaults.standard.object(forKey: AppConstants.fileNameReplaceSpacesKey) as? Bool ?? AppConstants.defaultFileNameReplaceSpaces
        let replaceScandinavianChars = UserDefaults.standard.object(forKey: AppConstants.fileNameReplaceScandinavianCharsKey) as? Bool ?? AppConstants.defaultFileNameReplaceScandinavianChars
        let mode = specialCharRemovalMode

        var cleanedName = input

        if replaceSpaces {
            cleanedName = cleanedName.replacingOccurrences(of: " ", with: "_")
        }

        if replaceScandinavianChars {
            cleanedName = cleanedName
                .replacingOccurrences(of: "æ", with: "ae")
                .replacingOccurrences(of: "ø", with: "o")
                .replacingOccurrences(of: "å", with: "aa")
                .replacingOccurrences(of: "Æ", with: "AE")
                .replacingOccurrences(of: "Ø", with: "O")
                .replacingOccurrences(of: "Å", with: "AA")
        }

        switch mode {
        case .off:
            break
        case .loose:
            let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
            cleanedName = cleanedName.components(separatedBy: unsafe).joined()
            cleanedName = cleanedName.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        case .strict:
            let pattern = "[^a-zA-Z0-9_\\- ]"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleanedName.startIndex..<cleanedName.endIndex, in: cleanedName)
                cleanedName = regex.stringByReplacingMatches(
                    in: cleanedName,
                    range: range,
                    withTemplate: ""
                )
            }
            cleanedName = cleanedName.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        }

        return cleanedName.isEmpty ? "unnamed" : cleanedName
    }

    /// Returns whether preset suffixes should be included in output filenames.
    static var includePresetSuffix: Bool {
        UserDefaults.standard.object(forKey: AppConstants.fileNameIncludePresetSuffixKey) as? Bool ?? AppConstants.defaultFileNameIncludePresetSuffix
    }

    /// Whether the custom filename template is enabled.
    static var customTemplateEnabled: Bool {
        UserDefaults.standard.object(forKey: AppConstants.enableCustomFileNameTemplateKey) as? Bool ?? AppConstants.defaultEnableCustomFileNameTemplate
    }

    /// Whether the configured template references the `{counter}` variable.
    static var customTemplateUsesCounter: Bool {
        guard customTemplateEnabled else { return false }
        let template = UserDefaults.standard.string(forKey: AppConstants.customFileNameTemplateKey)
            ?? AppConstants.defaultCustomFileNameTemplate
        return template.contains("{counter}")
    }

    /// Whether the configured template explicitly includes the preset suffix variable.
    /// When true, callers should suppress the global "include preset suffix" auto-append to avoid
    /// duplicating the suffix.
    static var customTemplateUsesPresetSuffix: Bool {
        guard customTemplateEnabled else { return false }
        let template = UserDefaults.standard.string(forKey: AppConstants.customFileNameTemplateKey)
            ?? AppConstants.defaultCustomFileNameTemplate
        return template.contains("{presetSuffix}")
    }

    /// Atomically reads and increments the persisted counter value, returning the value before increment.
    static func nextCounterValue() -> Int {
        let stored = UserDefaults.standard.object(forKey: AppConstants.customFileNameCounterValueKey) as? Int
            ?? AppConstants.defaultCustomFileNameCounterValue
        UserDefaults.standard.set(stored + 1, forKey: AppConstants.customFileNameCounterValueKey)
        return stored
    }

    /// Applies the user's custom filename template to a sanitized source name.
    /// - Parameters:
    ///   - sourceName: The already-sanitized base name (output of `processFileName`).
    ///   - counter: Counter value baked at queue-add time. If nil, `{counter}` resolves to "1".
    ///   - preset: Active export preset, used to resolve `{presetSuffix}`, `{resolution}`, `{framerate}`.
    ///     Pass nil to substitute those variables with empty strings.
    /// - Returns: The templated name, re-sanitized through the active filename rules.
    static func applyCustomTemplate(sourceName: String, counter: Int? = nil, preset: ExportPreset? = nil) -> String {
        guard customTemplateEnabled else { return sourceName }

        let template = UserDefaults.standard.string(forKey: AppConstants.customFileNameTemplateKey)
            ?? AppConstants.defaultCustomFileNameTemplate
        guard !template.isEmpty else { return sourceName }

        let dateFormat = UserDefaults.standard.string(forKey: AppConstants.customFileNameDateFormatKey)
            ?? AppConstants.defaultCustomFileNameDateFormat
        let padding = UserDefaults.standard.object(forKey: AppConstants.customFileNameCounterPaddingKey) as? Int
            ?? AppConstants.defaultCustomFileNameCounterPadding

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        let dateString = formatter.string(from: Date())

        let counterString = String(format: "%0\(max(1, padding))d", counter ?? 1)

        let presetSuffix = preset?.fileSuffix ?? ""
        let resolution = preset?.resolutionLabel ?? ""
        let framerate = preset?.framerateLabel ?? ""

        let substituted = template
            .replacingOccurrences(of: "{sourceName}", with: sourceName)
            .replacingOccurrences(of: "{date}", with: dateString)
            .replacingOccurrences(of: "{counter}", with: counterString)
            .replacingOccurrences(of: "{presetSuffix}", with: presetSuffix)
            .replacingOccurrences(of: "{resolution}", with: resolution)
            .replacingOccurrences(of: "{framerate}", with: framerate)

        return processFileName(substituted)
    }
}
