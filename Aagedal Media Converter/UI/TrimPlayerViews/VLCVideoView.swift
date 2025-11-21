// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VLCKit

struct VLCVideoView: NSViewRepresentable {
    let player: VLCPlayer
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        
        // Assign the view to VLC
        player.mediaPlayer.drawable = view
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Ensure drawable is set if view updates (though usually constant)
        if player.mediaPlayer.drawable as? NSView != nsView {
            player.mediaPlayer.drawable = nsView
        }
    }
}
