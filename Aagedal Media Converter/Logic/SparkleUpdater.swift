// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Sparkle
import SwiftUI

/// Selects the repository mirror for one retry when the primary appcast cannot
/// be downloaded or parsed. Failures after the appcast loads (for example,
/// signature validation or installation errors) must not switch feeds.
private final class SparkleFeedFallbackDelegate: NSObject, SPUUpdaterDelegate {
    private let backupFeedURL: String
    private var isUsingBackupFeed = false
    private var didLoadAppcast = false

    init(backupFeedURL: String) {
        self.backupFeedURL = backupFeedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        didLoadAppcast = false
        return isUsingBackupFeed ? backupFeedURL : nil
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        didLoadAppcast = true
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        let shouldRetry = !isUsingBackupFeed
            && !didLoadAppcast
            && Self.isFeedLoadFailure(error)

        if isUsingBackupFeed {
            isUsingBackupFeed = false
        }
        didLoadAppcast = false

        guard shouldRetry else { return }
        isUsingBackupFeed = true

        switch updateCheck {
        case .updates:
            updater.checkForUpdates()
        case .updatesInBackground:
            updater.checkForUpdatesInBackground()
        case .updateInformation:
            updater.checkForUpdateInformation()
        @unknown default:
            updater.checkForUpdatesInBackground()
        }
    }

    private static func isFeedLoadFailure(_ error: Error?) -> Bool {
        guard let error = error as NSError?,
              error.domain == SUSparkleErrorDomain
        else { return false }

        return error.code == SUError.downloadError.rawValue
            || error.code == SUError.appcastParseError.rawValue
            || error.code == SUError.appcastError.rawValue
    }
}

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest of
/// the app can interact with the updater through one stable handle and
/// pre-flight checks. Two gates decide whether the updater actually runs:
///
/// 1. **Install source** — Homebrew installs use the in-app `UpdateChecker`
///    (notify, route to `brew upgrade`) so Sparkle never replaces a bundle
///    brew thinks it manages.
/// 2. **Sparkle configuration** — if `SUFeedURL` isn't present in Info.plist,
///    Sparkle has nothing to talk to. We avoid starting the updater so the
///    console doesn't fill with misconfiguration warnings during development.
///
/// Both gates fail closed: `isActive == false` means the updater object still
/// exists (so SwiftUI bindings compile), but `startingUpdater` was `false` and
/// no checks will fire.
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController
    private let feedFallbackDelegate: SparkleFeedFallbackDelegate

    /// True when Sparkle is actually polling and able to install updates.
    /// False for Homebrew installs or when SUFeedURL is unset.
    let isActive: Bool

    private init() {
        let hasFeedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .isEmpty == false
        let isDirectInstall = InstallSource.current == .directDownload
        let active = hasFeedURL && isDirectInstall
        let feedFallbackDelegate = SparkleFeedFallbackDelegate(
            backupFeedURL: "https://raw.githubusercontent.com/aagedal/Aagedal-Media-Converter/main/appcast.xml"
        )

        self.isActive = active
        self.feedFallbackDelegate = feedFallbackDelegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: active,
            updaterDelegate: feedFallbackDelegate,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    /// One-time notice that automatic updates are on, so users discover the
    /// opt-out without having to find Settings → Updates on their own.
    ///
    /// The "have I shown this yet" flag lives in `UserDefaults.standard` under
    /// `AppConstants.didShowAutoUpdateNoticeKey`, which survives every app
    /// update (UserDefaults is at `~/Library/Preferences/<bundle>.plist`,
    /// untouched when Sparkle / brew swaps the bundle).
    ///
    /// Three gates, all required:
    ///   - `isActive` — Sparkle is the update path here (skips brew installs).
    ///   - `updater.automaticallyDownloadsUpdates == true` — the message
    ///     would be a lie for users who explicitly turned auto-install off.
    ///   - flag not already set — one-shot for the lifetime of this install.
    func presentFirstLaunchNoticeIfNeeded() {
        guard isActive else { return }
        guard updater.automaticallyDownloadsUpdates else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppConstants.didShowAutoUpdateNoticeKey) else { return }
        defaults.set(true, forKey: AppConstants.didShowAutoUpdateNoticeKey)

        let alert = NSAlert()
        alert.messageText = "Automatic updates are on"
        alert.informativeText = "New releases will download and install in the background so you stay current without thinking about it. You can turn this off any time in Settings → Updates."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings…")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // Hand off to AppKit's standard Settings command — works for the
            // SwiftUI `Settings { ... }` scene.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
