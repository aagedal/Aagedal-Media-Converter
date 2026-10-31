// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct UpdateNotificationView: View {
    let latestVersion: String
    let installSource: InstallSource
    let onReleaseNotes: () -> Void
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("New Version Available")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Release Notes") {
                onReleaseNotes()
            }
            .buttonStyle(.bordered)

            actionButton

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var subtitle: String {
        switch installSource {
        case .homebrew:
            return String(localized: "Version \(latestVersion) is available via Homebrew.")
        case .directDownload:
            return String(localized: "Version \(latestVersion) is ready to download.")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch installSource {
        case .homebrew:
            Button("Copy brew Command") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(UpdateChecker.homebrewUpgradeCommand, forType: .string)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .help(UpdateChecker.homebrewUpgradeCommand)
        case .directDownload:
            Button("Download") {
                onDownload()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct UpdateNotificationView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            UpdateNotificationView(
                latestVersion: "1.2.3",
                installSource: .directDownload,
                onReleaseNotes: {},
                onDownload: {},
                onDismiss: {}
            )
            UpdateNotificationView(
                latestVersion: "1.2.3",
                installSource: .homebrew,
                onReleaseNotes: {},
                onDownload: {},
                onDismiss: {}
            )
        }
        .frame(width: 500)
        .padding()
        .background(Color.gray.opacity(0.2))
    }
}
