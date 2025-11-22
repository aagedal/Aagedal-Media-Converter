// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VLCKit

struct VLCVideoView: NSViewRepresentable {
    let player: VLCPlayer
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        
        // Assign the view to the player's drawable property
        player.mediaPlayer.drawable = view
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed for the view itself
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }
    
    final class Coordinator: NSObject {
        private var monitor: Any?
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
        
        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
            super.init()
            
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return event }
                
                // VLC view may not have proper window focusing, so process all events
                // The handler will  decide if it should be handled
                let handled = self.keyHandler(characters, event.modifierFlags, event.specialKey)
                return handled ? nil : event
            }
        }
        
        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
