import CommonCrypto
import CryptoKit
import SQLite3
import XCTest
@testable import Aagedal_Media_Converter

final class YTDLPCookieSourceTests: XCTestCase {
    func testZenUsesFirefoxReaderWithOnlyZenProfiles() throws {
        let name = "YTDLPCookieSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Zen Tests \(UUID())")
        defaults.set("zen", forKey: AppConstants.ytdlpCookiesBrowserKey)
        // Even when Zen is absent, pass its explicit path rather than falling
        // back to Firefox. Spaces must remain inside a single argument.
        for profile in ["", "abc123.default-release", "Personal Profile"] {
            defaults.set(profile, forKey: AppConstants.ytdlpZenProfileKey)
            let source = try YTDLPCookieSource.configured(defaults: defaults, homeDirectory: home) { _, _ in
                XCTFail("Zen cookies should not query the Chromium Keychain")
                return Data()
            }
            let root = home.appendingPathComponent("Library/Application Support/zen/Profiles")
            let directory = profile.isEmpty ? root : root.appendingPathComponent(profile)
            XCTAssertEqual(source.arguments, ["--cookies-from-browser", "firefox:\(directory.path)"])
            source.cleanup()
        }
        // A saved Zen profile must not affect the standard Firefox option.
        defaults.set("firefox", forKey: AppConstants.ytdlpCookiesBrowserKey)
        XCTAssertEqual(try YTDLPCookieSource.configured(defaults: defaults).arguments, ["--cookies-from-browser", "firefox"])
    }

    func testZenRejectsProfileTraversalAndArgumentDelimiters() throws {
        let name = "YTDLPCookieSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("zen", forKey: AppConstants.ytdlpCookiesBrowserKey)
        for profile in [".", "..", "../Firefox", "/tmp/profile", "Profiles/test", "..\\Firefox", "profile::container", "profile\nname"] {
            defaults.set(profile, forKey: AppConstants.ytdlpZenProfileKey)
            XCTAssertThrowsError(try YTDLPCookieSource.configured(defaults: defaults)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Zen"))
            }
        }
    }

    func testHeliumAndNeoExportFromTheirOwnProfilesAndKeychainIdentities() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "YTDLPCookieSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Different profiles, DB layouts, and keys catch cross-browser fallback.
        let fixtures = [
            ("helium", "net.imput.helium/Default/Cookies", "Helium Storage Key", "Helium", "upstream"),
            ("helium-neo", "no.aagedal.helium-neo/Profile 2/Network/Cookies", "Helium Neo Storage Key", "Helium Neo", "neo")
        ]
        defaults.set("Profile 2", forKey: AppConstants.ytdlpHeliumNeoProfileKey)
        for (browser, path, service, account, token) in fixtures {
            let database = home.appendingPathComponent("Library/Application Support/" + path)
            try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
            let key = try ChromiumCookieExport.deriveKey(password: Data(token.utf8))
            let value = try encrypt(Data(token.utf8), key: key).map { String(format: "%02x", $0) }.joined()
            let status = sqlite3_exec(db, """
                CREATE TABLE meta (key TEXT, value TEXT);
                INSERT INTO meta VALUES ('version', '23');
                CREATE TABLE cookies (host_key TEXT, path TEXT, is_secure INTEGER, expires_utc INTEGER,
                                      name TEXT, value TEXT, encrypted_value BLOB, is_httponly INTEGER);
                INSERT INTO cookies VALUES ('example.com', '/', 1, 0, 'session', '', X'\(value)', 0);
                """, nil, nil, nil)
            sqlite3_close(db)
            XCTAssertEqual(status, SQLITE_OK)
            defaults.set(browser, forKey: AppConstants.ytdlpCookiesBrowserKey)
            let cookies = try YTDLPCookieSource.configured(defaults: defaults, homeDirectory: home) { requestedService, requestedAccount in
                XCTAssertEqual(requestedService, service)
                XCTAssertEqual(requestedAccount, account)
                return Data(token.utf8)
            }
            defer { cookies.cleanup() }
            XCTAssertEqual(cookies.arguments.first, "--cookies")
            let exported = try String(contentsOfFile: cookies.arguments[1], encoding: .utf8)
            XCTAssertEqual(exported, "# Netscape HTTP Cookie File\nexample.com\tFALSE\t/\tTRUE\t0\tsession\t\(token)\n")
        }
    }

    func testBothBrowsersRejectInvalidProfilesBeforeAccessingCookies() throws {
        let name = "YTDLPCookieSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for browser in [YTDLPChromiumBrowser.helium, .heliumNeo] {
            defaults.set(browser.rawValue, forKey: AppConstants.ytdlpCookiesBrowserKey)
            defaults.set("../Default", forKey: browser.profilePreferenceKey)
            XCTAssertThrowsError(try YTDLPCookieSource.configured(defaults: defaults)) { error in
                XCTAssertTrue(error.localizedDescription.contains(browser.label))
            }
        }
    }

    func testExistingBrowserArgumentsRemainCompatible() throws {
        let name = "YTDLPCookieSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(try YTDLPCookieSource.configured(defaults: defaults).arguments, [])
        for browser in ["safari", "chrome", "chromium", "firefox", "edge", "brave", "opera", "vivaldi", "whale"] {
            defaults.set(browser, forKey: AppConstants.ytdlpCookiesBrowserKey)
            XCTAssertEqual(try YTDLPCookieSource.configured(defaults: defaults).arguments, ["--cookies-from-browser", browser])
        }
    }

    func testExportsArePrivateIndependentAndCleanedUp() throws {
        let first = try YTDLPCookieSource.exported(contents: "fixture")
        defer { first.cleanup() }
        let second = try YTDLPCookieSource.exported(contents: "fixture")
        defer { second.cleanup() }
        XCTAssertEqual(first.arguments.first, "--cookies")
        let firstURL = URL(fileURLWithPath: first.arguments[1])
        let secondURL = URL(fileURLWithPath: second.arguments[1])
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: firstURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: firstURL.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testLegacyAndHostBoundCookieDecryption() throws {
        let key = try ChromiumCookieExport.deriveKey(password: Data("fixture-password".utf8))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "5d84e88b8d2628e23102b464d77a5bbd")
        let host = ".example.com"
        let value = Data("session-token".utf8)
        let legacy = try encrypt(value, key: key)
        XCTAssertEqual(try ChromiumCookieExport.decrypt(legacy, key: key, host: host, version: 23), "session-token")
        let bound = try encrypt(Data(SHA256.hash(data: Data(host.utf8))) + value, key: key)
        XCTAssertEqual(try ChromiumCookieExport.decrypt(bound, key: key, host: host, version: 24), "session-token")
        XCTAssertThrowsError(try ChromiumCookieExport.decrypt(bound, key: key, host: "other.example", version: 24))
        XCTAssertThrowsError(try ChromiumCookieExport.decrypt(Data("v20unsupported".utf8), key: key, host: host, version: 24))
    }

    func testSQLiteSnapshotIncludesWALAndExportsNetscapeFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let key = try ChromiumCookieExport.deriveKey(password: Data("fixture-password".utf8))
        let encrypted = try encrypt(Data(SHA256.hash(data: Data(".example.com".utf8))) + Data("secret".utf8), key: key)
        let hex = encrypted.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE meta (key TEXT, value TEXT);
            INSERT INTO meta VALUES ('version', '24');
            CREATE TABLE cookies (host_key TEXT, path TEXT, is_secure INTEGER, expires_utc INTEGER,
                                  name TEXT, value TEXT, encrypted_value BLOB, is_httponly INTEGER);
            INSERT INTO cookies VALUES ('.example.com', '/', 1, 0, 'session', '', X'\(hex)', 1);
            INSERT INTO cookies VALUES ('example.com', '/', 0, 11644473601000000, 'expired', 'skip', X'', 0);
            """, nil, nil, nil), SQLITE_OK)
        let contents = try ChromiumCookieExport.read(database: url) { Data("fixture-password".utf8) }
        XCTAssertEqual(contents, "# Netscape HTTP Cookie File\n#HttpOnly_.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n")
        XCTAssertThrowsError(try ChromiumCookieExport.read(database: url) { Data("wrong-password".utf8) })
        XCTAssertEqual(sqlite3_exec(db, "UPDATE cookies SET encrypted_value = X'', value = 'bad' || char(10) || 'value'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try ChromiumCookieExport.read(database: url) { XCTFail("Plaintext cookies should not query Keychain"); return Data() })
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        var result = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = result.count
        var count = 0
        let iv = Array(repeating: UInt8(0x20), count: kCCBlockSizeAES128)
        let status = result.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                plaintext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, plaintext.count,
                            output.baseAddress, capacity, &count)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        result.count = count
        return Data("v10".utf8) + result
    }
}
