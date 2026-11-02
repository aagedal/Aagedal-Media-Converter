import XCTest
@testable import Aagedal_Media_Converter

final class ManagedToolVersioningTests: XCTestCase {
    // MARK: - Version ordering

    private func v(_ string: String) -> ManagedToolVersion {
        guard let version = ManagedToolVersion(string) else {
            XCTFail("Unparseable version \(string)")
            return ManagedToolVersion("0")!
        }
        return version
    }

    func testYTDLPDateVersionsOrderNumerically() {
        XCTAssertLessThan(v("2026.9.1"), v("2026.10.21"))
        XCTAssertLessThan(v("2026.09.30"), v("2026.10.01"))
        XCTAssertLessThan(v("2025.12.31"), v("2026.01.01"))
        // Nightly builds append a time component.
        XCTAssertLessThan(v("2026.10.21"), v("2026.10.21.232415"))
        XCTAssertEqual(v("2026.10.21"), v("2026.10.21.0"))
    }

    func testDenoSemverIgnoresLeadingV() {
        XCTAssertEqual(v("v2.5.4"), v("2.5.4"))
        XCTAssertLessThan(v("v2.5.4"), v("v2.10.0"))
        XCTAssertLessThan(v("1.46.3"), v("v2.0.0"))
        XCTAssertEqual(v("2.5.4+build.7"), v("2.5.4"))
    }

