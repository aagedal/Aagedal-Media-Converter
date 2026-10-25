// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Thin playhead scrubber with in/out markers and the trim region, in the style
/// of Aagedal Media Player. Shared by the fullscreen player and the download
/// clip picker. Dragging seeks; holding Option scrubs finely. With trim
/// callbacks the in and out handles always show (at the ends when unset) and
/// can be dragged.
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
    /// Called while the in handle is dragged; nil keeps the markers fixed.
    var onTrimStartDrag: ((Double) -> Void)? = nil
    var onTrimEndDrag: ((Double) -> Void)? = nil

    private enum DragTarget { case playhead, trimStart, trimEnd }
    /// Pointer distance at which a press grabs a trim handle.
    private static let handleGrabDistance: CGFloat = 8

    @State private var dragTarget: DragTarget?
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
            let editable = onTrimStartDrag != nil || onTrimEndDrag != nil

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

                if trimStart != nil || editable {
                    trimHandle(editable: editable, x: trimInFrac * width, width: width)
                }

                if trimEnd != nil || editable {
                    trimHandle(editable: editable, x: trimOutFrac * width, width: width)
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
                            dragTarget = target(at: value.startLocation.x, inX: trimInFrac * width,
                                                outX: trimOutFrac * width)
                            onScrubBegan()
                        }
                        drag(to: targetFraction(for: value.location.x, width: width, tracking: true) * duration)
                    }
                    .onEnded { value in
                        drag(to: targetFraction(for: value.location.x, width: width, tracking: false) * duration)
                        onScrubEnded()
                        isDragging = false
                        precisionWasActive = false
                        dragTarget = nil
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

    private func trimHandle(editable: Bool, x: CGFloat, width: CGFloat) -> some View {
        let handleWidth: CGFloat = editable ? 4 : 2
        return RoundedRectangle(cornerRadius: editable ? 1 : 0)
            .fill(Color.blue.opacity(0.8))
            .frame(width: handleWidth, height: editable ? 18 : 14)
            .offset(x: max(0, min(width - handleWidth, x - handleWidth / 2)))
    }

    /// A press on a trim handle moves it; anywhere else moves the playhead.
    /// When the handles meet, the side of the press picks one.
    private func target(at x: CGFloat, inX: CGFloat, outX: CGFloat) -> DragTarget {
        let inDistance = onTrimStartDrag == nil ? .infinity : abs(x - inX)
        let outDistance = onTrimEndDrag == nil ? .infinity : abs(x - outX)
        guard min(inDistance, outDistance) <= Self.handleGrabDistance else { return .playhead }
        if inDistance == outDistance { return x < inX ? .trimStart : .trimEnd }
        return inDistance < outDistance ? .trimStart : .trimEnd
    }

    /// Handles also seek so the frame at the new point shows.
    private func drag(to time: Double) {
        switch dragTarget ?? .playhead {
        case .playhead: break
        case .trimStart: onTrimStartDrag?(time)
        case .trimEnd: onTrimEndDrag?(time)
        }
        onSeek(time)
    }

    /// Absolute position under the pointer, or a scaled-down offset from where
    /// Option was first held while it stays held.
    private func targetFraction(for x: CGFloat, width: CGFloat, tracking: Bool) -> Double {
        let width = max(width, 1)
        if tracking {
            if NSEvent.modifierFlags.contains(.option) {
                if !precisionWasActive {
                    let anchorTime: Double = switch dragTarget ?? .playhead {
                    case .playhead: playbackTime
                    case .trimStart: trimStart ?? 0
                    case .trimEnd: trimEnd ?? duration
                    }
                    precisionAnchorFraction = duration > 0 ? anchorTime / duration : 0
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
