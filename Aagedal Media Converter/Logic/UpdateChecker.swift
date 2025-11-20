// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    
    var id: String { self.rawValue }
    
    var timeInterval: TimeInterval {
        switch self {
        case .daily: return 86400 // 24 * 60 * 60
        case .weekly: return 604800 // 7 * 24 * 60 * 60
        case .monthly: return 2592000 // 30 * 24 * 60 * 60 (approx)
        }
    }
}

@MainActor
class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    @AppStorage(AppConstants.checkForUpdatesKey) private var checkForUpdates = true
    @AppStorage(AppConstants.updateCheckFrequencyKey) private var checkFrequencyRaw = UpdateCheckFrequency.weekly.rawValue
    @AppStorage(AppConstants.lastUpdateCheckDateKey) private var lastUpdateCheckDate: Double = 0
    
    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var isChecking: Bool = false
    
    private let caskURL = URL(string: "https://raw.githubusercontent.com/aagedal/homebrew-casks/main/Casks/aagedal-media-converter.rb")!
    private let downloadURL = URL(string: "https://github.com/aagedal/Aagedal-Media-Converter/releases/latest")!
    
    private init() {}
    
    func checkForUpdatesIfNeeded() {
        guard checkForUpdates else { return }
        
        let lastCheck = Date(timeIntervalSince1970: lastUpdateCheckDate)
        let frequency = UpdateCheckFrequency(rawValue: checkFrequencyRaw) ?? .weekly
        
        if Date().timeIntervalSince(lastCheck) >= frequency.timeInterval {
            Task {
                await performUpdateCheck(isUserInitiated: false)
            }
        }
    }
    
    func performUpdateCheck(isUserInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        
        do {
            let (data, _) = try await URLSession.shared.data(from: caskURL)
            if let content = String(data: data, encoding: .utf8),
               let remoteVersion = parseVersion(from: content) {
                
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                
                if isVersion(remoteVersion, newerThan: currentVersion) {
                    self.latestVersion = remoteVersion
                    self.updateAvailable = true
                } else {
                    self.updateAvailable = false
                }
                
                // Only update last check date if successful
                if !isUserInitiated {
                    self.lastUpdateCheckDate = Date().timeIntervalSince1970
                }
            }
        } catch {
            print("Error checking for updates: \(error)")
        }
        
        isChecking = false
    }
    
    private func parseVersion(from caskContent: String) -> String? {
        // Look for version "x.y.z"
        let pattern = #"version\s+"([\d\.]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let nsString = caskContent as NSString
        let results = regex.matches(in: caskContent, options: [], range: NSRange(location: 0, length: nsString.length))
        
        if let match = results.first, match.numberOfRanges > 1 {
            return nsString.substring(with: match.range(at: 1))
        }
        
        return nil
    }
    
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        return v1.compare(v2, options: .numeric) == .orderedDescending
    }
    
    func openDownloadPage() {
        NSWorkspace.shared.open(downloadURL)
    }
}
