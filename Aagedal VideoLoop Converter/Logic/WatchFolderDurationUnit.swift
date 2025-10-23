// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Represents the unit used for watch folder age thresholds
enum WatchFolderDurationUnit: String, CaseIterable, Identifiable, Sendable {
    case minutes
    case hours
    case days
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        case .days: return "Days"
        }
    }
    
    var secondsMultiplier: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 3600
        case .days: return 86_400
        }
    }
}