    func testYTDLPRSPreReleaseOrdering() {
        let ordered = [
            "0.2.0-alpha.1", "0.2.0", "0.3.0-alpha.2", "0.3.0-beta.1", "0.3.0-beta.2",
            "0.3.0-beta.10", "0.3.0-rc.1", "0.3.0", "0.3.1-beta.1", "1.0.0",
        ]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(v(lower), v(higher), "\(lower) < \(higher)")
        }
        XCTAssertLessThan(v("1.0.0-beta"), v("1.0.0-beta.1"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"))
    }

    func testUnparseableVersionsAreRejected() {
        XCTAssertNil(ManagedToolVersion("legacy"))
        XCTAssertNil(ManagedToolVersion(""))
        XCTAssertNil(ManagedToolVersion("1..2"))
        XCTAssertNil(ManagedToolVersion("1.2-"))
    }

    func testSortedNewestFirstPlacesUnparseableLast() {
        XCTAssertEqual(
            ManagedToolPolicy.sortedNewestFirst(["legacy", "2026.9.1", "2026.10.21", "2025.1.1"]),
            ["2026.10.21", "2026.9.1", "2025.1.1", "legacy"]
        )
    }

    func testNormalizedVersionName() {
        XCTAssertEqual(ManagedToolPolicy.normalizedVersionName("v2.5.4"), "2.5.4")
        XCTAssertEqual(ManagedToolPolicy.normalizedVersionName(" 2026.10.21\n"), "2026.10.21")
        XCTAssertEqual(ManagedToolPolicy.normalizedVersionName("v0.3.0-beta.1"), "0.3.0-beta.1")
        XCTAssertNil(ManagedToolPolicy.normalizedVersionName("../evil"))
        XCTAssertNil(ManagedToolPolicy.normalizedVersionName("a/b"))
        XCTAssertNil(ManagedToolPolicy.normalizedVersionName(""))
        XCTAssertNil(ManagedToolPolicy.normalizedVersionName(nil))
    }

    func testVersionOutputMatching() {
        XCTAssertTrue(ManagedToolPolicy.versionOutput("2026.10.21\n", matches: "2026.10.21"))
        XCTAssertTrue(ManagedToolPolicy.versionOutput(
            "deno 2.5.4 (stable, release, aarch64-apple-darwin)\nv8 14.0\ntypescript 5.9.2\n",
            matches: "2.5.4"
        ))
        XCTAssertTrue(ManagedToolPolicy.versionOutput("yt-dlp-rs 0.3.0-beta.1\n", matches: "0.3.0-beta.1"))
        XCTAssertFalse(ManagedToolPolicy.versionOutput("yt-dlp-rs 0.3.0-beta.2\n", matches: "0.3.0-beta.1"))
        XCTAssertFalse(ManagedToolPolicy.versionOutput("yt-dlp-rs 0.3.0\n", matches: "0.3.0-beta.1"))
        XCTAssertFalse(ManagedToolPolicy.versionOutput("", matches: "2026.10.21"))
    }

    // MARK: - Install / retention decisions

    func testShouldInstallOnlyNewerReleases() {
        XCTAssertTrue(ManagedToolPolicy.shouldInstall(latest: "2026.10.21", installed: [], bundled: nil))
        XCTAssertTrue(ManagedToolPolicy.shouldInstall(latest: "2026.10.21", installed: ["2026.9.1"], bundled: nil))
        XCTAssertFalse(ManagedToolPolicy.shouldInstall(latest: "2026.10.21", installed: ["2026.10.21"], bundled: nil))
        XCTAssertFalse(ManagedToolPolicy.shouldInstall(latest: "v2.5.4", installed: ["2.5.4"], bundled: nil))
        XCTAssertFalse(ManagedToolPolicy.shouldInstall(latest: "2026.9.1", installed: ["2026.10.21"], bundled: nil))
        // Against the bundled yt-dlp-rs baseline.
        XCTAssertFalse(ManagedToolPolicy.shouldInstall(latest: "0.3.0-beta.1", installed: [], bundled: "0.3.0-beta.1"))
        XCTAssertFalse(ManagedToolPolicy.shouldInstall(latest: "0.3.0-alpha.9", installed: [], bundled: "0.3.0-beta.1"))
        XCTAssertTrue(ManagedToolPolicy.shouldInstall(latest: "v0.3.0-beta.2", installed: [], bundled: "0.3.0-beta.1"))
        // A legacy (unknown-version) install does not block a real version.
        XCTAssertTrue(ManagedToolPolicy.shouldInstall(latest: "2026.10.21", installed: ["legacy"], bundled: nil))
    }

    func testRetentionKeepsNewestThreePlusProtected() {
        let installed = ["2026.6.1", "2026.10.21", "2026.7.1", "2026.9.1", "2026.8.1", "legacy"]
        XCTAssertEqual(
            Set(ManagedToolPolicy.versionsToPrune(installed: installed, keep: 3, protected: [])),
            ["2026.7.1", "2026.6.1", "legacy"]
        )
        // A pinned (rolled-back) version survives even when it is old.
        XCTAssertEqual(
            Set(ManagedToolPolicy.versionsToPrune(installed: installed, keep: 3, protected: ["2026.6.1"])),
            ["2026.7.1", "legacy"]
        )
        XCTAssertEqual(ManagedToolPolicy.versionsToPrune(installed: ["1.0.0", "2.0.0"], keep: 3, protected: []), [])
    }

    // MARK: - Active version, rollback and pinning

    func testActiveChoicePrefersNewestUnlessPinned() {
        let installed = ["2026.9.1", "2026.10.21"]
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: installed, bundled: nil, pin: .automatic),
                       .installed("2026.10.21"))
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: installed, bundled: nil, pin: .version("2026.9.1")),
                       .installed("2026.9.1"))
        // A pin whose version was removed falls back to the newest.
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: installed, bundled: nil, pin: .version("2026.1.1")),
                       .installed("2026.10.21"))
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: [], bundled: nil, pin: .automatic), .none)
    }

    func testActiveChoiceComparesBundledYTDLPRSWithDownloads() {
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: [], bundled: "0.3.0-beta.1", pin: .automatic), .bundled)
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: ["0.3.0-beta.2"], bundled: "0.3.0-beta.1", pin: .automatic),
                       .installed("0.3.0-beta.2"))
        // An app update bundling a newer release wins over an older download.
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: ["0.3.0-beta.2"], bundled: "0.4.0", pin: .automatic), .bundled)
        // Equal versions prefer the bundled, app-signed copy.
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: ["0.3.0-beta.1"], bundled: "0.3.0-beta.1", pin: .automatic), .bundled)
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: ["0.3.0-beta.2"], bundled: "0.3.0-beta.1", pin: .bundled), .bundled)
        XCTAssertEqual(ManagedToolPolicy.activeChoice(installed: ["0.3.0-beta.2"], bundled: nil, pin: .bundled),
                       .installed("0.3.0-beta.2"))
    }

    func testPinStorageRoundTrip() {
        for pin in [ManagedToolPin.automatic, .bundled, .version("2026.10.21")] {
            XCTAssertEqual(ManagedToolPin(storageValue: pin.storageValue), pin)
        }
        XCTAssertEqual(ManagedToolPin(storageValue: ""), .automatic)
    }

    func testScheduledCheckDecisions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func decide(
            auto: Bool = true, pin: ManagedToolPin = .automatic, managed: Bool = true,
            enabled: Bool = true, lastCheck: Date? = nil
        ) -> ManagedToolScheduledCheckDecision {
            ManagedToolPolicy.scheduledCheckDecision(
                autoUpdateEnabled: auto, pin: pin, isAppManagedSource: managed, isToolEnabled: enabled,
                lastCheck: lastCheck, now: now, interval: 86_400
            )
        }
        XCTAssertEqual(decide(), .check)
        XCTAssertEqual(decide(lastCheck: now.addingTimeInterval(-86_401)), .check)
        XCTAssertEqual(decide(lastCheck: now.addingTimeInterval(-3_600)), .skip(.checkedRecently))
        // A clock moved backwards must not block checks forever.
        XCTAssertEqual(decide(lastCheck: now.addingTimeInterval(3_600)), .check)
        XCTAssertEqual(decide(auto: false), .skip(.autoUpdateDisabled))
        // Rolling back pauses automatic updates rather than re-upgrading.
        XCTAssertEqual(decide(pin: .version("2026.9.1")), .skip(.pinned))
        XCTAssertEqual(decide(pin: .bundled), .skip(.pinned))
        XCTAssertEqual(decide(managed: false), .skip(.notAppManaged))
        XCTAssertEqual(decide(enabled: false), .skip(.toolDisabled))
    }

    // MARK: - Migration

    func testLegacyMigrationPlans() {
        XCTAssertNil(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: false, recordedVersion: "2026.9.1", versionFileContents: nil, installed: []
        ))
        XCTAssertEqual(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: true, recordedVersion: "2026.09.01", versionFileContents: "2026.08.01", installed: []
        ), .adopt(version: "2026.09.01"))
        XCTAssertEqual(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: true, recordedVersion: nil, versionFileContents: "2026.08.01\n", installed: []
        ), .adopt(version: "2026.08.01"))
        // deno recorded its tag with a leading "v".
        XCTAssertEqual(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: true, recordedVersion: "v2.5.4", versionFileContents: nil, installed: []
        ), .adopt(version: "2.5.4"))
        XCTAssertEqual(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: true, recordedVersion: nil, versionFileContents: nil, installed: []
        ), .adopt(version: ManagedToolPolicy.legacyVersionName))
        XCTAssertEqual(ManagedToolPolicy.legacyMigration(
            legacyIsRegularFile: true, recordedVersion: "2026.9.1", versionFileContents: nil, installed: ["2026.9.1"]
        ), .linkExisting(version: "2026.9.1"))
    }

    // MARK: - yt-dlp-rs releases

    func testReleaseSelectorPicksNewestPreReleaseWithArchiveAndChecksums() throws {
        func release(_ tag: String, draft: Bool = false, assets: [String]) -> [String: Any] {
            [
                "tag_name": tag, "draft": draft, "prerelease": tag.contains("-"),
                "assets": assets.map { ["name": $0, "browser_download_url": "https://example.test/\(tag)/\($0)"] },
            ]
        }
        func archive(_ tag: String) -> String { "yt-dlp-rs-\(tag)-aarch64-apple-darwin.tar.gz" }
        let releases: [[String: Any]] = [
            release("v0.3.0-beta.1", assets: [archive("v0.3.0-beta.1"), "SHA256SUMS"]),
            release("v0.4.0", draft: true, assets: [archive("v0.4.0"), "SHA256SUMS"]),
            release("v0.3.0-beta.3", assets: [archive("v0.3.0-beta.3")]), // no checksums
            release("v0.3.0-beta.2", assets: ["yt-dlp-rs-v0.3.0-beta.2-x86_64-apple-darwin.tar.gz", "SHA256SUMS",
                                               archive("v0.3.0-beta.2")]),
            release("v0.2.0-alpha.1", assets: [archive("v0.2.0-alpha.1"), "SHA256SUMS"]),
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        let selected = try XCTUnwrap(YTDLPRSReleaseSelector.newest(fromGitHubReleasesJSON: data))
        XCTAssertEqual(selected.version, "0.3.0-beta.2")
        XCTAssertEqual(selected.assetName, archive("v0.3.0-beta.2"))
        XCTAssertEqual(selected.archiveDirectoryName, "yt-dlp-rs-v0.3.0-beta.2-aarch64-apple-darwin")
        XCTAssertEqual(selected.checksumURL.lastPathComponent, "SHA256SUMS")
        XCTAssertNil(try YTDLPRSReleaseSelector.newest(fromGitHubReleasesJSON: Data("[]".utf8)))
    }

    // MARK: - File-system layout

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testStoreMigratesLegacyInstallWithoutLosingTheBinary() throws {
        let store = ManagedToolStore(root: try makeTemporaryRoot())
        let legacy = store.stableLinkURL(for: .ytdlp)
        try writeExecutable("#!/bin/sh\necho 2026.09.01\n", to: legacy)
        XCTAssertTrue(store.hasLegacyInstall(for: .ytdlp))

        try store.migrateLegacyInstall(for: .ytdlp, plan: .adopt(version: "2026.09.01"))

        XCTAssertFalse(store.hasLegacyInstall(for: .ytdlp))
        XCTAssertEqual(store.linkedVersion(for: .ytdlp), "2026.09.01")
        XCTAssertEqual(store.installedVersions(for: .ytdlp), ["2026.09.01"])
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "#!/bin/sh\necho 2026.09.01\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: legacy.path))
    }

    func testStoreStagesOnedirBuildUnderTheToolExecutableName() throws {
        let root = try makeTemporaryRoot()
        let store = ManagedToolStore(root: root)
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try writeExecutable("#!/bin/sh\necho 2026.10.21\n", to: extracted.appendingPathComponent("yt-dlp_macos"))
        try writeExecutable("library", to: extracted.appendingPathComponent("_internal/libpython.dylib"))
        let staging = try store.makeStagingDirectory(for: .ytdlp)
        let executable = try store.stageDirectoryContents(
            for: .ytdlp, from: extracted, executableName: "yt-dlp_macos", in: staging
        )
        XCTAssertEqual(executable.lastPathComponent, "yt-dlp")
        try store.publish(staging: staging, for: .ytdlp, version: "2026.10.21")
        XCTAssertTrue(store.hasSupportDirectory(for: .ytdlp, version: "2026.10.21"))
        XCTAssertEqual(store.installedVersions(for: .ytdlp), ["2026.10.21"])

        // A migrated onefile install has no support directory and is replaced in place.
        try writeExecutable("#!/bin/sh\n", to: store.executableURL(for: .ytdlp, version: "2026.9.1"))
        XCTAssertFalse(store.hasSupportDirectory(for: .ytdlp, version: "2026.9.1"))
    }

    func testStorePublishesStagedVersionsAndSwitchesTheLink() throws {
        let root = try makeTemporaryRoot()
        let store = ManagedToolStore(root: root)
        for version in ["2.5.3", "2.5.4"] {
            let staging = try store.makeStagingDirectory(for: .deno)
            let download = root.appendingPathComponent("download-\(version)")
            try writeExecutable("#!/bin/sh\necho deno \(version)\n", to: download)
            _ = try store.stageExecutable(for: .deno, from: download, in: staging)
            XCTAssertFalse(store.installedVersions(for: .deno).contains(version), "Staged copies are not installed")
            try store.publish(staging: staging, for: .deno, version: version)
            try store.pointStableLink(for: .deno, to: version)
        }
        XCTAssertEqual(Set(store.installedVersions(for: .deno)), ["2.5.3", "2.5.4"])
        XCTAssertEqual(store.linkedVersion(for: .deno), "2.5.4")
        try store.pointStableLink(for: .deno, to: "2.5.3")
        XCTAssertEqual(store.linkedVersion(for: .deno), "2.5.3")

        // Reinstalling a version replaces it in place.
        let staging = try store.makeStagingDirectory(for: .deno)
        let download = root.appendingPathComponent("download-again")
        try writeExecutable("#!/bin/sh\necho deno 2.5.3 again\n", to: download)
        _ = try store.stageExecutable(for: .deno, from: download, in: staging)
        try store.publish(staging: staging, for: .deno, version: "2.5.3")
        XCTAssertEqual(
            try String(contentsOf: store.executableURL(for: .deno, version: "2.5.3"), encoding: .utf8),
            "#!/bin/sh\necho deno 2.5.3 again\n"
        )
        store.removeLeftovers(for: .deno)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.versionsDirectory(for: .deno).path)
        XCTAssertEqual(Set(names), ["2.5.3", "2.5.4"])
    }
}

