// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

@MainActor
enum RandomTips {
    static let tips: [LocalizedStringKey] = [
        "Tip: Choose your default encoding preset in Settings > Presets.",
        "Tip: Press Tab or Shift + Tab to move between visible comment fields in the queue.",
        "Tip: Import files with ⌘I, and start converting with ⌘Enter.",
        "Tip: Use ⌘T to open the trim editor for the selected file.",
        "Tip: Hold Option while resizing the crop box to scale it from its center. Hold Shift to lock its aspect ratio.",
        "Tip: You can drag items to reorder them in the queue.",
        "Tip: Hold Option when clicking Reset to reverse the reset behavior chosen in General settings.",
        "Tip: Press ⌘F to play the selected video in fullscreen.",
        "Tip: Use ⌘↑ and ⌘↓ to move selected items up and down in the queue.",
        "Tip: Set up a Watch Folder in Settings to automatically import new files.",
        "Tip: Use Option + A to configure audio routing for the selected file.",
        "Tip: Press Control + D to toggle the date tag on the selected item.",
        "Tip: In either player, J starts reverse playback, K toggles playback, and L fast-forwards.",
        "Tip: In either player, ← and → step one frame; ↑ and ↓ jump ten frames.",
        "Tip: In either player, type a timecode and press Return to jump to that position.",
        "Tip: In either player, prefix a number with + or - to seek forward or backward in seconds, or in frames when the frame counter is active.",
        "Tip: In either player, press T to switch between relative timecode, source timecode, and the frame counter.",
        "Tip: In either player, press ⌘S to save a still image of the current frame.",
        "Tip: Press Control + M to toggle mute on the selected queue items.",
        "Tip: In the trim timeline, hold ⌘ and drag to set both in and out points in one gesture.",
        "Tip: In the trim timeline, hold Shift and drag between the trim points to move the entire trim range.",
        "Tip: In fullscreen, use ⌘N for the next video and ⌘B for the previous video in the queue.",
        "Tip: Move the pointer to the right edge of the fullscreen player to hide its overlay while away from the playback controls.",
        "Tip: Press Control + R to load a different tip here.",
        "Tip: In Audio Routing, Control + M toggles mute and ⌘1–8 toggles individual source tracks.",
        "Tip: In Crop mode, use ⌘1–9 to select an aspect ratio and ⌘0 to reset the crop.",
        "Tip: In Crop mode, ⌘arrow keys move the crop box; ⌘+ and ⌘- resize it.",
        "Tip: Press Control + K to see all keyboard shortcuts.",
        "Tip: Press ⌘P to open the preset selector.",
        "Tip: Press ⌘D to download a video from a URL.",
        "Tip: Use ⌘1–9 to select a visible preset; ⌘0 selects the tenth preset.",
        "Tip: In fullscreen, press A to toggle Auto Next and play through the queue automatically.",
        "Tip: With Auto Next enabled in fullscreen, press ⌘L to loop the entire queue.",
        "Tip: Use File > Import Camera Card… (⌘⇧I) to scan a memory card or folder for video clips.",
        "Tip: Camera card import can combine compatible clips into one file, or queue them separately.",
        "Tip: During camera card import, choose Review recording-date groups… to organize clips by recording date.",
        "Tip: Press ⌘N to create an encoding group with its own preset and clip settings.",
        "Tip: Use Option + I to inspect metadata. Select several files to compare their metadata.",
        "Tip: Press ⌘⇧C to open screen capture and record a screen, window, or selected region.",
        "Tip: If a website download fails, check for app-managed yt-dlp updates in Downloads settings, then retry."
    ]

    static func initialTip() -> LocalizedStringKey {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["AMC_UI_TEST_SESSION"] == "1",
           let rawIndex = environment["AMC_UI_TEST_TIP_INDEX"],
           let index = Int(rawIndex), tips.indices.contains(index) {
            return tips[index]
        }
#endif
        return randomTip()
    }

    static func randomTip(excluding currentTip: LocalizedStringKey? = nil) -> LocalizedStringKey {
        let candidates = tips.filter { $0 != currentTip }
        return candidates.randomElement() ?? tips[0]
    }
}
