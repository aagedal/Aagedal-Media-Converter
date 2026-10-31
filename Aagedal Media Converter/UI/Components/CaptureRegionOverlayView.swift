// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct CaptureRegionOverlayView: View {
    let screenSize: CGSize
    let displayScaleFactor: CGFloat
    let initialRegion: CGRect?
    let onRegionChanged: (CGRect) -> Void
    let onCancel: () -> Void

    private enum SelectionPhase {
        case drawing
        case refining
    }

    private enum DragMode {
        case none
        case draw
        case move
        case resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight
        case resizeTop, resizeBottom, resizeLeft, resizeRight
    }

    private static let aspectRatioStorageKey = "screenRecordingAspectRatio"

    private let minimumSize: CGFloat = 64
    private let handleHitSize: CGFloat = 20

    @State private var phase: SelectionPhase = .drawing
    @State private var selectionRect: CGRect? = nil
    @State private var isDragging = false
    @State private var dragMode: DragMode = .none
    @State private var dragStartPoint: CGPoint? = nil
    @State private var dragStartRect: CGRect? = nil

    // Modifier state, kept in sync by RegionModifierKeyView (NSView local event monitor)
    @State private var isShiftHeld = false
    @State private var isOptionHeld = false
    @State private var isSpaceHeld = false

    // Space-to-move tracking
    @State private var spacePressCursor: CGPoint? = nil
    @State private var dragStartPointAtSpacePress: CGPoint? = nil

    // Shift-axis-lock snapshot: captured when Shift is pressed mid-drag so the locked
    // axis stays at the dimension it had at that moment, instead of collapsing to a line.
    @State private var shiftPressedRect: CGRect? = nil

    // For replaying the last drag value when a modifier flips mid-drag
    @State private var lastDragLocation: CGPoint? = nil
    @State private var lastDragTranslation: CGSize? = nil

    // Aspect ratio lock, persisted across launches
    @AppStorage(CaptureRegionOverlayView.aspectRatioStorageKey)
    private var lockedAspectRatioRaw: String = AspectRatio.free.rawValue

    private var lockedAspectRatio: AspectRatio {
        AspectRatio(rawValue: lockedAspectRatioRaw) ?? .free
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Cursor tracking layer — must be behind everything but cover the full area
                CaptureRegionCursorView(
                    selectionRect: selectionRect,
                    phase: phase == .refining,
                    handleHitSize: handleHitSize,
                    isDragging: isDragging,
                    dragMode: dragModeForCursor,
                    onEscape: { onCancel() }
                )

                dimOverlay(in: geometry.size)

                if let rect = selectionRect {
                    selectionRectangleView(rect: rect)
                }

                if phase == .drawing, selectionRect == nil {
                    crosshairOverlay
                }

                // Center crosshair when Option is held mid-drag
                if isOptionHeld, isDragging, let rect = selectionRect {
                    centerCrosshair(for: rect)
                }
            }
            .contentShape(Rectangle())
            .gesture(mainDragGesture(in: geometry.size))
            .onAppear {
                if let initialRegion {
                    // The saved region may come from a different (larger) display, e.g. after
                    // switching the capture display — keep it on this screen and persist the fix
                    // so the recording's source rect stays inside the display.
                    let clamped = clampToScreen(initialRegion, in: screenSize, ratio: nil)
                    selectionRect = clamped
                    phase = .refining
                    if clamped != initialRegion {
                        onRegionChanged(clamped)
                    }
                }
            }
            .onChange(of: isShiftHeld) { _, newValue in
                handleShiftTransition(isHeld: newValue)
            }
            .onChange(of: isOptionHeld) { _, _ in
                replayDragForModifierChange()
            }
            .onChange(of: isSpaceHeld) { _, newValue in
                handleSpaceTransition(isHeld: newValue)
            }
            .onChange(of: lockedAspectRatioRaw) { _, _ in
                handleAspectRatioMenuChange()
            }
        }
        .ignoresSafeArea()
        .background(
            RegionModifierKeyView(
                isShiftHeld: $isShiftHeld,
                isOptionHeld: $isOptionHeld,
                isSpaceHeld: $isSpaceHeld
            )
        )
    }

    /// Maps internal DragMode to a cursor-friendly integer for the NSView
    private var dragModeForCursor: Int {
        switch dragMode {
        case .none: return 0
        case .draw: return 1
        case .move: return 2
        case .resizeTopLeft: return 3
        case .resizeTopRight: return 4
        case .resizeBottomLeft: return 5
        case .resizeBottomRight: return 6
        case .resizeTop: return 7
        case .resizeBottom: return 8
        case .resizeLeft: return 9
        case .resizeRight: return 10
        }
    }

    // MARK: - Overlay Components

    private func dimOverlay(in size: CGSize) -> some View {
        Color.black.opacity(0.4)
            .frame(width: size.width, height: size.height)
            .mask(
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Group {
                            if let rect = selectionRect {
                                Rectangle()
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blendMode(.destinationOut)
                            }
                        }
                    )
            )
            .allowsHitTesting(false)
    }

    private var crosshairOverlay: some View {
        ZStack {
            Text("Click and drag to select a recording region")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 4)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func selectionRectangleView(rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if phase == .refining {
                ruleOfThirdsGrid(rect: rect)
                resizeHandles(rect: rect)
            }

            dimensionLabel(for: rect)

            // Aspect-ratio badge (only when locked)
            if lockedAspectRatio != .free {
                aspectRatioBadge(for: rect)
            }
        }
        .allowsHitTesting(false)
    }

    private func ruleOfThirdsGrid(rect: CGRect) -> some View {
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: rect.minX + thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + thirdWidth, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.maxY))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)

            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + thirdHeight))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2 * thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2 * thirdHeight))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
    }

    private func resizeHandles(rect: CGRect) -> some View {
        Group {
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.minY), hDir: -1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.minY), hDir: 1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.maxY), hDir: -1, vDir: 1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.maxY), hDir: 1, vDir: 1, in: rect)

            edgeHandle(at: CGPoint(x: rect.midX, y: rect.minY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.midX, y: rect.maxY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.minX, y: rect.midY), isVertical: true)
            edgeHandle(at: CGPoint(x: rect.maxX, y: rect.midY), isVertical: true)
        }
    }

    private func cornerBracket(at corner: CGPoint, hDir: Double, vDir: Double, in rect: CGRect) -> some View {
        let armLength = min(16.0, min(rect.width, rect.height) * 0.15)
        let hPoint = CGPoint(x: corner.x - hDir * armLength, y: corner.y)
        let vPoint = CGPoint(x: corner.x, y: corner.y - vDir * armLength)

        return ZStack {
            Path { path in
                path.move(to: hPoint)
                path.addLine(to: corner)
                path.addLine(to: vPoint)
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))

            Circle()
                .fill(Color.clear)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .position(corner)
        }
    }

    private func edgeHandle(at point: CGPoint, isVertical: Bool) -> some View {
        ZStack {
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

            Rectangle()
                .fill(Color.clear)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .position(point)
    }

    private func dimensionLabel(for rect: CGRect) -> some View {
        let pixelW = Int(rect.width * displayScaleFactor)
        let pixelH = Int(rect.height * displayScaleFactor)
        let evenW = (pixelW / 2) * 2
        let evenH = (pixelH / 2) * 2

        return Text("\(Int(rect.width)) \u{00D7} \(Int(rect.height)) pts \u{2022} \(evenW) \u{00D7} \(evenH) px")
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: rect.midX, y: rect.maxY + 24)
    }

    private func aspectRatioBadge(for rect: CGRect) -> some View {
        Text(lockedAspectRatio.displayName)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.9))
            .clipShape(Capsule())
            .position(x: rect.midX, y: rect.minY - 18)
    }

    private func centerCrosshair(for rect: CGRect) -> some View {
        let arm: CGFloat = 8
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: rect.midX - arm, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY))
                path.move(to: CGPoint(x: rect.midX, y: rect.midY - arm))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + arm))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .shadow(color: .black.opacity(0.6), radius: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gesture Handling

    private func mainDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                handleDragChanged(value: value, in: size)
            }
            .onEnded { _ in
                handleDragEnded()
            }
    }

    private func handleDragChanged(value: DragGesture.Value, in size: CGSize) {
        if !isDragging {
            isDragging = true
            dragStartPoint = value.startLocation

            if phase == .drawing {
                dragMode = .draw
                dragStartRect = nil
            } else if let rect = selectionRect {
                dragStartRect = rect
                dragMode = determineDragMode(location: value.startLocation, rect: rect)
                if dragMode == .none {
                    dragMode = .draw
                    phase = .drawing
                    dragStartRect = nil
                }
            }

            // If Space was already held when the drag started, prime the move state
            if isSpaceHeld {
                spacePressCursor = value.location
                dragStartPointAtSpacePress = dragStartPoint
            }
        }

        // Save for replay when a modifier flips without mouse motion
        lastDragLocation = value.location
        lastDragTranslation = value.translation

        applyDragPipeline(location: value.location, translation: value.translation, in: size)
    }

    private func applyDragPipeline(location: CGPoint, translation: CGSize, in size: CGSize) {
        // Space-to-move: shift dragStartPoint by the cursor delta since Space was pressed
        if isSpaceHeld,
           let pressCursor = spacePressCursor,
           let startAtPress = dragStartPointAtSpacePress {
            dragStartPoint = CGPoint(
                x: startAtPress.x + (location.x - pressCursor.x),
                y: startAtPress.y + (location.y - pressCursor.y)
            )
        }

        // Step 1: candidate rect from drag mode geometry (Option center-scaling handled inline)
        var rect = computeCandidateRect(location: location, translation: translation)

        // Step 2: aspect ratio lock OR Shift axis lock (ratio wins)
        let ratioCG: CGFloat? = lockedAspectRatio.numericRatio.map { CGFloat($0) }
        if let ratio = ratioCG, dragMode != .move, dragMode != .none {
            rect = applyAspectRatioConstraint(rect, ratio: ratio)
        } else if isShiftHeld, !isSpaceHeld, supportsShiftAxisLock(dragMode) {
            rect = applyShiftAxisLock(rect, translation: translation)
        }

        // Step 3: clamp to screen
        rect = clampToScreen(rect, in: size, ratio: ratioCG)

        selectionRect = rect
    }

    private func computeCandidateRect(location: CGPoint, translation: CGSize) -> CGRect {
        guard let start = dragStartPoint else { return selectionRect ?? .zero }

        switch dragMode {
        case .draw:
            if isOptionHeld {
                let halfW = max(abs(location.x - start.x), 0.5)
                let halfH = max(abs(location.y - start.y), 0.5)
                return CGRect(
                    x: start.x - halfW,
                    y: start.y - halfH,
                    width: halfW * 2,
                    height: halfH * 2
                )
            } else {
                let x = min(start.x, location.x)
                let y = min(start.y, location.y)
                let w = max(abs(location.x - start.x), 1)
                let h = max(abs(location.y - start.y), 1)
                return CGRect(x: x, y: y, width: w, height: h)
            }

        case .move:
            guard let startRect = dragStartRect else { return selectionRect ?? .zero }
            return CGRect(
                x: startRect.origin.x + translation.width,
                y: startRect.origin.y + translation.height,
                width: startRect.width,
                height: startRect.height
            )

        case .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight,
             .resizeTop, .resizeBottom, .resizeLeft, .resizeRight:
            return computeResizeRect(translation: translation)

        case .none:
            return selectionRect ?? .zero
        }
    }

    private func computeResizeRect(translation: CGSize) -> CGRect {
        guard let startRect = dragStartRect else { return selectionRect ?? .zero }
        let dx = translation.width
        let dy = translation.height
        let centerScale = isOptionHeld

        var newMinX = startRect.minX
        var newMaxX = startRect.maxX
        var newMinY = startRect.minY
        var newMaxY = startRect.maxY
        let cx = startRect.midX
        let cy = startRect.midY

        switch dragMode {
        case .resizeBottomRight:
            newMaxX += dx
            newMaxY += dy
            if centerScale {
                newMinX = 2 * cx - newMaxX
                newMinY = 2 * cy - newMaxY
            }
        case .resizeBottomLeft:
            newMinX += dx
            newMaxY += dy
            if centerScale {
                newMaxX = 2 * cx - newMinX
                newMinY = 2 * cy - newMaxY
            }
        case .resizeTopRight:
            newMaxX += dx
            newMinY += dy
            if centerScale {
                newMinX = 2 * cx - newMaxX
                newMaxY = 2 * cy - newMinY
            }
        case .resizeTopLeft:
            newMinX += dx
            newMinY += dy
            if centerScale {
                newMaxX = 2 * cx - newMinX
                newMaxY = 2 * cy - newMinY
            }
        case .resizeRight:
            newMaxX += dx
            if centerScale {
                newMinX = 2 * cx - newMaxX
            }
        case .resizeLeft:
            newMinX += dx
            if centerScale {
                newMaxX = 2 * cx - newMinX
            }
        case .resizeBottom:
            newMaxY += dy
            if centerScale {
                newMinY = 2 * cy - newMaxY
            }
        case .resizeTop:
            newMinY += dy
            if centerScale {
                newMaxY = 2 * cy - newMinY
            }
        default:
            break
        }

        // Normalize in case the drag inverted the rectangle
        let minX = min(newMinX, newMaxX)
        let maxX = max(newMinX, newMaxX)
        let minY = min(newMinY, newMaxY)
        let maxY = max(newMinY, newMaxY)

        return CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 1),
            height: max(maxY - minY, 1)
        )
    }

    // MARK: - Aspect Ratio Constraint

    private func applyAspectRatioConstraint(_ rect: CGRect, ratio: CGFloat) -> CGRect {
        // Edge resizes: dragged axis determines the other; perpendicular axis centers
        switch dragMode {
        case .resizeRight, .resizeLeft:
            let newH = rect.width / ratio
            let newY = rect.midY - newH / 2
            return CGRect(x: rect.minX, y: newY, width: rect.width, height: newH)
        case .resizeTop, .resizeBottom:
            let newW = rect.height * ratio
            let newX = rect.midX - newW / 2
            return CGRect(x: newX, y: rect.minY, width: newW, height: rect.height)
        default:
            break
        }

        let curW = rect.width
        let curH = rect.height
        let curRatio = curW / max(curH, 0.001)

        let newW: CGFloat
        let newH: CGFloat
        if curRatio > ratio {
            newH = curH
            newW = curH * ratio
        } else {
            newW = curW
            newH = curW / ratio
        }

        if isOptionHeld {
            let cx = rect.midX
            let cy = rect.midY
            return CGRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        }

        switch dragMode {
        case .draw:
            guard let start = dragStartPoint else { return rect }
            let newX = (start.x <= rect.midX) ? start.x : start.x - newW
            let newY = (start.y <= rect.midY) ? start.y : start.y - newH
            return CGRect(x: newX, y: newY, width: newW, height: newH)
        case .resizeBottomRight:
            return CGRect(x: rect.minX, y: rect.minY, width: newW, height: newH)
        case .resizeBottomLeft:
            return CGRect(x: rect.maxX - newW, y: rect.minY, width: newW, height: newH)
        case .resizeTopRight:
            return CGRect(x: rect.minX, y: rect.maxY - newH, width: newW, height: newH)
        case .resizeTopLeft:
            return CGRect(x: rect.maxX - newW, y: rect.maxY - newH, width: newW, height: newH)
        default:
            return rect
        }
    }

    // MARK: - Shift Axis Lock

    private func supportsShiftAxisLock(_ mode: DragMode) -> Bool {
        switch mode {
        case .draw, .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight:
            return true
        default:
            return false
        }
    }

    private func applyShiftAxisLock(_ rect: CGRect, translation: CGSize) -> CGRect {
        let horizontalDominant = abs(translation.width) >= abs(translation.height)

        switch dragMode {
        case .draw:
            // If Shift was pressed mid-drag, freeze the non-dominant axis at the size
            // and position it had at that moment.
            if let frozen = shiftPressedRect {
                if horizontalDominant {
                    return CGRect(x: rect.minX, y: frozen.minY, width: rect.width, height: frozen.height)
                } else {
                    return CGRect(x: frozen.minX, y: rect.minY, width: frozen.width, height: rect.height)
                }
            }

            // Shift held from the very start of the drag — collapse to a 1pt line so
            // the user can draw a perfectly horizontal/vertical guide.
            guard let start = dragStartPoint else { return rect }
            if horizontalDominant {
                if isOptionHeld {
                    return CGRect(x: rect.minX, y: start.y - 0.5, width: rect.width, height: 1)
                } else {
                    return CGRect(x: rect.minX, y: start.y, width: rect.width, height: 1)
                }
            } else {
                if isOptionHeld {
                    return CGRect(x: start.x - 0.5, y: rect.minY, width: 1, height: rect.height)
                } else {
                    return CGRect(x: start.x, y: rect.minY, width: 1, height: rect.height)
                }
            }

        case .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight:
            // Prefer the snapshot taken when Shift was pressed; fall back to the rect
            // the resize started from when Shift was held before the drag began.
            let basePreShift = shiftPressedRect ?? dragStartRect
            guard let base = basePreShift else { return rect }

            if horizontalDominant {
                return CGRect(
                    x: rect.minX,
                    y: base.minY,
                    width: rect.width,
                    height: base.height
                )
            } else {
                return CGRect(
                    x: base.minX,
                    y: rect.minY,
                    width: base.width,
                    height: rect.height
                )
            }

        default:
            return rect
        }
    }

    // MARK: - Clamping

    private func clampToScreen(_ rect: CGRect, in size: CGSize, ratio: CGFloat?) -> CGRect {
        var r = rect

        r.size.width = max(1, r.size.width)
        r.size.height = max(1, r.size.height)

        if let ratio {
            let maxWidthForScreen = size.width
            let maxHeightForScreen = size.height
            let widthIfBoundedByWidth = maxWidthForScreen
            let heightIfBoundedByWidth = widthIfBoundedByWidth / ratio
            let heightIfBoundedByHeight = maxHeightForScreen
            let widthIfBoundedByHeight = heightIfBoundedByHeight * ratio

            let maxW: CGFloat
            let maxH: CGFloat
            if heightIfBoundedByWidth <= maxHeightForScreen {
                maxW = widthIfBoundedByWidth
                maxH = heightIfBoundedByWidth
            } else {
                maxW = widthIfBoundedByHeight
                maxH = heightIfBoundedByHeight
            }

            if r.width > maxW || r.height > maxH {
                r.size = CGSize(width: maxW, height: maxH)
            }

            r.origin.x = max(0, min(size.width - r.width, r.origin.x))
            r.origin.y = max(0, min(size.height - r.height, r.origin.y))
        } else {
            r.size.width = min(r.size.width, size.width)
            r.size.height = min(r.size.height, size.height)
            r.origin.x = max(0, min(size.width - r.width, r.origin.x))
            r.origin.y = max(0, min(size.height - r.height, r.origin.y))
        }

        return r
    }

    // MARK: - Modifier Change Replay

    private func replayDragForModifierChange() {
        guard isDragging,
              let location = lastDragLocation,
              let translation = lastDragTranslation else { return }
        applyDragPipeline(location: location, translation: translation, in: screenSize)
    }

    private func handleShiftTransition(isHeld: Bool) {
        if isHeld {
            // Snapshot the current rect ONLY if a drag is already in progress with a
            // visible rectangle. Shift held before a drag begins keeps the original
            // "collapse to a line" behavior so users can intentionally draw a line.
            if isDragging, let rect = selectionRect, rect.width > 1, rect.height > 1 {
                shiftPressedRect = rect
            }
        } else {
            shiftPressedRect = nil
        }
        replayDragForModifierChange()
    }

    private func handleSpaceTransition(isHeld: Bool) {
        guard isDragging else { return }

        if isHeld {
            spacePressCursor = lastDragLocation
            dragStartPointAtSpacePress = dragStartPoint
        } else {
            if let pressCursor = spacePressCursor,
               let startAtPress = dragStartPointAtSpacePress,
               let location = lastDragLocation {
                dragStartPoint = CGPoint(
                    x: startAtPress.x + (location.x - pressCursor.x),
                    y: startAtPress.y + (location.y - pressCursor.y)
                )
            }
            spacePressCursor = nil
            dragStartPointAtSpacePress = nil
        }

        replayDragForModifierChange()
    }

    private func handleAspectRatioMenuChange() {
        if isDragging {
            replayDragForModifierChange()
        } else if let rect = selectionRect,
                  let ratio = lockedAspectRatio.numericRatio.map({ CGFloat($0) }) {
            var newRect = fitRect(rect, toRatio: ratio)
            newRect = clampToScreen(newRect, in: screenSize, ratio: ratio)
            selectionRect = newRect
            onRegionChanged(newRect)
        }
    }

    private func fitRect(_ rect: CGRect, toRatio ratio: CGFloat) -> CGRect {
        let curRatio = rect.width / max(rect.height, 0.001)
        let newW: CGFloat
        let newH: CGFloat
        if curRatio > ratio {
            newH = rect.height
            newW = rect.height * ratio
        } else {
            newW = rect.width
            newH = rect.width / ratio
        }
        let newX = rect.midX - newW / 2
        let newY = rect.midY - newH / 2
        return CGRect(x: newX, y: newY, width: newW, height: newH)
    }

    // MARK: - Drag End

    private func handleDragEnded() {
        isDragging = false

        if dragMode == .draw {
            if let rect = selectionRect, rect.width >= minimumSize, rect.height >= minimumSize {
                phase = .refining
                onRegionChanged(rect)
            } else if let rect = selectionRect, (rect.width < minimumSize || rect.height < minimumSize) {
                selectionRect = nil
                phase = .drawing
            }
        } else if let rect = selectionRect {
            if rect.width < minimumSize || rect.height < minimumSize, let startRect = dragStartRect {
                // A resize collapsed the region below the minimum size (down to 1 pt, which can
                // round to a 0-pixel-wide recording); restore the pre-drag region instead.
                selectionRect = startRect
                onRegionChanged(startRect)
            } else {
                onRegionChanged(rect)
            }
        }

        dragMode = .none
        dragStartPoint = nil
        dragStartRect = nil
        spacePressCursor = nil
        dragStartPointAtSpacePress = nil
        shiftPressedRect = nil
        lastDragLocation = nil
        lastDragTranslation = nil
    }

    private func determineDragMode(location: CGPoint, rect: CGRect) -> DragMode {
        if location.distance(to: CGPoint(x: rect.minX, y: rect.minY)) < handleHitSize {
            return .resizeTopLeft
        }
        if location.distance(to: CGPoint(x: rect.maxX, y: rect.minY)) < handleHitSize {
            return .resizeTopRight
        }
        if location.distance(to: CGPoint(x: rect.minX, y: rect.maxY)) < handleHitSize {
            return .resizeBottomLeft
        }
        if location.distance(to: CGPoint(x: rect.maxX, y: rect.maxY)) < handleHitSize {
            return .resizeBottomRight
        }

        if abs(location.y - rect.minY) < handleHitSize &&
           location.x > rect.minX + handleHitSize &&
           location.x < rect.maxX - handleHitSize {
            return .resizeTop
        }
        if abs(location.y - rect.maxY) < handleHitSize &&
           location.x > rect.minX + handleHitSize &&
           location.x < rect.maxX - handleHitSize {
            return .resizeBottom
        }
        if abs(location.x - rect.minX) < handleHitSize &&
           location.y > rect.minY + handleHitSize &&
           location.y < rect.maxY - handleHitSize {
            return .resizeLeft
        }
        if abs(location.x - rect.maxX) < handleHitSize &&
           location.y > rect.minY + handleHitSize &&
           location.y < rect.maxY - handleHitSize {
            return .resizeRight
        }

        if rect.contains(location) {
            return .move
        }

        return .none
    }
}

