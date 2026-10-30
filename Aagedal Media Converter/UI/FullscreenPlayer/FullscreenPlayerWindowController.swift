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

    // Queue navigation state
    private var queue: [VideoItem] = []
    private var currentIndex: Int = 0
    private var currentScreen: NSScreen?

    // Queue playback options
    private var queueAutoAdvanceEnabled = false
    private var queueLoopEnabled = false

    // Currently playing item identifier
    private var currentlyPlayingItemID: UUID?

    // Identifies the player view currently installed; end-of-playback reports from
    // a replaced view are ignored.
    private var playerSessionID = UUID()

    // Overlay state preserved across video switches
    private var isOverlayHidden = false

    // Timecode display mode preserved across video switches
    private var currentTimecodeDisplayMode: TimecodeDisplayMode = .preferred

    // Callback to notify when fullscreen player closes with final position
    private var onCloseWithPosition: ((Double) -> Void)?

    // Callback to notify when trim points change in fullscreen player
    private var onTrimChanged: ((Double?, Double?) -> Void)?

    // Callback to notify when trim points change for any item (includes item ID for queue context)
    private var onItemTrimChanged: ((UUID, Double?, Double?) -> Void)?

    // Reference to current player view to get final position
    private var currentPlayerView: FullscreenPlayerView?

    private init() {}
    
    /// Opens a fullscreen player for the given video item
    func openFullscreenPlayer(for item: VideoItem, on screen: NSScreen? = nil) {
        // Don't open player for items that are downloading, recording, or scheduled
        guard item.isPlayable else { return }

        // Save callbacks intended for the new window before dismiss clears them
        let savedItemTrimCallback = onItemTrimChanged

        // Close any existing fullscreen player
        dismissWindow()

        // Restore callbacks for the new window
        onItemTrimChanged = savedItemTrimCallback

        // Clear queue if opening without queue context
        if queue.isEmpty || queue.first(where: { $0.id == item.id }) == nil {
            queue = []
            currentIndex = 0
        }

        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.error("No screen available for fullscreen player")
            return
        }
        currentScreen = targetScreen

        currentlyPlayingItemID = item.id

        // Create a borderless fullscreen window
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

        // Reset state when opening fresh
        isOverlayHidden = false
        currentTimecodeDisplayMode = .preferred

        // Create the SwiftUI view with navigation callbacks
        let itemID = item.id
        let sessionID = UUID()
        playerSessionID = sessionID
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: false,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onTrimChanged: onItemTrimChanged != nil ? { [weak self] trimStart, trimEnd in
                self?.handleItemTrimChanged(itemID: itemID, trimStart: trimStart, trimEnd: trimEnd)
            } : nil,
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
                Task { @MainActor in
                    self?.toggleQueueAutoAdvance()
                }
            },
            onToggleQueueLoop: { [weak self] in
                Task { @MainActor in
                    self?.toggleQueueLoopEnabled()
                }
            },
            onPlaybackDidFinish: { [weak self] in
                Task { @MainActor in
                    self?.handlePlaybackDidFinish(session: sessionID)
                }
            },
            autoPlayOnReady: false
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? targetScreen.frame
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        // Store references
        self.currentWindow = window
        self.hostingView = hostingView

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

        // Enter fullscreen mode
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
    
    /// Opens fullscreen player from the primary screen
    func openFullscreenPlayer(for item: VideoItem) {
        openFullscreenPlayer(for: item, on: nil)
    }

    /// Opens fullscreen player with queue navigation support
    func openFullscreenPlayer(
        for item: VideoItem,
        in queue: [VideoItem],
        on screen: NSScreen? = nil,
        onItemTrimChanged: ((UUID, Double?, Double?) -> Void)? = nil
    ) {
        self.queue = queue
        self.currentIndex = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        self.onItemTrimChanged = onItemTrimChanged
        openFullscreenPlayer(for: item, on: screen)
    }

    /// Opens fullscreen player from trim view with position synchronization
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
        // Don't open player for items that are downloading, recording, or scheduled
        guard item.isPlayable else { return }

        // Close any existing fullscreen player
        dismissWindow()

        // Store the callbacks after dismiss to prevent them from being cleared
        self.onCloseWithPosition = onCloseWithPosition
        self.onTrimChanged = onTrimChanged

        // Clear queue since we're opening from trim view (single item context)
        queue = []
        currentIndex = 0

        guard let targetScreen = NSScreen.main ?? NSScreen.screens.first else {
            logger.error("No screen available for fullscreen player")
            return
        }
        currentScreen = targetScreen

        currentlyPlayingItemID = item.id

        // Create a borderless fullscreen window
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

        // Reset state when opening fresh
        isOverlayHidden = false
        currentTimecodeDisplayMode = .preferred

        // Create the SwiftUI view with position callbacks
        let sessionID = UUID()
        playerSessionID = sessionID
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: false,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            startTime: startTime,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onCloseWithPosition: { [weak self] position in
                self?.onCloseWithPosition?(position)
            },
            onTrimChanged: { [weak self] trimStart, trimEnd in
                self?.onTrimChanged?(trimStart, trimEnd)
            },
            onPreviousItem: nil,
            onNextItem: nil,
            onOverlayVisibilityChanged: { [weak self] isHidden in
                MainActor.assumeIsolated { self?.isOverlayHidden = isHidden }
            },
            onTimecodeDisplayModeChanged: { [weak self] mode in
                MainActor.assumeIsolated { self?.currentTimecodeDisplayMode = mode }
            },
            canGoToPrevious: false,
            canGoToNext: false,
            queueAutoAdvanceEnabled: queueAutoAdvanceEnabled,
            queueLoopEnabled: queueLoopEnabled,
            onToggleQueueAutoAdvance: { [weak self] in
                Task { @MainActor in
                    self?.toggleQueueAutoAdvance()
                }
            },
            onToggleQueueLoop: { [weak self] in
                Task { @MainActor in
                    self?.toggleQueueLoopEnabled()
                }
            },
            onPlaybackDidFinish: { [weak self] in
                Task { @MainActor in
                    self?.handlePlaybackDidFinish(session: sessionID)
                }
            },
            autoPlayOnReady: false
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? targetScreen.frame
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        // Store references
        self.currentWindow = window
        self.hostingView = hostingView

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

        // Enter fullscreen mode
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Navigate to the previous playable item in the queue (skips downloading/recording items)
    func goToPreviousItem() {
        guard let newIndex = findPreviousPlayableIndex() else { return }

        currentIndex = newIndex
        let item = queue[newIndex]
        reopenWithItem(item)
    }

    /// Navigate to the next playable item in the queue (skips downloading/recording items)
    func goToNextItem() {
        guard let newIndex = findNextPlayableIndex() else { return }

        currentIndex = newIndex
        let item = queue[newIndex]
        reopenWithItem(item)
    }

    /// Returns true if navigation to a previous playable item is possible
    var canGoToPrevious: Bool {
        findPreviousPlayableIndex() != nil
    }

    /// Returns true if navigation to a next playable item is possible
    var canGoToNext: Bool {
        findNextPlayableIndex() != nil
    }

    /// Find the index of the previous playable item (not downloading, recording, or scheduled)
    private func findPreviousPlayableIndex() -> Int? {
        guard !queue.isEmpty, currentIndex > 0 else { return nil }

        for index in stride(from: currentIndex - 1, through: 0, by: -1) {
            if queue[index].isPlayable {
                return index
            }
        }
        return nil
    }

    /// Find the index of the next playable item (not downloading, recording, or scheduled)
    private func findNextPlayableIndex() -> Int? {
        guard !queue.isEmpty, currentIndex < queue.count - 1 else { return nil }

        for index in (currentIndex + 1)..<queue.count {
            if queue[index].isPlayable {
                return index
            }
        }
        return nil
    }

    private func reopenWithItem(_ item: VideoItem, autoPlayOnReady: Bool = false) {
        currentlyPlayingItemID = item.id

        guard let window = currentWindow else { return }

        // Create new player view with updated item, preserving overlay and timecode state
        let itemID = item.id
        let sessionID = UUID()
        playerSessionID = sessionID
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: isOverlayHidden,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onTrimChanged: onItemTrimChanged != nil ? { [weak self] trimStart, trimEnd in
                self?.handleItemTrimChanged(itemID: itemID, trimStart: trimStart, trimEnd: trimEnd)
            } : onTrimChanged,
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
                Task { @MainActor in
                    self?.toggleQueueAutoAdvance()
                }
            },
            onToggleQueueLoop: { [weak self] in
                Task { @MainActor in
                    self?.toggleQueueLoopEnabled()
                }
            },
            onPlaybackDidFinish: { [weak self] in
                Task { @MainActor in
                    self?.handlePlaybackDidFinish(session: sessionID)
                }
            },
            autoPlayOnReady: autoPlayOnReady
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? .zero
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

        // Clear callbacks after window is dismissed
        onCloseWithPosition = nil
        onTrimChanged = nil
        onItemTrimChanged = nil
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

    @MainActor
    private func handlePlaybackDidFinish(session: UUID) {
        // Both the near-end proximity check and the player's own end-of-file callback
        // report completion. Advancing installs a new view (and session), so a second
        // report from the old view is dropped instead of skipping an extra item.
        guard session == playerSessionID else { return }
        logger.debug("handlePlaybackDidFinish called - autoAdvance: \(self.queueAutoAdvanceEnabled), currentIndex: \(self.currentIndex), queueCount: \(self.queue.count)")

        guard queueAutoAdvanceEnabled,
              queue.indices.contains(currentIndex) else {
            logger.debug("handlePlaybackDidFinish: returning early (autoAdvance=\(self.queueAutoAdvanceEnabled), validIndex=\(self.queue.indices.contains(self.currentIndex)))")
            return
        }

        let currentItem = queue[currentIndex]
        guard !currentItem.loopPlayback else {
            logger.debug("handlePlaybackDidFinish: returning early (loopPlayback enabled)")
            return
        }

        // Find next playable item, skipping downloading/recording items
        let nextItem: VideoItem?
        if let nextIndex = findNextPlayableIndex() {
            logger.debug("handlePlaybackDidFinish: found next playable index \(nextIndex)")
            currentIndex = nextIndex
            nextItem = queue[nextIndex]
        } else if queueLoopEnabled {
            // When looping, find first playable item from beginning
            if let firstPlayableIndex = findFirstPlayableIndex() {
                logger.debug("handlePlaybackDidFinish: looping to first playable index \(firstPlayableIndex)")
                currentIndex = firstPlayableIndex
                nextItem = queue[firstPlayableIndex]
            } else {
                logger.debug("handlePlaybackDidFinish: no playable items found for loop")
                nextItem = nil
            }
        } else {
            logger.debug("handlePlaybackDidFinish: no next item and loop disabled")
            nextItem = nil
        }

        if let nextItem {
            logger.debug("handlePlaybackDidFinish: advancing to \(nextItem.name, privacy: .public)")
            reopenWithItem(nextItem, autoPlayOnReady: true)
        }
    }

    /// Find the index of the first playable item in the queue
    private func findFirstPlayableIndex() -> Int? {
        for index in 0..<queue.count {
            if queue[index].isPlayable {
                return index
            }
        }
        return nil
    }

    @MainActor
    private func toggleQueueAutoAdvance() {
        queueAutoAdvanceEnabled.toggle()
    }

    @MainActor
    private func toggleQueueLoopEnabled() {
        queueLoopEnabled.toggle()
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

// MARK: - Convenience Extension for VideoItem

extension VideoItem {
    /// Opens this video in the fullscreen player
    @MainActor
    func openInFullscreenPlayer() {
        FullscreenPlayerWindowController.shared.openFullscreenPlayer(for: self)
    }
}
