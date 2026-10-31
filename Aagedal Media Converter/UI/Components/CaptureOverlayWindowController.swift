// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureOverlayWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {

    static let shared = CaptureOverlayWindowController()

    private var overlayPanel: NSPanel?
    private var controlPanel: NSPanel?
    private var controlHostingView: NSHostingView<CaptureControlPanelView>?
    private var processingObserver: AnyCancellable?
    private var escapeKeyLocalMonitor: Any?
    private var escapeKeyGlobalMonitor: Any?
    private var modifierKeyLocalMonitor: Any?
    private var modifierKeyGlobalMonitor: Any?

    // Menu bar status item (shown during recording) whose dropdown holds the recording controls.
    private var showPanelStatusItem: NSStatusItem?
    private var statusMenuUpdateTimer: Timer?

    // Dynamic items in the status dropdown. The menu structure is built once; the per-second
    // timer only mutates these items' titles / visibility so an open menu (and its submenu)
    // is never torn down underneath the user. Weak: the menu owns them.
    private weak var statusTogglePreviewItem: NSMenuItem?
    private weak var statusRecordedItem: NSMenuItem?
    private weak var statusStopsInItem: NSMenuItem?
    private weak var statusStopsAtItem: NSMenuItem?
    private weak var statusCancelAutoStopItem: NSMenuItem?
    private weak var statusCancelAutoStopSeparator: NSMenuItem?

    private(set) var isShowing = false

    // Click-through state — when either is true, the region overlay passes mouse events through.
    // The control panel passes events through only while CMD is held, so the toggle button stays usable.
    private var isCmdHeld = false
    private(set) var isRegionOverlayClickThrough = false

    // Base window levels — high enough to sit above other apps. Users can hold CMD or use the
    // toggle button on the control panel to click through to anything underneath (e.g. a TCC dialog).
    private let regionOverlayLevel: NSWindow.Level = .popUpMenu
    private var controlPanelLevelWhenRegionShown: NSWindow.Level {
        .init(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    }
    private let controlPanelLevelWhenAlone: NSWindow.Level = .popUpMenu

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func showCaptureOverlay(on screen: NSScreen? = nil) {
        guard !isShowing else { return }

        // Check screen recording permission before hiding the app.
        if !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() {
                // Permission was already denied previously — CGRequestScreenCaptureAccess()
                // won't show the dialog again, so open System Settings directly.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        isShowing = true

        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            isShowing = false // no active displays — abort the overlay
            return
        }

        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isShowing else { return }
            self.createOverlayPanel(on: targetScreen)
            self.createControlPanel(on: targetScreen)
            self.setupRecordingObservers()
            self.installEscapeKeyMonitor()
            self.installModifierKeyMonitor()
        }
    }

    func dismissCaptureOverlay() {
        guard isShowing else { return }
        isShowing = false

        processingObserver = nil
        removeEscapeKeyMonitor()
        removeModifierKeyMonitor()
        isRegionOverlayClickThrough = false

        let captureManager = ScreenCaptureManager.shared
        Task {
            await captureManager.stopPreview()
        }

        overlayPanel?.close()
        overlayPanel = nil

        controlPanel?.close()
        controlPanel = nil
        controlHostingView = nil
        hideStatusItems()

        // Record mode closed without recording (cancel/Escape). Under the default ephemeral policy,
        // tear down any virtual displays that were spun up for this session. Safe here: this path is
        // unreachable while recording or processing (see the Escape monitor's guard).
        VirtualDisplayManager.shared.destroyAllIfEphemeral()

        NSApp.unhide(nil)
    }

    func hideControlPanel() {
        controlPanel?.orderOut(nil)
        showStatusItems()
    }

    func showControlPanel() {
        controlPanel?.makeKeyAndOrderFront(nil)
        hideStatusItems()
    }

    /// Resizes the floating control panel to match the SwiftUI content's current fitting size
    /// (driven by the user's overlay scale), anchored at the bottom-center so it grows upward and
    /// outward without drifting.
    func resizeControlPanelToFit() {
        guard let panel = controlPanel, let hosting = controlHostingView else { return }
        // Let the hosting view recompute its layout before measuring.
        hosting.layoutSubtreeIfNeeded()
        let newSize = hosting.fittingSize
        guard newSize.width > 0, newSize.height > 0 else { return }
        let oldFrame = panel.frame
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.minY
        )
        var newFrame = NSRect(origin: newOrigin, size: newSize)
        // Keep the panel on screen: at high scale the upward growth can otherwise push the
        // top (resize handle) under the menu bar, or the width can spill past the edges.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if newFrame.maxY > visible.maxY { newFrame.origin.y = visible.maxY - newFrame.height }
            if newFrame.minY < visible.minY { newFrame.origin.y = visible.minY }
            if newFrame.maxX > visible.maxX { newFrame.origin.x = visible.maxX - newFrame.width }
            if newFrame.minX < visible.minX { newFrame.origin.x = visible.minX }
        }
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Recording Lifecycle

    func startRecording() {
        // Dismiss overlay (region selection) so actual screen content is visible
        overlayPanel?.close()
        overlayPanel = nil
        // Show menu bar items so user can stop or re-show panel even if hidden
        showStatusItems()
    }

    func stopRecordingAndShowDialog() {
        Task {
            let captureManager = ScreenCaptureManager.shared
            await captureManager.stopRecording()
        }
    }

    func handleRecordingStopped() {
        let urls = ScreenCaptureManager.shared.lastOutputURLs

        // Dismiss control panel and status items
        controlPanel?.close()
        controlPanel = nil
        controlHostingView = nil
        overlayPanel?.close()
        overlayPanel = nil
        hideStatusItems()
        removeEscapeKeyMonitor()
        removeModifierKeyMonitor()
        isRegionOverlayClickThrough = false

        processingObserver = nil
        isShowing = false

        // Recording and processing have finished, so record mode is closing. Under the default
        // ephemeral policy, tear down any virtual displays used for this session.
        VirtualDisplayManager.shared.destroyAllIfEphemeral()

        NSApp.unhide(nil)

        // Show post-recording dialog after a brief delay to let the app unhide
        if !urls.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPostRecordingDialog(for: urls)
            }
        }
    }

    // MARK: - Region Mode Coordination

    func showRegionOverlay(on screen: NSScreen, initialRegion: CGRect?) {
        overlayPanel?.close()
        overlayPanel = nil

        let screenFrame = screen.frame
        let scaleFactor = screen.backingScaleFactor

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
        // Sit above other apps. If a system dialog (e.g. TCC permission prompt) gets stuck behind
        // the overlay, the user can hold CMD or press the click-through toggle on the control
        // panel to make this panel ignore mouse events.
        panel.level = regionOverlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = isRegionOverlayClickThrough || isCmdHeld
        panel.hidesOnDeactivate = false

        let overlayView = CaptureRegionOverlayView(
            screenSize: screenFrame.size,
            displayScaleFactor: scaleFactor,
            initialRegion: initialRegion,
            onRegionChanged: { rect in
                UserDefaults.standard.set(rect.origin.x, forKey: AppConstants.captureRegionXKey)
                UserDefaults.standard.set(rect.origin.y, forKey: AppConstants.captureRegionYKey)
                UserDefaults.standard.set(rect.size.width, forKey: AppConstants.captureRegionWidthKey)
                UserDefaults.standard.set(rect.size.height, forKey: AppConstants.captureRegionHeightKey)
            },
            onCancel: { [weak self] in
                self?.dismissCaptureOverlay()
            }
        )

        let hosting = FirstMouseHostingView(rootView: overlayView)
        hosting.frame = CGRect(origin: .zero, size: screenFrame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(screenFrame, display: true)

        self.overlayPanel = panel
        panel.makeKeyAndOrderFront(nil)

        // Ensure control panel stays above the overlay
        controlPanel?.level = controlPanelLevelWhenRegionShown
    }

    func hideRegionOverlay() {
        overlayPanel?.close()
        overlayPanel = nil
        // Reset control panel level
        controlPanel?.level = controlPanelLevelWhenAlone
        // The region overlay no longer exists, so the manual click-through toggle has nothing to
        // act on. Reset it so the next time the overlay appears, it starts in the default state.
        isRegionOverlayClickThrough = false
    }

    func moveToDisplay(_ screen: NSScreen, initialRegion: CGRect?) {
        // Recreate overlay on the new screen if in region mode
        let isRegionMode = UserDefaults.standard.bool(forKey: AppConstants.captureRegionModeKey)
        if isRegionMode {
            showRegionOverlay(on: screen, initialRegion: initialRegion)
        }

        // Reposition control panel to the new screen
        if let controlPanel {
            let screenFrame = screen.visibleFrame
            let panelFrame = controlPanel.frame
            let x = screenFrame.midX - panelFrame.width / 2
            let y = screenFrame.minY + 40
            controlPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - Private Methods

    private func createOverlayPanel(on screen: NSScreen) {
        let isRegionMode = UserDefaults.standard.bool(forKey: AppConstants.captureRegionModeKey)
        guard isRegionMode else { return }

        let regionX = UserDefaults.standard.double(forKey: AppConstants.captureRegionXKey)
        let regionY = UserDefaults.standard.double(forKey: AppConstants.captureRegionYKey)
        let regionW = UserDefaults.standard.double(forKey: AppConstants.captureRegionWidthKey)
        let regionH = UserDefaults.standard.double(forKey: AppConstants.captureRegionHeightKey)

        let initialRegion: CGRect?
        if regionW > 0, regionH > 0 {
            initialRegion = CGRect(x: regionX, y: regionY, width: regionW, height: regionH)
        } else {
            initialRegion = nil
        }

        showRegionOverlay(on: screen, initialRegion: initialRegion)
    }

    private func createControlPanel(on screen: NSScreen) {
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 520
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY + 40

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = overlayPanel != nil ? controlPanelLevelWhenRegionShown : controlPanelLevelWhenAlone
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = isCmdHeld
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let controlView = CaptureControlPanelView(
            onCancel: { [weak self] in
                self?.dismissCaptureOverlay()
            },
            onStartRecording: { [weak self] in
                self?.startRecording()
            },
            onStopRecording: { [weak self] in
                self?.stopRecordingAndShowDialog()
            },
            onHidePanel: { [weak self] in
                self?.hideControlPanel()
            },
            onRegionModeChanged: { [weak self] isRegion in
                guard let self else { return }
                if isRegion {
                    guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
                    let regionX = UserDefaults.standard.double(forKey: AppConstants.captureRegionXKey)
                    let regionY = UserDefaults.standard.double(forKey: AppConstants.captureRegionYKey)
                    let regionW = UserDefaults.standard.double(forKey: AppConstants.captureRegionWidthKey)
                    let regionH = UserDefaults.standard.double(forKey: AppConstants.captureRegionHeightKey)
                    let initial: CGRect? = (regionW > 0 && regionH > 0)
                        ? CGRect(x: regionX, y: regionY, width: regionW, height: regionH)
                        : nil
                    self.showRegionOverlay(on: screen, initialRegion: initial)
                } else {
                    self.hideRegionOverlay()
                }
            },
            onDisplayChanged: { [weak self] screen, initialRegion in
                self?.moveToDisplay(screen, initialRegion: initialRegion)
            },
            onSetOverlayClickThrough: { [weak self] enabled in
                self?.setRegionOverlayClickThrough(enabled)
            },
            onScaleChanged: { [weak self] in
                self?.resizeControlPanelToFit()
            }
        )

        let hosting = FirstMouseHostingView(rootView: controlView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        self.controlPanel = panel
        self.controlHostingView = hosting

        panel.makeKeyAndOrderFront(nil)
    }

    private func setupRecordingObservers() {
        let captureManager = ScreenCaptureManager.shared

        // Only react when processing finishes — this is the final state after recording stops.
        // isRecording goes false first, then isProcessing goes true (writing file),
        // then isProcessing goes false (file complete, lastOutputURL set).
        processingObserver = captureManager.$isProcessing
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] isProcessing in
                guard let self else { return }
                if !isProcessing && !captureManager.isRecording {
                    self.handleRecordingStopped()
                }
            }
    }

    private func showPostRecordingDialog(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Recording Saved" : "\(urls.count) Recordings Saved"
        if urls.count == 1 {
            alert.informativeText = urls[0].lastPathComponent
        } else {
            let folder = urls[0].deletingLastPathComponent().lastPathComponent
            alert.informativeText = "\(urls.count) files saved to \(folder)."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: urls.count == 1 ? "Add to Encoding Queue" : "Add All to Encoding Queue")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            for url in urls {
                NotificationCenter.default.post(name: .enqueueFileURL, object: url)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        default:
            break
        }
    }

    // MARK: - Escape Key Handling

    private func installEscapeKeyMonitor() {
        guard escapeKeyLocalMonitor == nil else { return }

        let handleEscape = { [weak self] in
            guard let self else { return }
            let manager = ScreenCaptureManager.shared
            if !manager.isRecording && !manager.isProcessing {
                self.dismissCaptureOverlay()
            }
        }

        // Local monitor catches Escape when our app/panels are focused
        escapeKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                handleEscape()
                return nil
            }
            return event
        }

        // Global monitor catches Escape when another app is focused
        // (since the overlay panel is non-activating, focus stays with the previous app)
        escapeKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                handleEscape()
            }
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyLocalMonitor = nil
        }
        if let monitor = escapeKeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyGlobalMonitor = nil
        }
    }

    // MARK: - Click-Through

    /// Public toggle used by the floating control panel's button. Affects only the region overlay
    /// so the control panel itself stays clickable for un-toggling.
    func setRegionOverlayClickThrough(_ enabled: Bool) {
        isRegionOverlayClickThrough = enabled
        applyClickThroughState()
    }

    private func applyClickThroughState() {
        overlayPanel?.ignoresMouseEvents = isRegionOverlayClickThrough || isCmdHeld
        // Holding CMD also passes events through the control panel, so a TCC dialog (or any
        // window) hidden behind it can be reached. The manual toggle does not affect the control
        // panel — that would lock the user out of the toggle itself.
        controlPanel?.ignoresMouseEvents = isCmdHeld
    }

    // MARK: - Modifier Key Handling

    private func installModifierKeyMonitor() {
        guard modifierKeyLocalMonitor == nil else { return }

        let handleFlags = { [weak self] (event: NSEvent) in
            guard let self else { return }
            let cmdNow = event.modifierFlags.contains(.command)
            if cmdNow != self.isCmdHeld {
                self.isCmdHeld = cmdNow
                self.applyClickThroughState()
            }
        }

        modifierKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
            return event
        }

        modifierKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
        }
    }

    private func removeModifierKeyMonitor() {
        if let monitor = modifierKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierKeyLocalMonitor = nil
        }
        if let monitor = modifierKeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierKeyGlobalMonitor = nil
        }
        isCmdHeld = false
        applyClickThroughState()
    }

    // MARK: - Menu Bar Status Item

    /// Shows a single red menu-bar icon whose click opens a dropdown with recording controls
    /// (stop, show/hide preview, extend auto-stop) and a read-only status section.
    private func showStatusItems() {
        if showPanelStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                // Bake the red into the symbol via a palette color. A template image would be
                // re-tinted to the menu-bar's monochrome appearance (rendering black); a
                // non-template image with a palette color stays red in both light and dark menu bars.
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                let image = NSImage(
                    systemSymbolName: "record.circle.fill",
                    accessibilityDescription: String(localized: "Recording", comment: "Screen-recording menu-bar icon accessibility label.")
                )?.withSymbolConfiguration(config)
                image?.isTemplate = false
                button.image = image
                button.toolTip = String(localized: "Screen Recording", comment: "Screen-recording menu-bar icon tooltip.")
            }
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            buildStatusMenu(menu)
            item.menu = menu
            showPanelStatusItem = item
        }
        updateStatusMenuItems()
        showPanelStatusItem?.isVisible = true
    }

    private func hideStatusItems() {
        statusMenuUpdateTimer?.invalidate()
        statusMenuUpdateTimer = nil
        showPanelStatusItem?.isVisible = false
    }

    /// Builds the fixed structure of the status-bar dropdown once. Dynamic content
    /// (titles, auto-stop row visibility) is refreshed separately by `updateStatusMenuItems()`
    /// so the live menu — and any open submenu — is never rebuilt out from under the user.
    private func buildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let stop = NSMenuItem(
            title: String(localized: "Stop Recording", comment: "Screen-recording menu-bar dropdown."),
            action: #selector(menuStopRecording),
            keyEquivalent: ""
        )
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())

        // Title is set by updateStatusMenuItems (Show/Hide depending on panel visibility).
        let toggle = NSMenuItem(title: "", action: #selector(menuTogglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        statusTogglePreviewItem = toggle

        // Extend auto-stop submenu — increments start a fresh auto-stop when none is active.
        let extendItem = NSMenuItem(
            title: String(localized: "Extend Auto-Stop", comment: "Screen-recording menu-bar dropdown submenu."),
            action: nil,
            keyEquivalent: ""
        )
        let extendMenu = NSMenu()
        for minutes in [1, 5, 10, 30] {
            let entry = NSMenuItem(
                title: String(localized: "+\(minutes) min", comment: "Extend the recording auto-stop by N minutes."),
                action: #selector(menuExtendAutoStop(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = NSNumber(value: minutes * 60)
            extendMenu.addItem(entry)
        }
        // Cancel row is always present but hidden when no auto-stop is active.
        let cancelSeparator = NSMenuItem.separator()
        extendMenu.addItem(cancelSeparator)
        statusCancelAutoStopSeparator = cancelSeparator
        let cancel = NSMenuItem(
            title: String(localized: "Cancel Auto-Stop", comment: "Screen-recording menu-bar dropdown submenu."),
            action: #selector(menuCancelAutoStop),
            keyEquivalent: ""
        )
        cancel.target = self
        extendMenu.addItem(cancel)
        statusCancelAutoStopItem = cancel
        extendItem.submenu = extendMenu
        menu.addItem(extendItem)

        menu.addItem(.separator())

        // Titles for these read-only status rows are filled in by updateStatusMenuItems.
        let recorded = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recorded.isEnabled = false
        menu.addItem(recorded)
        statusRecordedItem = recorded

        let stopsIn = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stopsIn.isEnabled = false
        menu.addItem(stopsIn)
        statusStopsInItem = stopsIn

        let stopsAt = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stopsAt.isEnabled = false
        menu.addItem(stopsAt)
        statusStopsAtItem = stopsAt
    }

    /// Refreshes only the dynamic titles / visibility of the (already-built) status dropdown.
    /// Safe to call every second while the menu is open — it mutates no menu structure.
    private func updateStatusMenuItems() {
        let manager = ScreenCaptureManager.shared

        statusTogglePreviewItem?.title = (controlPanel?.isVisible == true)
            ? String(localized: "Hide Preview", comment: "Screen-recording menu-bar dropdown.")
            : String(localized: "Show Preview", comment: "Screen-recording menu-bar dropdown.")
        let recorded = Self.statusDurationFormatter.string(from: manager.elapsedTime) ?? "00:00:00"
        statusRecordedItem?.title = String(localized: "Recorded: \(recorded)", comment: "Screen-recording menu-bar dropdown: elapsed time.")

        if let stopDate = manager.autoStopDate {
            let remaining = max(0, stopDate.timeIntervalSinceNow)
            let remainingText = Self.statusDurationFormatter.string(from: remaining) ?? "00:00:00"
            let clockText = Self.statusClockFormatter.string(from: stopDate)
            statusStopsInItem?.title = String(localized: "Stops in: \(remainingText)", comment: "Screen-recording menu-bar dropdown: time until auto-stop.")
            statusStopsAtItem?.title = String(localized: "Auto-stop at: \(clockText)", comment: "Screen-recording menu-bar dropdown: clock time of auto-stop.")
            statusStopsInItem?.isHidden = false
            statusStopsAtItem?.isHidden = false
            statusCancelAutoStopItem?.isHidden = false
            statusCancelAutoStopSeparator?.isHidden = false
        } else {
            statusStopsInItem?.isHidden = true
            statusStopsAtItem?.isHidden = true
            statusCancelAutoStopItem?.isHidden = true
            statusCancelAutoStopSeparator?.isHidden = true
        }
    }

    @objc private func menuStopRecording() {
        stopRecordingAndShowDialog()
    }

    @objc private func menuTogglePanel() {
        if controlPanel?.isVisible == true {
            hideControlPanel()
        } else {
            showControlPanel()
        }
    }

    @objc private func menuExtendAutoStop(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        ScreenCaptureManager.shared.extendAutoStop(by: seconds)
    }

    @objc private func menuCancelAutoStop() {
        ScreenCaptureManager.shared.cancelAutoStop()
    }

    private static let statusDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private static let statusClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // Avoid sending the non-Sendable `menu` parameter into the MainActor region; the controller
        // owns the same menu via `showPanelStatusItem`.
        MainActor.assumeIsolated {
            updateStatusMenuItems()
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // Tick the countdown / elapsed time live while the menu stays open. Use a
            // target/selector timer so the repeating block carries no Sendable-capture concerns.
            statusMenuUpdateTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(statusMenuTick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            statusMenuUpdateTimer = timer
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            statusMenuUpdateTimer?.invalidate()
            statusMenuUpdateTimer = nil
        }
    }

    @objc private func statusMenuTick() {
        updateStatusMenuItems()
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        let closedWindow = notification.object as? NSPanel
        Task { @MainActor in
            if let closedWindow, closedWindow === self.controlPanel {
                if !ScreenCaptureManager.shared.isRecording && !ScreenCaptureManager.shared.isProcessing {
                    self.dismissCaptureOverlay()
                }
            }
        }
    }
}

// MARK: - Capture Region Panel

/// `.nonactivatingPanel` keeps the app from foregrounding when the overlay appears, but it also
/// blocks the panel from becoming key — which means keystrokes (Shift/Option/Space modifiers
/// during a drag, Escape, etc.) flow to whichever app was previously active instead of to our
/// local event monitors. Overriding `canBecomeKey` to `true` lets the panel hold keyboard focus
/// while the app itself stays in the background, so local monitors fire and Space can be
/// swallowed before the underlying app sees it. Also used by `RegionSelectionWindowController`.
final class CaptureRegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - First-Mouse Hosting View

/// The overlay is shown while the app is hidden (`NSApp.hide(nil)`) and its panels are
/// `.nonactivatingPanel`, so the app is never the frontmost application while the overlay is up.
/// When you click a window of a non-frontmost app, macOS swallows that first mouse-down to activate
/// the window instead of delivering it to the view under the cursor — unless the view opts in via
/// `acceptsFirstMouse`. Without this, the first click on the overlay (a control-panel button or a
/// region drag) is eaten and appears to fall through to the app below; only the second click lands.
/// `NSHostingView` returns `false` by default, so we override it here for every overlay surface.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