// MARK: - Modifier Key Tracking (Shift, Option, Space)

/// Installs a local NSEvent monitor for Shift/Option flags and Space key, and bridges them
/// to SwiftUI @State via @Binding. Coexists with CaptureOverlayWindowController's CMD monitor;
/// that one runs at the controller level for click-through, this one runs at the view level
/// for drag-modifier behaviors.
private struct RegionModifierKeyView: NSViewRepresentable {
    @Binding var isShiftHeld: Bool
    @Binding var isOptionHeld: Bool
    @Binding var isSpaceHeld: Bool

    func makeNSView(context: Context) -> ModifierKeyNSView {
        let view = ModifierKeyNSView()
        view.isShiftHeld = $isShiftHeld
        view.isOptionHeld = $isOptionHeld
        view.isSpaceHeld = $isSpaceHeld
        return view
    }

    func updateNSView(_ nsView: ModifierKeyNSView, context: Context) {
        nsView.isShiftHeld = $isShiftHeld
        nsView.isOptionHeld = $isOptionHeld
        nsView.isSpaceHeld = $isSpaceHeld
    }

    final class ModifierKeyNSView: NSView {
        var isShiftHeld: Binding<Bool>?
        var isOptionHeld: Binding<Bool>?
        var isSpaceHeld: Binding<Bool>?

