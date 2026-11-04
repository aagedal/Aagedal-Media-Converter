// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// Shows P2 card rewrapping progress (see `P2CardImporter`) with a Cancel
/// button, and briefly reports clips that couldn't be prepared.
struct P2ImportProgressOverlay: View {
    private var progress = P2ImportProgress.shared

    var body: some View {
        VStack(spacing: 8) {
            if let message = progress.message {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction ?? 0)
                        .frame(width: 140)
                    Text(message)
                        .font(.callout)
                        .lineLimit(1)
                    Button("Cancel") { progress.cancel() }
                        .controlSize(.small)
                }
                .modifier(P2OverlayCapsule())
            }
            if let failure = progress.failureMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(failure)
                        .font(.callout)
                }
                .modifier(P2OverlayCapsule())
            }
        }
        .padding(.bottom, 16)
        .animation(.default, value: progress.message == nil)
        .animation(.default, value: progress.failureMessage)
    }
}

private struct P2OverlayCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 4, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
