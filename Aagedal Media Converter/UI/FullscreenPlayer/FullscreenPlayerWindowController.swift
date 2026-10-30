// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import OSLog
import SwiftUI

/// Manages fullscreen player windows for video playback
@MainActor
final class FullscreenPlayerWindowController {

    static let shared = FullscreenPlayerWindowController()
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FullscreenPlayer")

    private var currentWindow: NSWindow?
    private var hostingView: NSHostingView<FullscreenPlayerView>?

    private var exitFullscreenObserver: Any?
    private var shouldCloseAfterExitFullscreen = false

    // Queue navigation state. Empty when opened for a single item (trim view).
    private var queue: [VideoItem] = []
    private var currentIndex: Int = 0

    // Queue playback options, kept for the app session
    private var queueAutoAdvanceEnabled = false
    private var queueLoopEnabled = false

    // Currently playing item identifier
    private var currentlyPlayingItemID: UUID?

    // Identifies the player view currently installed; end-of-playback reports from
    // a replaced view are ignored.
    private var playerSessionID = UUID()

    // Overlay and timecode state preserved across video switches
    private var isOverlayHidden = false
    private var currentTimecodeDisplayMode: TimecodeDisplayMode = .preferred

    // Owner callbacks for the current session
    private var onCloseWithPosition: ((Double) -> Void)?
    private var onItemTrimChanged: ((UUID, Double?, Double?) -> Void)?

    private init() {}

    /// Opens the fullscreen player with queue navigation support
    func openFullscreenPlayer(
        for item: VideoItem,
        in queue: [VideoItem],
        on screen: NSScreen? = nil,
        onItemTrimChanged: ((UUID, Double?, Double?) -> Void)? = nil
    ) {
        guard item.isPlayable else { return }
        dismissWindow()

        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            self.queue = queue
            self.currentIndex = index
        } else {
            self.queue = []
            self.currentIndex = 0
        }
        self.onItemTrimChanged = onItemTrimChanged

