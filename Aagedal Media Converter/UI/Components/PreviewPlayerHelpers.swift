// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helper views and styles used by PreviewPlayerView and the fullscreen player.

import SwiftUI
import AVKit

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct CheckerboardBackground: View {
    private let squareSize: CGFloat = 24
    private let lightColor = Color.white.opacity(0.14)
    private let darkColor = Color.white.opacity(0.06)

    var body: some View {
        Canvas { context, size in
            guard squareSize > 0 else { return }

            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for row in 0..<rows {
                for column in 0..<columns {
                    let origin = CGPoint(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize
                    )
                    let rect = CGRect(
                        origin: origin,
                        size: CGSize(
                            width: min(squareSize, size.width - origin.x),
                            height: min(squareSize, size.height - origin.y)
                        )
                    )

                    let color = ((row + column).isMultiple(of: 2) ? lightColor : darkColor)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
    }
}

/// AVPlayerView that lets video with an alpha channel (e.g. ProRes 4444) show the
/// checkerboard behind it. AVPlayerView paints black behind its internal AVPlayerLayer,
/// so transparent areas would otherwise render black.
final class TransparentAVPlayerView: AVPlayerView {
    var showsTransparency = false {
        didSet { if showsTransparency != oldValue { restartBackdropClearing() } }
    }

    override var player: AVPlayer? {
        didSet { if player !== oldValue { restartBackdropClearing() } }
    }

    /// The player layer is created a moment after the player is attached, without a
    /// layout pass, so poll briefly for it (up to 2 seconds).
    private static let maxRetries = 40
    private var retriesLeft = maxRetries
    private var retryScheduled = false

    override func layout() {
        super.layout()
        // AVPlayerView rebuilds its internal views when the controls change, so clear on every layout.
        clearVideoBackdrop()
    }

    private func restartBackdropClearing() {
        retriesLeft = Self.maxRetries
        clearVideoBackdrop()
    }

    /// Clears the backgrounds between this view and the player layer; controls keep theirs.
    private func clearVideoBackdrop() {
        guard showsTransparency, let root = layer else { return }
        guard let videoLayer = Self.playerLayer(in: root) else {
            scheduleRetry()
            return
        }
        var current = videoLayer.superlayer
        while let layer = current {
            layer.backgroundColor = nil
            if layer === root { break }
            current = layer.superlayer
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled, retriesLeft > 0 else { return }
        retriesLeft -= 1
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.clearVideoBackdrop()
        }
    }

    private static func playerLayer(in layer: CALayer) -> AVPlayerLayer? {
        if let playerLayer = layer as? AVPlayerLayer { return playerLayer }
        for sublayer in layer.sublayers ?? [] {
            if let playerLayer = playerLayer(in: sublayer) { return playerLayer }
        }
        return nil
    }
}
