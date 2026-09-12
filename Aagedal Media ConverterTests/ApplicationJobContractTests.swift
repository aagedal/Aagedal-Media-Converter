// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ApplicationJobContractTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/input.mov")
    private let destination = URL(fileURLWithPath: "/outputs", isDirectory: true)

    func testSupportedPresetIDsAreStableAndMapToInitialPresetSubset() {
        XCTAssertEqual(ApplicationPresetID.allCases.map(\.rawValue), [
            "h264", "hevc", "prores", "proxy", "audio_only", "stream_copy"
        ])
        XCTAssertEqual(ApplicationPresetID.allCases.map(\.exportPreset), [
            .h264, .h265, .prores, .proxy, .audioOnly, .streamCopy
        ])
    }

    func testRequestAndJobIDRoundTripThroughJSON() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let request = makeRequest(capturedAt: date)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ApplicationConversionRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, 1)

        let id = ApplicationJobID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let idData = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: idData, as: UTF8.self), "\"11111111-2222-3333-4444-555555555555\"")
        XCTAssertEqual(try JSONDecoder().decode(ApplicationJobID.self, from: idData), id)
    }

    func testRequestCapturesResolvedPresetAndNamingSettings() throws {
        let defaults = try makeDefaults()
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(CodecQualityLevel.high.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(EncodingSpeed.slow.rawValue, forKey: AppConstants.h264SpeedKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.h264ResolutionLimitKey)
        defaults.set(CodecAudioFormat.opus.rawValue, forKey: AppConstants.h264AudioFormatKey)
        defaults.set(AudioBitrate.k256.rawValue, forKey: AppConstants.h264AudioBitrateKey)
        defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        defaults.set(false, forKey: AppConstants.fileNameReplaceSpacesKey)

        let request = makeRequest(defaults: defaults)
        XCTAssertEqual(request.presetSettings.containerID, .mkv)
        XCTAssertEqual(request.presetSettings.video?.encoderID, .libx264)
        XCTAssertEqual(request.presetSettings.video?.quality, 18)
        XCTAssertEqual(request.presetSettings.video?.speed, "slow")
        XCTAssertEqual(request.presetSettings.video?.maximumHeight, 720)
        XCTAssertEqual(request.presetSettings.audio, ApplicationAudioSettings(codecID: .opus, bitrate: "256k"))
        XCTAssertTrue(request.presetSettings.preserveMetadata)
        XCTAssertTrue(request.presetSettings.keepSubtitles)
        XCTAssertFalse(request.presetSettings.fileName.replaceSpaces)

        defaults.set(CodecQualityLevel.veryLow.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(CodecAudioFormat.aac.rawValue, forKey: AppConstants.h264AudioFormatKey)
        XCTAssertEqual(request.presetSettings.video?.quality, 18)
        XCTAssertEqual(request.presetSettings.audio?.codecID, .opus)

        let roundTrip = try JSONDecoder().decode(
            ApplicationConversionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(roundTrip, request)
    }

    func testSupportedPresetSnapshotsUseStableResolvedValues() throws {
        let defaults = try makeDefaults()
        defaults.set(ProResProfile.hq.rawValue, forKey: AppConstants.proResProfileKey)
        defaults.set(ProxyCodec.dnxhd.rawValue, forKey: AppConstants.proxyCodecKey)
        defaults.set(ProxyResolutionLimit.r480.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
        defaults.set(AudioOnlyFormat.flac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        defaults.set(StreamCopyContainer.keepCurrent.rawValue, forKey: AppConstants.streamCopyContainerKey)

        let proRes = ApplicationPresetSettings(presetID: .proRes, defaults: defaults)
        XCTAssertEqual(proRes.containerID, .mov)
        XCTAssertEqual(proRes.video?.profileID, .proResHQ)
        XCTAssertEqual(proRes.audio?.codecID, .pcm24)

        let proxy = ApplicationPresetSettings(presetID: .proxy, defaults: defaults)
        XCTAssertEqual(proxy.containerID, .mxf)
        XCTAssertEqual(proxy.video?.encoderID, .dnxhd)
        XCTAssertEqual(proxy.video?.profileID, .dnxhrLB)
        XCTAssertEqual(proxy.video?.maximumHeight, 480)

        let audioOnly = ApplicationPresetSettings(presetID: .audioOnly, defaults: defaults)
        XCTAssertNil(audioOnly.video)
        XCTAssertEqual(audioOnly.containerID, .flac)
        XCTAssertEqual(audioOnly.audio?.codecID, .flac)

        let streamCopy = ApplicationPresetSettings(presetID: .streamCopy, defaults: defaults)
        XCTAssertEqual(streamCopy.containerID, .source)
        XCTAssertEqual(streamCopy.video?.encoderID, .streamCopy)
        XCTAssertEqual(streamCopy.audio?.codecID, .streamCopy)
        XCTAssertFalse(streamCopy.keepSubtitles)
    }

    func testMalformedH265QualityUsesTheExecutionFallback() throws {
        let defaults = try makeDefaults()
        defaults.set("not-a-quality", forKey: AppConstants.h265QualityKey)

        let settings = ApplicationPresetSettings(presetID: .hevc, defaults: defaults)

        XCTAssertEqual(settings.video?.quality, CodecQualityLevel.balanced.crfValue)
    }

    func testAcceptanceCreatesStableQueuedRecordAndPreservesOrder() async throws {
        let registry = ApplicationJobRegistry()
        let first = try await registry.accept(makeRequest(idempotencyKey: nil))
        let second = try await registry.accept(makeRequest(
            sourceURLs: [URL(fileURLWithPath: "/fixtures/second.mov")],
            idempotencyKey: nil
        ))
        XCTAssertFalse(first.wasAlreadyAccepted)
        XCTAssertEqual(first.record.state, .queued)
        let records = await registry.allRecords()
        XCTAssertEqual(records.map(\.id), [first.record.id, second.record.id])
    }

    func testConcurrentRetriesWithSameIdempotencyKeyCreateOneJob() async throws {
        let registry = ApplicationJobRegistry()
        let firstRequest = makeRequest(requestID: UUID(), idempotencyKey: "retry-42")
        let retryRequest = makeRequest(requestID: UUID(), idempotencyKey: "retry-42")

        async let first = registry.accept(firstRequest)
        async let retry = registry.accept(retryRequest)
        let results = try await [first, retry]

        XCTAssertEqual(Set(results.map(\.record.id)).count, 1)
        XCTAssertEqual(results.filter(\.wasAlreadyAccepted).count, 1)
        let records = await registry.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testIdempotencyIsScopedByRequesterAndRejectsChangedPayload() async throws {
        let registry = ApplicationJobRegistry()
        _ = try await registry.accept(makeRequest(requesterID: "client-a", idempotencyKey: "same-key"))
        let otherClient = try await registry.accept(makeRequest(requesterID: "client-b", idempotencyKey: "same-key"))
        XCTAssertFalse(otherClient.wasAlreadyAccepted)

        do {
            _ = try await registry.accept(makeRequest(
                requesterID: "client-a",
                sourceURLs: [URL(fileURLWithPath: "/fixtures/different.mov")],
                idempotencyKey: "same-key"
            ))
            XCTFail("Expected a changed payload to conflict with the accepted key")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .idempotencyConflict)
        }
    }

    func testIdempotencyRejectsAChangedCapturedPresetSnapshot() async throws {
        let defaults = try makeDefaults()
        defaults.set(CodecQualityLevel.good.rawValue, forKey: AppConstants.h264QualityKey)
        let first = makeRequest(idempotencyKey: "same-settings-key", defaults: defaults)

        defaults.set(CodecQualityLevel.low.rawValue, forKey: AppConstants.h264QualityKey)
        let changed = makeRequest(idempotencyKey: "same-settings-key", defaults: defaults)
        let registry = ApplicationJobRegistry()
        _ = try await registry.accept(first)

        do {
            _ = try await registry.accept(changed)
            XCTFail("Expected changed captured settings to conflict")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .idempotencyConflict)
        }
    }

    func testValidationRejectsUnsupportedOrUnsafeBoundaryValues() async {
        let cases: [(ApplicationConversionRequest, ApplicationJobError)] = [
            (makeRequest(schemaVersion: 2), .unsupportedSchema(2)),
            (makeRequest(requesterID: " client "), .invalidRequesterID),
            (makeRequest(sourceURLs: []), .noSources),
            (makeRequest(sourceURLs: [source, source]), .duplicateSource(source)),
            (makeRequest(sourceURLs: [URL(string: "https://example.com/input.mov")!]),
             .nonFileURL(URL(string: "https://example.com/input.mov")!)),
            (makeRequest(destinationFolderURL: URL(string: "https://example.com/output")!),
             .nonFileURL(URL(string: "https://example.com/output")!)),
            (makeRequest(idempotencyKey: " bad-key "), .invalidIdempotencyKey),
            (makeRequest(
                presetID: .h264,
                presetSettings: ApplicationPresetSettings(presetID: .hevc)
            ), .presetSettingsMismatch)
        ]

        for (request, expectedError) in cases {
            let registry = ApplicationJobRegistry()
            do {
                _ = try await registry.accept(request)
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? ApplicationJobError, expectedError)
            }
        }
    }

    func testErrorsExposeStableWireCodes() {
        XCTAssertEqual(ApplicationJobError.unsupportedSchema(99).code.rawValue, "unsupported_schema")
        XCTAssertEqual(ApplicationJobError.idempotencyConflict.code.rawValue, "idempotency_conflict")
        XCTAssertEqual(ApplicationJobError.presetSettingsMismatch.code.rawValue, "preset_settings_mismatch")
        XCTAssertEqual(
            ApplicationJobError.invalidTransition(from: .queued, to: .succeeded).code.rawValue,
            "invalid_transition"
        )
    }

    func testCancellationWaitsForRunningOwnerButQueuedCancellationIsTerminal() async throws {
        let registry = ApplicationJobRegistry()
        let queued = try await registry.accept(makeRequest(idempotencyKey: nil)).record
        let cancelledBeforeStart = try await registry.requestCancellation(queued.id)
        XCTAssertEqual(cancelledBeforeStart.state, .cancelled)

        let running = try await registry.accept(makeRequest(
            sourceURLs: [URL(fileURLWithPath: "/fixtures/running.mov")],
            idempotencyKey: nil
        )).record
        _ = try await registry.transition(running.id, to: .running)
        let cancelling = try await registry.requestCancellation(running.id)
        XCTAssertEqual(cancelling.state, .cancelling)
        let repeatedCancellation = try await registry.requestCancellation(running.id)
        XCTAssertEqual(repeatedCancellation.state, .cancelling)
        let cancelledAfterDrain = try await registry.transition(running.id, to: .cancelled)
        XCTAssertEqual(cancelledAfterDrain.state, .cancelled)
    }

    func testTerminalJobsCannotBeRevivedAndProgressRequiresAnActiveOwner() async throws {
        let registry = ApplicationJobRegistry()
        let record = try await registry.accept(makeRequest()).record
        _ = try await registry.transition(record.id, to: .running)
        let progress = try await registry.updateProgress(record.id, progress: 0.5, stage: "Encoding")
        XCTAssertEqual(progress.progress, 0.5)
        XCTAssertEqual(progress.stage, "Encoding")
        _ = try await registry.transition(
            record.id,
            to: .succeeded,
            outputURLs: [destination.appendingPathComponent("output.mp4")]
        )

        do {
            _ = try await registry.transition(record.id, to: .running)
            XCTFail("Expected a terminal-state transition to fail")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .invalidTransition(from: .succeeded, to: .running))
        }
        do {
            _ = try await registry.updateProgress(record.id, progress: 1.1, stage: nil)
            XCTFail("Expected invalid progress to fail")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .invalidProgress(1.1))
        }
    }

    func testRestartInterruptsOnlyIncompleteJobs() async throws {
        let registry = ApplicationJobRegistry()
        let queued = try await registry.accept(makeRequest(idempotencyKey: "queued")).record
        let running = try await registry.accept(makeRequest(idempotencyKey: "running")).record
        let finished = try await registry.accept(makeRequest(idempotencyKey: "finished")).record
        _ = try await registry.transition(running.id, to: .running)
        _ = try await registry.transition(finished.id, to: .running)
        _ = try await registry.transition(finished.id, to: .succeeded)

        let interrupted = await registry.interruptInFlightJobs(diagnostic: "Application restarted")
        XCTAssertEqual(Set(interrupted.map(\.id)), [queued.id, running.id])
        XCTAssertTrue(interrupted.allSatisfy { $0.state == .interrupted })
        let retainedFinished = await registry.record(for: finished.id)
        XCTAssertEqual(retainedFinished?.state, .succeeded)
    }

    private func makeRequest(
        schemaVersion: Int = ApplicationConversionRequest.currentSchemaVersion,
        requestID: UUID = UUID(),
        origin: ApplicationJobOrigin = .localAgent,
        requesterID: String = "codex",
        sourceURLs: [URL]? = nil,
        destinationFolderURL: URL? = nil,
        presetID: ApplicationPresetID = .h264,
        presetSettings: ApplicationPresetSettings? = nil,
        idempotencyKey: String? = "request-1",
        capturedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        defaults: UserDefaults = .standard
    ) -> ApplicationConversionRequest {
        ApplicationConversionRequest(
            schemaVersion: schemaVersion,
            requestID: requestID,
            origin: origin,
            requesterID: requesterID,
            sourceURLs: sourceURLs ?? [source],
            destinationFolderURL: destinationFolderURL ?? destination,
            presetID: presetID,
            presetSettings: presetSettings,
            idempotencyKey: idempotencyKey,
            capturedAt: capturedAt,
            defaults: defaults
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ApplicationJobContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