        // `nonisolated(unsafe)` so `deinit` (a nonisolated context) can tear the monitors down.
        // All access happens on the main thread in practice (view lifecycle + main-thread dealloc).
        private nonisolated(unsafe) var localMonitor: Any?
        private nonisolated(unsafe) var globalMonitor: Any?

        // Pass through hit testing so gestures still flow to SwiftUI
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // Closing the overlay panel does not detach this view, so also tear the monitors
                // down when the window closes (e.g. when recording starts).
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(hostWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
                installMonitors()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            }
            if newWindow == nil {
                removeMonitors()
            }
        }

        @objc private func hostWindowWillClose(_ notification: Notification) {
            removeMonitors()
        }

        deinit {
            // NSEvent.removeMonitor must run on the main thread. The guaranteed teardown is
            // viewWillMove(toWindow: nil) (main-actor); this deinit is only a fallback. Skip it
            // if we're somehow off-main — the monitors' [weak self] closures no-op once self is
            // gone, so a leaked monitor is harmless, whereas an off-main removeMonitor is not.
            if Thread.isMainThread {
                removeMonitors()
            }
        }

        private func installMonitors() {
            // Local catches events that ARE delivered to this app's responder chain
            // (e.g. when our panel is key). Returning nil swallows the event.
            if localMonitor == nil {
                let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                    guard let self else { return event }
                    return self.handleLocal(event: event)
                }
            }
            // Global catches events going to OTHER apps. Because the capture overlay panel
            // is .nonactivatingPanel and the app is hidden, keystrokes typically flow to the
            // user's previously-active app — the global monitor is what makes Shift/Option/
            // Space track during a drag. Global monitors can only observe; they cannot
            // swallow the event from the underlying app.
            if globalMonitor == nil {
                let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                    _ = self?.handleLocal(event: event)
                }
            }
        }

        private nonisolated func removeMonitors() {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
                globalMonitor = nil
            }
        }

        @discardableResult
        private func handleLocal(event: NSEvent) -> NSEvent? {
            switch event.type {
            case .keyDown:
                if event.keyCode == 49 { // Space
                    if !event.isARepeat {
                        DispatchQueue.main.async { [weak self] in
                            self?.isSpaceHeld?.wrappedValue = true
                        }
                    }
                    return nil  // swallow so the system doesn't beep (local only)
                }
                return event
            case .keyUp:
                if event.keyCode == 49 {
                    DispatchQueue.main.async { [weak self] in
                        self?.isSpaceHeld?.wrappedValue = false
                    }
                    return nil
                }
                return event
            case .flagsChanged:
                let flags = event.modifierFlags
                DispatchQueue.main.async { [weak self] in
                    self?.isShiftHeld?.wrappedValue = flags.contains(.shift)
                    self?.isOptionHeld?.wrappedValue = flags.contains(.option)
                }
                return event
            default:
                return event
            }
        }
    }
}

