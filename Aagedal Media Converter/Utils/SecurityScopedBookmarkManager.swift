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

/// Tracks which security-scoped access method succeeded for correct cleanup.
enum SecurityScopedAccess {
    case none
    case direct(URL)
    case bookmark(URL)
}

final class SecurityScopedBookmarkManager: @unchecked Sendable {
    static let shared = SecurityScopedBookmarkManager()
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "BookmarkManager")
    private let userDefaults: UserDefaults
    private let bookmarksKey = "securityScopedBookmarks"
    private let readOnlyKey = "securityScopedBookmarksReadOnly"
    private let lock = NSRecursiveLock()
    private var activeBookmarks: [URL: (url: URL, count: Int)] = [:]
    private let createBookmark: (URL, URL.BookmarkCreationOptions) throws -> Data
    private let resolveData: (Data) throws -> (url: URL, isStale: Bool)
    private let startScope: (URL) -> Bool
    private let stopScope: (URL) -> Void

    init(
        defaults: UserDefaults = .standard,
        createBookmark: @escaping (URL, URL.BookmarkCreationOptions) throws -> Data = {
            try $0.bookmarkData(options: $1, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolveData: @escaping (Data) throws -> (url: URL, isStale: Bool) = {
            var stale = false
            let url = try URL(resolvingBookmarkData: $0, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        startScope: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopScope: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        userDefaults = defaults
        self.createBookmark = createBookmark
        self.resolveData = resolveData
        self.startScope = startScope
        self.stopScope = stopScope
    }

    func saveBookmark(for url: URL) -> Bool {
        saveBookmark(for: url, storageURL: url, readOnly: true)
    }

    /// Saves a security-scoped bookmark that allows both read and write access.
    func saveWritableBookmark(for url: URL) -> Bool {
        saveBookmark(for: url, storageURL: url, readOnly: false)
    }

    private func saveBookmark(for url: URL, storageURL: URL, readOnly: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let accessed = startScope(url)
        defer { if accessed { stopScope(url) } }
        do {
            var modes = userDefaults.dictionary(forKey: readOnlyKey) ?? [:]
            var bookmarks = userDefaults.dictionary(forKey: bookmarksKey) ?? [:]
            // A later import must not downgrade a folder already saved for output.
            // Legacy records have unknown permissions; preserve their scope too.
            let savedReadOnly = modes[storageURL.absoluteString] as? Bool
            let existingMayBeWritable = bookmarks[storageURL.absoluteString] != nil && savedReadOnly != true
            let effectiveReadOnly = readOnly && !existingMayBeWritable && savedReadOnly != false
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if effectiveReadOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
            let data = try createBookmark(url, options)
            bookmarks[storageURL.absoluteString] = data
            modes[storageURL.absoluteString] = effectiveReadOnly
            userDefaults.set(bookmarks, forKey: bookmarksKey)
            userDefaults.set(modes, forKey: readOnlyKey)
            return true
        } catch {
            logger.error("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func resolveBookmark(for url: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let bookmarks = userDefaults.dictionary(forKey: bookmarksKey) as? [String: Data],
              let data = bookmarks[url.absoluteString] else { return nil }
        do {
            let resolved = try resolveData(data)
            if resolved.isStale {
                // Legacy data did not record permissions. Do not add a read-only
                // restriction when renewing it; the resolved scope limits access.
                let readOnly = userDefaults.dictionary(forKey: readOnlyKey)?[url.absoluteString] as? Bool ?? false
                _ = saveBookmark(for: resolved.url, storageURL: url, readOnly: readOnly)
            }
            return resolved.url
        } catch {
            logger.error("Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Reuse the same resolved scope until its last borrower releases it.
        // Resolving again after a move or renewal could stop a different URL.
        if var active = activeBookmarks[url] {
            active.count += 1
            activeBookmarks[url] = active
            return true
        }
        guard let resolved = resolveBookmark(for: url), startScope(resolved) else { return false }
        activeBookmarks[url] = (resolved, 1)
        return true
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeBookmarks[url] else { return }
        active.count -= 1
        if active.count == 0 {
            activeBookmarks.removeValue(forKey: url)
            stopScope(active.url)
        } else {
            activeBookmarks[url] = active
        }
    }

    /// Try direct access first, then bookmark. Returns which method succeeded.
    func startAccessing(url: URL) -> SecurityScopedAccess {
        if startScope(url) { return .direct(url) }
        if startAccessingSecurityScopedResource(for: url) { return .bookmark(url) }
        return .none
    }

    /// Release access acquired via startAccessing(url:).
    func stopAccessing(_ access: SecurityScopedAccess) {
        switch access {
        case .direct(let url): stopScope(url)
        case .bookmark(let url): stopAccessingSecurityScopedResource(for: url)
        case .none: break
        }
    }
}
