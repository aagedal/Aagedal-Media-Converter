// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct UpdateSettingsView: View {
    @AppStorage(AppConstants.checkForUpdatesKey) private var checkForUpdates = true
    @AppStorage(AppConstants.updateCheckFrequencyKey) private var checkFrequencyRaw = UpdateCheckFrequency.weekly.rawValue
    
    @StateObject private var updateChecker = UpdateChecker.shared
    
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
                        
                        Text("FFMPEG version: 8.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
            
            Section(header: Text("Updates")) {
                Toggle("Automatically check for updates", isOn: $checkForUpdates)
                
                if checkForUpdates {
                    Picker("Check frequency", selection: $checkFrequencyRaw) {
                        ForEach(UpdateCheckFrequency.allCases) { frequency in
                            Text(frequency.rawValue).tag(frequency.rawValue)
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
                            Button("Download") {
                                updateChecker.openDownloadPage()
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
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    UpdateSettingsView()
}
