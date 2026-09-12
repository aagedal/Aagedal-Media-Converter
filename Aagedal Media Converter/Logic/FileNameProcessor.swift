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
enum SpecialCharacterRemovalMode: String, CaseIterable, Identifiable, Sendable {
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
    static func processFileName(_ input: String, settings: FileNamePreferences = FileNameSettings().snapshot) -> String {
        guard settings.isEnabled else { return input }
        let replaceSpaces = settings.replaceSpaces
        let replaceScandinavianChars = settings.replaceScandinavianCharacters
        let mode = settings.specialCharacterRemovalMode

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

    /// Compatibility accessors for individual UI actions.
    static var includePresetSuffix: Bool { FileNameSettings().snapshot.includePresetSuffix }
    static var customTemplateEnabled: Bool { FileNameSettings().snapshot.customTemplateEnabled }
    static var customTemplateUsesCounter: Bool { FileNameSettings().snapshot.customTemplateUsesCounter }
    static var customTemplateUsesPresetSuffix: Bool { FileNameSettings().snapshot.customTemplateUsesPresetSuffix }

    @MainActor
    static func nextCounterValue() -> Int { FileNameSettings().nextCounterValue() }

    /// Shared by import, the queue preview, and conversion execution.
    static func outputBaseName(
        inputURL: URL, override: String? = nil, counter: Int? = nil, preset: ExportPreset,
        settings: FileNamePreferences = FileNameSettings().snapshot,
        context: FileNameTemplateContext? = nil, date: Date = Date()
    ) -> String {
        let parts = outputNameParts(inputURL: inputURL, override: override, counter: counter, preset: preset,
                                    settings: settings, context: context, date: date)
        return parts.baseName + parts.suffix
    }

    static func outputNameParts(
        inputURL: URL, override: String? = nil, counter: Int? = nil, preset: ExportPreset,
        settings: FileNamePreferences = FileNameSettings().snapshot,
        context: FileNameTemplateContext? = nil, date: Date = Date()
    ) -> (baseName: String, suffix: String) {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return (processFileName((override as NSString).deletingPathExtension, settings: settings), "")
        }
        let context = context ?? FileNameTemplateContext(preset: preset)
        let sourceName = processFileName(inputURL.deletingPathExtension().lastPathComponent, settings: settings)
        let templated = applyCustomTemplate(sourceName: sourceName, counter: counter, settings: settings, context: context, date: date)
        let suffix = settings.includePresetSuffix && !settings.customTemplateUsesPresetSuffix ? context.presetSuffix : ""
        return (templated, suffix)
    }

    /// Applies the user's custom filename template to a sanitized source name.
    /// - Parameters:
    ///   - sourceName: The already-sanitized base name (output of `processFileName`).
    ///   - counter: Counter value baked at queue-add time. If nil, `{counter}` resolves to "1".
    ///   - preset: Active export preset, used to resolve `{presetSuffix}`, `{resolution}`, `{framerate}`.
    ///     Pass nil to substitute those variables with empty strings.
    /// - Returns: The templated name, re-sanitized through the active filename rules.
    static func applyCustomTemplate(
        sourceName: String, counter: Int? = nil, preset: ExportPreset? = nil,
        settings: FileNamePreferences = FileNameSettings().snapshot,
        context: FileNameTemplateContext? = nil, date: Date = Date()
    ) -> String {
        guard settings.customTemplateEnabled, !settings.template.isEmpty else { return sourceName }
        let template = settings.template
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = settings.dateFormat
        let dateString = formatter.string(from: date)

        // Preserve the full Swift integer instead of truncating it through C's %d.
        let value = counter ?? 1
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        let padding = min(6, max(1, settings.counterPadding))
        let counterString = sign + String(repeating: "0", count: max(0, padding - sign.count - digits.count)) + digits
        let context = context ?? FileNameTemplateContext(preset: preset)
        let presetSuffix = context.presetSuffix
        let resolution = context.resolution
        let framerate = context.framerate

        let substituted = template
            .replacingOccurrences(of: "{sourceName}", with: sourceName)
            .replacingOccurrences(of: "{date}", with: dateString)
            .replacingOccurrences(of: "{counter}", with: counterString)
            .replacingOccurrences(of: "{presetSuffix}", with: presetSuffix)
            .replacingOccurrences(of: "{resolution}", with: resolution)
            .replacingOccurrences(of: "{framerate}", with: framerate)

        return processFileName(substituted, settings: settings)
    }
}
