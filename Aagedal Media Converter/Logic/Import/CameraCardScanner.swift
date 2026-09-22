// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

enum CameraCardScanner {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "CameraCardScanner")

    /// Recursively scans a folder for video files, sorted by filename (natural sort).
    /// Camera cards typically store clips in nested subfolders with incrementing filenames.
    /// - Parameter folderURL: The root folder to scan (e.g., root of a camera card).
    /// - Returns: Array of video file URLs found, sorted naturally by filename.
    static func scanForVideoFiles(in folderURL: URL) -> [URL] {
        let supportedExtensions = AppConstants.supportedVideoExtensions

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Failed to create directory enumerator for \(folderURL.path, privacy: .public)")
            return []
        }

        var videoURLs: [URL] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard !ext.isEmpty, supportedExtensions.contains(ext) else { continue }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else { continue }
            } catch {
                continue
            }

            videoURLs.append(fileURL)
        }

        videoURLs = sortedForImport(videoURLs)

        logger.info("Found \(videoURLs.count) video file(s) in \(folderURL.lastPathComponent, privacy: .public)")
        return videoURLs
    }

    /// Repeated clip names are common when a card contains multiple camera
    /// folders. Directory enumeration order is unspecified, so use the path to
    /// break filename ties before presenting or importing the sequence. This is
    /// ordering only: adjacent names are not evidence of a spanned recording.
    static func sortedForImport(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let filenameOrder = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
            let pathOrder = lhs.path.localizedStandardCompare(rhs.path)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            // Natural comparison may consider distinct spellings equivalent
            // (for example case or leading zeroes). Preserve a total ordering.
            return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
    }
}
