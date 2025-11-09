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

    var body: some View {
        VStack(alignment: .leading) {
            Text("Overall Progress: \(Int(progress * 100))%")
                .font(.subheadline)
                .foregroundColor(.secondary)
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
        }
        .padding()
    }
}
