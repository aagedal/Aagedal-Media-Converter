// Aagedal VideoLoop Converter 2.0
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
    
    // Supported video file extensions (lowercase)
    static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "flv", "wmv", "mxf"]
    
    // Supported UTType identifiers for file picker
    static let supportedVideoTypes: [String] = [
        "public.movie",
        "public.video",
        "public.mpeg-4",
        "com.apple.quicktime-movie",
        "com.apple.m4v-video",
        "public.avi",
        "com.apple.m4v-video",
        "public.mpeg-4-audio"
    ]
    
    // Maximum thumbnail dimensions
    static let maxThumbnailSize = CGSize(width: 320, height: 320)
    static let includeDateTagPreferenceKey = "includeDateTagByDefault"
    static let preserveMetadataPreferenceKey = "preserveMetadataByDefault"
    static let customPresetCommandKey = "customPresetFFmpegCommand"
    static let customPresetSuffixKey = "customPresetFileSuffix"
    static let customPresetExtensionKey = "customPresetFileExtension"
    static let defaultPresetKey = "defaultExportPreset"
    static let watchFolderModeKey = "watchFolderModeEnabled"
    static let watchFolderPathKey = "watchFolderPath"
    static let watchFolderIgnoreOlderThan24hKey = "watchFolderIgnoreOlderThan24h"
    static let watchFolderAutoDeleteOlderThanWeekKey = "watchFolderAutoDeleteOlderThanWeek"
}
