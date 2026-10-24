// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// macOS identities from Helium and Helium Neo's utils/neo_branding.py.
/// Keep the profile roots and Keychain identities paired; never fall back to
/// another browser's key or signed-in profile.
enum YTDLPChromiumBrowser: String {
    case helium
    case heliumNeo = "helium-neo"

    var label: String { self == .helium ? "Helium" : "Helium Neo" }
    var profileRootName: String { self == .helium ? "net.imput.helium" : "no.aagedal.helium-neo" }
    var keychainService: String { "\(label) Storage Key" }
    var keychainAccount: String { label }
    var profilePreferenceKey: String {
        self == .helium ? AppConstants.ytdlpHeliumProfileKey : AppConstants.ytdlpHeliumNeoProfileKey
    }
}

/// Owns a per-operation cookie export. Never persist decrypted cookies in preferences
/// or reuse an export between concurrent downloads.
struct YTDLPCookieSource {
    let arguments: [String]
    private let temporaryDirectory: URL?

    static func configured(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        storagePassword: (String, String) throws -> Data = ChromiumCookieExport.storagePassword
    ) throws -> Self {
        let browser = defaults.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
        if browser == "zen" {
            // Zen uses Firefox's cookie format, but its profiles must never fall
            // back to Firefox's signed-in accounts. yt-dlp selects the newest
            // cookie database when given the Profiles directory.
            let profile = (defaults.string(forKey: AppConstants.ytdlpZenProfileKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ![".", ".."].contains(profile),
                  !profile.contains("/"), !profile.contains("\\"), !profile.contains(":"),
                  profile.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw CookieError.message("Choose a valid Zen profile directory name in Downloads settings.")
            }
            var directory = homeDirectory.appendingPathComponent("Library/Application Support/zen/Profiles")
            if !profile.isEmpty { directory.appendPathComponent(profile) }
            return Self(arguments: ["--cookies-from-browser", "firefox:\(directory.path)"], temporaryDirectory: nil)
        }
        guard let source = YTDLPChromiumBrowser(rawValue: browser) else {
            return Self(arguments: browser.isEmpty ? [] : ["--cookies-from-browser", browser], temporaryDirectory: nil)
        }
        let root = homeDirectory
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(source.profileRootName)
        let profile = defaults.string(forKey: source.profilePreferenceKey) ?? "Default"
        guard profile == "Default" || (profile.hasPrefix("Profile ") && !profile.contains("/") && !profile.contains("\\")) else {
            throw CookieError.message("Choose a valid \(source.label) profile in Downloads settings.")
        }
        let directory = root.appendingPathComponent(profile)
        let candidates = [directory.appendingPathComponent("Network/Cookies"), directory.appendingPathComponent("Cookies")]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CookieError.message("No cookies found for \(source.label) (\(profile)). Open \(source.label), sign in, and select the correct profile in Downloads settings.")
        }
        let contents = try ChromiumCookieExport.read(database: database, browserName: source.label) {
            try storagePassword(source.keychainService, source.keychainAccount)
        }
        return try exported(contents: contents)
    }

    static func exported(contents: String) throws -> Self {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("amc-cookies-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = temporaryDirectory.appendingPathComponent("cookies.txt")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CookieError.message("Could not create the temporary browser cookie file.")
            }
            return Self(arguments: ["--cookies", file.path], temporaryDirectory: temporaryDirectory)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    func cleanup() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

enum CookieError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Chromium's macOS v10 cookie format, including the host hash introduced in DB
/// version 24. Read a SQLite snapshot so WAL data is included without modifying
/// the browser database. No cookie values or Keychain secrets are logged.
enum ChromiumCookieExport {
    static func storagePassword(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw CookieError.message("Could not access \(account)’s cookie encryption key (Keychain error \(status)). Allow access to \(service) when macOS asks.")
        }
        return password
    }

    static func deriveKey(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.bindMemory(to: Int8.self).baseAddress,
                                    password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                    1003, output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw CookieError.message("Could not derive the browser cookie key.") }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data, host: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else {
            throw CookieError.message("The browser uses an unsupported cookie encryption format.")
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let iv = Array(repeating: UInt8(0x20), count: kCCBlockSizeAES128)
        let capacity = plaintext.count
        let status = plaintext.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, ciphertext.count,
                            output.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw CookieError.message("Could not decrypt browser cookies with its Keychain key.") }
        plaintext.count = count
        if version >= 24 {
            let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.starts(with: hostHash) else {
                throw CookieError.message("Browser cookie verification failed. Check the selected browser profile.")
            }
            plaintext = Data(plaintext.dropFirst(hostHash.count))
        }
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw CookieError.message("The browser returned an invalid cookie value.")
        }
        return value
    }

    static func read(database: URL, browserName: String = "Helium", password: () throws -> Data) throws -> String {
        var source: OpaquePointer?
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let source { sqlite3_close(source) }
            throw CookieError.message("Could not read browser cookies. Close the browser and check file access permissions.")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 1500)
        var snapshot: OpaquePointer?
        guard sqlite3_open(":memory:", &snapshot) == SQLITE_OK else {
            if let snapshot { sqlite3_close(snapshot) }
            throw CookieError.message("Could not open the cookie snapshot.")
        }
        defer { sqlite3_close(snapshot) }
        guard let backup = sqlite3_backup_init(snapshot, "main", source, "main") else {
            throw CookieError.message("Could not snapshot browser cookies.")
        }
        let backupStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard backupStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw CookieError.message("The browser’s cookie database is busy. Close the browser and retry.")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(snapshot, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK else {
            throw CookieError.message("Unrecognized browser cookie database.")
        }
        let version = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        sqlite3_finalize(statement)
        statement = nil
        guard sqlite3_prepare_v2(snapshot, "SELECT host_key, path, is_secure, expires_utc, name, value, encrypted_value, is_httponly FROM cookies", -1, &statement, nil) == SQLITE_OK else {
            throw CookieError.message("Unrecognized browser cookie database schema.")
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: bytes)
        }
        var key: Data?
        var lines = ["# Netscape HTTP Cookie File"]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let host = text(0)
            let expiry = sqlite3_column_int64(statement, 3)
            let unixExpiry = expiry == 0 ? 0 : expiry / 1_000_000 - 11_644_473_600
            if unixExpiry == 0 || unixExpiry > Int64(Date().timeIntervalSince1970) {
                var value = text(5)
                let size = Int(sqlite3_column_bytes(statement, 6))
                if size > 0, let bytes = sqlite3_column_blob(statement, 6) {
                    if key == nil { key = try deriveKey(password: password()) }
                    guard let key else { throw CookieError.message("Could not derive the browser cookie key.") }
                    value = try decrypt(Data(bytes: bytes, count: size), key: key, host: host, version: version)
                }
                let domain = (sqlite3_column_int(statement, 7) != 0 ? "#HttpOnly_" : "") + host
                let fields = [domain, host.hasPrefix(".") ? "TRUE" : "FALSE", text(1),
                              sqlite3_column_int(statement, 2) != 0 ? "TRUE" : "FALSE", String(unixExpiry), text(4), value]
                guard fields.allSatisfy({ !$0.contains("\t") && !$0.contains("\n") && !$0.contains("\r") }) else {
                    throw CookieError.message("\(browserName) contains a cookie that cannot be exported safely.")
                }
                lines.append(fields.joined(separator: "\t"))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CookieError.message("Could not finish reading browser cookies.") }
        guard lines.count > 1 else { throw CookieError.message("The selected browser profile has no unexpired cookies. Sign in using that profile first.") }
        return lines.joined(separator: "\n") + "\n"
    }
}
