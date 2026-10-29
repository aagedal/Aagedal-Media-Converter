// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Blackmagic's `com.blackmagicdesign.metadata:recording` extended attribute, which
/// DaVinci Resolve reads at import to treat a file as a growing (REC) clip. The screen
/// recorder sets it itself; yt-dlp-rs `--growing-file` sets and removes it, but a killed
/// process leaves it behind. Tagged paths are remembered so a crash or quit before the
/// recording ends can be cleaned up at the next launch. See docs/growing-file-research.
enum GrowingRecordingTag {
    static let attributeName = "com.blackmagicdesign.metadata:recording"

    /// Tags `path` as recording with a fresh UUID. Returns the `setxattr` errno on failure.
    @discardableResult
    static func set(at path: String) -> Int32? {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let bytes = Array("{\"r\":1, \"uuid\":\"\(uuid)\"}".utf8)
        let result = bytes.withUnsafeBytes { raw in
            setxattr(path, attributeName, raw.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { return errno }
        register(path)
        return nil
    }

    /// Removes the tag and forgets the path. Returns the `removexattr` errno when the
    /// attribute existed but could not be removed.
    @discardableResult
    static func clear(at path: String) -> Int32? {
        let result = removexattr(path, attributeName, 0)
        let failure = result != 0 && errno != ENOATTR && errno != ENOENT ? errno : nil
        unregister(path)
        return failure
    }

    static func isSet(at path: String) -> Bool {
        getxattr(path, attributeName, nil, 0, 0, 0) >= 0
    }

    /// Remembers a path tagged by another process (yt-dlp-rs).
    static func register(_ path: String) {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey) ?? []
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: AppConstants.pendingGrowingRecordingPathsKey)
    }

    static func unregister(_ path: String) {
        let defaults = UserDefaults.standard
        guard var paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey),
              paths.contains(path) else { return }
        paths.removeAll { $0 == path }
        if paths.isEmpty {
            defaults.removeObject(forKey: AppConstants.pendingGrowingRecordingPathsKey)
        } else {
            defaults.set(paths, forKey: AppConstants.pendingGrowingRecordingPathsKey)
        }
    }

    /// Strips the tag from every remembered file. Call once at launch, before any
    /// recording starts.
    static func sweepStale() {
        let defaults = UserDefaults.standard
        guard let paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey),
              !paths.isEmpty else { return }
        for path in paths {
            removexattr(path, attributeName, 0)
        }
        defaults.removeObject(forKey: AppConstants.pendingGrowingRecordingPathsKey)
    }
}
