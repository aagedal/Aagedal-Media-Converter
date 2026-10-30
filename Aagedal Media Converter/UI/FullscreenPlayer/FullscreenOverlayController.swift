// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Owns the fullscreen player's control-overlay visibility, idle cursor hiding,
// and the AppKit observers behind them. Adapted from Aagedal Media Player's
// PlayerOverlayController.

import AppKit
import AVFoundation
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    @Published private(set) var isVisible: Bool
    @Published private(set) var isRightEdgeHovered = false
    @Published private(set) var isMenuOpen = false

    /// True while any playback is running (forward, reverse simulation, image sequence).
    @Published private(set) var isPlaying = false

    private var isControlsHovered = false
    private weak var window: NSWindow?
    private var isInteractionActive: @MainActor () -> Bool = { false }

    private var interactionActive: Bool { isMenuOpen || isInteractionActive() }

    private var hideTask: Task<Void, Never>?
    private var hideDeadline: ContinuousClock.Instant?
    private var mouseMoveMonitor: Any?
    private var keyDownMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var playStateCancellable: AnyCancellable?
    private let hideDelay: Duration

    /// Hardware key code used by AppKit for Tab, including Shift-Tab.
    private static let tabKeyCode: UInt16 = 48

    init(initiallyVisible: Bool = true, hideDelay: Duration = .seconds(3)) {
        self.isVisible = initiallyVisible
        self.hideDelay = hideDelay
    }

    /// Installs event monitors scoped to `window`. Safe to call again when the window changes.
    func install(window: NSWindow, isInteractionActive: @escaping @MainActor () -> Bool) {
        guard self.window !== window || mouseMoveMonitor == nil else { return }
        removeObservers()
        self.window = window
        self.isInteractionActive = isInteractionActive

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      event.windowNumber == window.windowNumber, window.isKeyWindow,
                      !self.isRightEdgeHovered else { return }
                self.reveal()
                self.scheduleHide()
            }
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      event.keyCode == Self.tabKeyCode,
                      event.windowNumber == window.windowNumber, window.isKeyWindow else { return }
                // Keep controls up while Full Keyboard Access moves focus through them.
                // The event is returned so normal Tab traversal still happens.
                self.reveal()
                self.cancelScheduledHide()
            }
            return event
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRightEdgeHovered = false
                FullscreenCursorHideNSView.ensureCursorVisible()
                self.reveal()
                self.scheduleHide()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.interactionActive else { return }
                self.hide(hidesCursor: false)
            }
        })
        // SwiftUI Menus (audio/subtitle pickers) run their own tracking loop; keep the
        // controls on screen while one is open so the menu isn't orphaned mid-selection.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true else { return }
                self.isMenuOpen = true
                self.reveal()
                self.cancelScheduledHide()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMenuOpen else { return }
                self.isMenuOpen = false
                self.scheduleHide()
            }
        })
    }

    /// Tracks play state from whichever backend the controller ends up using.
    func bindPlayState(to controller: PreviewPlayerController) {
        guard playStateCancellable == nil else { return }

        let mpvPlaying = controller.$mpvPlayer
            .map { player -> AnyPublisher<Bool, Never> in
                player?.$isPlaying.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
            }
            .switchToLatest()
        let avPlaying = controller.$player
            .map { player -> AnyPublisher<Bool, Never> in
                player?.publisher(for: \.rate).map { $0 != 0 }.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
            }
            .switchToLatest()

        playStateCancellable = Publishers.CombineLatest4(
            mpvPlaying,
            avPlaying,
            controller.$isReverseSimulating,
            controller.$isImageSequencePlaying
        )
        .map { $0 || $1 || $2 || $3 }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] playing in
            MainActor.assumeIsolated { self?.setPlaying(playing) }
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        if playing {
            scheduleHide()
        } else if !isRightEdgeHovered {
            // Paused: bring the controls back and keep them up until playback resumes.
            reveal()
            cancelScheduledHide()
        }
    }

    func setControlsHovered(_ hovered: Bool) {
        isControlsHovered = hovered
        if hovered {
            cancelScheduledHide()
        } else {
            scheduleHide()
        }
    }

    func setRightEdgeHovered(_ hovered: Bool) {
        isRightEdgeHovered = hovered
        if hovered {
            cancelScheduledHide()
            if !interactionActive {
                hide(hidesCursor: false)
            }
        } else {
            reveal()
            scheduleHide()
        }
    }

    func reveal() {
        if !isVisible { isVisible = true }
    }

    /// Arms (or extends) the auto-hide timer. Only hides while playing, so paused
    /// frames stay inspectable with the controls visible.
    func scheduleHide() {
        guard !isControlsHovered, !interactionActive, isPlaying else {
            cancelScheduledHide()
            return
        }

        // Mouse moves arrive at display rate; extend one running timer instead of
        // spawning a task per event.
        hideDeadline = .now + hideDelay
        guard hideTask == nil else { return }

        hideTask = Task { @MainActor [weak self] in
            while let deadline = self?.hideDeadline, deadline > .now {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.hideDeadline = nil
            if !self.isControlsHovered, !self.interactionActive, self.isPlaying {
                self.hide(hidesCursor: true)
            }
        }
    }

    func cancelScheduledHide() {
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
    }

    func tearDown() {
        cancelScheduledHide()
        removeObservers()
        playStateCancellable = nil
        FullscreenCursorHideNSView.ensureCursorVisible()
    }

    private func hide(hidesCursor: Bool) {
        cancelScheduledHide()
        // The controls are removed from the hierarchy, so their hover-exit never fires.
        isControlsHovered = false
        if isVisible { isVisible = false }
        if hidesCursor, window?.isKeyWindow == true, NSApp.isActive {
            // Self-balancing: AppKit unhides on the next mouse move.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func removeObservers() {
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
