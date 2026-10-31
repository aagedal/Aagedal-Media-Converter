// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// Expands folders that are dropped on the queue or chosen in the import panel.
enum FolderImportScanner {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FolderImportScanner")

    struct Expansion: Sendable {
        /// Dropped files plus the supported media found inside dropped folders,
        /// in import order.
        var fileURLs: [URL] = []
        /// Folders (the dropped folder or any subfolder) holding still images
        /// that may form image sequences.
        var imageSequenceFolders: [URL] = []
    }

    /// Whether `url` is a folder to look inside. Packages such as apps, Photos
    /// libraries or project bundles are treated as files, so they're skipped
    /// rather than scanned.
    static func isImportableFolder(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// Replaces each folder in `urls` with the supported media files inside it,
    /// searching subfolders and skipping hidden files and packages. Files are
    /// passed through unchanged. Walks the file system, so call it off the main actor.
    static func expand(_ urls: [URL]) -> Expansion {
        let mediaExtensions = AppConstants.supportedVideoExtensions
        let imageExtensions = AppConstants.supportedImageSequenceExtensions
        var expansion = Expansion()

        for url in urls {
            guard isImportableFolder(url) else {
                expansion.fileURLs.append(url)
                continue
            }

            let hadAccess = url.startAccessingSecurityScopedResource()
            defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                logger.warning("Failed to create directory enumerator for \(url.path, privacy: .public)")
                continue
            }

            var mediaURLs: [URL] = []
            var sequenceFolders: Set<URL> = []
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard !ext.isEmpty,
                      mediaExtensions.contains(ext) || imageExtensions.contains(ext),
                      (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if mediaExtensions.contains(ext) {
                    mediaURLs.append(fileURL)
                } else {
                    sequenceFolders.insert(fileURL.deletingLastPathComponent().standardizedFileURL)
                }
            }

            expansion.fileURLs += CameraCardScanner.sortedForImport(mediaURLs)
            expansion.imageSequenceFolders += sequenceFolders.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            logger.info("Found \(mediaURLs.count) media file(s) and \(sequenceFolders.count) image folder(s) in \(url.lastPathComponent, privacy: .public)")
        }
        return expansion
    }

    /// `expand(_:)` off the main actor, plus the image sequences in the folders
    /// it found. Audio that a sequence uses as its soundtrack is left out of
    /// `fileURLs` so it isn't also queued on its own.
    static func expandWithImageSequences(_ urls: [URL]) async -> (fileURLs: [URL], sequences: [ImageSequenceConfig]) {
        let expansion = await Task.detached(priority: .userInitiated) { expand(urls) }.value
        var sequences: [ImageSequenceConfig] = []
        for folder in expansion.imageSequenceFolders {
            guard !Task.isCancelled else { break }
            sequences += await ImageSequenceDetector.detectSequences(inFolder: folder, securityScopedAccessURL: folder)
        }
        let soundtracks = Set(sequences.compactMap { $0.associatedAudioURL?.standardizedFileURL })
        let fileURLs = expansion.fileURLs.filter { !soundtracks.contains($0.standardizedFileURL) }
        return (fileURLs, sequences)
    }
}