/// Service-level behaviour over a temporary tools directory. These touch the
/// shared defaults domain, so every key is restored afterwards.
final class ManagedToolServiceTests: XCTestCase {
    private let keys = [
        AppConstants.ytdlpRSEnabledKey, AppConstants.ytdlpRSPinnedVersionKey, AppConstants.ytdlpPinnedVersionKey,
        AppConstants.ytdlpVersionKey, AppConstants.ytdlpBinarySourceKey, AppConstants.ytdlpAutoUpdateKey,
        AppConstants.ytdlpLastUpdateCheckKey, AppConstants.denoVersionKey, AppConstants.denoPinnedVersionKey,
        AppConstants.ytdlpRSAutoUpdateKey, AppConstants.ytdlpRSLastUpdateCheckKey,
    ]
    private var saved: [String: Any] = [:]
    private var root: URL!

    override func setUpWithError() throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedToolServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testMigrationRollbackPinsAndResumes() async throws {
        let store = ManagedToolStore(root: root)
        try writeExecutable("#!/bin/sh\necho 2026.09.01\n", to: store.stableLinkURL(for: .ytdlp))
        try writeExecutable("#!/bin/sh\necho 2026.10.21\n", to: store.executableURL(for: .ytdlp, version: "2026.10.21"))
        UserDefaults.standard.set("2026.09.01", forKey: AppConstants.ytdlpVersionKey)
        UserDefaults.standard.set(BinarySourceSelection.app.rawValue, forKey: AppConstants.ytdlpBinarySourceKey)
        let service = YTDLPUpdateService(managedStore: store, bundledYTDLPRSPathProvider: { nil })

        await service.prepareManagedTools()
        XCTAssertEqual(Set(store.installedVersions(for: .ytdlp)), ["2026.09.01", "2026.10.21"])
        XCTAssertEqual(store.linkedVersion(for: .ytdlp), "2026.10.21")
        let resolved = await service.resolveYTDLPPath()
        XCTAssertEqual(resolved, store.stableLinkURL(for: .ytdlp).path)
        let active = await service.getCurrentVersion()
        XCTAssertEqual(active, "2026.10.21")
        let decision = await service.scheduledCheckDecision(for: .ytdlp)
        XCTAssertEqual(decision, .check)

        // Roll back: the link switches and automatic updates pause.
        await service.setManagedToolPin(.version("2026.09.01"), for: .ytdlp)
        XCTAssertEqual(store.linkedVersion(for: .ytdlp), "2026.09.01")
        let pinnedDecision = await service.scheduledCheckDecision(for: .ytdlp)
        XCTAssertEqual(pinnedDecision, .skip(.pinned))
        let snapshot = await service.managedToolSnapshot(for: .ytdlp)
        XCTAssertEqual(snapshot.activeVersion, "2026.09.01")
        XCTAssertEqual(snapshot.installedVersions, ["2026.10.21", "2026.09.01"])

        // Choosing Newest resumes.
        await service.setManagedToolPin(.automatic, for: .ytdlp)
        XCTAssertEqual(store.linkedVersion(for: .ytdlp), "2026.10.21")
        UserDefaults.standard.set(false, forKey: AppConstants.ytdlpAutoUpdateKey)
        let disabledDecision = await service.scheduledCheckDecision(for: .ytdlp)
        XCTAssertEqual(disabledDecision, .skip(.autoUpdateDisabled))
    }

