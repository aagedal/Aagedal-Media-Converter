// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Security-scoped resource access for conversion inputs and output folders.

import Foundation

extension ConversionManager {
    // MARK: - Security-Scoped Resource Management

    /// Ensures an input file is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the file is accessible, false otherwise
    func ensureInputFileAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let success = withSecurityScopedAccessFallback(at: url) {
            fileManager.isReadableFile(atPath: url.path)
        }
        if !success {
            logger.error("Failed to access input file with any access method: \(url.path, privacy: .public)")
        }
        return success
    }

    /// Ensures a directory exists and is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the directory was created/accessible, false otherwise
    func ensureDirectoryAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let success = withSecurityScopedAccessFallback(at: url) {
            (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        }
        if !success {
            logger.error("Failed to create directory with any access method: \(url.path, privacy: .public)")
        }
        return success
    }

    /// Runs `attempt` while escalating through security-scoped access fallbacks:
    /// direct → bookmark(url) → bookmark(parent) → startAccess(url) → startAccess(parent).
    /// On success, any acquired access is retained in `activeSecurityScopedURLs` for
    /// later balanced release via `releaseAllSecurityScopedAccess()`. On failure at
    /// a given step, that step's access is stopped before trying the next.
    private func withSecurityScopedAccessFallback(at url: URL, attempt: () -> Bool) -> Bool {
        // First try: no access acquisition — works if we already have permission.
        if attempt() { return true }

        // Helper: given a URL on which startAccessingSecurityScopedResource() has
        // already returned true, track it and run `attempt`. Releases on failure.
        func runAttemptAndTrack(_ acquiredURL: URL) -> Bool {
            activeSecurityScopedURLs.insert(acquiredURL)
            if attempt() { return true }
            acquiredURL.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(acquiredURL)
            return false
        }

        let parentURL = url.deletingLastPathComponent()

        // Second try: bookmark for this exact URL.
        if let resolvedURL = SecurityScopedBookmarkManager.shared.resolveBookmark(for: url),
           resolvedURL.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(resolvedURL) {
            return true
        }

        // Third try: bookmark for parent directory.
        if let resolvedParent = SecurityScopedBookmarkManager.shared.resolveBookmark(for: parentURL),
           resolvedParent.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(resolvedParent) {
            return true
        }

        // Fourth try: direct access on the URL (e.g. granted via NSOpenPanel).
        if url.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(url) {
            return true
        }

        // Fifth try: direct access on parent URL.
        if parentURL.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(parentURL) {
            return true
        }

        return false
    }

    /// Releases all security-scoped resource access acquired during conversion
    func releaseAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }
}
