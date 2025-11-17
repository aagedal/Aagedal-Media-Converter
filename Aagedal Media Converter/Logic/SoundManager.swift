// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Lightweight helper for playing short UI feedback sounds (success + error).
@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private let successSound: NSSound?
    private let errorSound: NSSound?

    private init() {
        successSound = SoundManager.loadSound(named: "done", fileExtension: "mp3")
        errorSound = SoundManager.loadSound(named: "error", fileExtension: "mp3")
    }

    func playSuccess() {
        successSound?.stop()
        successSound?.play()
    }

    func playError() {
        errorSound?.stop()
        errorSound?.play()
    }

    private static func loadSound(named name: String, fileExtension: String) -> NSSound? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: name, withExtension: fileExtension)
            ?? bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Sounds")

        guard let resolvedURL = url else {
            NSLog("[SoundManager] Missing sound resource: \(name).\(fileExtension)")
            return nil
        }

        return NSSound(contentsOf: resolvedURL, byReference: true)
    }
}
