// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct FullscreenMPVView: NSViewControllerRepresentable {
    let player: MPVPlayer
    /// See `MPVViewController.fixedRenderAspect`.
    var fixedRenderAspect: CGFloat? = nil

    func makeNSViewController(context: Context) -> MPVViewController {
        // Reuse the MPVViewController from MPVVideoView
        let viewController = MPVViewController(player: player, fixedRenderAspect: fixedRenderAspect)
        return viewController
    }

    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        // Handle updates if needed
    }
}
