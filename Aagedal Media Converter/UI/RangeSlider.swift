// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// A custom range slider with two draggable handles for selecting start and end values
struct RangeSlider: View {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double
    let bounds: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    
    @State private var isDraggingLower = false
    @State private var isDraggingUpper = false
    
    private let handleSize: CGFloat = 20
    private let trackHeight: CGFloat = 6
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: trackHeight)
                
                // Active range track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: upperOffset(in: geometry.size.width) - lowerOffset(in: geometry.size.width), height: trackHeight)
                    .offset(x: lowerOffset(in: geometry.size.width))
                
                // Lower handle
                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .overlay(
                        Circle()
                            .stroke(isDraggingLower ? Color.accentColor : Color.gray, lineWidth: 2)
                    )
                    .offset(x: lowerOffset(in: geometry.size.width) - handleSize / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDraggingLower {
                                    isDraggingLower = true
                                    onEditingChanged(true)
                                }
                                let newValue = valueForOffset(value.location.x, in: geometry.size.width)
                                lowerValue = min(newValue, upperValue - step)
                            }
                            .onEnded { _ in
                                isDraggingLower = false
                                onEditingChanged(false)
                            }
                    )
                
                // Upper handle
                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .overlay(
                        Circle()
                            .stroke(isDraggingUpper ? Color.accentColor : Color.gray, lineWidth: 2)
                    )
                    .offset(x: upperOffset(in: geometry.size.width) - handleSize / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDraggingUpper {
                                    isDraggingUpper = true
                                    onEditingChanged(true)
                                }
                                let newValue = valueForOffset(value.location.x, in: geometry.size.width)
                                upperValue = max(newValue, lowerValue + step)
                            }
                            .onEnded { _ in
                                isDraggingUpper = false
                                onEditingChanged(false)
                            }
                    )
            }
            .frame(height: handleSize)
        }
        .frame(height: handleSize)
    }
    
    private func lowerOffset(in width: CGFloat) -> CGFloat {
        let range = bounds.upperBound - bounds.lowerBound
        let normalizedValue = (lowerValue - bounds.lowerBound) / range
        return CGFloat(normalizedValue) * width
    }
    
    private func upperOffset(in width: CGFloat) -> CGFloat {
        let range = bounds.upperBound - bounds.lowerBound
        let normalizedValue = (upperValue - bounds.lowerBound) / range
        return CGFloat(normalizedValue) * width
    }
    
    private func valueForOffset(_ offset: CGFloat, in width: CGFloat) -> Double {
        let normalizedOffset = max(0, min(1, offset / width))
        let range = bounds.upperBound - bounds.lowerBound
        let value = bounds.lowerBound + Double(normalizedOffset) * range
        return (value / step).rounded() * step
    }
}

struct RangeSlider_Previews: PreviewProvider {
    struct Preview: View {
        @State private var lower: Double = 2.0
        @State private var upper: Double = 8.0
        
        var body: some View {
            VStack(spacing: 20) {
                Text("Range: \(lower, specifier: "%.1f") - \(upper, specifier: "%.1f")")
                    .font(.headline)
                
                RangeSlider(
                    lowerValue: $lower,
                    upperValue: $upper,
                    bounds: 0...10,
                    step: 0.1
                )
                .padding(.horizontal, 40)
            }
            .frame(width: 400, height: 200)
        }
    }
    
    static var previews: some View {
        Preview()
    }
}