    func testYTDLPRSResolutionComparesBundledAndDownloadedCopies() async throws {
        let store = ManagedToolStore(root: root)
        let bundled = root.appendingPathComponent("bundle/yt-dlp-rs")
        try writeExecutable("#!/bin/sh\necho yt-dlp-rs \(AppConstants.bundledYTDLPRSVersion)\n", to: bundled)
        let service = YTDLPUpdateService(managedStore: store, bundledYTDLPRSPathProvider: { bundled.path })

        // Off by default while yt-dlp-rs is in beta.
        var path = await service.resolveYTDLPRSPath()
        XCTAssertNil(path)
        UserDefaults.standard.set(true, forKey: AppConstants.ytdlpRSEnabledKey)

        path = await service.resolveYTDLPRSPath()
        XCTAssertEqual(path, bundled.path)

        // An older download never replaces the bundled baseline.
        try writeExecutable("#!/bin/sh\n", to: store.executableURL(for: .ytdlpRS, version: "0.1.0"))
        path = await service.resolveYTDLPRSPath()
        XCTAssertEqual(path, bundled.path)

        let newer = store.executableURL(for: .ytdlpRS, version: "99.0.0-beta.1")
        try writeExecutable("#!/bin/sh\n", to: newer)
        path = await service.resolveYTDLPRSPath()
        XCTAssertEqual(path, newer.path)
        var version = await service.getCurrentYTDLPRSVersion()
        XCTAssertEqual(version, "99.0.0-beta.1")

        // The bundled copy always remains selectable.
        await service.setManagedToolPin(.bundled, for: .ytdlpRS)
        path = await service.resolveYTDLPRSPath()
        XCTAssertEqual(path, bundled.path)
        version = await service.getCurrentYTDLPRSVersion()
        XCTAssertEqual(version, AppConstants.bundledYTDLPRSVersion)

        UserDefaults.standard.set(false, forKey: AppConstants.ytdlpRSEnabledKey)
        path = await service.resolveYTDLPRSPath()
        XCTAssertNil(path)
        version = await service.getCurrentYTDLPRSVersion()
        XCTAssertNil(version)
        let decision = await service.scheduledCheckDecision(for: .ytdlpRS)
        XCTAssertEqual(decision, .skip(.toolDisabled))
    }

    func testBundledYTDLPRSMatchesRecordedVersion() async throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "yt-dlp-rs", ofType: nil), "yt-dlp-rs is not bundled")
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["--version"],
            timeout: .seconds(30)
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(
            ManagedToolPolicy.versionOutput(result.standardOutputText, matches: AppConstants.bundledYTDLPRSVersion),
            "Update AppConstants.bundledYTDLPRSVersion (scripts/update-ytdlp-rs.sh does this)"
        )
    }
}
