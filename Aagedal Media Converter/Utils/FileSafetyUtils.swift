// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Utilities for safe file operations to prevent accidental data loss
enum FileSafetyUtils {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FileSafety")

    /// Thread-safe storage for created files
    private final class CreatedFilesStorage: @unchecked Sendable {
        private var files: Set<URL> = []
        private let lock = NSLock()

        func insert(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            files.insert(url)
        }

        func remove(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            files.remove(url)
        }

        func contains(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return files.contains(url)
        }
    }

    private static let createdFiles = CreatedFilesStorage()

    /// Register a file as created by the app (safe to delete later)
    static func registerCreatedFile(_ url: URL) {
        createdFiles.insert(url.standardizedFileURL)
        logger.debug("Registered created file: \(url.path)")
    }

    /// Unregister a file (e.g., after successful move/rename)
    static func unregisterCreatedFile(_ url: URL) {
        createdFiles.remove(url.standardizedFileURL)
    }

    /// Check if a file was created by the app
    static func isCreatedByApp(_ url: URL) -> Bool {
        createdFiles.contains(url.standardizedFileURL)
    }

    /// Safe delete - only deletes files we created, uses Trash
    static func safeTrash(_ url: URL) throws {
        let standardized = url.standardizedFileURL

        guard isCreatedByApp(standardized) else {
            logger.error("Refusing to delete file not created by app: \(url.path)")
            throw FileSafetyError.refusingToDeleteUnknownFile(url)
        }

        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        unregisterCreatedFile(url)
        logger.info("Trashed app-created file: \(url.path)")
    }

    /// For watch folder cleanup - always uses Trash (recoverable)
    static func trashWatchFolderItem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        logger.info("Trashed watch folder item: \(url.path)")
    }

    /// Generates a safe output URL that won't overwrite the input file
    /// - Parameters:
    ///   - inputURL: The source file URL
    ///   - outputFolder: The destination folder
    ///   - baseName: The base filename (without extension)
    ///   - suffix: Optional suffix to add (e.g., "_encoded")
    ///   - fileExtension: The output file extension
    /// - Returns: A safe output URL that won't conflict with the input
    static func safeOutputURL(
        inputURL: URL,
        outputFolder: URL,
        baseName: String,
        suffix: String,
        fileExtension: String
    ) -> URL {
        let inputStandardized = inputURL.standardizedFileURL

        let finalName = baseName + suffix
        var candidate = outputFolder.appendingPathComponent(finalName).appendingPathExtension(fileExtension)

        // Judge the complete rendered name: templates may already have changed it
        // even when no automatic suffix remains. Compare conservatively without case
        // because the default macOS filesystem treats differently cased names as equal.
        if candidate.standardizedFileURL.path.caseInsensitiveCompare(inputStandardized.path) == .orderedSame {
            let safeName = baseName + "_encoded" + suffix
            candidate = outputFolder.appendingPathComponent(safeName).appendingPathExtension(fileExtension)
            logger.warning("Added _encoded suffix to prevent overwriting source file")
        }

        return candidate
    }

    /// Generates a unique output path by adding numeric suffix if file exists
    /// - Parameters:
    ///   - url: The desired output URL
    ///   - inputURL: The original input URL (to prevent overwriting)
    /// - Returns: A unique URL that doesn't exist and isn't the input
    static func uniqueOutputURL(_ url: URL, notOverwriting inputURL: URL? = nil) -> URL {
        let standardizedInput = inputURL?.standardizedFileURL
        var candidate = url
        var counter = 1

        let fm = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()

        while fm.fileExists(atPath: candidate.path) || candidate.standardizedFileURL == standardizedInput {
            let newName = "\(baseName)_\(counter)"
            candidate = folder.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1

            // Safety limit to prevent infinite loop
            if counter > 1000 {
                logger.error("Could not find unique filename after 1000 attempts")
                break
            }
        }

        return candidate
    }
}

enum FileSafetyError: LocalizedError {
    case refusingToDeleteUnknownFile(URL)
    case wouldOverwriteSourceFile(URL)

    var errorDescription: String? {
        switch self {
        case .refusingToDeleteUnknownFile(let url):
            return "Refusing to delete file not created by app: \(url.path)"
        case .wouldOverwriteSourceFile(let url):
            return "Operation would overwrite source file: \(url.path)"
        }
    }
}
