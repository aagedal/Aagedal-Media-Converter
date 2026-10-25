// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Thin playhead scrubber with in/out markers and the trim region, in the style
/// of Aagedal Media Player. Shared by the fullscreen player and the download
/// clip picker. Dragging seeks; holding Option scrubs finely.
struct PlayheadTrimTimeline: View {
    let duration: Double
    let playbackTime: Double
    let trimStart: Double?
    let trimEnd: Double?
    var trackColor: Color = Color.white.opacity(0.3)
    @Binding var isDragging: Bool
    /// Spoken position for the accessibility slider.
    let accessibilityValue: String
    let accessibilityIdentifier: String
    let onScrubBegan: () -> Void
    let onSeek: (Double) -> Void
    let onScrubEnded: () -> Void

    @State private var precisionWasActive = false
    @State private var precisionAnchorFraction: Double = 0
    @State private var precisionAnchorX: CGFloat = 0
    @AppStorage("precisionScrubFactor") private var precisionScrubFactor: Double = 10.0

    private static let playheadColor = Color(red: 1.0, green: 0.071, blue: 0.361) // #FF125C

    var body: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? playbackTime / duration : 0
            let width = geo.size.width
            let trimInFrac: CGFloat = duration > 0 ? CGFloat((trimStart ?? 0) / duration) : 0
            let trimOutFrac: CGFloat = duration > 0 ? CGFloat((trimEnd ?? duration) / duration) : 1
            let hasTrim = trimStart != nil || trimEnd != nil

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                    .frame(height: 4)

                if duration > 0 && hasTrim {
                    Rectangle()
                        .fill(Color.blue.opacity(0.25))
                        .frame(width: max(0, (trimOutFrac - trimInFrac) * width), height: 6)
                        .offset(x: trimInFrac * width)
                }

                if trimStart != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, min(width - 2, trimInFrac * width - 1)))
                }

                if trimEnd != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, min(width - 2, trimOutFrac * width - 1)))
                }

                Rectangle()
                    .fill(Self.playheadColor)
                    .frame(width: 2, height: 14)
                    .offset(x: max(0, min(width - 2, width * CGFloat(progress) - 1)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            precisionWasActive = false
                            onScrubBegan()
                        }
                        onSeek(targetFraction(for: value.location.x, width: width, tracking: true) * duration)
                    }
                    .onEnded { value in
                        onSeek(targetFraction(for: value.location.x, width: width, tracking: false) * duration)
                        onScrubEnded()
                        isDragging = false
                        precisionWasActive = false
                    }
            )
        }
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { min(max(0, playbackTime), max(0, duration)) },
                    set: { onSeek($0) }
                ),
                in: 0...max(duration, 0.001),
                step: 1
            ) {
                Text("Playback position")
            }
            .disabled(duration <= 0)
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    /// Absolute position under the pointer, or a scaled-down offset from where
    /// Option was first held while it stays held.
    private func targetFraction(for x: CGFloat, width: CGFloat, tracking: Bool) -> Double {
        let width = max(width, 1)
        if tracking {
            if NSEvent.modifierFlags.contains(.option) {
                if !precisionWasActive {
                    precisionAnchorFraction = duration > 0 ? playbackTime / duration : 0
                    precisionAnchorX = x
                    precisionWasActive = true
                }
            } else {
                precisionWasActive = false
            }
        }
        guard precisionWasActive else { return max(0, min(1, Double(x / width))) }
        let delta = (x - precisionAnchorX) / width
        return max(0, min(1, precisionAnchorFraction + Double(delta) / precisionScrubFactor))
    }
}
