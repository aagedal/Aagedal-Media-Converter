// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Right-edge zone that instantly hides the cursor and overlay when the mouse
// enters. Ported from Aagedal Media Player's CursorHideZone, which fixed several
// "cursor stuck hidden" bugs by keeping NSCursor.hide/unhide strictly balanced.

import AppKit
import SwiftUI

struct FullscreenCursorHideZone: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> FullscreenCursorHideNSView {
        let view = FullscreenCursorHideNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: FullscreenCursorHideNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class FullscreenCursorHideNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    /// NSCursor.hide() is reference counted; this keeps at most one outstanding hide.
    private static var isCursorHiddenByUs = false

    /// Force the cursor visible if we hid it. Safe to call at any time.
    static func ensureCursorVisible() {
        if isCursorHiddenByUs {
            NSCursor.unhide()
            isCursorHiddenByUs = false
        }
    }

    // Let clicks pass through while the tracking area stays active.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        if !Self.isCursorHiddenByUs {
            NSCursor.hide()
            Self.isCursorHiddenByUs = true
        }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        endHover(notify: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        updateTrackingAreas()
        for name in [NSWindow.willEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowWillTransition), name: name, object: window)
        }
    }

    @objc private func windowWillTransition(_ notification: Notification) {
        endHover(notify: true)
    }

    override func removeFromSuperview() {
        endHover(notify: false)
        NotificationCenter.default.removeObserver(self)
        super.removeFromSuperview()
    }

    private func endHover(notify: Bool) {
        guard isHovering else { return }
        isHovering = false
        Self.ensureCursorVisible()
        if notify { onHoverChanged?(false) }
    }

    deinit {
        // Replacing the window's content view (queue navigation) deallocates this view
        // without removeFromSuperview, so restore the cursor here too.
        if isHovering {
            if Thread.isMainThread {
                MainActor.assumeIsolated { Self.ensureCursorVisible() }
            } else {
                DispatchQueue.main.async { FullscreenCursorHideNSView.ensureCursorVisible() }
            }
        }
        NotificationCenter.default.removeObserver(self)
    }
}
