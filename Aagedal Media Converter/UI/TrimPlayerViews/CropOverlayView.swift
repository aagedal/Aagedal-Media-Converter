// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

/// Interactive crop overlay view that renders over the video player.
/// Drawing and pointer mapping live here; all crop geometry is delegated to `CropEditor`.
struct CropOverlayView: View {
    @Binding var cropConfig: CropConfig
    /// Shape of the displayed picture (width / height), including PAR and rotation.
    let displayAspectRatio: Double
    /// Display aspect ratio chosen in the crop panel; falls back to the config's own lock.
    var lockedAspectRatio: Double? = nil
    let isEnabled: Bool

    private enum DragState {
        case idle
        /// The drag started outside the crop box and is ignored until release.
        case ignored
        case active(handle: CropHandle, startRect: CropRect)
    }

    @State private var dragState: DragState = .idle
    /// Ratio captured when Shift is first held during a drag (free-form crops only).
    @State private var shiftLockedRatio: Double?
    @State private var isScalingFromCenter = false

    private var editor: CropEditor { CropEditor(displayAspectRatio: displayAspectRatio) }

    private var activeHandle: CropHandle? {
        if case .active(let handle, _) = dragState { return handle }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let videoFrame = calculateVideoFrame(in: geometry.size)
            let screenRect = normalizedToScreen(cropConfig.normalizedRect, videoFrame: videoFrame)

            ZStack {
                // Darkened overlay outside crop area
                cropDimOverlay(screenRect: screenRect)

                if isEnabled {
                    cropRectangleView(screenRect: screenRect)
                        .allowsHitTesting(false)

                    // Cursor feedback only; never intercepts events
                    CursorTrackingView(screenRect: screenRect, activeHandle: activeHandle)
                        .allowsHitTesting(false)

                    // Center crosshair while Option-scaling from the center
                    if isScalingFromCenter {
                        centerCrosshairView(screenRect: screenRect)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(screenRect: screenRect, videoFrame: videoFrame))
        }
        .allowsHitTesting(isEnabled)
    }

    // MARK: - Overlay Components

    private func cropDimOverlay(screenRect: CGRect) -> some View {
        // Creates darkened overlay with cutout for crop area
        Color.black.opacity(0.5)
            .mask(
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Rectangle()
                            .frame(width: screenRect.width, height: screenRect.height)
                            .position(x: screenRect.midX, y: screenRect.midY)
                            .blendMode(.destinationOut)
                    )
            )
    }

