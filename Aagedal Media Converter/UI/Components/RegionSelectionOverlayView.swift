// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct RegionSelectionOverlayView: View {
    let screenSize: CGSize
    let displayScaleFactor: CGFloat
    let initialRegion: CGRect?
    let onConfirmed: (CGRect?) -> Void

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

    // Modifier state, kept in sync by KeyEventHandlingView
    @State private var isShiftHeld = false
    @State private var isOptionHeld = false
    @State private var isSpaceHeld = false

    // Space-to-move tracking
    @State private var spacePressCursor: CGPoint? = nil
    @State private var dragStartPointAtSpacePress: CGPoint? = nil

    // Shift-axis-lock snapshot: captured when Shift is pressed mid-drag so the locked
    // axis stays at the dimension it had at that moment.
    @State private var shiftPressedRect: CGRect? = nil

    // For replaying the last drag value when a modifier flips mid-drag
    @State private var lastDragLocation: CGPoint? = nil
    @State private var lastDragTranslation: CGSize? = nil

    // Aspect ratio lock, persisted across launches
    @AppStorage(RegionSelectionOverlayView.aspectRatioStorageKey)
    private var lockedAspectRatioRaw: String = AspectRatio.free.rawValue

    private var lockedAspectRatio: AspectRatio {
        AspectRatio(rawValue: lockedAspectRatioRaw) ?? .free
    }

    private var menuAspectRatios: [AspectRatio] {
        AspectRatio.allCases.filter { $0 != .ratio21_9 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dimmed overlay with cutout
                dimOverlay(in: geometry.size)

                // Selection rectangle with handles
                if let rect = selectionRect {
                    selectionRectangleView(rect: rect)
                }

                // Crosshair cursor when in drawing phase and no rect yet
                if phase == .drawing, selectionRect == nil {
                    crosshairOverlay
                }

                // Center crosshair when Option is held mid-drag
                if isOptionHeld, isDragging, let rect = selectionRect {
                    centerCrosshair(for: rect)
                }

                // Aspect-ratio picker (top-center, always visible)
                aspectRatioPicker
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)

                // Floating toolbar
                if let rect = selectionRect, phase == .refining {
                    toolbar(for: rect)
                }
            }
            .contentShape(Rectangle())
            .gesture(mainDragGesture())
            .onAppear {
                if let initialRegion {
                    // The saved region may come from a different (larger) display — keep it on this screen.
                    selectionRect = clampToScreen(initialRegion, in: screenSize, ratio: nil)
                    phase = .refining
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
            KeyEventHandlingView(
                onEscape: { cancel() },
                onReturn: { confirm() },
                isShiftHeld: $isShiftHeld,
                isOptionHeld: $isOptionHeld,
                isSpaceHeld: $isSpaceHeld
            )
        )
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
            // Transparent fill for hit testing
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // White border
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rule of thirds grid
            if phase == .refining {
                ruleOfThirdsGrid(rect: rect)
                resizeHandles(rect: rect)
            }

            // Dimension label
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

    private var aspectRatioPicker: some View {
        Menu {
            ForEach(menuAspectRatios) { ratio in
                Button {
                    lockedAspectRatioRaw = ratio.rawValue
                } label: {
                    if ratio == lockedAspectRatio {
                        Label(ratio.displayName, systemImage: "checkmark")
                    } else {
                        Text(ratio.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "aspectratio")
                Text(lockedAspectRatio.displayName)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func toolbar(for rect: CGRect) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)

                Button(action: { resetSelection() }) {
                    Label("Redraw", systemImage: "arrow.counterclockwise")
                }

                Button(action: confirm) {
                    Label("Confirm", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Gesture Handling

    private func mainDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                handleDragChanged(value: value)
            }
            .onEnded { _ in
                handleDragEnded()
            }
    }

    private func handleDragChanged(value: DragGesture.Value) {
        // First frame: pick the drag mode and capture origin
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

            // If Space was already held when the drag started, prime the move state now
            if isSpaceHeld {
                spacePressCursor = value.location
                dragStartPointAtSpacePress = dragStartPoint
            }
        }

        // Save for replay when a modifier flips without mouse motion
        lastDragLocation = value.location
        lastDragTranslation = value.translation

        applyDragPipeline(location: value.location, translation: value.translation)
    }

    private func applyDragPipeline(location: CGPoint, translation: CGSize) {
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
        rect = clampToScreen(rect, in: screenSize, ratio: ratioCG)

        selectionRect = rect
    }

    private func computeCandidateRect(location: CGPoint, translation: CGSize) -> CGRect {
        guard let start = dragStartPoint else { return selectionRect ?? .zero }

        switch dragMode {
        case .draw:
            if isOptionHeld {
                // Center at start, half-extents from |location - start|
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
        // around the dragged edge's midpoint (or the rect's mid for Option center-scale).
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

        // Determine the anchor that should stay fixed
        let curW = rect.width
        let curH = rect.height
        let curRatio = curW / max(curH, 0.001)

        // Pick the bounding axis: keep the larger projection, derive the other from ratio
        let newW: CGFloat
        let newH: CGFloat
        if curRatio > ratio {
            newH = curH
            newW = curH * ratio
        } else {
            newW = curW
            newH = curW / ratio
        }

        // Find the anchor point we're pivoting around
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
            if let frozen = shiftPressedRect {
                if horizontalDominant {
                    return CGRect(x: rect.minX, y: frozen.minY, width: rect.width, height: frozen.height)
                } else {
                    return CGRect(x: frozen.minX, y: rect.minY, width: frozen.width, height: rect.height)
                }
            }

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

        // Enforce non-negative sizes
        r.size.width = max(1, r.size.width)
        r.size.height = max(1, r.size.height)

        if let ratio {
            // Maintain aspect ratio while fitting within screen bounds
            // First, cap width and height to the maximum that fits the screen at this ratio
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

            // Clamp position
            r.origin.x = max(0, min(size.width - r.width, r.origin.x))
            r.origin.y = max(0, min(size.height - r.height, r.origin.y))
        } else {
            // Free clamping: cap each dimension, then position
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
        applyDragPipeline(location: location, translation: translation)
    }

    private func handleShiftTransition(isHeld: Bool) {
        if isHeld {
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
            // Space just went down — capture origin
            spacePressCursor = lastDragLocation
            dragStartPointAtSpacePress = dragStartPoint
        } else {
            // Space released — commit the shift and clear
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
            // Re-fit the existing rect to the new ratio, preserving center, clamping to screen
            var newRect = fitRect(rect, toRatio: ratio)
            newRect = clampToScreen(newRect, in: screenSize, ratio: ratio)
            selectionRect = newRect
        }
    }

    private func fitRect(_ rect: CGRect, toRatio ratio: CGFloat) -> CGRect {
        let curRatio = rect.width / max(rect.height, 0.001)
        let newW: CGFloat
        let newH: CGFloat
        if curRatio > ratio {
            // Currently wider than target — shrink width to match
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
            } else if let rect = selectionRect, (rect.width < minimumSize || rect.height < minimumSize) {
                selectionRect = nil
                phase = .drawing
            }
        } else if let rect = selectionRect, let startRect = dragStartRect,
                  rect.width < minimumSize || rect.height < minimumSize {
            // A resize collapsed the region below the minimum size; restore the pre-drag region
            // instead of leaving a sliver that Confirm would silently treat as Cancel.
            selectionRect = startRect
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

    // MARK: - Actions

    private func confirm() {
        guard let rect = selectionRect, rect.width >= minimumSize, rect.height >= minimumSize else {
            cancel()
            return
        }
        onConfirmed(rect)
    }

    private func cancel() {
        onConfirmed(nil)
    }

    private func resetSelection() {
        selectionRect = nil
        phase = .drawing
    }
}

// MARK: - Key + Modifier Event Handling

private struct KeyEventHandlingView: NSViewRepresentable {
    let onEscape: () -> Void
    let onReturn: () -> Void
    @Binding var isShiftHeld: Bool
    @Binding var isOptionHeld: Bool
    @Binding var isSpaceHeld: Bool

    func makeNSView(context: Context) -> KeyEventNSView {
        let view = KeyEventNSView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        view.isShiftHeld = $isShiftHeld
        view.isOptionHeld = $isOptionHeld
        view.isSpaceHeld = $isSpaceHeld
        return view
    }

    func updateNSView(_ nsView: KeyEventNSView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onReturn = onReturn
        nsView.isShiftHeld = $isShiftHeld
        nsView.isOptionHeld = $isOptionHeld
        nsView.isSpaceHeld = $isSpaceHeld
    }

    final class KeyEventNSView: NSView {
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?
        var isShiftHeld: Binding<Bool>?
        var isOptionHeld: Binding<Bool>?
        var isSpaceHeld: Binding<Bool>?

        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // Closing the panel does not detach this view from it, so viewWillMove(toWindow: nil)
                // is not guaranteed — tear the monitor down when the window closes as well, or it would
                // keep swallowing Escape / Return / Space in the app's other windows.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(hostWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            }
            if window != nil, eventMonitor == nil {
                let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event: event)
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            }
            if newWindow == nil {
                removeMonitor()
            }
        }

        @objc private func hostWindowWillClose(_ notification: Notification) {
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        private func handle(event: NSEvent) -> NSEvent? {
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { // Escape
                    onEscape?()
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 { // Return / Numpad Enter
                    onReturn?()
                    return nil
                }
                if event.keyCode == 49 { // Space
                    // Swallow auto-repeat too; only update state on the first press
                    if !event.isARepeat {
                        DispatchQueue.main.async { [weak self] in
                            self?.isSpaceHeld?.wrappedValue = true
                        }
                    }
                    return nil
                }
                return event
            case .keyUp:
                if event.keyCode == 49 { // Space
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
