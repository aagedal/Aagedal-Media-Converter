import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class PackageMetadataSettingsTests: XCTestCase {
    private let inputURL = URL(fileURLWithPath: "/source/Example.trailer.mov")

    func testAbsentAndUnknownKindsFallBackWithoutOverwritingPreferences() throws {
        let suite = "PackageMetadataSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let absent = PackageMetadataSettings(defaults: defaults)
        XCTAssertEqual(absent.resolveDCPMetadata(nil, inputURL: inputURL).contentKind, .feature)
        XCTAssertEqual(absent.resolveIMFMetadata(nil, inputURL: inputURL).contentKind, .feature)
        XCTAssertNil(defaults.object(forKey: AppConstants.lastDCPContentKindKey))
        XCTAssertNil(defaults.object(forKey: AppConstants.lastIMFContentKindKey))

        defaults.set("future-kind", forKey: AppConstants.lastDCPContentKindKey)
        defaults.set("future-kind", forKey: AppConstants.lastIMFContentKindKey)
        let invalid = PackageMetadataSettings(defaults: defaults)
        XCTAssertEqual(invalid.resolveDCPMetadata(nil, inputURL: inputURL).contentKind, .feature)
        XCTAssertEqual(invalid.resolveIMFMetadata(nil, inputURL: inputURL).contentKind, .feature)
        XCTAssertEqual(defaults.string(forKey: AppConstants.lastDCPContentKindKey), "future-kind")
        XCTAssertEqual(defaults.string(forKey: AppConstants.lastIMFContentKindKey), "future-kind")
    }

    func testRememberedKindsRemainStableAcrossSuspendedPreparation() async throws {
        let suite = "PackageMetadataSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DCPContentKind.trailer.rawValue, forKey: AppConstants.lastDCPContentKindKey)
        defaults.set(IMFContentKind.episode.rawValue, forKey: AppConstants.lastIMFContentKindKey)
        let captured = PackageMetadataSettings(defaults: defaults)

        await Task.yield()
        defaults.set(DCPContentKind.advertisement.rawValue, forKey: AppConstants.lastDCPContentKindKey)
        defaults.set(IMFContentKind.promo.rawValue, forKey: AppConstants.lastIMFContentKindKey)

        let dcp = captured.resolveDCPMetadata(nil, inputURL: inputURL)
        let imf = captured.resolveIMFMetadata(nil, inputURL: inputURL)
        XCTAssertEqual(dcp.contentKind, .trailer)
        XCTAssertEqual(imf.contentKind, .episode)
        XCTAssertEqual(dcp.contentTitleText, "Example.trailer")
        XCTAssertEqual(imf.contentTitleText, "Example.trailer")
        let next = PackageMetadataSettings(defaults: defaults)
        XCTAssertEqual(next.resolveDCPMetadata(nil, inputURL: inputURL).contentKind, .advertisement)
        XCTAssertEqual(next.resolveIMFMetadata(nil, inputURL: inputURL).contentKind, .promo)
    }

    func testExplicitMetadataWinsAndOnlyEmptyTitlesAreFilled() throws {
        let suite = "PackageMetadataSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DCPContentKind.trailer.rawValue, forKey: AppConstants.lastDCPContentKindKey)
        defaults.set(IMFContentKind.episode.rawValue, forKey: AppConstants.lastIMFContentKindKey)
        let settings = PackageMetadataSettings(defaults: defaults)
        let dcp = DCPItemMetadata(contentTitleText: "Custom Title", contentKind: .feature,
                                  annotationText: "Note", ratingLabel: "PG", audioLanguage: "nb")
        let imf = IMFItemMetadata(contentTitleText: "Custom Title", contentKind: .feature,
                                  annotationText: "Note", audioLanguage: "nb")
        XCTAssertEqual(settings.resolveDCPMetadata(dcp, inputURL: inputURL), dcp)
        XCTAssertEqual(settings.resolveIMFMetadata(imf, inputURL: inputURL), imf)

        var untitledDCP = dcp
        var untitledIMF = imf
        untitledDCP.contentTitleText = ""
        untitledIMF.contentTitleText = ""
        var expectedDCP = dcp
        var expectedIMF = imf
        expectedDCP.contentTitleText = "Example.trailer"
        expectedIMF.contentTitleText = "Example.trailer"
        XCTAssertEqual(settings.resolveDCPMetadata(untitledDCP, inputURL: inputURL), expectedDCP)
        XCTAssertEqual(settings.resolveIMFMetadata(untitledIMF, inputURL: inputURL), expectedIMF)
    }
}
