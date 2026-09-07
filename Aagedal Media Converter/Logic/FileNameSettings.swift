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