        present(item, startTime: nil, on: screen)
    }

    /// Opens the fullscreen player from the trim view with position synchronization
    /// - Parameters:
    ///   - item: The video item to play
    ///   - startTime: The starting playback position
    ///   - onCloseWithPosition: Callback invoked when player closes with final position
    func openFullscreenPlayerFromTrimView(
        for item: VideoItem,
        startTime: Double,
        onCloseWithPosition: @escaping (Double) -> Void,
        onTrimChanged: ((Double?, Double?) -> Void)? = nil
    ) {
        guard item.isPlayable else { return }
        dismissWindow()

        // Single item context: no queue navigation
        queue = []
        currentIndex = 0
        self.onCloseWithPosition = onCloseWithPosition
        if let onTrimChanged {
            self.onItemTrimChanged = { _, trimStart, trimEnd in onTrimChanged(trimStart, trimEnd) }
        }

        present(item, startTime: startTime, on: nil)
    }

    // MARK: - Window

    private func present(_ item: VideoItem, startTime: Double?, on screen: NSScreen?) {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.error("No screen available for fullscreen player")
            return
        }

        // Reset per-session view state when opening fresh
        isOverlayHidden = false
        currentTimecodeDisplayMode = .preferred

        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        currentWindow = window

        installPlayerView(for: item, startTime: startTime, autoPlayOnReady: false)

        shouldCloseAfterExitFullscreen = false
        exitFullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.shouldCloseAfterExitFullscreen else { return }
                self.dismissWindow()
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Builds a player view for `item` and makes it the window's content, replacing
    /// any previous one (whose teardown runs from its onDisappear).
    private func installPlayerView(for item: VideoItem, startTime: Double?, autoPlayOnReady: Bool) {
        guard let window = currentWindow else { return }

        currentlyPlayingItemID = item.id
        let itemID = item.id
        let sessionID = UUID()
        playerSessionID = sessionID

        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: isOverlayHidden,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            startTime: startTime,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            // Captured directly: the view reports its final position from onDisappear,
            // which can run after dismissWindow() has cleared the session callbacks.
            onCloseWithPosition: onCloseWithPosition,
            onTrimChanged: onItemTrimChanged == nil ? nil : { [weak self] trimStart, trimEnd in
                self?.handleItemTrimChanged(itemID: itemID, trimStart: trimStart, trimEnd: trimEnd)
            },
            onPreviousItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToPreviousItem() }
            },
            onNextItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToNextItem() }
            },
            onOverlayVisibilityChanged: { [weak self] isHidden in
                MainActor.assumeIsolated { self?.isOverlayHidden = isHidden }
            },
            onTimecodeDisplayModeChanged: { [weak self] mode in
                MainActor.assumeIsolated { self?.currentTimecodeDisplayMode = mode }
            },
            canGoToPrevious: canGoToPrevious,
            canGoToNext: canGoToNext,
            queueAutoAdvanceEnabled: queueAutoAdvanceEnabled,
            queueLoopEnabled: queueLoopEnabled,
            onToggleQueueAutoAdvance: { [weak self] in
                Task { @MainActor in self?.queueAutoAdvanceEnabled.toggle() }
            },
            onToggleQueueLoop: { [weak self] in
                Task { @MainActor in self?.queueLoopEnabled.toggle() }
            },
            onPlaybackDidFinish: { [weak self] in
                Task { @MainActor in self?.handlePlaybackDidFinish(session: sessionID) }
            },
            autoPlayOnReady: autoPlayOnReady
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? window.frame
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        self.hostingView = hostingView
    }

    /// Closes the current fullscreen player window
    func closeFullscreenPlayer() {
        guard let window = currentWindow else { return }

        if window.styleMask.contains(.fullScreen) {
            shouldCloseAfterExitFullscreen = true
            window.toggleFullScreen(nil)
        } else {
            dismissWindow()
        }
    }

    private func dismissWindow() {
        if let observer = exitFullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
            exitFullscreenObserver = nil
        }
        shouldCloseAfterExitFullscreen = false

        currentWindow?.close()
        currentWindow = nil
        hostingView = nil

        currentlyPlayingItemID = nil
        onCloseWithPosition = nil
        onItemTrimChanged = nil
    }

    // MARK: - Queue Navigation

    /// Navigate to the previous playable item in the queue (skips downloading/recording items)
    func goToPreviousItem() {
        guard let newIndex = findPreviousPlayableIndex() else { return }
        currentIndex = newIndex
        installPlayerView(for: queue[newIndex], startTime: nil, autoPlayOnReady: false)
    }

    /// Navigate to the next playable item in the queue (skips downloading/recording items)
    func goToNextItem() {
        guard let newIndex = findNextPlayableIndex() else { return }
        currentIndex = newIndex
        installPlayerView(for: queue[newIndex], startTime: nil, autoPlayOnReady: false)
    }

    /// Returns true if navigation to a previous playable item is possible
    var canGoToPrevious: Bool {
        findPreviousPlayableIndex() != nil
    }

    /// Returns true if navigation to a next playable item is possible
    var canGoToNext: Bool {
        findNextPlayableIndex() != nil
    }

    private func findPreviousPlayableIndex() -> Int? {
        guard !queue.isEmpty, currentIndex > 0 else { return nil }
        return stride(from: currentIndex - 1, through: 0, by: -1).first { queue[$0].isPlayable }
    }

    private func findNextPlayableIndex() -> Int? {
        guard !queue.isEmpty, currentIndex < queue.count - 1 else { return nil }
        return ((currentIndex + 1)..<queue.count).first { queue[$0].isPlayable }
    }

    /// Keeps the queue snapshot in step with trim edits so navigating back to an item
    /// shows its current trim points, then forwards the change to the owner.
    private func handleItemTrimChanged(itemID: UUID, trimStart: Double?, trimEnd: Double?) {
        if let index = queue.firstIndex(where: { $0.id == itemID }) {
            queue[index].trimStart = trimStart
            queue[index].trimEnd = trimEnd
        }
        onItemTrimChanged?(itemID, trimStart, trimEnd)
    }

    private func handlePlaybackDidFinish(session: UUID) {
        // Both the near-end proximity check and the player's own end-of-file callback
        // report completion. Advancing installs a new view (and session), so a second
        // report from the old view is dropped instead of skipping an extra item.
        guard session == playerSessionID,
              queueAutoAdvanceEnabled,
              queue.indices.contains(currentIndex),
              !queue[currentIndex].loopPlayback else { return }

        // Next playable item, wrapping to the first when looping the queue
        let nextIndex = findNextPlayableIndex()
            ?? (queueLoopEnabled ? queue.indices.first { queue[$0].isPlayable } : nil)
        guard let nextIndex else {
            logger.debug("Auto Next: reached end of queue")
            return
        }

        currentIndex = nextIndex
        logger.debug("Auto Next: advancing to \(self.queue[nextIndex].name, privacy: .public)")
        installPlayerView(for: queue[nextIndex], startTime: nil, autoPlayOnReady: true)
    }

    /// Returns true if a fullscreen player is currently open
    var isFullscreenPlayerOpen: Bool {
        currentWindow != nil
    }

    /// Returns true if the provided item is currently displayed
    func isCurrentlyPlaying(itemID: UUID) -> Bool {
        currentlyPlayingItemID == itemID
    }
}
