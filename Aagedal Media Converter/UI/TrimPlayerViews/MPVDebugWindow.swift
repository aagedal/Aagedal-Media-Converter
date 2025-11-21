// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import OSLog

class MPVDebugWindowController: NSWindowController {
    private let player: MPVPlayer
    private let url: URL
    
    init(url: URL) {
        self.url = url
        self.player = MPVPlayer()
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MPV Debug: \(url.lastPathComponent)"
        window.center()
        
        super.init(window: window)
        window.delegate = self
        
        setupContent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupContent() {
        guard let window = window else { return }
        
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        
        let mpvView = MPVOpenGLView(frame: container.bounds)
        mpvView.autoresizingMask = [.width, .height]
        mpvView.player = player
        
        container.addSubview(mpvView)
        window.contentView = container
        
        // Start playback
        player.load(url: url)
        player.play()
    }
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    
    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.destroy()
    }
}

extension MPVDebugWindowController: NSWindowDelegate {}
