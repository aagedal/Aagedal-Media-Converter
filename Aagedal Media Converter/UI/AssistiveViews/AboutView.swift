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

struct AboutView: View {
    @State private var showsLicenses = false
    private let homepageURL = URL(string: "https://mediaconverter.aagedal.me")!
    private let repoURL = URL(string: "https://github.com/aagedal/Aagedal-Media-Converter")!

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .cornerRadius(20)
            }
            VStack(spacing: 4) {
                Text("Aagedal Media Converter")
                    .font(.title)
                    .fontWeight(.semibold)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Text("Minimalist FFMPEG frontend written in Swift and SwiftUI.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("FFMPEG version: 8.1")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Link("Homepage", destination: homepageURL)
                Link("GitHub Repository", destination: repoURL)
            }
            .font(.subheadline)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                Text("Aagedal Media Converter is licensed under GPL-3.0-or-later.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("Bundles FFmpeg, mpv, tesseract, asdcplib, bmx and rclone; optionally downloads yt-dlp, Deno, whisper.cpp and Parakeet at runtime. Each component is distributed under its own license. Bundled license notices are available below; see the source repository for component details.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Licenses") {
                    showsLicenses = true
                }
            }
            .padding(.horizontal)
        }
        .padding(24)
        .frame(width: 440)
        .sheet(isPresented: $showsLicenses) {
            BundledLicensesView()
        }
    }
}

private struct BundledLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedNotice = "LICENSE"

    private let notices: [(name: String, file: String)] = [
        ("Aagedal Media Converter", "LICENSE"),
        ("FFmpeg", "ffmpeg-LICENSE.txt"),
        ("mpv", "mpv-LICENSE.txt"),
        ("tesseract", "tesseract-LICENSE.txt"),
        ("asdcplib", "asdcplib-LICENSE.txt"),
        ("bmx", "bmx-LICENSE.txt")
    ]

    private var noticeText: String? {
        guard let url = Bundle.main.url(forResource: selectedNotice, withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Licenses")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            Picker("Component", selection: $selectedNotice) {
                ForEach(notices, id: \.file) { notice in
                    Text(verbatim: notice.name).tag(notice.file)
                }
            }

            ScrollView {
                if let noticeText {
                    Text(verbatim: noticeText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text("This license notice could not be loaded. See the source repository for license information.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .id(selectedNotice)
            .background(.background)
            .border(Color(nsColor: .separatorColor))

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
    }
}

#Preview {
    AboutView()
}
