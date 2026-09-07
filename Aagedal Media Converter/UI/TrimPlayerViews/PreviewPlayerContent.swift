// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encapsulates the video playback area for PreviewPlayerView, including overlays and fallback handling.

import SwiftUI
import AppKit
import AVKit

struct PreviewPlayerContent: View {
    @Binding var item: VideoItem
    let controller: PreviewPlayerController
    let showsPlaybackControls: Bool
    let togglePlaybackControls: () -> Void
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
    @Binding var currentPlaybackTime: Double
    @State private var showPreviewUnavailable = false

    private struct PreviewAvailabilityKey: Equatable {
        let isPreviewAvailable: Bool
        let hasError: Bool
    }

    private var playerAspectRatio: CGFloat {
        if let ratio = item.videoDisplayAspectRatio, ratio.isFinite, ratio > 0 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }

    private var isPreviewAvailable: Bool {
        controller.player != nil || (controller.useMPV && controller.mpvPlayer != nil) || controller.useImageSequence
    }

    /// True for input formats the app accepts but cannot decode for preview (e.g. AV2 .ivf).
    private var isFormatUnsupportedForPreview: Bool {
        AppConstants.previewUnsupportedExtensions.contains(item.url.pathExtension.lowercased())
    }

    private var formatUnsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 40))
            Text("Preview not available for this format")
                .font(.headline)
                .foregroundColor(.white)
            Text("\(item.url.pathExtension.uppercased()) files can be queued and encoded, but can't be played back inside the app yet.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewAvailabilityKey: PreviewAvailabilityKey {
        PreviewAvailabilityKey(
            isPreviewAvailable: isPreviewAvailable,
            hasError: controller.errorMessage != nil
        )
    }

    @ViewBuilder
    private func playbackBackground() -> some View {
        if item.hasVideoStream {
            CheckerboardBackground()
        } else {
            Color.black
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().progressViewStyle(.circular)
            Text("Preview loading")
                .foregroundColor(.white.opacity(0.8))
        }
        .padding()
    }


    var body: some View {
        Group {
            if isFormatUnsupportedForPreview {
                formatUnsupportedView
            } else if let player = controller.player {
                ZStack {
                    playbackBackground()

                    PlayerContainerView(
                        player: player,
                        controller: controller,
                        showsPlaybackControls: showsPlaybackControls,
                        keyHandler: keyHandler
                    )
                    .aspectRatio(playerAspectRatio, contentMode: .fit)

                    // Crop overlay
                    if controller.isCropEnabled, item.hasVideoStream {
                        CropOverlayView(
                            cropConfig: Binding(
                                get: { item.cropConfig ?? CropConfig(normalizedRect: .fullFrame) },
                                set: { item.cropConfig = $0.isActive ? $0 : nil }
                            ),
                            sourceWidth: item.metadata?.primaryVideoStream?.width ?? 1920,
                            sourceHeight: item.metadata?.primaryVideoStream?.height ?? 1080,
                            videoAspectRatio: Double(playerAspectRatio),
                            isEnabled: true
                        )
                    }

                    overlayIndicators
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
            } else if controller.useMPV, let mpvPlayer = controller.mpvPlayer {
                ZStack {
                    playbackBackground()

                    MPVVideoView(player: mpvPlayer, keyHandler: keyHandler)
                        .aspectRatio(playerAspectRatio, contentMode: .fit)

                    // Crop overlay
                    if controller.isCropEnabled, item.hasVideoStream {
                        CropOverlayView(
                            cropConfig: Binding(
                                get: { item.cropConfig ?? CropConfig(normalizedRect: .fullFrame) },
                                set: { item.cropConfig = $0.isActive ? $0 : nil }
                            ),
                            sourceWidth: item.metadata?.primaryVideoStream?.width ?? 1920,
                            sourceHeight: item.metadata?.primaryVideoStream?.height ?? 1080,
                            videoAspectRatio: Double(playerAspectRatio),
                            isEnabled: true
                        )
                    }

                    overlayIndicators
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
            } else if controller.useImageSequence, let frame = controller.imageSequenceFrame {
                ZStack {
                    CheckerboardBackground()

                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)

                    // Invisible view that captures keyboard events for image sequence preview
                    KeyboardCapturingView(keyHandler: keyHandler)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    overlayIndicators
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
            } else if let message = controller.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 40))
                    Text("Preview unavailable")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        controller.preparePreview(startTime: item.effectiveTrimStart)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if showPreviewUnavailable {
                Text("Preview not available")
                    .foregroundColor(.white.opacity(0.8))
                    .padding()
            } else {
                loadingView
            }
        }
        .task(id: previewAvailabilityKey) { @MainActor in
            showPreviewUnavailable = false
            guard !isPreviewAvailable, controller.errorMessage == nil else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            if !isPreviewAvailable && controller.errorMessage == nil {
                showPreviewUnavailable = true
            }
        }
    }


    @ViewBuilder
    private var overlayIndicators: some View {
        ZStack {
            // Top-left: Speed indicator (visible during active playback at non-1x speed)
            VStack {
                HStack {
                    PlaybackSpeedIndicator(
                        speed: controller.currentPlaybackSpeed,
                        isReversing: controller.isReverseSimulating,
                        isPlaying: controller.isPlaying
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
            
            // Top-right: Audio meter (when enabled) - moved to avoid overlap with native player controls
            VStack {
                HStack {
                    Spacer()
                    if controller.isAudioMeterEnabled {
                        AudioMeterView(levels: controller.audioLevels ?? .silence)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                Spacer()
            }
            .padding(16)
            
            if controller.isCapturingScreenshot {
                dimOverlay(title: "Capturing Still…")
            }
        }
    }


    private func dimOverlay(title: String, subtitle: String? = nil) -> some View {
        ZStack {
            Color.black.opacity(0.5)

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                    .tint(.white)

                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.8))
            )
        }
        .transition(.opacity)
    }

    private func timeString(for seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    private var screenshotBadge: some View {
        HStack {
            Image(systemName: "camera")
            Text("Screenshot saved")
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .padding(12)
        .transition(.opacity.combined(with: .scale))
        .animation(.easeOut(duration: 0.2), value: controller.showScreenshotOverlay)
    }

    private var toggleControlsButton: some View {
        Button(action: togglePlaybackControls) {
            Image(systemName: showsPlaybackControls ? "slider.horizontal.below.rectangle" : "slider.horizontal.below.square.filled.and.square")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.7))
                )
        }
        .buttonStyle(.plain)
        .help(showsPlaybackControls ? "Hide native AVPlayer controls" : "Show native AVPlayer controls")
        .accessibilityLabel(showsPlaybackControls ? "Hide playback controls" : "Show playback controls")
        .accessibilityIdentifier("preview.togglePlaybackControls")
        .padding(12)
    }
}

