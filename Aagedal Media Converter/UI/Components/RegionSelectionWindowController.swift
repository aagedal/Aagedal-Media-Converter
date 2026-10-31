// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
final class RegionSelectionWindowController: NSObject, NSWindowDelegate {

    static let shared = RegionSelectionWindowController()

    private var overlayPanel: NSPanel?
    private var hostingView: NSHostingView<RegionSelectionOverlayView>?
    private var onRegionConfirmed: ((CGRect?) -> Void)?

    // The display the overlay was laid out for. If it disappears or changes size while the
    // overlay is open, the selection coordinates no longer match the screen, so we cancel.
    private var overlayDisplayID: CGDirectDisplayID?
    private var overlayScreenFrame: CGRect = .zero

    private override init() {
        super.init()
    }

    var isShowing: Bool {
        overlayPanel != nil
    }

    func showOverlay(on screen: NSScreen, initialRegion: CGRect?, onConfirmed: @escaping (CGRect?) -> Void) {
        // Dismiss any existing overlay first
        if overlayPanel != nil {
            dismissOverlay(confirmed: false)
        }

        self.onRegionConfirmed = onConfirmed

        let screenFrame = screen.frame
        let scaleFactor = screen.backingScaleFactor

        // CaptureRegionPanel overrides canBecomeKey: a plain borderless NSPanel can never become
        // key, so Escape / Return / Shift / Option / Space would go to the previously active app.
        let panel = CaptureRegionPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Sit above other apps. If a system dialog (e.g. TCC permission prompt) is hidden behind
        // the overlay, the user can press Escape to dismiss and try again.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        let overlayView = RegionSelectionOverlayView(
            screenSize: screenFrame.size,
            displayScaleFactor: scaleFactor,
            initialRegion: initialRegion,
            onConfirmed: { [weak self] rect in
                self?.dismissOverlay(confirmed: true, rect: rect)
            }
        )

        let hosting = FirstMouseHostingView(rootView: overlayView)
        hosting.frame = CGRect(origin: .zero, size: screenFrame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(screenFrame, display: true)

        self.overlayPanel = panel
        self.hostingView = hosting
        self.overlayDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        self.overlayScreenFrame = screenFrame

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Hide the app so the user can see the full screen underneath
        NSApp.hide(nil)

        // Small delay to let the hide animation complete before showing the overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Skip if this panel was dismissed or replaced during the delay — otherwise a closed,
            // untracked overlay would be ordered back on screen and cover the display.
            guard let self, self.overlayPanel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func dismissOverlay(confirmed: Bool, rect: CGRect? = nil) {
        let callback = onRegionConfirmed
        onRegionConfirmed = nil

        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        overlayPanel?.close()
        overlayPanel = nil
        hostingView = nil

        // Unhide the app
        NSApp.unhide(nil)

        if confirmed {
            callback?(rect)
        } else {
            callback?(nil)
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard overlayPanel != nil else { return }
        let screenStillMatches = NSScreen.screens.contains { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == overlayDisplayID
                && screen.frame == overlayScreenFrame
        }
        if !screenStillMatches {
            dismissOverlay(confirmed: false)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        overlayPanel = nil
        hostingView = nil
        let callback = onRegionConfirmed
        onRegionConfirmed = nil
        callback?(nil)
    }
}
