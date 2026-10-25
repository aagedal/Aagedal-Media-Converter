// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit

// Workaround for MoltenVK problems - matches MPVKit demo
// https://github.com/mpv-player/mpv/pull/13651
class MPVMetalLayer: CAMetalLayer {

    /// When true, drawableSize changes are coalesced and deferred to the next
    /// run loop iteration. This prevents a race condition during resize where
    /// MoltenVK's in-flight render pass references the new renderTarget
    /// dimensions while still holding a drawable allocated at the old size.
    /// Set to true after MPV's Vulkan pipeline is initialized.
    var deferResizes = false

    /// Called with the new size after a deferred drawable resize lands, so
    /// mpv can resize its swapchain (it only polls the size while running).
    var onDrawableResize: ((CGSize) -> Void)?

    private var pendingSize: CGSize = .zero
    private var hasPendingResize = false

    override init() {
        super.init()
        configureForHDR()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        configureForHDR()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureForHDR()
    }

    private func configureForHDR() {
        // Enable Extended Dynamic Range (EDR) for HDR content on macOS
        // This allows HDR content to display correctly on HDR-capable displays
        wantsExtendedDynamicRangeContent = true

        // Note: We intentionally don't change pixelFormat or colorspace here
        // because MoltenVK/Vulkan manages these when creating the swapchain.
        // Changing them can cause render target size mismatches during resize.
        // The target-colorspace-hint=yes option in MPVPlayer handles HDR passthrough.
    }

    /// Apply the drawable size directly to the superclass, bypassing deferral.
    private func applyDrawableSize(_ size: CGSize) {
        super.drawableSize = size
    }

    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            // Workaround for MoltenVK setting drawableSize to 1x1 to forcefully
            // complete presentation, which causes flicker
            guard Int(newValue.width) > 1 && Int(newValue.height) > 1 else { return }

            guard deferResizes else {
                super.drawableSize = newValue
                return
            }

            // Skip if the size hasn't meaningfully changed
            let current = super.drawableSize
            guard abs(current.width - newValue.width) > 1 ||
                  abs(current.height - newValue.height) > 1 else { return }

            // Store the latest requested size. Multiple calls (from auto-resize
            // and explicit sets) are coalesced — only the last value is applied.
            pendingSize = newValue

            if !hasPendingResize {
                hasPendingResize = true
                // Schedule on the next run loop iteration via NSObject.perform.
                // This avoids Sendable capture issues with DispatchQueue closures
                // and ensures the current MoltenVK render pass completes first.
                perform(#selector(applyPendingResize), with: nil, afterDelay: 0)
            }
        }
    }

    @objc private func applyPendingResize() {
        hasPendingResize = false
        applyDrawableSize(pendingSize)
        setNeedsDisplay()
        onDrawableResize?(pendingSize)
    }
}