private struct PlayerContainerView: NSViewRepresentable {
    typealias NSViewType = AVPlayerView

    let player: AVPlayer
    let controller: PreviewPlayerController
    let showsPlaybackControls: Bool
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        configure(playerView)
        context.coordinator.attach(to: playerView, controller: controller)
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.controlsStyle = showsPlaybackControls ? .floating : .none
        nsView.showsFullScreenToggleButton = showsPlaybackControls
        nsView.showsFrameSteppingButtons = showsPlaybackControls
        nsView.showsTimecodes = showsPlaybackControls
        context.coordinator.showsPlaybackControls = showsPlaybackControls
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }

    private func configure(_ playerView: AVPlayerView) {
        playerView.controlsStyle = showsPlaybackControls ? .floating : .none
        playerView.showsFullScreenToggleButton = showsPlaybackControls
        playerView.showsFrameSteppingButtons = showsPlaybackControls
        playerView.showsSharingServiceButton = false
        playerView.showsTimecodes = showsPlaybackControls
        playerView.videoGravity = .resizeAspect
        playerView.allowsVideoFrameAnalysis = false
        playerView.player = player
        // Make background transparent so checkerboard shows through
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    final class Coordinator: NSObject {
        private var monitor: Any?
        private weak var attachedView: AVPlayerView?
        var showsPlaybackControls: Bool = false
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
        }

        @MainActor
        func attach(to playerView: AVPlayerView, controller: PreviewPlayerController) {
            playerView.player = controller.player
            controller.playerView = playerView
            attachedView = playerView

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events if our window is the key window
                // This prevents capturing events when fullscreen player is open
                guard let view = self.attachedView,
                      let window = view.window,
                      window.isKeyWindow else {
                    return event
                }

                guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return event }
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

/// Invisible NSView that captures keyboard events for image sequence preview.
/// Uses the same NSEvent local monitor pattern as PlayerContainerView.
private struct KeyboardCapturingView: NSViewRepresentable {
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSView(context: Context) -> KeyCapturingNSView {
        let view = KeyCapturingNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.attachedView = view
        return view
    }

    func updateNSView(_ nsView: KeyCapturingNSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }

    final class Coordinator: NSObject {
        private var monitor: Any?
        weak var attachedView: NSView?
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let view = self.attachedView,
                      MainActor.assumeIsolated({ view.window?.isKeyWindow == true }) else { return event }
                guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return event }
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

/// Simple NSView that accepts first responder for keyboard capture.
private final class KeyCapturingNSView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
