import XCTest
import Security
import LocalAuthentication
@testable import Aagedal_Media_Converter

final class KeychainCredentialManagerTests: XCTestCase {
    func testPasswordPresenceUsesNonInteractiveStatusOnlyMatch() {
        let manager = KeychainCredentialManager(presenceQuery: { query in
            Self.assertPresenceQuery(query, account: "editor@example.test")
            return errSecSuccess
        })
        XCTAssertTrue(manager.hasCredential(server: "example.test", username: "editor"))
    }

    func testS3PresenceUsesNonInteractiveStatusOnlyMatch() {
        let manager = KeychainCredentialManager(presenceQuery: { query in
            Self.assertPresenceQuery(query, account: "s3:example-access-key")
            return errSecSuccess
        })
        XCTAssertTrue(manager.hasS3SecretKey(accessKeyID: "example-access-key"))
    }

    func testUnavailableAndAuthenticationRequiredMatchesDoNotReportCredential() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
            let manager = KeychainCredentialManager(presenceQuery: { _ in status })
            XCTAssertFalse(manager.hasCredential(server: "example.test", username: "editor"))
            XCTAssertFalse(manager.hasS3SecretKey(accessKeyID: "example-access-key"))
        }
    }

    func testInvalidIdentifiersNeverQueryKeychain() {
        let manager = KeychainCredentialManager(presenceQuery: { _ in
            XCTFail("Invalid identifiers must not reach the Keychain")
            return errSecSuccess
        })
        XCTAssertFalse(manager.hasCredential(server: "", username: "editor"))
        XCTAssertFalse(manager.hasCredential(server: "example.test", username: ""))
        XCTAssertFalse(manager.hasS3SecretKey(accessKeyID: ""))
    }

    private static func assertPresenceQuery(_ query: CFDictionary, account: String) {
        let values = query as NSDictionary
        XCTAssertEqual(values[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(values[kSecAttrService] as? String, "com.aagedal.media-converter.upload")
        XCTAssertEqual(values[kSecAttrAccount] as? String, account)
        XCTAssertEqual(values[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(values[kSecReturnData] as? Bool, false)
        XCTAssertNil(values[kSecValueData])
        XCTAssertNil(values[kSecReturnRef])
        XCTAssertNil(values[kSecReturnPersistentRef])
        XCTAssertTrue((values[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
    }
}

extension KeychainCredentialManagerTests {
    func testPasswordAndS3SavesUpdateExistingSecretWithoutAdding() throws {
        let manager = KeychainCredentialManager(updateItem: { query, attributes in
            let values = attributes as NSDictionary
            XCTAssertEqual(values[kSecValueData] as? Data, Data("replacement".utf8))
            XCTAssertEqual(values[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlocked as String)
            XCTAssertNotNil((query as NSDictionary)[kSecAttrAccount])
            return errSecSuccess
        }, addItem: { _ in
            XCTFail("Existing credentials must be updated in place")
            return errSecDuplicateItem
        })
        try manager.saveCredential(server: "example.test", username: "editor", password: "replacement")
        try manager.saveS3SecretKey(accessKeyID: "example-access-key", secretKey: "replacement")
    }

    func testUpdateFailureDoesNotAttemptToReplaceExistingCredential() {
        let manager = KeychainCredentialManager(updateItem: { _, _ in errSecAuthFailed }, addItem: { _ in
            XCTFail("Authentication failures must preserve the existing entry")
            return errSecSuccess
        })
        XCTAssertThrowsError(try manager.saveCredential(server: "example.test", username: "editor", password: "replacement")) {
            guard case KeychainError.saveFailed(errSecAuthFailed) = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try manager.saveS3SecretKey(accessKeyID: "example-access-key", secretKey: "replacement"))
    }

    func testMissingCredentialIsAddedWithItsAccountAndSecret() throws {
        let manager = KeychainCredentialManager(updateItem: { _, _ in errSecItemNotFound }, addItem: { query in
            let values = query as NSDictionary
            XCTAssertEqual(values[kSecAttrAccount] as? String, "editor@example.test")
            XCTAssertEqual(values[kSecValueData] as? Data, Data("new secret".utf8))
            return errSecSuccess
        })
        try manager.saveCredential(server: "example.test", username: "editor", password: "new secret")
    }

    func testDuplicateInsertionRetriesUpdate() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let counter = Counter()
        let manager = KeychainCredentialManager(updateItem: { _, _ in
            counter.next() == 1 ? errSecItemNotFound : errSecSuccess
        }, addItem: { _ in errSecDuplicateItem })
        try manager.saveCredential(server: "example.test", username: "editor", password: "replacement")
        XCTAssertEqual(counter.count, 2)
    }
}
