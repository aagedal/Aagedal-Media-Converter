// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Prevents the Mac from going to sleep while at least one caller holds an assertion.
///
/// `shared` uses `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventUserIdleSystemSleep`,
/// which stops the system from idling to sleep but still allows the display to dim/turn off.
/// `display` uses `kIOPMAssertionTypePreventUserIdleDisplaySleep`, which keeps the display (and
/// so the system) awake: screen recording and scheduled recordings need it, since a sleeping
/// display locks the screen and ScreenCaptureKit stops delivering video and audio.
/// Reference-counted by token — multiple features (scheduled recordings, scheduled downloads,
/// watch-folder monitoring) can hold the assertion concurrently, and the underlying IOKit
/// assertion is only released when the last holder releases its token.
final class PowerAssertion: @unchecked Sendable {
    static let shared = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)
    static let display = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PowerAssertion")
    private let lock = NSLock()
    private var holders: [UUID: String] = [:]
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private let type: String

    private init(type: String) {
        self.type = type
    }

    /// Acquire an assertion. Returns a token that must be passed to ``release(_:)`` to drop it.
    /// Safe to call off the main actor.
    @discardableResult
    func acquire(reason: String) -> UUID {
        let token = UUID()
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = holders.isEmpty
        holders[token] = reason
        if wasEmpty {
            var id: IOPMAssertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                logger.info("Created power assertion (\(reason, privacy: .public))")
            } else {
                logger.error("Failed to create power assertion: \(result)")
                holders.removeValue(forKey: token)
            }
        }
        return token
    }

    /// Release a previously acquired assertion. No-op if the token is unknown.
    func release(_ token: UUID?) {
        guard let token else { return }
        lock.lock()
        defer { lock.unlock() }
        guard holders.removeValue(forKey: token) != nil else { return }
        if holders.isEmpty, assertionID != 0 {
            let result = IOPMAssertionRelease(assertionID)
            if result == kIOReturnSuccess {
                logger.info("Released power assertion (no more holders)")
            } else {
                logger.error("Failed to release power assertion: \(result)")
            }
            assertionID = 0
        }
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !holders.isEmpty
    }
}
