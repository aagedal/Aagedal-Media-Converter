// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Comment formatting captured once before conversion preparation suspends.
struct CommentSettings: Sendable {
    let prefix: String
    let suffix: String
    let separator: String
    let dateFormat: String
    let dateTagPrefix: String

    init(defaults: UserDefaults = .standard) {
        prefix = defaults.string(forKey: AppConstants.commentPrefixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        suffix = defaults.string(forKey: AppConstants.commentSuffixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        separator = defaults.string(forKey: AppConstants.commentSeparatorKey) ?? AppConstants.defaultCommentSeparator
        dateFormat = defaults.string(forKey: AppConstants.commentDateFormatKey) ?? AppConstants.defaultCommentDateFormat
        let savedPrefix = defaults.string(forKey: AppConstants.dateTagPrefixKey) ?? AppConstants.defaultDateTagPrefix
        dateTagPrefix = savedPrefix.isEmpty ? AppConstants.defaultDateTagPrefix : savedPrefix
    }
}
