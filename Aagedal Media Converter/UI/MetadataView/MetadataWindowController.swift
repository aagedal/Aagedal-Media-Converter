// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Manages the standalone metadata window for displaying video file metadata.
/// Follows the same singleton pattern as FullscreenPlayerWindowController.
@MainActor
final class MetadataWindowController: NSObject, NSWindowDelegate {

    static let shared = MetadataWindowController()
    private static let frameAutosaveName = "MetadataWindow"

    private var currentWindow: NSWindow?
    private var hostingView: NSHostingView<MetadataWindowContent>?

    private override init() {
        super.init()
    }

    /// Shows the metadata window, creating it if necessary.
    /// Positions the window to the right of the main window.
    func showWindow() {
        if let existingWindow = currentWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            MetadataWindowState.shared.isWindowVisible = true
            return
        }

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Metadata"
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Create the SwiftUI content view
        let contentView = MetadataWindowContent()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        // Restore the user's last frame; otherwise place it next to the main window.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            positionWindowNextToMainWindow(window)
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // Store references
        self.currentWindow = window
        self.hostingView = hostingView

        // Show the window
        window.makeKeyAndOrderFront(nil)
        MetadataWindowState.shared.isWindowVisible = true
    }

    /// Closes the metadata window.
    func closeWindow() {
        currentWindow?.close()
        currentWindow = nil
        hostingView = nil
        MetadataWindowState.shared.isWindowVisible = false
    }

    /// Returns true if the metadata window is currently open.
    var isWindowOpen: Bool {
        currentWindow != nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        currentWindow = nil
        hostingView = nil
        MetadataWindowState.shared.isWindowVisible = false
    }

    // MARK: - Window Positioning

    private func positionWindowNextToMainWindow(_ window: NSWindow) {
        // Find the main window
        guard let mainWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            window.center()
            return
        }

        let mainFrame = mainWindow.frame
        let windowSize = window.frame.size

        // Position to the right of the main window
        var newOrigin = NSPoint(
            x: mainFrame.maxX + 20,
            y: mainFrame.maxY - windowSize.height
        )

        // Check if the window would be off-screen on the right
        if let screen = mainWindow.screen {
            let screenFrame = screen.visibleFrame

            // If it would go off the right edge, try to position it to the left
            if newOrigin.x + windowSize.width > screenFrame.maxX {
                newOrigin.x = mainFrame.minX - windowSize.width - 20
            }

            // If it would go off the left edge, center it
            if newOrigin.x < screenFrame.minX {
                newOrigin.x = screenFrame.midX - windowSize.width / 2
            }

            // Ensure vertical position is within screen bounds
            if newOrigin.y < screenFrame.minY {
                newOrigin.y = screenFrame.minY
            }
            if newOrigin.y + windowSize.height > screenFrame.maxY {
                newOrigin.y = screenFrame.maxY - windowSize.height
            }
        }

        window.setFrameOrigin(newOrigin)
    }
}
