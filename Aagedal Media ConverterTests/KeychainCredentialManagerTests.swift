import XCTest
import Security
import LocalAuthentication
@testable import Aagedal_Media_Converter

final class KeychainCredentialManagerTests: XCTestCase {
    func testPasswordPresenceUsesNonInteractiveStatusOnlyMatch() {
        let manager = KeychainCredentialManager { query in
            Self.assertPresenceQuery(query, account: "editor@example.test")
            return errSecSuccess
        }
        XCTAssertTrue(manager.hasCredential(server: "example.test", username: "editor"))
    }

    func testS3PresenceUsesNonInteractiveStatusOnlyMatch() {
        let manager = KeychainCredentialManager { query in
            Self.assertPresenceQuery(query, account: "s3:example-access-key")
            return errSecSuccess
        }
        XCTAssertTrue(manager.hasS3SecretKey(accessKeyID: "example-access-key"))
    }

    func testUnavailableAndAuthenticationRequiredMatchesDoNotReportCredential() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
            let manager = KeychainCredentialManager { _ in status }
            XCTAssertFalse(manager.hasCredential(server: "example.test", username: "editor"))
            XCTAssertFalse(manager.hasS3SecretKey(accessKeyID: "example-access-key"))
        }
    }

    func testInvalidIdentifiersNeverQueryKeychain() {
        let manager = KeychainCredentialManager { _ in
            XCTFail("Invalid identifiers must not reach the Keychain")
            return errSecSuccess
        }
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
