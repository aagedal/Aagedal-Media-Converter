// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Security

/// This preference is intentionally absent from settings sync and export. Consent
/// applies to this installation only, just like its device-only Keychain secret.
enum AnonymousUsageChoice: String {
    case allow
    case decline

    static let defaultsKey = "anonymousUsageCountChoice"
    static let lastAttemptKey = "anonymousUsageCountLastAttempt"
}

enum AnonymousUsagePayload {
    static func weekIdentifier(for date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear!, parts.weekOfYear!)
    }

    static func token(secret: Data, date: Date) -> String {
        let key = SymmetricKey(data: secret)
        let digest = HMAC<SHA256>.authenticationCode(for: Data(weekIdentifier(for: date).utf8), using: key)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    static func shouldAttempt(choice: AnonymousUsageChoice?, lastAttempt: Date?, now: Date) -> Bool {
        guard choice == .allow else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= 24 * 60 * 60
    }
}

@MainActor
final class AnonymousUsageIndicator {
    static let shared = AnonymousUsageIndicator()
    // The feature is deferred from 4.5. Keep reporting disabled even if a
    // previously saved choice or endpoint remains on this Mac.
    static let enabledForThisRelease = false

    private let defaults: UserDefaults
    private let endpoint: URL?
    private var sendTask: Task<Void, Never>?
    private let keychainService = "com.aagedal.media-converter.anonymous-usage"
    private let keychainAccount = "installation-secret"

    init(defaults: UserDefaults = .standard, endpoint: URL? = (Bundle.main.object(forInfoDictionaryKey: "AnonymousUsageEndpoint") as? String).flatMap(URL.init(string:))) {
        self.defaults = defaults
        self.endpoint = endpoint
    }

    var choice: AnonymousUsageChoice? {
        defaults.string(forKey: AnonymousUsageChoice.defaultsKey).flatMap(AnonymousUsageChoice.init(rawValue:))
    }

    func setChoice(_ choice: AnonymousUsageChoice) {
        defaults.set(choice.rawValue, forKey: AnonymousUsageChoice.defaultsKey)
        if choice == .decline {
            sendTask?.cancel()
            sendTask = nil
            // Turning reporting off also removes the local identifier.
            SecItemDelete(keychainQuery() as CFDictionary)
            defaults.removeObject(forKey: AnonymousUsageChoice.lastAttemptKey)
        } else {
            _ = loadOrCreateSecret()
        }
    }

    /// Reserved for a future release. No 4.5 caller can initiate reporting.
    func reportOnOpen(now: Date = Date()) {
        guard Self.enabledForThisRelease else { return }
        guard AnonymousUsagePayload.shouldAttempt(
            choice: choice,
            lastAttempt: defaults.object(forKey: AnonymousUsageChoice.lastAttemptKey) as? Date,
            now: now
        ), sendTask == nil, let endpoint, endpoint.scheme?.lowercased() == "https",
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { return }

        // Reserve the day before any suspension, including failed requests. This
        // bounds retries and concurrent windows to at most one attempt per day.
        defaults.set(now, forKey: AnonymousUsageChoice.lastAttemptKey)
        sendTask = Task {
            defer { sendTask = nil }
            guard let secret = loadOrCreateSecret(), choice == .allow, !Task.isCancelled else { return }
            let token = AnonymousUsagePayload.token(secret: secret, date: now)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("AMC-anonymous-count/1", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
            guard choice == .allow, !Task.isCancelled else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: NoUsageRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            _ = try? await session.data(for: request)
        }
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private func loadOrCreateSecret() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess { return item as? Data }
        guard status == errSecItemNotFound else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        var add = keychainQuery()
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return secret
    }
}


private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
