// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import OSLog

/// Commits output preferences only after a usable, persistent folder grant is saved.
@MainActor
struct OutputFolderSelectionService {
    enum FolderError: LocalizedError {
        case preparation(String)
        case bookmark
        case unavailable(String)
        case notDirectory
        case finderRejected

        var errorDescription: String? {
            switch self {
            case .preparation(let detail):
                return String(localized: "The output folder could not be prepared. Choose a writable folder and try again. \(detail)")
            case .bookmark:
                return String(localized: "Access to the selected output folder could not be saved. Select the folder again or choose another location. Your previous output folder is unchanged.")
            case .unavailable(let detail):
                return String(localized: "The output folder is unavailable. Reconnect its drive or select the folder again. Your saved output location is unchanged. \(detail)")
            case .notDirectory:
                return String(localized: "The saved output location is not a folder. Choose another output folder in Settings.")
            case .finderRejected:
                return String(localized: "Finder could not open the output folder. Try again or open the folder manually.")
            }
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bookmarkManager: SecurityScopedBookmarkManager
    private let openInFinder: (URL) -> Bool
    private let logger = Logger(subsystem: "me.aagedal.MediaConverter", category: "OutputFolderSelection")

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bookmarkManager: SecurityScopedBookmarkManager = .shared,
        openInFinder: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.bookmarkManager = bookmarkManager
        self.openInFinder = openInFinder
    }

    func select(_ url: URL) throws {
        let access = bookmarkManager.startAccessing(url: url)
        defer { bookmarkManager.stopAccessing(access) }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not prepare output folder at \(url.path): \(error.localizedDescription)")
            throw FolderError.preparation(error.localizedDescription)
        }
        guard bookmarkManager.saveWritableBookmark(for: url) else {
            logger.error("Could not persist access to output folder at \(url.path)")
            throw FolderError.bookmark
        }
        defaults.set(url.path, forKey: "outputFolder")
    }

    func reveal(_ url: URL) throws {
        let access = bookmarkManager.startAccessing(url: url)
        defer { bookmarkManager.stopAccessing(access) }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        } catch {
            logger.error("Could not inspect output folder at \(url.path): \(error.localizedDescription)")
            throw FolderError.unavailable(error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw FolderError.notDirectory
        }
        guard openInFinder(url) else {
            logger.error("Finder could not open output folder at \(url.path)")
            throw FolderError.finderRejected
        }
    }
}
