// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encapsulates the video playback area for PreviewPlayerView, including overlays and fallback handling.

import SwiftUI
import AppKit
import AVKit

struct PreviewPlayerContent: View {
    let item: VideoItem
    let controller: PreviewPlayerController
    let showsPlaybackControls: Bool
    let togglePlaybackControls: () -> Void
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
    @Binding var currentPlaybackTime: Double

    private var playerAspectRatio: CGFloat {
        if let ratio = item.videoDisplayAspectRatio, ratio.isFinite, ratio > 0 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }

    var body: some View {
        Group {
            if let player = controller.player {
                ZStack {
                    CheckerboardBackground()

                    HStack {
                        if let stillImage = controller.fallbackStillImage,
                           let previewRange = controller.fallbackPreviewRange,
                           !previewRange.contains(currentPlaybackTime),
                           !controller.isLoadingChunk {
                            Image(nsImage: stillImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            PlayerContainerView(
                                player: player,
                                controller: controller,
                                showsPlaybackControls: showsPlaybackControls,
                                keyHandler: keyHandler
                            )
                        }
                    }
                    .aspectRatio(playerAspectRatio, contentMode: .fit)

                    overlayIndicators
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
            } else if controller.isPreparing {
                VStack(spacing: 12) {
                    ProgressView().progressViewStyle(.circular)
                    Text("Preparing preview…")
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
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
            } else {
                Text("Preview not available")
                    .foregroundColor(.white.opacity(0.8))
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var overlayIndicators: some View {
        if controller.isCapturingScreenshot {
            dimOverlay(title: "Capturing Still…")
        }

        if controller.isGeneratingFallbackPreview {
            dimOverlay(
                title: "Generating Preview…",
                subtitle: "This format requires transcoding for playback"
            )
        }

        if controller.fallbackPreviewRange != nil && !controller.isGeneratingFallbackPreview {
            VStack {
                Spacer()
                HStack {
                    fallbackBadge
                    Spacer()
                    toggleControlsButton
                }
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

    private var fallbackBadge: some View {
        HStack {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 11, weight: .medium))
            Text("Low Quality Preview")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .help("Unsupported format. Low quality preview files are generated.")
        .padding(12)
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
    }

    final class Coordinator: NSObject {
        private var monitor: Any?
        var showsPlaybackControls: Bool = false
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
        }

        @MainActor
        func attach(to playerView: AVPlayerView, controller: PreviewPlayerController) {
            playerView.player = controller.player
            controller.playerView = playerView

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
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
