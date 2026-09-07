// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Sparkle

struct UpdateSettingsView: View {
    @AppStorage(AppConstants.checkForUpdatesKey) private var checkForUpdates = true
    @AppStorage(AppConstants.updateCheckFrequencyKey) private var checkFrequencyRaw = UpdateCheckFrequency.weekly.rawValue

    @StateObject private var updateChecker = UpdateChecker.shared
    @StateObject private var sparkleUpdater = SparkleUpdater.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
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
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
            
            Section(header: Text("Updates")) {
                if sparkleUpdater.isActive {
                    SparkleUpdateControls(updater: sparkleUpdater.updater,
                                          checkNow: { sparkleUpdater.controller.checkForUpdates(nil) })
                } else {
                    Toggle("Automatically check for updates", isOn: $checkForUpdates)
                        .toggleStyle(SwitchToggleStyle())

                    if checkForUpdates {
                        Picker("Check frequency", selection: $checkFrequencyRaw) {
                            ForEach(UpdateCheckFrequency.allCases) { frequency in
                                Text(LocalizedStringKey(frequency.rawValue)).tag(frequency.rawValue)
                            }
                        }
                    }

                    HStack {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                                .foregroundColor(.secondary)
                        } else {
                            if updateChecker.updateAvailable {
                                Text("Version \(updateChecker.latestVersion) is available!")
                                    .foregroundColor(.green)
                                Button("Release Notes") {
                                    updateChecker.openReleaseNotes()
                                }
                                if !updateChecker.isHomebrewInstall {
                                    Button("Download") {
                                        updateChecker.openDownloadAsset()
                                    }
                                }
                            } else {
                                Text("App is up to date")
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Check Now") {
                                Task {
                                    await updateChecker.performUpdateCheck(isUserInitiated: true)
                                }
                            }
                            .disabled(updateChecker.isChecking)
                        }
                    }

                    if updateChecker.isHomebrewInstall {
                        HomebrewUpdateHintView(highlight: updateChecker.updateAvailable)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Source code and author website", systemImage: "questionmark.circle")
                        .font(.headline)
                    HStack {
                        Link("Source Code (GitHub)", destination: URL(string: "https://github.com/aagedal/Aagedal-Media-Converter")!)
                        Spacer()
                        Link("Developer Website", destination: URL(string: "https://aagedal.me/about")!)
                    }
                    .padding(8)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HomebrewUpdateHintView: View {
    let highlight: Bool
    private var command: String { UpdateChecker.homebrewUpgradeCommand }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Managed by Homebrew", systemImage: "shippingbox")
                .font(.headline)

            Text(highlight
                 ? "An update is available. Install it through Homebrew to keep brew's records consistent:"
                 : "This copy was installed via Homebrew. To update, run:")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(highlight ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .cornerRadius(6)

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
                .accessibilityLabel("Copy to clipboard")
                .accessibilityIdentifier("settings.updates.copyCommand")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Settings controls bound to Sparkle's `SPUUpdater`. `SPUUpdater` exposes its
/// state via KVO rather than `@Published`, so the toggles use direct
/// `Binding` closures — that means changes coming from Sparkle's own UI won't
/// live-refresh this view, but user input in Settings persists immediately.
private struct SparkleUpdateControls: View {
    let updater: SPUUpdater
    let checkNow: () -> Void

    private static let intervalChoices: [(label: String, seconds: TimeInterval)] = [
        ("Daily", 86_400),
        ("Weekly", 604_800),
        ("Monthly", 2_592_000)
    ]

    var body: some View {
        Toggle("Automatically check for updates", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        ))
        .toggleStyle(SwitchToggleStyle())

        if updater.automaticallyChecksForUpdates {
            Picker("Check frequency", selection: Binding(
                get: { closestInterval(to: updater.updateCheckInterval) },
                set: { updater.updateCheckInterval = $0 }
            )) {
                ForEach(Self.intervalChoices, id: \.seconds) { choice in
                    Text(LocalizedStringKey(choice.label)).tag(choice.seconds)
                }
            }

            Toggle("Install updates automatically", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .toggleStyle(SwitchToggleStyle())
            .help("Downloads new releases in the background and installs them on next launch.")
        }

        HStack {
            Spacer()
            Button("Check Now", action: checkNow)
        }
    }

    private func closestInterval(to seconds: TimeInterval) -> TimeInterval {
        Self.intervalChoices
            .min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) })?
            .seconds ?? 604_800
    }
}

#Preview {
    UpdateSettingsView()
}
