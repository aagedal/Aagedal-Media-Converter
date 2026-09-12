// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import OSLog

/// Validates folder access before committing a watch-folder preference or starting a monitor.
@MainActor
struct WatchFolderSelectionService {
    /// Written only after a user selection successfully saves a writable grant.
    nonisolated static let writableGrantPathKey = "watchFolderWritableGrantPath"

    nonisolated static func cleanupAccessNeedsRenewal(for path: String, defaults: UserDefaults = .standard) -> Bool {
        !path.isEmpty && defaults.string(forKey: writableGrantPathKey) != path
    }

    enum FolderError: LocalizedError {
        case unavailable(String)
        case notDirectory
        case bookmark
        case finderRejected

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return String(localized: "The watch folder is unavailable. Reconnect its drive or select the folder again in Settings. Your saved watch folder is unchanged. \(detail)")
            case .notDirectory:
                return String(localized: "The watch location is not a folder. Select another watch folder in Settings.")
            case .bookmark:
                return String(localized: "Access to the selected watch folder could not be saved. Select the folder again or choose another location. Your previous watch folder is unchanged.")
            case .finderRejected:
                return String(localized: "Finder could not open the watch folder. Try again or open the folder manually.")
            }
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bookmarks: SecurityScopedBookmarkManager
    private let openInFinder: (URL) -> Bool
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WatchFolderSelection")

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bookmarkManager: SecurityScopedBookmarkManager = .shared,
        openInFinder: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        bookmarks = bookmarkManager
        self.openInFinder = openInFinder
    }

    func select(_ url: URL) throws {
        let access = bookmarks.startAccessing(url: url)
        defer { bookmarks.stopAccessing(access) }
        try inspectDirectory(url)
        // Watch-folder cleanup moves old files to Trash, including when enabled
        // after selection. Retain the user-selected folder's write grant for it.
        guard bookmarks.saveWritableBookmark(for: url) else {
            logger.error("Could not persist watch folder access at \(url.path)")
            throw FolderError.bookmark
        }
        defaults.set(url.path, forKey: Self.writableGrantPathKey)
        defaults.set(url.path, forKey: AppConstants.watchFolderPathKey)
    }

    func validate(_ url: URL) throws {
        let access = bookmarks.startAccessing(url: url)
        defer { bookmarks.stopAccessing(access) }
        try inspectDirectory(url)
    }

    func reveal(_ url: URL) throws {
        let access = bookmarks.startAccessing(url: url)
        defer { bookmarks.stopAccessing(access) }
        try inspectDirectory(url)
        guard openInFinder(url) else {
            logger.error("Finder could not open watch folder at \(url.path)")
            throw FolderError.finderRejected
        }
    }

    private func inspectDirectory(_ url: URL) throws {
        do {
            let directory = url.resolvingSymlinksInPath()
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw FolderError.notDirectory
            }
            // Metadata access alone does not establish that the monitor can list files.
            // Foundation's directory enumeration rejects an unresolved directory
            // symlink. Inspect its target while retaining the selected URL's scope,
            // bookmark key, saved path, and Finder destination.
            _ = try WatchFolderDirectoryContents.list(in: url, fileManager: fileManager)
        } catch let error as FolderError {
            throw error
        } catch {
            logger.error("Could not read watch folder at \(url.path): \(error.localizedDescription)")
            throw FolderError.unavailable(error.localizedDescription)
        }
    }
}
