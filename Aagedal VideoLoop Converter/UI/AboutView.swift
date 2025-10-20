// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .cornerRadius(20)
            }
            VStack(spacing: 4) {
                Text("Aagedal VideoLoop Converter")
                    .font(.title)
                    .fontWeight(.semibold)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Text("FFMPEG frontend with focus on creating videoloops: small .mp4-files are intended to loop infinitely and automatically inline on websites. This works as a modern replacement for GIFs.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("FFMPEG version: 8.0")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}

#Preview {
    AboutView()
}