    private func cropRectangleView(screenRect: CGRect) -> some View {
        ZStack {
            // White border
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)

            // Rule of thirds grid
            ruleOfThirdsGrid(rect: screenRect)

            // Resize handles (8 total)
            resizeHandles(rect: screenRect)
        }
    }

    private func ruleOfThirdsGrid(rect: CGRect) -> some View {
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        return ZStack {
            // Vertical lines
            Path { path in
                path.move(to: CGPoint(x: rect.minX + thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + thirdWidth, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.maxY))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)

            // Horizontal lines
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + thirdHeight))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2 * thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2 * thirdHeight))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
    }

    private func centerCrosshairView(screenRect: CGRect) -> some View {
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let crosshairSize: CGFloat = 20

        return ZStack {
            // Horizontal line
            Path { path in
                path.move(to: CGPoint(x: center.x - crosshairSize, y: center.y))
                path.addLine(to: CGPoint(x: center.x + crosshairSize, y: center.y))
            }
            .stroke(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)

            // Vertical line
            Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - crosshairSize))
                path.addLine(to: CGPoint(x: center.x, y: center.y + crosshairSize))
            }
            .stroke(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)

            // Center dot
            Circle()
                .fill(Color.white)
                .frame(width: 4, height: 4)
                .position(center)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
        }
    }

    private func resizeHandles(rect: CGRect) -> some View {
        return Group {
            // Corner brackets (L-shaped)
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.minY), hDir: -1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.minY), hDir: 1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.maxY), hDir: -1, vDir: 1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.maxY), hDir: 1, vDir: 1, in: rect)

            // Edge handles (small rectangles)
            edgeHandle(at: CGPoint(x: rect.midX, y: rect.minY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.midX, y: rect.maxY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.minX, y: rect.midY), isVertical: true)
            edgeHandle(at: CGPoint(x: rect.maxX, y: rect.midY), isVertical: true)
        }
    }

    private func cornerBracket(at corner: CGPoint, hDir: Double, vDir: Double, in rect: CGRect) -> some View {
        let armLength = min(16.0, min(rect.width, rect.height) * 0.15)

        // Arm endpoints extending inward from the corner
        let hPoint = CGPoint(x: corner.x - hDir * armLength, y: corner.y)
        let vPoint = CGPoint(x: corner.x, y: corner.y - vDir * armLength)

        return Path { path in
            path.move(to: hPoint)
            path.addLine(to: corner)
            path.addLine(to: vPoint)
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
    }

    private func edgeHandle(at point: CGPoint, isVertical: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(
                width: isVertical ? 4 : 24,
                height: isVertical ? 24 : 4
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.5), lineWidth: 0.5)
            )
            .position(point)
    }

    // MARK: - Gesture Handling

    private func dragGesture(screenRect: CGRect, videoFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value: value, screenRect: screenRect, videoFrame: videoFrame)
            }
            .onEnded { _ in
                dragState = .idle
                shiftLockedRatio = nil
                isScalingFromCenter = false
            }
    }

    private func handleDragChanged(value: DragGesture.Value, screenRect: CGRect, videoFrame: CGRect) {
        if case .idle = dragState {
            guard let handle = CropHandle.hitTest(value.startLocation, in: screenRect) else {
                dragState = .ignored
                return
            }
            dragState = .active(handle: handle, startRect: cropConfig.normalizedRect)
        }
        guard case .active(let handle, let startRect) = dragState,
              videoFrame.width > 0, videoFrame.height > 0 else { return }

        // Modifiers are read live so keys held before the click count too.
        let flags = NSEvent.modifierFlags
        let fromCenter = flags.contains(.option) && handle != .move
        isScalingFromCenter = fromCenter

        // A configured lock wins; otherwise Shift holds the box's ratio from when it was pressed.
        let aspectRatio: Double?
        if let locked = lockedAspectRatio ?? cropConfig.aspectRatioLock?.numericRatio {
            aspectRatio = locked
        } else if flags.contains(.shift) {
            let ratio = shiftLockedRatio ?? editor.displayAspectRatio(of: cropConfig.normalizedRect)
            shiftLockedRatio = ratio
            aspectRatio = ratio
        } else {
            shiftLockedRatio = nil
            aspectRatio = nil
        }

        let delta = CGSize(
            width: value.translation.width / videoFrame.width,
            height: value.translation.height / videoFrame.height
        )
        cropConfig.normalizedRect = editor.resized(
            startRect, handle: handle, by: delta, fromCenter: fromCenter, aspectRatio: aspectRatio
        )
    }

    // MARK: - Coordinate Mapping

    /// Calculates the rect where video actually renders (accounting for letterbox/pillarbox)
    private func calculateVideoFrame(in playerSize: CGSize) -> CGRect {
        guard playerSize.width > 0, playerSize.height > 0 else { return .zero }
        let playerAspect = playerSize.width / playerSize.height

        if abs(displayAspectRatio - playerAspect) < 0.01 {
            return CGRect(origin: .zero, size: playerSize)
        }

        if displayAspectRatio > playerAspect {
            // Video is wider: letterbox top/bottom
            let videoHeight = playerSize.width / displayAspectRatio
            let offsetY = (playerSize.height - videoHeight) / 2
            return CGRect(x: 0, y: offsetY, width: playerSize.width, height: videoHeight)
        } else {
            // Video is taller: pillarbox left/right
            let videoWidth = playerSize.height * displayAspectRatio
            let offsetX = (playerSize.width - videoWidth) / 2
            return CGRect(x: offsetX, y: 0, width: videoWidth, height: playerSize.height)
        }
    }

    /// Maps the normalized crop rect onto the displayed video.
    ///
    /// Normalized coordinates are fractions of the stored pixel grid. Pixel-aspect stretching is
    /// uniform across the frame, so those fractions are also fractions of the displayed picture:
    /// the box covers exactly the pixels FFmpeg will keep, for anamorphic sources too.
    private func normalizedToScreen(_ rect: CropRect, videoFrame: CGRect) -> CGRect {
        CGRect(
            x: videoFrame.origin.x + rect.x * videoFrame.width,
            y: videoFrame.origin.y + rect.y * videoFrame.height,
            width: rect.width * videoFrame.width,
            height: rect.height * videoFrame.height
        )
    }
}

// MARK: - CGPoint Extension

extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        sqrt(pow(x - point.x, 2) + pow(y - point.y, 2))
    }
}

// MARK: - Cursor Tracking

/// Sets the system cursor for the crop handle under the pointer, using the same hit test as the
/// drag gesture so the cursor always matches what a click will do.
private struct CursorTrackingView: NSViewRepresentable {
    let screenRect: CGRect
    let activeHandle: CropHandle?

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.screenRect = screenRect
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.screenRect = screenRect
        nsView.activeHandle = activeHandle
    }

    final class CursorTrackingNSView: NSView {
        var screenRect: CGRect = .zero
        var activeHandle: CropHandle? {
            didSet {
                if let activeHandle { Self.cursor(for: activeHandle, isDragging: true).set() }
            }
        }

        // Match SwiftUI's top-left origin so `screenRect` can be compared directly.
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseMoved(with event: NSEvent) {
            guard activeHandle == nil else { return }
            let location = convert(event.locationInWindow, from: nil)
            if let handle = CropHandle.hitTest(location, in: screenRect) {
                Self.cursor(for: handle, isDragging: false).set()
            } else {
                NSCursor.arrow.set()
            }
        }

        override func mouseExited(with event: NSEvent) {
            guard activeHandle == nil else { return }
            NSCursor.arrow.set()
        }

        static func cursor(for handle: CropHandle, isDragging: Bool) -> NSCursor {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .move: return isDragging ? .closedHand : .openHand
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
    }
}
