//
//  OverallProgressView.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct OverallProgressView: View {
    let progress: Double
    let currentFileName: String?
    let completedCount: Int
    let totalCount: Int
    let currentFileETA: String?

    /// Where this run started, so the queue estimate ignores items that were
    /// already done before encoding began.
    @State private var runStart: (date: Date, progress: Double)?

    /// Remaining time for the whole queue, extrapolated from the progress made
    /// since this run started. Nil until there's enough progress to be useful.
    private var queueRemaining: TimeInterval? {
        guard let runStart else { return nil }
        let gained = progress - runStart.progress
        let elapsed = Date().timeIntervalSince(runStart.date)
        guard gained > 0.01, elapsed > 5, progress < 1 else { return nil }
        return elapsed * (1 - progress) / gained
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let name = currentFileName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if totalCount > 0 {
                    Text("\(completedCount) of \(totalCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)

            HStack {
                Text("Overall: \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let remaining = queueRemaining {
                    Text("ETA: \(Self.formatted(remaining))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let eta = currentFileETA {
                    Text("This file: \(eta)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .onAppear { runStart = (Date(), progress) }
    }
}
