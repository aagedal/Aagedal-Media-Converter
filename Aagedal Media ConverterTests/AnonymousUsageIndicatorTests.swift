// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Aagedal_Media_Converter

final class AnonymousUsageIndicatorTests: XCTestCase {
    func testConsentAndDailyLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(AnonymousUsagePayload.shouldAttempt(choice: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(AnonymousUsagePayload.shouldAttempt(choice: .decline, lastAttempt: nil, now: now))
        XCTAssertTrue(AnonymousUsagePayload.shouldAttempt(choice: .allow, lastAttempt: nil, now: now))
        XCTAssertFalse(AnonymousUsagePayload.shouldAttempt(choice: .allow, lastAttempt: now, now: now.addingTimeInterval(86_399)))
        XCTAssertTrue(AnonymousUsagePayload.shouldAttempt(choice: .allow, lastAttempt: now, now: now.addingTimeInterval(86_400)))
    }

    func testWeeklyTokenChangesAcrossISOWeekAndIsStableWithinWeek() throws {
        let formatter = ISO8601DateFormatter()
        let monday = try XCTUnwrap(formatter.date(from: "2026-09-21T00:00:00Z"))
        let sunday = try XCTUnwrap(formatter.date(from: "2026-09-27T23:59:59Z"))
        let nextMonday = try XCTUnwrap(formatter.date(from: "2026-09-28T00:00:00Z"))
        let secret = Data(repeating: 1, count: 32)
        XCTAssertEqual(AnonymousUsagePayload.weekIdentifier(for: monday), "2026-W39")
        XCTAssertEqual(AnonymousUsagePayload.token(secret: secret, date: monday), AnonymousUsagePayload.token(secret: secret, date: sunday))
        XCTAssertNotEqual(AnonymousUsagePayload.token(secret: secret, date: monday), AnonymousUsagePayload.token(secret: secret, date: nextMonday))
        XCTAssertNotEqual(AnonymousUsagePayload.token(secret: secret, date: monday), AnonymousUsagePayload.token(secret: Data(repeating: 2, count: 32), date: monday))
    }

    @MainActor
    func testNoEndpointDoesNotReserveDayWithoutConsent() throws {
        let name = "AnonymousUsageIndicatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let indicator = AnonymousUsageIndicator(defaults: defaults, endpoint: nil)
        indicator.reportOnOpen()
        XCTAssertNil(defaults.object(forKey: AnonymousUsageChoice.lastAttemptKey))
        defaults.set(AnonymousUsageChoice.allow.rawValue, forKey: AnonymousUsageChoice.defaultsKey)
        indicator.reportOnOpen()
        XCTAssertNil(defaults.object(forKey: AnonymousUsageChoice.lastAttemptKey))
        defaults.set(AnonymousUsageChoice.decline.rawValue, forKey: AnonymousUsageChoice.defaultsKey)
        indicator.reportOnOpen()
        XCTAssertNil(defaults.object(forKey: AnonymousUsageChoice.lastAttemptKey))
    }

    @MainActor
    func testDeferredReleaseDoesNotReportWithStoredConsentAndEndpoint() throws {
        let name = "AnonymousUsageIndicatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(AnonymousUsageChoice.allow.rawValue, forKey: AnonymousUsageChoice.defaultsKey)
        let endpoint = try XCTUnwrap(URL(string: "https://example.invalid/usage"))
        let indicator = AnonymousUsageIndicator(defaults: defaults, endpoint: endpoint)

        indicator.reportOnOpen()

        XCTAssertFalse(AnonymousUsageIndicator.enabledForThisRelease)
        XCTAssertNil(defaults.object(forKey: AnonymousUsageChoice.lastAttemptKey))
    }
}
