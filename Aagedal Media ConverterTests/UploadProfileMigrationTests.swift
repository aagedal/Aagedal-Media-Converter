import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class UploadProfileMigrationTests: XCTestCase {
    private func withStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "UploadProfileMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func seedLegacy(_ defaults: UserDefaults) throws -> [UUID] {
        let ids = (0..<4).map { _ in UUID() }
        let common: [String: Any] = ["server": "example.test", "port": 1234,
                                     "username": "user", "remotePath": "/delivery"]
        let variants: [(String, [String: Any])] = [
            ("FTP", ["useFTPS": true]),
            ("SFTP", ["useKeyAuth": true, "keyFilePath": "/example/key"]),
            ("SMB", ["smbShare": "media", "smbDomain": "studio"]),
            ("S3", ["bucket": "media", "region": "eu-north-1",
                    "endpoint": "https://example.test", "accessKeyID": "example-id"])
        ]
        for (index, variant) in variants.enumerated() {
            var object = common.merging(variant.1) { _, new in new }
            object["id"] = ids[index].uuidString
            object["name"] = variant.0
            defaults.set(try JSONSerialization.data(withJSONObject: [object]),
                         forKey: "upload\(variant.0)Profiles")
            defaults.set(ids[index].uuidString, forKey: "upload\(variant.0)SelectedProfileID")
        }
        return ids
    }

    func testAllBackendsKeepIdentityFieldsAndSelectedDestination() throws {
        for (index, backend) in ["ftp", "sftp", "smb", "s3"].enumerated() {
            try withStore { defaults in
                let ids = try seedLegacy(defaults)
                defaults.set(backend, forKey: "uploadBackendType")
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                let profiles = UploadProfileStore.loadProfiles(defaults: defaults)
                XCTAssertEqual(profiles.map(\.id), ids, "IDs must preserve Keychain credential associations")
                XCTAssertEqual(profiles.map(\.backend), [.ftp, .sftp, .smb, .s3])
                XCTAssertEqual(profiles.map(\.remotePath), Array(repeating: "/delivery", count: 4))
                XCTAssertEqual(profiles[0].server, "example.test")
                XCTAssertEqual(profiles[0].port, 1234)
                XCTAssertEqual(profiles[0].username, "user")
                XCTAssertTrue(profiles[0].useFTPS)
                XCTAssertTrue(profiles[1].useKeyAuth)
                XCTAssertEqual(profiles[1].keyFilePath, "/example/key")
                XCTAssertEqual(profiles[2].smbShare, "media")
                XCTAssertEqual(profiles[2].smbDomain, "studio")
                XCTAssertEqual(profiles[3].bucket, "media")
                XCTAssertEqual(profiles[3].region, "eu-north-1")
                XCTAssertEqual(profiles[3].endpoint, "https://example.test")
                XCTAssertEqual(profiles[3].accessKeyID, "example-id")
                XCTAssertEqual(UploadProfileStore.resolveSelectedProfile(from: profiles, defaults: defaults)?.id, ids[index])
                XCTAssertTrue(defaults.bool(forKey: AppConstants.uploadProfileMigrationV2Key))
                XCTAssertNil(defaults.object(forKey: "uploadFTPProfiles"))
                XCTAssertNil(defaults.object(forKey: "uploadBackendType"))
                let before = defaults.dictionaryRepresentation()
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                XCTAssertEqual(before as NSDictionary, defaults.dictionaryRepresentation() as NSDictionary)
            }
        }
    }

    func testModernProfilesAndExplicitEmptyListWinOverLegacyData() throws {
        for modern in [[UploadProfile.new(backend: .smb)], []] {
            try withStore { defaults in
                _ = try seedLegacy(defaults)
                UploadProfileStore.saveProfiles(modern, defaults: defaults)
                let selection = UUID()
                UploadProfileStore.saveSelectedProfileID(selection, defaults: defaults)
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                XCTAssertEqual(UploadProfileStore.loadProfiles(defaults: defaults), modern)
                XCTAssertEqual(UploadProfileStore.loadSelectedProfileID(defaults: defaults), selection)
            }
        }
    }

    func testMalformedLegacyDataDoesNotPublishPartialMigrationOrDeleteRecoveryData() throws {
        for malformed: Any in [Data("invalid".utf8), "wrong-storage-type", Data("{}".utf8)] {
            try withStore { defaults in
                _ = try seedLegacy(defaults)
                defaults.set(malformed, forKey: "uploadS3Profiles")
                let before = defaults.dictionaryRepresentation()
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                XCTAssertEqual(before as NSDictionary, defaults.dictionaryRepresentation() as NSDictionary)
                XCTAssertNil(defaults.object(forKey: AppConstants.uploadProfilesKey))
                XCTAssertFalse(defaults.bool(forKey: AppConstants.uploadProfileMigrationV2Key))
                // Repairing the source permits a subsequent complete migration.
                let ids = try seedLegacy(defaults)
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                XCTAssertEqual(UploadProfileStore.loadProfiles(defaults: defaults).map(\.id), ids)
            }
        }
    }

    func testInvalidLegacySelectionFallsBackToFirstProfile() throws {
        for selection in ["invalid", UUID().uuidString] {
            try withStore { defaults in
                let ids = try seedLegacy(defaults)
                defaults.set("sftp", forKey: "uploadBackendType")
                defaults.set(selection, forKey: "uploadSFTPSelectedProfileID")
                UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
                XCTAssertEqual(UploadProfileStore.loadSelectedProfileID(defaults: defaults), ids.first)
            }
        }
    }

    func testEmptyStoreMigrationIsIdempotentAndDoesNotInventProfiles() {
        withStore { defaults in
            UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
            XCTAssertTrue(UploadProfileStore.loadProfiles(defaults: defaults).isEmpty)
            XCTAssertNil(UploadProfileStore.loadSelectedProfileID(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: AppConstants.uploadProfileMigrationV2Key))
        }
    }

    func testMalformedModernDataIsPreservedForRecovery() throws {
        try withStore { defaults in
            _ = try seedLegacy(defaults)
            let damaged = Data("damaged-modern-profiles".utf8)
            defaults.set(damaged, forKey: AppConstants.uploadProfilesKey)
            UploadProfileStore.migrateLegacyProfilesIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.data(forKey: AppConstants.uploadProfilesKey), damaged)
            XCTAssertNotNil(defaults.data(forKey: "uploadFTPProfiles"))
        }
    }
}
