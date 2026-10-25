// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - View Controller (matches MPVKit demo pattern)

final class MPVViewController: NSViewController {
    let player: MPVPlayer
    /// Renders at a fixed size with this aspect ratio and scales the layer to
    /// the view instead of resizing mpv's surface. mpv's MoltenVK context only
    /// adopts a new surface size when the video is reconfigured, so a resized
    /// view otherwise shows a paused frame at its old size in a corner.
    let fixedRenderAspect: CGFloat?
    private var metalLayer: MPVMetalLayer!

    /// Width in points of the fixed render surface; previews are ≤720p.
    private static let fixedRenderWidth: CGFloat = 1280

    init(player: MPVPlayer, fixedRenderAspect: CGFloat? = nil) {
        self.player = player
        self.fixedRenderAspect = fixedRenderAspect.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Create the view - matches demo's loadView
        self.view = NSView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create and configure Metal layer - matches demo's viewDidLoad
        metalLayer = MPVMetalLayer()
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        if let aspect = fixedRenderAspect {
            let scale = metalLayer.contentsScale
            // Even pixel dimensions, as in viewDidLayout.
            let pixels = CGSize(width: floor(Self.fixedRenderWidth * scale / 2) * 2,
                                height: floor(Self.fixedRenderWidth / aspect * scale / 2) * 2)
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            view.layer = host
            metalLayer.bounds = CGRect(x: 0, y: 0, width: pixels.width / scale, height: pixels.height / scale)
            metalLayer.drawableSize = pixels
            host.addSublayer(metalLayer)
        } else {
            view.layer = metalLayer
        }

        // Initialize MPV with the layer - this is where the demo calls setupMpv()
        player.attachDrawable(metalLayer)

        // After MPV's Vulkan pipeline is up, defer all future drawableSize changes
        // to avoid racing with MoltenVK's in-flight render passes during resize.
        metalLayer.deferResizes = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        if fixedRenderAspect != nil {
            // Scale the fixed surface to fit; mpv never sees a size change.
            let bounds = view.bounds
            let size = metalLayer.bounds.size
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            metalLayer.setAffineTransform(CGAffineTransform(scaleX: fit, y: fit))
            CATransaction.commit()
            return
        }

        // Handle resize - matches demo's viewDidLayout
        guard let window = view.window else { return }

        let scale = window.screen?.backingScaleFactor ?? 2.0
        let layerSize = view.bounds.size

        // Floor to even pixel dimensions. A drawable slightly smaller than the
        // layer's frame gets imperceptibly stretched to fill, which eliminates
        // the black sub-pixel border that appears when MPV's aspect-ratio
        // enforcement leaves 1-2px of the drawable unfilled.
        let newDrawableSize = CGSize(
            width: floor(layerSize.width * scale / 2) * 2,
            height: floor(layerSize.height * scale / 2) * 2
        )

        // Constrain the layer frame to match the floored drawable dimensions
        // in points. Without this, MoltenVK derives the Vulkan swapchain extent
        // from the layer's full bounds (e.g. 1012.5pt * 2 = 2025px), but the
        // drawable is only 2024px, causing a Metal validation crash:
        //   "renderTargetHeight (2025) must be <= minimum attachment height (2024)"
        // The sub-point difference (at most 1pt) is invisible; the view's black
        // background fills the gap.
        let constrainedSize = CGSize(
            width: newDrawableSize.width / scale,
            height: newDrawableSize.height / scale
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(origin: .zero, size: constrainedSize)
        CATransaction.commit()

        // Set our floor-to-even size (coalesced with any auto-resize; deferred by MPVMetalLayer)
        metalLayer.drawableSize = newDrawableSize
    }
}

// MARK: - SwiftUI Wrapper (NSViewControllerRepresentable like demo)

struct MPVVideoView: NSViewControllerRepresentable {
    let player: MPVPlayer
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSViewController(context: Context) -> MPVViewController {
        let viewController = MPVViewController(player: player)
        context.coordinator.viewController = viewController
        return viewController
    }

    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        context.coordinator.viewController = nsViewController
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        private var monitor: Any?
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
        weak var viewController: MPVViewController?

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
            super.init()

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events if our window is the key window
                // This prevents capturing events when fullscreen player is open
                // NSEvent monitors always run on the main thread, so we can safely assume main actor isolation
                let isKeyWindow = MainActor.assumeIsolated {
                    self.viewController?.view.window?.isKeyWindow ?? false
                }
                guard isKeyWindow else {
                    return event
                }

                guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return event }

                // Process keyboard events - the handler decides if they should be handled
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
