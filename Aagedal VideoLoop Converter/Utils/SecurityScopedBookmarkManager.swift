// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

final class SecurityScopedBookmarkManager: @unchecked Sendable {
    static let shared = SecurityScopedBookmarkManager()
    private let userDefaults = UserDefaults.standard
    private let bookmarksKey = "securityScopedBookmarks"
    
    private init() {}
    
    func saveBookmark(for url: URL) -> Bool {
        do {
            // Only save bookmarks for files that are not already accessible
            guard !url.startAccessingSecurityScopedResource() else {
                url.stopAccessingSecurityScopedResource()
                return true
            }
            
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            var bookmarks = userDefaults.dictionary(forKey: bookmarksKey) ?? [String: Data]()
            bookmarks[url.absoluteString] = bookmarkData
            userDefaults.set(bookmarks, forKey: bookmarksKey)
            return true
        } catch {
            print("Failed to create bookmark: \(error)")
            return false
        }
    }
    
    func resolveBookmark(for url: URL) -> URL? {
        // First try to access directly
        if url.startAccessingSecurityScopedResource() {
            return url
        }
        
        // If direct access fails, try to resolve from saved bookmarks
        guard let bookmarks = userDefaults.dictionary(forKey: bookmarksKey) as? [String: Data],
              let bookmarkData = bookmarks[url.absoluteString] else {
            return nil
        }
        
        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                // Update the bookmark if it's stale
                _ = saveBookmark(for: resolvedURL)
            }
            
            return resolvedURL
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
    
    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        if let resolvedURL = resolveBookmark(for: url) {
            return resolvedURL.startAccessingSecurityScopedResource()
        }
        return false
    }
    
    func stopAccessingSecurityScopedResource(for url: URL) {
        _ = resolveBookmark(for: url)?.stopAccessingSecurityScopedResource()
    }
}