// MARK: - Cursor Tracking + Key Event Handling

/// NSViewRepresentable that covers the full overlay area, manages cursor appearance
/// based on hover position relative to the selection rectangle, and handles key events.
private struct CaptureRegionCursorView: NSViewRepresentable {
    let selectionRect: CGRect?
    let phase: Bool              // true = refining
    let handleHitSize: CGFloat
    let isDragging: Bool
    let dragMode: Int            // mapped from DragMode enum
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.onEscape = onEscape
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.selectionRect = selectionRect
        nsView.isRefining = phase
        nsView.handleHitSize = handleHitSize
        nsView.currentDragging = isDragging
        nsView.currentDragMode = dragMode
        nsView.onEscape = onEscape
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    class CursorTrackingNSView: NSView {
        var selectionRect: CGRect?
        var isRefining = false
        var handleHitSize: CGFloat = 20
        var currentDragging = false
        var currentDragMode = 0
        var onEscape: (() -> Void)?

        private var keyEventMonitor: Any?
        private var mouseEventMonitor: Any?
        private var trackingArea: NSTrackingArea?

        // Pass through all hit testing so SwiftUI gestures work
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // Closing the overlay panel does not detach this view, so viewWillMove(toWindow: nil)
                // is not guaranteed. Without this, the Escape monitor would outlive the overlay and
                // keep swallowing Escape in the app's windows after recording.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(hostWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
                if keyEventMonitor == nil {
                    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        if event.keyCode == 53 { // Escape
                            self?.onEscape?()
                            return nil
                        }
                        return event
                    }
                }
                if mouseEventMonitor == nil {
                    mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                        guard let self else { return event }
                        if self.currentDragging {
                            self.cursorForDragMode(self.currentDragMode).set()
                        }
                        return event
                    }
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            }
            if newWindow == nil {
                removeMonitors()
            }
        }

        @objc private func hostWindowWillClose(_ notification: Notification) {
            removeMonitors()
            // The overlay set crosshair / resize cursors; restore the arrow so it doesn't linger.
            NSCursor.arrow.set()
        }

        private func removeMonitors() {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
            if let monitor = mouseEventMonitor {
                NSEvent.removeMonitor(monitor)
                mouseEventMonitor = nil
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseEntered(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        private func updateCursorForCurrentPosition(_ event: NSEvent) {
            if currentDragging {
                cursorForDragMode(currentDragMode).set()
                return
            }

            let locationInView = convert(event.locationInWindow, from: nil)
            // Flip Y: NSView has origin at bottom-left, but selection rect uses top-left (SwiftUI coords)
            let flippedY = bounds.height - locationInView.y
            let point = CGPoint(x: locationInView.x, y: flippedY)

            guard isRefining, let rect = selectionRect else {
                NSCursor.crosshair.set()
                return
            }

            let hitSize = handleHitSize

            // Check corners
            if point.distance(to: CGPoint(x: rect.minX, y: rect.minY)) < hitSize {
                cursorForDragMode(3).set() // topLeft
                return
            }
            if point.distance(to: CGPoint(x: rect.maxX, y: rect.minY)) < hitSize {
                cursorForDragMode(4).set() // topRight
                return
            }
            if point.distance(to: CGPoint(x: rect.minX, y: rect.maxY)) < hitSize {
                cursorForDragMode(5).set() // bottomLeft
                return
            }
            if point.distance(to: CGPoint(x: rect.maxX, y: rect.maxY)) < hitSize {
                cursorForDragMode(6).set() // bottomRight
                return
            }

            // Check edges
            if abs(point.y - rect.minY) < hitSize &&
               point.x > rect.minX + hitSize && point.x < rect.maxX - hitSize {
                cursorForDragMode(7).set() // top
                return
            }
            if abs(point.y - rect.maxY) < hitSize &&
               point.x > rect.minX + hitSize && point.x < rect.maxX - hitSize {
                cursorForDragMode(8).set() // bottom
                return
            }
            if abs(point.x - rect.minX) < hitSize &&
               point.y > rect.minY + hitSize && point.y < rect.maxY - hitSize {
                cursorForDragMode(9).set() // left
                return
            }
            if abs(point.x - rect.maxX) < hitSize &&
               point.y > rect.minY + hitSize && point.y < rect.maxY - hitSize {
                cursorForDragMode(10).set() // right
                return
            }

            // Inside selection
            if rect.contains(point) {
                NSCursor.openHand.set()
                return
            }

            // Outside selection
            NSCursor.crosshair.set()
        }

        /// Maps drag mode int to the appropriate NSCursor
        private func cursorForDragMode(_ mode: Int) -> NSCursor {
            switch mode {
            case 1:  return .crosshair                          // draw
            case 2:  return .closedHand                         // move
            case 3:  return Self.diagonalResizeCursor(nwse: true)  // topLeft
            case 4:  return Self.diagonalResizeCursor(nwse: false) // topRight
            case 5:  return Self.diagonalResizeCursor(nwse: false) // bottomLeft
            case 6:  return Self.diagonalResizeCursor(nwse: true)  // bottomRight
            case 7:  return .resizeUpDown                       // top
            case 8:  return .resizeUpDown                       // bottom
            case 9:  return .resizeLeftRight                    // left
            case 10: return .resizeLeftRight                    // right
            default: return .crosshair
            }
        }

        /// Creates a diagonal resize cursor (NW-SE or NE-SW).
        /// macOS doesn't provide diagonal cursors by default, so we create them from SF Symbols.
        private static func diagonalResizeCursor(nwse: Bool) -> NSCursor {
            let symbolName = nwse
                ? "arrow.up.left.and.arrow.down.right"
                : "arrow.up.right.and.arrow.down.left"
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage

                // Render with white fill and black stroke for visibility
                let size = NSSize(width: 20, height: 20)
                let rendered = NSImage(size: size, flipped: false) { rect in
                    // Draw shadow
                    NSColor.black.withAlphaComponent(0.6).set()
                    configured.draw(in: rect.offsetBy(dx: 0.5, dy: -0.5))
                    // Draw cursor
                    NSColor.white.set()
                    configured.draw(in: rect)
                    return true
                }
                return NSCursor(image: rendered, hotSpot: NSPoint(x: 10, y: 10))
            }
            // Fallback
            return nwse ? .resizeUpDown : .resizeLeftRight
        }
    }
}

// CGPoint.distance(to:) is provided by CropOverlayView.swift
