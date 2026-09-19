// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ApplicationJobContractTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/input.mov")
    private let destination = URL(fileURLWithPath: "/outputs", isDirectory: true)

    func testOpenCodeSetupUsesLocalStdioAndKeepsTheHelperPathAsOneArgument() throws {
        let helperURL = URL(fileURLWithPath:
            "/Applications/Aagedal Media Converter.app/Contents/Helpers/aagedal-media-converter-mcp"
        )
        let data = Data(ApplicationAgentMCPClient.openCode.configuration(helperURL: helperURL).utf8)
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try XCTUnwrap(configuration["mcp"] as? [String: [String: Any]])
        let server = try XCTUnwrap(servers["aagedal-media-converter"])

        XCTAssertEqual(configuration["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(server["type"] as? String, "local")
        XCTAssertEqual(server["command"] as? [String], [helperURL.path])
        XCTAssertEqual(server["enabled"] as? Bool, true)
    }

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

    func testRequestDecodesSnapshotsCreatedBeforeCounterCapture() throws {
        let encoded = try JSONEncoder().encode(makeRequest())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "executionSettings")
        root.removeValue(forKey: "sourceSettings")
        var presetSettings = try XCTUnwrap(root["presetSettings"] as? [String: Any])
        var fileName = try XCTUnwrap(presetSettings["fileName"] as? [String: Any])
        fileName.removeValue(forKey: "counterStart")
        presetSettings["fileName"] = fileName
        root["presetSettings"] = presetSettings

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(ApplicationConversionRequest.self, from: legacyData)
        XCTAssertEqual(
            decoded.presetSettings.fileName.counterStart,
            AppConstants.defaultCustomFileNameCounterValue
        )
        XCTAssertNil(decoded.executionSettings)
        XCTAssertNil(decoded.sourceSettings)
    }

    func testSourceSettingsDecodeSnapshotsCreatedBeforePerSourceDestinations() throws {
        let settings = ApplicationSourceExecutionSettings(
            sourceURL: source,
            destinationFolderURL: URL(fileURLWithPath: "/other-output", isDirectory: true),
            includeDateTag: false,
            timecodeConfig: nil
        )
        let encoded = try JSONEncoder().encode(makeRequest(sourceSettings: [settings]))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var sourceSettings = try XCTUnwrap(root["sourceSettings"] as? [[String: Any]])
        sourceSettings[0].removeValue(forKey: "destinationFolderURL")
        root["sourceSettings"] = sourceSettings

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(ApplicationConversionRequest.self, from: legacyData)
        XCTAssertNil(decoded.sourceSettings?.first?.destinationFolderURL)
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

    func testPlanningCapturesDeterministicOutputsAndCollisionWarnings() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("First Clip.mov")
        let secondSource = directory.appendingPathComponent("Second Clip.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{counter}{presetSuffix}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(3, forKey: AppConstants.customFileNameCounterPaddingKey)
        defaults.set(7, forKey: AppConstants.customFileNameCounterValueKey)
        defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        let request = makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: outputDirectory,
            defaults: defaults
        )
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        let existingOutput = outputDirectory.appendingPathComponent("First_Clip_007_h264.mkv")
        try Data().write(to: existingOutput)

        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let plan = try await service.plan(request, now: now)

        XCTAssertEqual(plan.createdAt, now)
        XCTAssertEqual(plan.expiresAt, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(plan.sources.map(\.fileSize), [5, 6])
        XCTAssertEqual(plan.outputs.map { $0.outputURL.lastPathComponent }, [
            "First_Clip_007_h264.mkv", "Second_Clip_008_h264.mkv"
        ])
        XCTAssertEqual(plan.warnings, [
            ApplicationPlanWarning(code: .outputAlreadyExists, url: existingOutput)
        ])
        let roundTrip = try JSONDecoder().decode(
            ApplicationConversionPlan.self,
            from: JSONEncoder().encode(plan)
        )
        XCTAssertEqual(roundTrip, plan)
    }

    func testPlanningUsesAndAuthorizesPerSourceDestinations() async throws {
        final class AccessLog: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [(URL, ApplicationFileAccessMode)] = []

            func append(_ value: (URL, ApplicationFileAccessMode)) {
                lock.withLock { values.append(value) }
            }

            func snapshot() -> [(URL, ApplicationFileAccessMode)] {
                lock.withLock { values }
            }
        }

        let directory = try makeTemporaryDirectory()
        let globalDestination = directory.appendingPathComponent("unused", isDirectory: true)
        let firstDestination = directory.appendingPathComponent("first-output", isDirectory: true)
        let secondDestination = directory.appendingPathComponent("second-output", isDirectory: true)
        for folder in [globalDestination, firstDestination, secondDestination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let sourceSettings = [
            ApplicationSourceExecutionSettings(
                sourceURL: firstSource,
                destinationFolderURL: firstDestination,
                includeDateTag: false,
                timecodeConfig: nil
            ),
            ApplicationSourceExecutionSettings(
                sourceURL: secondSource,
                destinationFolderURL: secondDestination,
                includeDateTag: false,
                timecodeConfig: nil
            )
        ]
        let log = AccessLog()
        let service = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            url, mode in
            log.append((url, mode))
            guard url != globalDestination else { return nil }
            return ApplicationFileAccessLease {}
        })

        let plan = try await service.plan(makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: globalDestination,
            sourceSettings: sourceSettings,
            idempotencyKey: nil
        ))

        XCTAssertEqual(plan.outputs.map { $0.outputURL.deletingLastPathComponent() }, [
            firstDestination, secondDestination
        ])
        let accesses = log.snapshot()
        XCTAssertFalse(accesses.contains { $0.0 == globalDestination })
        XCTAssertTrue(accesses.contains { $0.0 == firstDestination && $0.1 == .write })
        XCTAssertTrue(accesses.contains { $0.0 == secondDestination && $0.1 == .write })
    }

    func testPlanAndSubmitUsesTheSharedPlanningAndAcceptanceBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let defaults = try makeDefaults()
        let request = makeRequest(
            origin: .appIntent,
            requesterID: AppIntentApplicationJobBridge.requesterID,
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            executionSettings: ApplicationRequestExecutionSettings(appIntentDefaults: defaults),
            idempotencyKey: "shortcut-request",
            defaults: defaults
        )
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let now = Date(timeIntervalSince1970: 1_800_000_200)

        let acceptance = try await service.planAndSubmit(request, now: now)

        XCTAssertFalse(acceptance.wasAlreadyAccepted)
        XCTAssertEqual(acceptance.record.request.origin, .appIntent)
        XCTAssertEqual(acceptance.record.state, .queued)
        let outputURLs = try await service.plannedOutputURLs(
            for: acceptance.record.id,
            now: now
        )
        XCTAssertEqual(
            outputURLs,
            [outputDirectory.appendingPathComponent("input_h264.mp4")]
        )
    }

    func testVisibleQueueUpdatesPublishAcceptedAndCancelledJobsWithPlannedOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)

        let service = ApplicationJobService(
            planLifetime: 1,
            fileAccessAuthorizer: .unrestricted
        )
        let updates = await service.recordUpdates()
        var iterator = updates.makeAsyncIterator()
        let initialRecords = await iterator.next()
        XCTAssertEqual(initialRecords, [])

        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        )
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let plan = try await service.plan(request, now: acceptedAt)
        let acceptance = try await service.submit(planID: plan.id, now: acceptedAt)

        let nextAcceptedRecords = await iterator.next()
        let acceptedRecords = try XCTUnwrap(nextAcceptedRecords)
        XCTAssertEqual(acceptedRecords.map(\.id), [acceptance.record.id])
        XCTAssertEqual(acceptedRecords.first?.state, .queued)
        let outputURLs = try await service.plannedOutputURLs(for: acceptance.record.id)
        XCTAssertEqual(outputURLs, plan.outputs.map(\.outputURL))

        // A submitted plan can age out while a long job is still visible. Its
        // immutable accepted request must continue to resolve the same output.
        _ = try await service.plan(request, now: acceptedAt.addingTimeInterval(2))
        let reconstructedOutputURLs = try await service.plannedOutputURLs(for: acceptance.record.id)
        XCTAssertEqual(reconstructedOutputURLs, plan.outputs.map(\.outputURL))

        _ = try await service.requestCancellation(acceptance.record.id)
        let nextCancelledRecords = await iterator.next()
        let cancelledRecords = try XCTUnwrap(nextCancelledRecords)
        XCTAssertEqual(cancelledRecords.first?.state, .cancelled)
    }

    func testPlanningRequiresApprovedReadAndWriteScopes() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        )

        let sourceDenied = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            url, mode in
            guard mode == .write, url == outputDirectory else { return nil }
            return ApplicationFileAccessLease {}
        })
        do {
            _ = try await sourceDenied.plan(request)
            XCTFail("Expected missing source approval to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
        }

        let destinationDenied = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            url, mode in
            guard mode == .read, url == sourceURL else { return nil }
            return ApplicationFileAccessLease {}
        })
        do {
            _ = try await destinationDenied.plan(request)
            XCTFail("Expected missing writable destination approval to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ApplicationJobError,
                .destinationAccessDenied(outputDirectory)
            )
        }
    }

    func testPlanningReportsUnavailableApprovedSource() async throws {
        let directory = try makeTemporaryDirectory()
        let missingSource = directory.appendingPathComponent("unmounted.mov")
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)

        do {
            _ = try await service.plan(makeRequest(
                sourceURLs: [missingSource],
                destinationFolderURL: directory
            ))
            XCTFail("Expected an unavailable source to be rejected during planning")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceUnavailable(missingSource))
            XCTAssertEqual((error as? ApplicationJobError)?.code.rawValue, "source_unavailable")
        }
        let records = try await service.allRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testSubmissionRechecksRevokedFolderAccess() async throws {
        final class GrantState: @unchecked Sendable {
            private let lock = NSLock()
            private var enabled = true

            func revoke() {
                lock.withLock { enabled = false }
            }

            func acquire() -> ApplicationFileAccessLease? {
                lock.withLock { enabled ? ApplicationFileAccessLease {} : nil }
            }
        }

        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let grants = GrantState()
        let service = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            _, _ in grants.acquire()
        })
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        ))

        grants.revoke()
        do {
            _ = try await service.submit(planID: plan.id)
            XCTFail("Expected revoked access to be rejected at submission")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
        }
        let records = try await service.allRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testSubmitRejectsExpiredPlansAndChangedSources() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("before".utf8).write(to: sourceURL)
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: directory,
            idempotencyKey: nil
        )
        let now = Date(timeIntervalSince1970: 1_800_000_200)

        let expiringService = ApplicationJobService(
            planLifetime: 10,
            fileAccessAuthorizer: .unrestricted
        )
        let expiredPlan = try await expiringService.plan(request, now: now)
        do {
            _ = try await expiringService.submit(planID: expiredPlan.id, now: now.addingTimeInterval(11))
            XCTFail("Expected an expired plan to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .expiredPlan(expiredPlan.id))
        }

        let changedSourceService = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let changedPlan = try await changedSourceService.plan(request, now: now)
        try Data("after-change".utf8).write(to: sourceURL)
        do {
            _ = try await changedSourceService.submit(planID: changedPlan.id, now: now)
            XCTFail("Expected a changed source to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceChanged(sourceURL))
        }
    }

    func testSubmissionReservesOutputsAndPlanRetryReturnsOriginalJob() async throws {
        let directory = try makeTemporaryDirectory()
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        for folder in [firstDirectory, secondDirectory, outputDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstSource = firstDirectory.appendingPathComponent("clip.mov")
        let secondSource = secondDirectory.appendingPathComponent("clip.mov")
        try Data("one".utf8).write(to: firstSource)
        try Data("two".utf8).write(to: secondSource)

        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let firstAcceptance = try await service.submit(planID: firstPlan.id)
        let retry = try await service.submit(planID: firstPlan.id)
        XCTAssertEqual(retry.record.id, firstAcceptance.record.id)
        XCTAssertTrue(retry.wasAlreadyAccepted)

        do {
            _ = try await service.submit(planID: secondPlan.id)
            XCTFail("Expected the accepted output reservation to reject a competing plan")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .outputCollision(secondPlan.outputs[0].outputURL))
        }

        _ = try await service.transition(firstAcceptance.record.id, to: .running)
        _ = try await service.transition(firstAcceptance.record.id, to: .succeeded)
        let secondAcceptance = try await service.submit(planID: secondPlan.id)
        XCTAssertNotEqual(secondAcceptance.record.id, firstAcceptance.record.id)
    }

    func testConcurrentSubmissionsReserveAnOutputForOnlyOneJob() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        var plans: [ApplicationConversionPlan] = []
        for _ in 0..<32 {
            plans.append(try await service.plan(makeRequest(
                sourceURLs: [sourceURL], destinationFolderURL: directory, idempotencyKey: nil
            )))
        }
        let outcomes = await withTaskGroup(of: Result<ApplicationJobAcceptance, Error>.self) { group in
            for plan in plans {
                group.addTask {
                    do { return .success(try await service.submit(planID: plan.id)) }
                    catch { return .failure(error) }
                }
            }
            var results: [Result<ApplicationJobAcceptance, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        var accepted: [ApplicationJobAcceptance] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let acceptance): accepted.append(acceptance)
            case .failure(let error):
                XCTAssertEqual(error as? ApplicationJobError, .outputCollision(plans[0].outputs[0].outputURL))
            }
        }
        XCTAssertEqual(accepted.count, 1)
        let records = try await service.allRecords()
        XCTAssertEqual(records.count, 1)

        // Rejection must release admission so subsequent valid work can proceed.
        let winner = try XCTUnwrap(accepted.first)
        _ = try await service.requestCancellation(winner.record.id)
        let nextPlan = try XCTUnwrap(plans.first { $0.request.requestID != winner.record.request.requestID })
        let nextAcceptance = try await service.submit(planID: nextPlan.id)
        XCTAssertFalse(nextAcceptance.wasAlreadyAccepted)
    }

    func testConcurrentPlanRetriesReturnOneAcceptance() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        var plans: [ApplicationConversionPlan] = []
        for _ in 0..<16 {
            plans.append(try await service.plan(makeRequest(
                sourceURLs: [sourceURL], destinationFolderURL: directory,
                idempotencyKey: "concurrent-network-retry"
            )))
        }
        let acceptances = try await withThrowingTaskGroup(of: ApplicationJobAcceptance.self) { group in
            for plan in plans {
                // Exercise both same-plan retries and equivalent newly planned requests.
                for _ in 0..<2 {
                    group.addTask { try await service.submit(planID: plan.id) }
                }
            }
            var results: [ApplicationJobAcceptance] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(acceptances.count, 32)
        XCTAssertEqual(Set(acceptances.map { $0.record.id }).count, 1)
        XCTAssertEqual(acceptances.filter { !$0.wasAlreadyAccepted }.count, 1)
        let records = try await service.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testIdempotentRetryThroughANewPlanReturnsOriginalReservedJob() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let firstRequest = makeRequest(
            requestID: UUID(),
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "network-retry"
        )
        let retryRequest = makeRequest(
            requestID: UUID(),
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "network-retry"
        )

        let firstPlan = try await service.plan(firstRequest)
        let firstAcceptance = try await service.submit(planID: firstPlan.id)
        let retryPlan = try await service.plan(retryRequest)
        let retryAcceptance = try await service.submit(planID: retryPlan.id)

        XCTAssertEqual(retryAcceptance.record.id, firstAcceptance.record.id)
        XCTAssertTrue(retryAcceptance.wasAlreadyAccepted)
        let records = try await service.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testSubmitRejectsAnOutputCreatedAfterPlanning() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory, idempotencyKey: nil
        ))
        let outputURL = try XCTUnwrap(plan.outputs.first?.outputURL)
        try Data("occupied".utf8).write(to: outputURL)

        do {
            _ = try await service.submit(planID: plan.id)
            XCTFail("Expected a submit-time output collision")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .outputCollision(outputURL))
        }
    }

    func testPlanningRejectsTwoSourcesThatResolveToTheSameOutput() async throws {
        let directory = try makeTemporaryDirectory()
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        for folder in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstSource = firstDirectory.appendingPathComponent("same.mov")
        let secondSource = secondDirectory.appendingPathComponent("same.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let request = makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: directory,
            idempotencyKey: nil
        )

        do {
            _ = try await ApplicationJobService(fileAccessAuthorizer: .unrestricted).plan(request)
            XCTFail("Expected duplicate proposed output names to be rejected")
        } catch {
            let expected = directory.appendingPathComponent("same_h264.mp4")
            XCTAssertEqual(error as? ApplicationJobError, .duplicateOutput(expected))
        }
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
        let audioTrack = AudioTrackInfo(
            streamIndex: 0, channels: 2, channelLayout: "stereo", codec: "aac",
            codecLongName: nil, sampleRate: 48_000
        )
        var invalidRouting = AudioRoutingConfig(inputTracks: [audioTrack])
        invalidRouting.channelOperation = .extractChannel(
            trackIndex: 0, channelIndex: 2, channelName: "out-of-range"
        )
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
            ), .presetSettingsMismatch),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: URL(fileURLWithPath: "/fixtures/different.mov"),
                includeDateTag: false,
                timecodeConfig: nil
            )]), .invalidSourceSettings(source)),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: source,
                includeDateTag: false,
                timecodeConfig: nil,
                trimStart: 4,
                trimEnd: 2
            )]), .invalidSourceSettings(source)),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: source,
                includeDateTag: false,
                timecodeConfig: nil,
                cropConfig: CropConfig(
                    normalizedRect: CropRect(x: 0.5, y: 0, width: 0.75, height: 1)
                )
            )]), .invalidSourceSettings(source)),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: source,
                includeDateTag: false,
                timecodeConfig: nil,
                audioRoutingConfig: invalidRouting
            )]), .invalidSourceSettings(source)),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: source,
                includeDateTag: false,
                timecodeConfig: nil,
                outputBaseNameOverride: "../outside"
            )]), .invalidSourceSettings(source)),
            (makeRequest(sourceSettings: [ApplicationSourceExecutionSettings(
                sourceURL: source,
                destinationFolderURL: URL(string: "https://example.com/output")!,
                includeDateTag: false,
                timecodeConfig: nil
            )]), .invalidSourceSettings(source))
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
        XCTAssertEqual(ApplicationJobError.invalidSourceSettings(source).code.rawValue, "invalid_source_settings")
        XCTAssertEqual(ApplicationJobError.outputCollision(destination).code.rawValue, "output_collision")
        XCTAssertEqual(ApplicationJobError.sourceChanged(source).code.rawValue, "source_changed")
        XCTAssertEqual(ApplicationJobError.sourceAccessDenied(source).code.rawValue, "source_access_denied")
        XCTAssertEqual(
            ApplicationJobError.destinationAccessDenied(destination).code.rawValue,
            "destination_access_denied"
        )
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

    func testPersistedPlansAndJobsRestoreIdempotencyAndInterruptIncompleteWork() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "persisted-request"
        )
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        let firstService = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await firstService.plan(request, now: createdAt)
        let accepted = try await firstService.submit(planID: plan.id, now: createdAt)
        _ = try await firstService.transition(accepted.record.id, to: .running, now: createdAt)

        let restoredService = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let restartDate = createdAt.addingTimeInterval(60)
        let interrupted = try await restoredService.restorePersistedState(
            now: restartDate,
            interruptionDiagnostic: "Restarted"
        )
        XCTAssertEqual(interrupted.map(\.id), [accepted.record.id])
        XCTAssertEqual(interrupted.first?.state, .interrupted)
        XCTAssertEqual(interrupted.first?.diagnostic, "Restarted")

        let retryPlan = try await restoredService.plan(request, now: restartDate)
        let retry = try await restoredService.submit(planID: retryPlan.id, now: restartDate)
        XCTAssertEqual(retry.record.id, accepted.record.id)
        XCTAssertEqual(retry.record.state, .interrupted)
        XCTAssertTrue(retry.wasAlreadyAccepted)

        let secondRestore = try await restoredService.restorePersistedState(now: restartDate)
        XCTAssertTrue(secondRestore.isEmpty)
    }

    func testStartupSaveFailurePublishesRecoveryAndRetriesBeforeServingRequests() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let store = ApplicationJobStore(fileURL: stateDirectory.appendingPathComponent("jobs.json"))
        let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let request = makeRequest(sourceURLs: [sourceURL], destinationFolderURL: directory)
        let plan = try await original.plan(request)
        let accepted = try await original.submit(planID: plan.id)
        let savedData = try Data(contentsOf: store.fileURL)
        let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let updates = await restored.recordUpdates()
        let published = expectation(description: "Recovered interruption reaches observers despite save failure")
        let observer = Task {
            for await records in updates {
                if records.contains(where: { $0.id == accepted.record.id && $0.state == .interrupted }) {
                    published.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }

        // Keep the snapshot readable while preventing atomic replacement.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        }
        let recoveryDate = Date()
        do {
            _ = try await restored.restorePersistedState(now: recoveryDate, interruptionDiagnostic: "First recovery")
            XCTFail("Expected recovery persistence failure")
        } catch {
            XCTAssertFalse(error is ApplicationJobError)
        }
        await fulfillment(of: [published], timeout: 5)
        do {
            _ = try await restored.plan(request)
            XCTFail("Expected requests to retry the failed recovery save")
        } catch {
            XCTAssertFalse(error is ApplicationJobError)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), savedData)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        let record = try await restored.record(for: accepted.record.id)
        XCTAssertEqual(record?.state, .interrupted)
        XCTAssertEqual(record?.diagnostic, "First recovery")
        XCTAssertEqual(record?.updatedAt, recoveryDate)
        let reloaded = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let savedRecord = try await reloaded.record(for: accepted.record.id)
        XCTAssertEqual(savedRecord, record)
        let retry = try await restored.submit(planID: plan.id)
        XCTAssertTrue(retry.wasAlreadyAccepted)
        XCTAssertEqual(retry.record, record)
    }

    func testConcurrentStartupRestoresOnceAndPreservesNewSubmissions() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let request = makeRequest(sourceURLs: [sourceURL], destinationFolderURL: directory)
        let plan = try await original.plan(request)
        let accepted = try await original.submit(planID: plan.id)
        let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let requests = try (0..<24).map { index in
            let newSource = directory.appendingPathComponent("restart-\(index).mov")
            try Data("source".utf8).write(to: newSource)
            return makeRequest(
                sourceURLs: [newSource],
                destinationFolderURL: directory,
                idempotencyKey: "restart-\(index)"
            )
        }

        let interrupted = try await withThrowingTaskGroup(of: [ApplicationJobRecord].self) { group in
            for request in requests {
                group.addTask {
                    let recovered = try await restored.restorePersistedState()
                    let newPlan = try await restored.plan(request)
                    _ = try await restored.submit(planID: newPlan.id)
                    return recovered
                }
            }
            var records: [ApplicationJobRecord] = []
            for try await result in group { records.append(contentsOf: result) }
            return records
        }
        XCTAssertEqual(interrupted.map(\.id), [accepted.record.id])
        let records = try await restored.allRecords()
        XCTAssertEqual(records.count, requests.count + 1)
        XCTAssertEqual(records.filter { $0.state == .queued }.count, requests.count)
        for request in requests {
            let retryPlan = try await restored.plan(request)
            let retry = try await restored.submit(planID: retryPlan.id)
            XCTAssertTrue(retry.wasAlreadyAccepted)
            XCTAssertEqual(retry.record.state, .queued)
        }
        let reloaded = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let savedRecords = try await reloaded.allRecords()
        XCTAssertEqual(Set(savedRecords.map(\.id)), Set(records.map(\.id)))
    }

    func testAcceptedPlansSurviveExpiryAndRestartWithTheirJobs() async throws {
        for cancelBeforeExpiry in [false, true] {
            let directory = try makeTemporaryDirectory()
            let source = directory.appendingPathComponent("input.mov")
            try Data("source".utf8).write(to: source)
            let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
            let service = ApplicationJobService(
                planLifetime: 10, recordRetentionLifetime: 100,
                store: store, fileAccessAuthorizer: .unrestricted
            )
            let request = makeRequest(sourceURLs: [source], destinationFolderURL: directory)
            let createdAt = Date()
            let plan = try await service.plan(request, now: createdAt)
            let accepted = try await service.submit(planID: plan.id, now: createdAt)
            let unusedPlan = try await service.plan(request, now: createdAt)
            if cancelBeforeExpiry {
                _ = try await service.requestCancellation(accepted.record.id, now: createdAt)
            }
            let afterExpiry = createdAt.addingTimeInterval(11)
            // Creating another plan triggers ordinary retention cleanup.
            _ = try await service.plan(request, now: afterExpiry)
            let retained = try await service.plan(for: plan.id, now: afterExpiry)
            let expired = try await service.plan(for: unusedPlan.id, now: afterExpiry)
            XCTAssertEqual(retained, plan)
            XCTAssertNil(expired)
            let retry = try await service.submit(planID: plan.id, now: afterExpiry)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            XCTAssertTrue(retry.wasAlreadyAccepted)

            let restored = ApplicationJobService(
                planLifetime: 10, recordRetentionLifetime: 100,
                store: store, fileAccessAuthorizer: .unrestricted
            )
            let restartedRetry = try await restored.submit(planID: plan.id, now: afterExpiry)
            XCTAssertEqual(restartedRetry.record.id, accepted.record.id)
            XCTAssertEqual(restartedRetry.record.state, cancelBeforeExpiry ? .cancelled : .interrupted)
            XCTAssertTrue(restartedRetry.wasAlreadyAccepted)
            let restoredPlan = try await restored.plan(for: plan.id, now: afterExpiry)
            XCTAssertEqual(restoredPlan, plan)
            let outputs = try await restored.plannedOutputURLs(for: accepted.record.id, now: afterExpiry)
            XCTAssertEqual(outputs, plan.outputs.map(\.outputURL))
        }
    }

    func testPlannedOutputsPreferOriginalRequestOverEquivalentRetryDates() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: source)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppConstants.enableFileNameProcessingKey)
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{date}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set("yyyyMMdd", forKey: AppConstants.customFileNameDateFormatKey)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let request = makeRequest(sourceURLs: [source], destinationFolderURL: directory, defaults: defaults)
        let now = Date()
        // Retry plans can predate the plan that is actually accepted. Their
        // requests are equivalent for idempotency but date-based names differ.
        var retryPlans: [ApplicationConversionPlan] = []
        for index in 0..<16 {
            retryPlans.append(try await service.plan(makeRequest(
                sourceURLs: [source], destinationFolderURL: directory,
                presetSettings: request.presetSettings,
                capturedAt: request.capturedAt.addingTimeInterval(Double(index + 1) * 86_400)
            ), now: now))
        }
        let plan = try await service.plan(request, now: now.addingTimeInterval(1))
        let accepted = try await service.submit(planID: plan.id)
        let expected = plan.outputs.map(\.outputURL)
        for retryPlan in retryPlans {
            XCTAssertNotEqual(retryPlan.outputs.map(\.outputURL), expected)
            let retry = try await service.submit(planID: retryPlan.id)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            let outputs = try await service.plannedOutputURLs(for: accepted.record.id)
            XCTAssertEqual(outputs, expected)
        }
        _ = try await service.transition(accepted.record.id, to: .running)
        _ = try await service.transition(accepted.record.id, to: .succeeded, outputURLs: expected)
        let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let outputs = try await restored.plannedOutputURLs(for: accepted.record.id)
        XCTAssertEqual(outputs, expected)
        let record = try await restored.record(for: accepted.record.id)
        XCTAssertEqual(record?.state, .succeeded)
        XCTAssertEqual(record?.outputURLs, expected)
    }

    func testPersistenceRetentionRemovesExpiredPlansAndOldTerminalIdempotencyKeys() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(
            planLifetime: 10,
            recordRetentionLifetime: 20,
            store: store,
            fileAccessAuthorizer: .unrestricted
        )
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "retained-request"
        )
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try await service.plan(request, now: createdAt)
        let accepted = try await service.submit(planID: plan.id, now: createdAt)
        _ = try await service.transition(accepted.record.id, to: .running, now: createdAt)
        _ = try await service.transition(accepted.record.id, to: .succeeded, now: createdAt)

        let retryDate = createdAt.addingTimeInterval(21)
        let newPlan = try await service.plan(request, now: retryDate)
        let removedPlan = try await service.plan(for: plan.id)
        let removedRecord = try await service.record(for: accepted.record.id)
        XCTAssertNil(removedPlan)
        XCTAssertNil(removedRecord)

        let newAcceptance = try await service.submit(planID: newPlan.id, now: retryDate)
        XCTAssertNotEqual(newAcceptance.record.id, accepted.record.id)
        XCTAssertFalse(newAcceptance.wasAlreadyAccepted)
    }

    func testPlanningRetentionPublishesRemovedJobsEvenWhenSavingFails() async throws {
        for failSave in [false, true] {
            let directory = try makeTemporaryDirectory()
            let sourceURL = directory.appendingPathComponent("input.mov")
            try Data("source".utf8).write(to: sourceURL)
            let stateURL = directory.appendingPathComponent("jobs.json")
            let service = ApplicationJobService(
                recordRetentionLifetime: 20,
                store: ApplicationJobStore(fileURL: stateURL),
                fileAccessAuthorizer: .unrestricted
            )
            let request = makeRequest(sourceURLs: [sourceURL], destinationFolderURL: directory)
            let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            let plan = try await service.plan(request, now: createdAt)
            let accepted = try await service.submit(planID: plan.id, now: createdAt)
            _ = try await service.requestCancellation(accepted.record.id, now: createdAt)

            let updates = await service.recordUpdates()
            var iterator = updates.makeAsyncIterator()
            let initial = await iterator.next()
            XCTAssertEqual(initial?.map(\.id), [accepted.record.id])
            let published = expectation(description: "Retention reaches existing queue observers")
            let observer = Task {
                for await records in updates {
                    if records.isEmpty {
                        published.fulfill()
                        return
                    }
                }
            }
            defer { observer.cancel() }

            if failSave {
                try FileManager.default.removeItem(at: stateURL)
                try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            }
            do {
                _ = try await service.plan(request, now: createdAt.addingTimeInterval(21))
                XCTAssertFalse(failSave, "Planning must still report its persistence failure")
            } catch {
                if !failSave { throw error }
            }
            await fulfillment(of: [published], timeout: 5)
            let records = try await service.allRecords()
            XCTAssertTrue(records.isEmpty)

            if failSave {
                try FileManager.default.removeItem(at: stateURL)
                _ = try await service.plan(request, now: createdAt.addingTimeInterval(22))
            }
            let restored = ApplicationJobService(
                store: ApplicationJobStore(fileURL: stateURL),
                fileAccessAuthorizer: .unrestricted
            )
            let restoredRecords = try await restored.allRecords(now: createdAt.addingTimeInterval(22))
            XCTAssertTrue(restoredRecords.isEmpty)
            let removedPlan = try await restored.plan(for: plan.id)
            XCTAssertNil(removedPlan)
        }
    }

    func testDamagedPersistenceBlocksMutationAndIsNotOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("jobs.json")
        let damagedData = Data("{not valid json".utf8)
        try damagedData.write(to: stateURL)
        let service = ApplicationJobService(
            store: ApplicationJobStore(fileURL: stateURL),
            fileAccessAuthorizer: .unrestricted
        )

        do {
            _ = try await service.plan(makeRequest())
            XCTFail("Expected damaged persisted state to block a new plan")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), damagedData)
    }

    func testInvalidSnapshotDoesNotExposePartialRecoveryAndCanRetryAfterRepair() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await original.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory
        ))
        let accepted = try await original.submit(planID: plan.id)
        let validData = try Data(contentsOf: store.fileURL)

        for corruption in 0..<10 {
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var plans = try XCTUnwrap(snapshot["plans"] as? [[String: Any]])
            var links = try XCTUnwrap(snapshot["submittedPlans"] as? [[String: Any]])
            let expectedError: ApplicationJobPersistenceError
            switch corruption {
            case 0:
                plans[0]["schemaVersion"] = 999
                expectedError = .unsupportedSchema(999)
            case 1:
                plans.append(plans[0])
                expectedError = .duplicatePlanID(plan.id)
            case 2:
                plans.removeAll()
                expectedError = .missingSubmittedPlan(plan.id)
            case 3:
                snapshot["records"] = []
                expectedError = .missingSubmittedJob(accepted.record.id)
            case 4:
                links.append(links[0])
                expectedError = .duplicateSubmittedPlan(plan.id)
            default:
                var request = try XCTUnwrap(plans[0]["request"] as? [String: Any])
                switch corruption {
                case 5:
                    request["requesterID"] = "another-client"
                case 6:
                    request["idempotencyKey"] = "another-key"
                case 7:
                    request["sourceURLs"] = [directory.appendingPathComponent("other.mov").absoluteString]
                case 8:
                    request.removeValue(forKey: "idempotencyKey")
                default:
                    request.removeValue(forKey: "idempotencyKey")
                    request["requestID"] = UUID().uuidString
                    var records = try XCTUnwrap(snapshot["records"] as? [[String: Any]])
                    var acceptedRequest = try XCTUnwrap(records[0]["request"] as? [String: Any])
                    acceptedRequest.removeValue(forKey: "idempotencyKey")
                    records[0]["request"] = acceptedRequest
                    snapshot["records"] = records
                }
                plans[0]["request"] = request
                expectedError = .mismatchedSubmittedRequest(plan.id)
            }
            snapshot["plans"] = plans
            snapshot["submittedPlans"] = links
            let damagedData = try JSONSerialization.data(withJSONObject: snapshot)
            try damagedData.write(to: store.fileURL)
            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)

            for _ in 0..<2 {
                do {
                    _ = try await restored.restorePersistedState()
                    XCTFail("Expected invalid snapshot to block recovery")
                } catch {
                    XCTAssertEqual(error as? ApplicationJobPersistenceError, expectedError)
                }
                let updates = await restored.recordUpdates()
                var iterator = updates.makeAsyncIterator()
                let visibleRecords = await iterator.next()
                XCTAssertEqual(visibleRecords, [], "Invalid snapshots must not leak records to the queue")
                XCTAssertEqual(try Data(contentsOf: store.fileURL), damagedData)
            }

            try validData.write(to: store.fileURL)
            let recovered = try await restored.restorePersistedState()
            XCTAssertEqual(recovered.map(\.id), [accepted.record.id])
            XCTAssertEqual(recovered.first?.state, .interrupted)
            let retry = try await restored.submit(planID: plan.id)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            XCTAssertEqual(retry.record.state, .interrupted)
            XCTAssertTrue(retry.wasAlreadyAccepted)
        }
    }

    func testRecoveryRejectsMalformedPlanContentsBeforePublishingJobs() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = [directory.appendingPathComponent("first.mov"), directory.appendingPathComponent("second.mov")]
        for source in sources {
            try Data("source".utf8).write(to: source)
        }
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await original.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
        let accepted = try await original.submit(planID: plan.id)
        let validData = try Data(contentsOf: store.fileURL)

        for corruption in 0..<8 {
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var plans = try XCTUnwrap(snapshot["plans"] as? [[String: Any]])
            var identities = try XCTUnwrap(plans[0]["sources"] as? [[String: Any]])
            var outputs = try XCTUnwrap(plans[0]["outputs"] as? [[String: Any]])
            switch corruption {
            case 0: identities.removeAll()
            case 1: identities.reverse()
            case 2: identities[0]["url"] = directory.appendingPathComponent("other.mov").absoluteString
            case 3: outputs.removeLast()
            case 4: outputs.reverse()
            case 5: outputs[0]["outputURL"] = directory.appendingPathComponent("unapproved/output.mp4").absoluteString
            case 6: outputs[1]["outputURL"] = outputs[0]["outputURL"]
            default: outputs[0]["outputURL"] = "https://example.com/output.mp4"
            }
            plans[0]["sources"] = identities
            plans[0]["outputs"] = outputs
            snapshot["plans"] = plans
            let damagedData = try JSONSerialization.data(withJSONObject: snapshot)
            try damagedData.write(to: store.fileURL)
            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            do {
                _ = try await restored.submit(planID: plan.id)
                XCTFail("Expected malformed plan to block submission")
            } catch {
                XCTAssertEqual(error as? ApplicationJobPersistenceError, .invalidPlanContents(plan.id))
            }
            var updates = await restored.recordUpdates().makeAsyncIterator()
            let visibleRecords = await updates.next()
            XCTAssertEqual(visibleRecords, [])
            XCTAssertEqual(try Data(contentsOf: store.fileURL), damagedData)

            try validData.write(to: store.fileURL)
            let recovered = try await restored.restorePersistedState()
            XCTAssertEqual(recovered.map(\.id), [accepted.record.id])
            let retry = try await restored.submit(planID: plan.id)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            XCTAssertEqual(retry.record.state, .interrupted)
        }
    }

    func testRecoveryRejectsOutputsOutsideAcceptedBatchBeforePublishing() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = [directory.appendingPathComponent("first.mov"), directory.appendingPathComponent("second.mov")]
        for source in sources {
            try Data("source".utf8).write(to: source)
        }
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
        let accepted = try await service.submit(planID: plan.id)
        _ = try await service.transition(accepted.record.id, to: .running)
        let validData = try Data(contentsOf: store.fileURL)
        let expected = plan.outputs.map { $0.outputURL.absoluteString }
        let invalidOutputs: [(ApplicationJobState, [String])] = [
            (.running, [expected[1]]),
            (.failed, Array(expected.reversed())),
            (.cancelled, [expected[0], expected[0]]),
            (.interrupted, expected + [expected[0]]),
            (.failed, [directory.appendingPathComponent("unrelated.mp4").absoluteString]),
            (.failed, ["https://example.com/output.mp4"]),
            (.succeeded, [expected[0]]),
            (.succeeded, []),
            (.queued, [expected[0]])
        ]
        for (state, outputs) in invalidOutputs {
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var records = try XCTUnwrap(snapshot["records"] as? [[String: Any]])
            records[0]["state"] = state.rawValue
            records[0]["outputURLs"] = outputs
            snapshot["records"] = records
            let damagedData = try JSONSerialization.data(withJSONObject: snapshot)
            try damagedData.write(to: store.fileURL)
            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            do {
                _ = try await restored.restorePersistedState()
                XCTFail("Expected invalid saved outputs to block recovery")
            } catch {
                XCTAssertEqual(error as? ApplicationJobPersistenceError, .invalidJobOutputs(accepted.record.id))
            }
            var updates = await restored.recordUpdates().makeAsyncIterator()
            let visible = await updates.next()
            XCTAssertEqual(visible, [])
            XCTAssertEqual(try Data(contentsOf: store.fileURL), damagedData)
            try validData.write(to: store.fileURL)
            let recovered = try await restored.restorePersistedState()
            XCTAssertEqual(recovered.map(\.id), [accepted.record.id])
            let retry = try await restored.submit(planID: plan.id)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            XCTAssertEqual(retry.record.state, .interrupted)
        }
    }

    func testRecoveryPreservesValidBatchOutputsForEveryLifecycleState() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = [directory.appendingPathComponent("first.mov"), directory.appendingPathComponent("second.mov")]
        for source in sources {
            try Data("source".utf8).write(to: source)
        }
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
        let accepted = try await service.submit(planID: plan.id)
        let validData = try Data(contentsOf: store.fileURL)
        let expected = plan.outputs.map(\.outputURL)
        for state in [ApplicationJobState.queued, .running, .cancelling, .succeeded, .failed, .cancelled, .interrupted] {
            let outputs = state == .queued ? [] : state == .succeeded ? expected : Array(expected.prefix(1))
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var records = try XCTUnwrap(snapshot["records"] as? [[String: Any]])
            records[0]["state"] = state.rawValue
            records[0]["outputURLs"] = outputs.map(\.absoluteString)
            snapshot["records"] = records
            try JSONSerialization.data(withJSONObject: snapshot).write(to: store.fileURL)
            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            let record = try await restored.record(for: accepted.record.id)
            XCTAssertEqual(record?.state, state.isTerminal ? state : .interrupted)
            XCTAssertEqual(record?.outputURLs, outputs)
        }
    }

    func testRecoveryPreservesPerSourceDestinationsAndAcceptedNames() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = [directory.appendingPathComponent("first.mov"), directory.appendingPathComponent("second.mov")]
        let destinations = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        for index in sources.indices {
            try Data("source".utf8).write(to: sources[index])
            try FileManager.default.createDirectory(at: destinations[index], withIntermediateDirectories: true)
        }
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await original.plan(makeRequest(
            sourceURLs: sources, destinationFolderURL: directory,
            sourceSettings: sources.indices.map { index in
                ApplicationSourceExecutionSettings(
                    sourceURL: sources[index], destinationFolderURL: destinations[index],
                    includeDateTag: false, timecodeConfig: nil, outputBaseNameOverride: "custom"
                )
            }
        ))
        // An unsubmitted plan must remain usable after restart, including its
        // captured names and separate per-source destinations.
        let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let accepted = try await restored.submit(planID: plan.id)
        XCTAssertEqual(accepted.record.state, .queued)
        let outputs = try await restored.plannedOutputURLs(for: accepted.record.id)
        XCTAssertEqual(outputs, plan.outputs.map(\.outputURL))
        XCTAssertEqual(outputs.map { $0.deletingLastPathComponent().path }, destinations.map(\.path))
    }

    func testRecoveryPreservesOriginalAndEquivalentSubmittedRequests() async throws {
        for key: String? in [nil, "retry-key"] {
            let directory = try makeTemporaryDirectory()
            let sourceURL = directory.appendingPathComponent("input.mov")
            try Data("source".utf8).write(to: sourceURL)
            let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
            let original = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            let request = makeRequest(
                sourceURLs: [sourceURL], destinationFolderURL: directory, idempotencyKey: key
            )
            let plan = try await original.plan(request)
            let accepted = try await original.submit(planID: plan.id)
            var planIDs = [plan.id]
            if key != nil {
                let retryRequest = makeRequest(
                    sourceURLs: [sourceURL], destinationFolderURL: directory,
                    presetSettings: request.presetSettings, idempotencyKey: key,
                    capturedAt: request.capturedAt.addingTimeInterval(1)
                )
                XCTAssertNotEqual(retryRequest.requestID, request.requestID)
                let retryPlan = try await original.plan(retryRequest)
                let retry = try await original.submit(planID: retryPlan.id)
                XCTAssertEqual(retry.record.id, accepted.record.id)
                planIDs.append(retryPlan.id)
            }

            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            let recovered = try await restored.restorePersistedState()
            XCTAssertEqual(recovered.map(\.id), [accepted.record.id])
            for planID in planIDs {
                let retry = try await restored.submit(planID: planID)
                XCTAssertEqual(retry.record.id, accepted.record.id)
                XCTAssertEqual(retry.record.state, .interrupted)
                XCTAssertTrue(retry.wasAlreadyAccepted)
            }
        }
    }

    func testSubmissionRetryRecoversFailedPersistenceWithoutDuplicateExecution() async throws {
        for (useEquivalentPlan, cancelBeforeRetry) in [(false, false), (true, false), (false, true), (true, true)] {
            let directory = try makeTemporaryDirectory()
            let sourceURL = directory.appendingPathComponent("source.mov")
            try Data("source".utf8).write(to: sourceURL)
            let stateURL = directory.appendingPathComponent("jobs.json")
            let harness = ApplicationJobExecutorHarness(blocksFirstExecution: false)
            let service = ApplicationJobService(
                store: ApplicationJobStore(fileURL: stateURL),
                fileAccessAuthorizer: .unrestricted,
                executor: ApplicationJobExecutor(
                    execute: { jobID, plan, progress in
                        await harness.execute(jobID: jobID, plan: plan, progress: progress)
                    },
                    cancel: { jobID in await harness.cancel(jobID: jobID) }
                )
            )
            let request = makeRequest(sourceURLs: [sourceURL], destinationFolderURL: directory)
            let plan = try await service.plan(request)
            let equivalentPlan = try await service.plan(request)

            let updates = await service.recordUpdates()
            let published = expectation(description: "Unsaved acceptance reaches queue observers")
            let observer = Task {
                for await records in updates {
                    if records.contains(where: { $0.request == request && $0.state == .queued }) {
                        published.fulfill()
                        return
                    }
                }
            }
            defer { observer.cancel() }

            // A directory at the snapshot path deterministically rejects atomic writes.
            try FileManager.default.removeItem(at: stateURL)
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
            for _ in 0..<2 {
                do {
                    _ = try await service.submit(planID: plan.id)
                    XCTFail("Expected persistence failure")
                } catch {
                    XCTAssertFalse(error is ApplicationJobError)
                }
            }
            await fulfillment(of: [published], timeout: 5)
            let pendingRecords = try await service.allRecords()
            let pending = try XCTUnwrap(pendingRecords.first)
            XCTAssertEqual(pendingRecords.count, 1)
            XCTAssertEqual(pending.state, .queued)
            let beforeRecovery = await harness.snapshot()
            XCTAssertTrue(beforeRecovery.startedIDs.isEmpty)

            if cancelBeforeRetry {
                do {
                    _ = try await service.requestCancellation(pending.id)
                    XCTFail("Expected cancellation persistence failure")
                } catch {
                    XCTAssertFalse(error is ApplicationJobError)
                }
                let cancelled = try await service.record(for: pending.id)
                XCTAssertEqual(cancelled?.state, .cancelled)
            }
            try FileManager.default.removeItem(at: stateURL)
            let retry = try await service.submit(planID: useEquivalentPlan ? equivalentPlan.id : plan.id)
            XCTAssertTrue(retry.wasAlreadyAccepted)
            XCTAssertEqual(retry.record.id, pending.id)
            let expectedState: ApplicationJobState = cancelBeforeRetry ? .cancelled : .succeeded
            _ = try await waitForRecord(service: service, jobID: pending.id, state: expectedState)
            let secondRetry = try await service.submit(planID: plan.id)
            XCTAssertEqual(secondRetry.record.state, expectedState)
            let afterRecovery = await harness.snapshot()
            XCTAssertEqual(afterRecovery.startedIDs, cancelBeforeRetry ? [] : [pending.id])
            let restored = ApplicationJobService(
                store: ApplicationJobStore(fileURL: stateURL), fileAccessAuthorizer: .unrestricted
            )
            let recovered = try await restored.record(for: pending.id)
            XCTAssertEqual(recovered?.state, expectedState)
            XCTAssertEqual(recovered?.outputURLs, cancelBeforeRetry ? [] : plan.outputs.map(\.outputURL))
        }
    }

    func testRunningPersistenceFailureStopsBeforeExecutionAndReleasesOutputReservation() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: sourceURL)
        let stateURL = directory.appendingPathComponent("jobs.json")
        let gate = ApplicationConversionExecutionGate()
        let legacyID = await gate.acquire()
        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: false)
        let service = ApplicationJobService(
            store: ApplicationJobStore(fileURL: stateURL),
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in await harness.cancel(jobID: jobID) }
            ),
            executionGate: gate
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory
        ))
        let accepted = try await service.submit(planID: plan.id)
        let updates = await service.recordUpdates()
        let failurePublished = expectation(description: "Failed job is visible despite unavailable persistence")
        let visibleFailure = Task { () -> ApplicationJobRecord? in
            for await records in updates {
                if let record = records.first(where: { $0.id == accepted.record.id }),
                   record.state.isTerminal {
                    failurePublished.fulfill()
                    return record
                }
            }
            return nil
        }
        defer { visibleFailure.cancel() }

        // Acceptance is durable, but the later running transition cannot save.
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        await gate.release(legacyID)
        let failed = try await waitForRecord(service: service, jobID: accepted.record.id, state: .failed)
        XCTAssertEqual(failed.diagnostic, "Could not save the job before starting conversion.")
        let beforeRecovery = await harness.snapshot()
        XCTAssertTrue(beforeRecovery.startedIDs.isEmpty)
        await fulfillment(of: [failurePublished], timeout: 5)
        visibleFailure.cancel()
        let visible = await visibleFailure.value
        XCTAssertEqual(visible?.state, .failed)

        try FileManager.default.removeItem(at: stateURL)
        let retry = try await service.submit(planID: plan.id)
        XCTAssertEqual(retry.record.id, accepted.record.id)
        XCTAssertEqual(retry.record.state, .failed)
        let restored = ApplicationJobService(
            store: ApplicationJobStore(fileURL: stateURL), fileAccessAuthorizer: .unrestricted
        )
        let recovered = try await restored.record(for: accepted.record.id)
        XCTAssertEqual(recovered?.state, .failed)

        // A new request can reuse the unproduced output and the execution queue.
        let replacementPlan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory,
            idempotencyKey: "after-running-save-failure"
        ))
        let replacement = try await service.submit(planID: replacementPlan.id)
        _ = try await waitForRecord(service: service, jobID: replacement.record.id, state: .succeeded)
        let completed = await harness.snapshot()
        XCTAssertEqual(completed.startedIDs, [replacement.record.id])
    }

    func testTerminalPersistenceFailurePublishesExecutorResultAndRetrySavesIt() async throws {
        for cancelRunningJob in [false, true] {
            let directory = try makeTemporaryDirectory()
            let sourceURL = directory.appendingPathComponent("source.mov")
            try Data("source".utf8).write(to: sourceURL)
            let stateURL = directory.appendingPathComponent("jobs.json")
            let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
            let started = expectation(description: "Executor started")
            let service = ApplicationJobService(
                store: ApplicationJobStore(fileURL: stateURL),
                fileAccessAuthorizer: .unrestricted,
                executor: ApplicationJobExecutor(
                    execute: { jobID, plan, progress in
                        started.fulfill()
                        return await harness.execute(jobID: jobID, plan: plan, progress: progress)
                    },
                    cancel: { jobID in await harness.cancel(jobID: jobID) }
                )
            )
            let plan = try await service.plan(makeRequest(
                sourceURLs: [sourceURL], destinationFolderURL: directory
            ))
            let accepted = try await service.submit(planID: plan.id)
            await fulfillment(of: [started], timeout: 5)
            let updates = await service.recordUpdates()
            let published = expectation(description: "Terminal result reaches queue observers")
            let observer = Task { () -> ApplicationJobRecord? in
                for await records in updates {
                    if let record = records.first(where: { $0.id == accepted.record.id }),
                       record.state.isTerminal {
                        published.fulfill()
                        return record
                    }
                }
                return nil
            }
            defer { observer.cancel() }
            try FileManager.default.removeItem(at: stateURL)
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
            if cancelRunningJob {
                do {
                    _ = try await service.requestCancellation(accepted.record.id)
                    XCTFail("Expected cancellation persistence failure")
                } catch {
                    XCTAssertFalse(error is ApplicationJobError)
                }
            } else {
                await harness.releaseFirstExecution()
            }
            await fulfillment(of: [published], timeout: 5)
            observer.cancel()
            let visible = await observer.value
            let expectedState: ApplicationJobState = cancelRunningJob ? .cancelled : .succeeded
            let expectedOutputs = cancelRunningJob ? [] : plan.outputs.map(\.outputURL)
            XCTAssertEqual(visible?.state, expectedState)
            XCTAssertEqual(visible?.outputURLs, expectedOutputs)

            try FileManager.default.removeItem(at: stateURL)
            let retry = try await service.submit(planID: plan.id)
            XCTAssertTrue(retry.wasAlreadyAccepted)
            XCTAssertEqual(retry.record.id, accepted.record.id)
            XCTAssertEqual(retry.record.state, expectedState)
            let restored = ApplicationJobService(
                store: ApplicationJobStore(fileURL: stateURL), fileAccessAuthorizer: .unrestricted
            )
            let recovered = try await restored.record(for: accepted.record.id)
            XCTAssertEqual(recovered?.state, expectedState)
            XCTAssertEqual(recovered?.outputURLs, expectedOutputs)
            let execution = await harness.snapshot()
            XCTAssertEqual(execution.startedIDs, [accepted.record.id])
            XCTAssertEqual(execution.cancelledIDs, cancelRunningJob ? [accepted.record.id] : [])
        }
    }

    func testQueuedCancellationPersistenceFailureStillPublishesAndReleasesReservation() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: sourceURL)
        let stateURL = directory.appendingPathComponent("jobs.json")
        let service = ApplicationJobService(
            store: ApplicationJobStore(fileURL: stateURL), fileAccessAuthorizer: .unrestricted
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory
        ))
        let accepted = try await service.submit(planID: plan.id)
        let updates = await service.recordUpdates()
        let published = expectation(description: "Queued cancellation reaches observers")
        let observer = Task {
            for await records in updates {
                if records.contains(where: { $0.id == accepted.record.id && $0.state == .cancelled }) {
                    published.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        do {
            _ = try await service.requestCancellation(accepted.record.id)
            XCTFail("Expected cancellation persistence failure")
        } catch {
            XCTAssertFalse(error is ApplicationJobError)
        }
        await fulfillment(of: [published], timeout: 5)
        try FileManager.default.removeItem(at: stateURL)
        let retry = try await service.submit(planID: plan.id)
        XCTAssertEqual(retry.record.state, .cancelled)
        let replacementPlan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory,
            idempotencyKey: "after-cancellation-save-failure"
        ))
        let replacement = try await service.submit(planID: replacementPlan.id)
        XCTAssertNotEqual(replacement.record.id, accepted.record.id)
        XCTAssertEqual(replacement.record.state, .queued)
    }

    func testSubmittedJobsExecuteSeriallyAndPublishProgressAndOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = makeExecutingService(harness: harness)
        let firstPlan = try await service.plan(makeRequest(
            origin: .manual,
            requesterID: "main-window",
            sourceURLs: [firstSource],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "manual-1"
        ))
        let secondPlan = try await service.plan(makeRequest(
            origin: .localAgent,
            requesterID: "codex",
            sourceURLs: [secondSource],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "agent-1"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)

        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)
        let queuedSecond = try await service.record(for: second.record.id)
        XCTAssertEqual(queuedSecond?.state, .queued)
        let blockedSnapshot = await harness.snapshot()
        XCTAssertEqual(blockedSnapshot.startedIDs, [first.record.id])
        XCTAssertEqual(blockedSnapshot.maximumConcurrentExecutions, 1)

        await harness.releaseFirstExecution()
        let completedFirst = try await waitForRecord(
            service: service, jobID: first.record.id, state: .succeeded
        )
        let completedSecond = try await waitForRecord(
            service: service, jobID: second.record.id, state: .succeeded
        )

        XCTAssertEqual(completedFirst.progress, 1)
        XCTAssertEqual(completedFirst.stage, "Encoding")
        XCTAssertEqual(completedFirst.outputURLs, firstPlan.outputs.map(\.outputURL))
        XCTAssertEqual(completedSecond.outputURLs, secondPlan.outputs.map(\.outputURL))
        XCTAssertEqual(completedFirst.request.origin, .manual)
        XCTAssertEqual(completedSecond.request.origin, .localAgent)
        let completedSnapshot = await harness.snapshot()
        XCTAssertEqual(completedSnapshot.startedIDs, [first.record.id, second.record.id])
        XCTAssertEqual(completedSnapshot.maximumConcurrentExecutions, 1)
    }

    func testApplicationJobWaitsForLegacyExecutionAndSkipsCancelledWork() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: sourceURL)
        let gate = ApplicationConversionExecutionGate()
        let legacyID = await gate.acquire()
        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: false)
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in await harness.cancel(jobID: jobID) }
            ),
            executionGate: gate
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory
        ))
        let accepted = try await service.submit(planID: plan.id)
        let queued = try await service.record(for: accepted.record.id)
        XCTAssertEqual(queued?.state, .queued)

        let cancelled = try await service.requestCancellation(accepted.record.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        await gate.release(legacyID)

        let nextSource = directory.appendingPathComponent("next.mov")
        try Data("next".utf8).write(to: nextSource)
        let nextPlan = try await service.plan(makeRequest(
            sourceURLs: [nextSource],
            destinationFolderURL: directory,
            idempotencyKey: "after-legacy"
        ))
        let next = try await service.submit(planID: nextPlan.id)
        _ = try await waitForRecord(service: service, jobID: next.record.id, state: .succeeded)
        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.startedIDs, [next.record.id])
    }

    func testCancellationSkipsQueuedJobAndSignalsRunningExecutor() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = makeExecutingService(harness: harness)
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: "first"
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: "second"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)

        let queuedCancellation = try await service.requestCancellation(second.record.id)
        XCTAssertEqual(queuedCancellation.state, .cancelled)
        let runningCancellation = try await service.requestCancellation(first.record.id)
        XCTAssertEqual(runningCancellation.state, .cancelling)

        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .cancelled)
        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.startedIDs, [first.record.id])
        XCTAssertEqual(snapshot.cancelledIDs, [first.record.id])
        XCTAssertFalse(snapshot.startedIDs.contains(second.record.id))
    }

    func testExecutionRechecksSourceIdentityAfterWaitingInQueue() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in
                    await harness.cancel(jobID: jobID)
                }
            ),
            sourceIdentityProvider: { url in
                ApplicationSourceIdentity(
                    url: url.standardizedFileURL,
                    fileSize: Int64(try Data(contentsOf: url).count),
                    modificationDate: nil,
                    fileIdentifier: nil
                )
            }
        )
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: "first"
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: "second"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)

        try Data("changed while queued".utf8).write(to: secondSource)
        await harness.releaseFirstExecution()
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .succeeded)
        let failed = try await waitForRecord(
            service: service, jobID: second.record.id, state: .failed
        )

        XCTAssertEqual(failed.diagnostic, ApplicationJobErrorCode.sourceChanged.rawValue)
        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.startedIDs, [first.record.id])
    }

    func testExecutorFailureAndOutputMismatchBecomeTerminalFailures() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let failedSource = directory.appendingPathComponent("failed.mov")
        let mismatchedSource = directory.appendingPathComponent("mismatched.mov")
        try Data("failed".utf8).write(to: failedSource)
        try Data("mismatched".utf8).write(to: mismatchedSource)

        let failedExecutor = ApplicationJobExecutor(
            execute: { _, _, _ in .failed(diagnostic: "Encoder unavailable") },
            cancel: { _ in }
        )
        let failedService = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: failedExecutor
        )
        let failedPlan = try await failedService.plan(makeRequest(
            sourceURLs: [failedSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let failed = try await failedService.submit(planID: failedPlan.id)
        let failedRecord = try await waitForRecord(
            service: failedService, jobID: failed.record.id, state: .failed
        )
        XCTAssertEqual(failedRecord.diagnostic, "Encoder unavailable")

        let mismatchExecutor = ApplicationJobExecutor(
            execute: { _, _, _ in
                .succeeded(outputURLs: [outputDirectory.appendingPathComponent("unexpected.mp4")])
            },
            cancel: { _ in }
        )
        let mismatchService = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: mismatchExecutor
        )
        let mismatchPlan = try await mismatchService.plan(makeRequest(
            sourceURLs: [mismatchedSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let mismatch = try await mismatchService.submit(planID: mismatchPlan.id)
        let mismatchRecord = try await waitForRecord(
            service: mismatchService, jobID: mismatch.record.id, state: .failed
        )
        XCTAssertEqual(
            mismatchRecord.diagnostic,
            "Executor outputs did not match the accepted conversion plan."
        )
    }

    func testExecutionRetainsAllAccessLeasesUntilExecutorCompletes() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)

        let leaseState = ApplicationJobLeaseState()
        let executor = ApplicationJobExecutor(
            execute: { _, plan, progress in
                XCTAssertEqual(leaseState.activeCount, 2)
                await progress.report(ApplicationJobProgressUpdate(progress: 0.5, stage: "Encoding"))
                XCTAssertEqual(leaseState.activeCount, 2)
                return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
            },
            cancel: { _ in }
        )
        let service = ApplicationJobService(
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { _, _ in
                leaseState.acquire()
            },
            executor: executor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        XCTAssertEqual(leaseState.activeCount, 0)
        let accepted = try await service.submit(planID: plan.id)
        let record = try await waitForRecord(
            service: service, jobID: accepted.record.id, state: .succeeded
        )
        XCTAssertEqual(record.outputURLs, plan.outputs.map(\.outputURL))
        XCTAssertEqual(leaseState.activeCount, 0)
    }

    func testFFmpegAdapterBuildsExecutableSettingsForAllSupportedPresets() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )

        for presetID in ApplicationPresetID.allCases {
            let sourceURL = directory.appendingPathComponent("\(presetID.rawValue).mov")
            try Data(presetID.rawValue.utf8).write(to: sourceURL)
            let request = makeRequest(
                sourceURLs: [sourceURL],
                destinationFolderURL: outputDirectory,
                presetID: presetID,
                idempotencyKey: presetID.rawValue,
                defaults: defaults
            )
            let plan = try await service.plan(request)
            let accepted = try await service.submit(planID: plan.id)
            _ = try await waitForRecord(
                service: service,
                jobID: accepted.record.id,
                state: .succeeded
            )
        }

        let snapshots = await harness.snapshots()
        XCTAssertEqual(snapshots.map(\.preset), [.h264, .h265, .prores, .proxy, .audioOnly, .streamCopy])
        XCTAssertEqual(Set(snapshots.map(\.outputURL)).count, ApplicationPresetID.allCases.count)
        XCTAssertTrue(snapshots[0].ffmpegArguments.contains("libx264"))
        XCTAssertTrue(snapshots[1].ffmpegArguments.contains("libx265"))
        XCTAssertTrue(snapshots[2].ffmpegArguments.contains("prores_videotoolbox"))
        XCTAssertTrue(snapshots[3].ffmpegArguments.contains("hevc_videotoolbox"))
        XCTAssertEqual(snapshots[4].audioOnlyFormat, .wav)
        XCTAssertTrue(snapshots[4].ffmpegArguments.contains("pcm_s24le"))
        XCTAssertTrue(snapshots[5].ffmpegArguments.contains("copy"))
        XCTAssertEqual(snapshots[0].keepsSubtitles, true)
        XCTAssertEqual(snapshots[4].keepsSubtitles, false)
    }

    func testFFmpegAdapterExecutesCapturedSettingsAfterDefaultsChange() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("captured.mov")
        let secondSourceURL = directory.appendingPathComponent("captured-2.mov")
        try Data("source".utf8).write(to: sourceURL)
        try Data("source-2".utf8).write(to: secondSourceURL)
        let defaults = try makeDefaults()
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set(CodecQualityLevel.high.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(EncodingSpeed.slow.rawValue, forKey: AppConstants.h264SpeedKey)
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.h264ResolutionLimitKey)
        defaults.set(CodecAudioFormat.pcm24.rawValue, forKey: AppConstants.h264AudioFormatKey)
        defaults.set(true, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("10:11:12:13", forKey: AppConstants.defaultTimecodeValueKey)
        defaults.set("Original", forKey: AppConstants.commentPrefixKey)
        let executionSettings = ApplicationRequestExecutionSettings(appIntentDefaults: defaults)
        let sourceSettings = ApplicationSourceExecutionSettings(
            sourceURL: sourceURL,
            comment: "Per-file comment",
            includeDateTag: false,
            timecodeConfig: TimecodeConfig(mode: .manual("02:03:04:05")),
            trimStart: 1.25,
            trimEnd: 4.5,
            cropConfig: CropConfig(
                normalizedRect: CropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
            ),
            isMuted: true,
            outputBaseNameOverride: "custom-output"
        )
        let secondSourceSettings = ApplicationSourceExecutionSettings(
            sourceURL: secondSourceURL,
            includeDateTag: true,
            timecodeConfig: nil,
            audioRoutingConfig: AudioRoutingConfig(
                inputTracks: [AudioTrackInfo(
                    streamIndex: 0, channels: 6, channelLayout: "5.1", codec: "aac",
                    codecLongName: nil, sampleRate: 48_000
                )],
                outputTracks: [OutputTrack(streamIndex: 0, downmixToStereo: true)]
            )
        )

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL, secondSourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .h264,
            executionSettings: executionSettings,
            sourceSettings: [sourceSettings, secondSourceSettings],
            idempotencyKey: nil,
            defaults: defaults
        ))

        defaults.set(H264Encoder.hardware.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set("50M", forKey: AppConstants.h264BitrateKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(false, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set("disabled", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("Changed", forKey: AppConstants.commentPrefixKey)
        let accepted = try await service.submit(planID: plan.id)
        _ = try await waitForRecord(service: service, jobID: accepted.record.id, state: .succeeded)

        let capturedSnapshots = await harness.snapshots()
        XCTAssertEqual(capturedSnapshots.count, 2)
        let snapshot = try XCTUnwrap(capturedSnapshots.first)
        XCTAssertEqual(plan.outputs.first?.outputURL.pathExtension, "mov")
        XCTAssertEqual(snapshot.outputURL.pathExtension, "")
        XCTAssertTrue(snapshot.ffmpegArguments.contains("libx264"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("18"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("slow"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("pcm_s24le"))
        XCTAssertFalse(snapshot.ffmpegArguments.contains("h264_videotoolbox"))
        XCTAssertFalse(snapshot.ffmpegArguments.contains("50M"))
        XCTAssertFalse(snapshot.includeDateTag)
        XCTAssertEqual(snapshot.manualTimecode, "02:03:04:05")
        XCTAssertEqual(snapshot.comment, "Per-file comment")
        XCTAssertEqual(snapshot.trimStart, 1.25)
        XCTAssertEqual(snapshot.trimEnd, 4.5)
        XCTAssertEqual(snapshot.cropConfig, sourceSettings.cropConfig)
        XCTAssertTrue(snapshot.isMuted)
        XCTAssertEqual(snapshot.outputURL.lastPathComponent, "custom-output")
        XCTAssertEqual(snapshot.commentPrefix, "Original")
        XCTAssertTrue(capturedSnapshots[1].includeDateTag)
        XCTAssertNil(capturedSnapshots[1].manualTimecode)
        XCTAssertEqual(capturedSnapshots[1].comment, "")
        XCTAssertEqual(
            capturedSnapshots[1].audioRoutingConfig,
            secondSourceSettings.audioRoutingConfig
        )
    }

    func testFFmpegAdapterCancellationSignalsOnlyItsActiveRunner() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("cancel.mov")
        try Data("source".utf8).write(to: sourceURL)

        let harness = ApplicationFFmpegRunnerHarness(blocksFirstRun: true)
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: nil
        ))
        let accepted = try await service.submit(planID: plan.id)
        _ = try await waitForRecord(service: service, jobID: accepted.record.id, state: .running)

        // Running is published before the adapter starts its runner. Wait for
        // that handoff so this test exercises cancellation during encoding.
        for _ in 0..<200 {
            if await harness.runCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let startedCount = await harness.runCount()
        XCTAssertEqual(startedCount, 1)
        _ = try await service.requestCancellation(accepted.record.id)
        let cancelled = try await waitForRecord(
            service: service,
            jobID: accepted.record.id,
            state: .cancelled
        )

        XCTAssertEqual(cancelled.diagnostic, "Conversion cancelled.")
        let cancelCount = await harness.cancelCount()
        let runCount = await harness.runCount()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(runCount, 1)
    }

    func testRunningBatchCheckpointsCompletedOutputBeforeNextSourceFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = ["first.mov", "second.mov"].map { directory.appendingPathComponent($0) }
        for source in sources { try Data("source".utf8).write(to: source) }
        let harness = ApplicationFFmpegRunnerHarness(blocksFirstRun: true)
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                if conversion.request.inputURL == sources[0] { return .succeeded }
                return await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(
            store: store, fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
        let accepted = try await service.submit(planID: plan.id)
        for _ in 0..<200 {
            if await harness.runCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let running = try await service.record(for: accepted.record.id)
        XCTAssertEqual(running?.state, .running)
        XCTAssertEqual(running?.outputURLs, [plan.outputs[0].outputURL])

        // Restore a copy while the original executor remains suspended. Recovery
        // must use the on-disk checkpoint, not a terminal callback or live registry.
        let recoveryURL = directory.appendingPathComponent("recovery.json")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("jobs.json"), to: recoveryURL)
        let restored = ApplicationJobService(
            store: ApplicationJobStore(fileURL: recoveryURL), fileAccessAuthorizer: .unrestricted
        )
        let recovered = try await restored.record(for: accepted.record.id)
        XCTAssertEqual(recovered?.state, .interrupted)
        XCTAssertEqual(recovered?.outputURLs, [plan.outputs[0].outputURL])
        let cancelling = try await service.requestCancellation(accepted.record.id)
        XCTAssertEqual(cancelling.outputURLs, [plan.outputs[0].outputURL])
        let cancelled = try await waitForRecord(service: service, jobID: accepted.record.id, state: .cancelled)
        XCTAssertEqual(cancelled.outputURLs, [plan.outputs[0].outputURL])
    }

    func testCheckpointRejectsNonPrefixAndRegressingOutputs() async throws {
        let registry = ApplicationJobRegistry()
        let accepted = try await registry.accept(makeRequest())
        let jobID = accepted.record.id
        _ = try await registry.transition(jobID, to: .running)
        let outputs = ["first.mp4", "second.mp4"].map { destination.appendingPathComponent($0) }
        try await registry.checkpointOutputs(jobID, outputURLs: [outputs[0]], expectedOutputs: outputs)
        for invalid in [[], [outputs[1]], [outputs[0], outputs[0]]] {
            do {
                try await registry.checkpointOutputs(jobID, outputURLs: invalid, expectedOutputs: outputs)
                XCTFail("Invalid checkpoint was accepted")
            } catch ApplicationJobCheckpointError.invalidOutputs { }
        }
        let record = await registry.record(for: jobID)
        XCTAssertEqual(record?.outputURLs, [outputs[0]])
        _ = try await registry.requestCancellation(jobID)
        try await registry.checkpointOutputs(jobID, outputURLs: outputs, expectedOutputs: outputs)
        _ = try await registry.transition(jobID, to: .cancelled, outputURLs: outputs)
        do {
            try await registry.checkpointOutputs(jobID, outputURLs: outputs, expectedOutputs: outputs)
            XCTFail("Terminal job accepted a late checkpoint")
        } catch is ApplicationJobError { }
    }

    func testFFmpegAdapterStopsBatchWhenCheckpointCannotBeSaved() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = ["first.mov", "second.mov"].map { directory.appendingPathComponent($0) }
        for source in sources { try Data("source".utf8).write(to: source) }
        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
        let reporter = ApplicationJobProgressReporter(checkpoint: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }, handler: { _ in })
        let result = await adapter.jobExecutor.execute(ApplicationJobID(), plan, reporter)
        guard case .failed = result else { return XCTFail("Checkpoint failure must stop the batch") }
        XCTAssertEqual(result.outputURLs, [plan.outputs[0].outputURL])
        let count = await harness.runCount()
        XCTAssertEqual(count, 1)
    }

    func testTerminalExecutorResultCannotDiscardCheckpointedOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let executor = ApplicationJobExecutor(execute: { _, plan, reporter in
            do {
                try await reporter.checkpoint(outputURLs: plan.outputs.map(\.outputURL))
            } catch {
                return .failed(diagnostic: "Checkpoint failed")
            }
            return .failed(diagnostic: "Executor omitted completed output")
        }, cancel: { _ in })
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted, executor: executor)
        let plan = try await service.plan(makeRequest(sourceURLs: [source], destinationFolderURL: directory))
        let accepted = try await service.submit(planID: plan.id)
        let record = try await waitForRecord(service: service, jobID: accepted.record.id, state: .failed)
        XCTAssertEqual(record.outputURLs, plan.outputs.map(\.outputURL))
        XCTAssertEqual(record.diagnostic, "Executor outputs did not match the accepted conversion plan.")
    }

    func testCancelledBatchRetainsEarlierCompletedOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let harness = ApplicationFFmpegRunnerHarness(blocksFirstRun: true)
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                if conversion.request.inputURL == firstSource { return .succeeded }
                return await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor)
        let plan = try await service.plan(makeRequest(
            sourceURLs: [firstSource, secondSource], destinationFolderURL: directory
        ))
        let accepted = try await service.submit(planID: plan.id)
        for _ in 0..<200 {
            if await harness.runCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let startedCount = await harness.runCount()
        XCTAssertEqual(startedCount, 1)
        _ = try await service.requestCancellation(accepted.record.id)
        let record = try await waitForRecord(service: service, jobID: accepted.record.id, state: .cancelled)
        XCTAssertEqual(record.outputURLs, [plan.outputs[0].outputURL])
        XCTAssertEqual(record.diagnostic, "Conversion cancelled.")
    }

    func testFailedAndCancelledExecutorsCannotReportNonPrefixOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let sources = ["first.mov", "second.mov"].map { directory.appendingPathComponent($0) }
        for source in sources { try Data("source".utf8).write(to: source) }
        for cancelled in [false, true] {
            let executor = ApplicationJobExecutor(
                execute: { _, plan, _ in
                    let outputs = [plan.outputs[1].outputURL]
                    return cancelled
                        ? .cancelled(diagnostic: "Stopped", outputURLs: outputs)
                        : .failed(diagnostic: "Failed", outputURLs: outputs)
                },
                cancel: { _ in }
            )
            let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted, executor: executor)
            let plan = try await service.plan(makeRequest(sourceURLs: sources, destinationFolderURL: directory))
            let accepted = try await service.submit(planID: plan.id)
            let record = try await waitForRecord(service: service, jobID: accepted.record.id, state: .failed)
            XCTAssertTrue(record.outputURLs.isEmpty)
            XCTAssertEqual(record.diagnostic, "Executor outputs did not match the accepted conversion plan.")
        }
    }

    func testFFmpegAdapterKeepsCancellationReceivedBeforeExecutionStarts() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("early-cancel.mov")
        try Data("source".utf8).write(to: sourceURL)

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let executor = adapter.jobExecutor
        let jobID = ApplicationJobID()

        await executor.cancel(jobID)
        let result = await executor.execute(
            jobID, plan, ApplicationJobProgressReporter { _ in }
        )

        XCTAssertEqual(result, .cancelled(diagnostic: "Conversion cancelled."))
        let runCount = await harness.runCount()
        let cancelCount = await harness.cancelCount()
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    func testFFmpegAdapterRechecksCancellationAfterPreparationProgress() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(sourceURLs: [source], destinationFolderURL: directory))
        let executor = adapter.jobExecutor
        let jobID = ApplicationJobID()
        let result = await executor.execute(jobID, plan, ApplicationJobProgressReporter { _ in
            await executor.cancel(jobID)
        })
        XCTAssertEqual(result, .cancelled(diagnostic: "Conversion cancelled."))
        let runCount = await harness.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testLiveCancellationAfterPublicationRetainsCompletedOutput() async throws {
        let directory = try makeTemporaryDirectory()
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", firstSource.path
        ])
        try FileManager.default.copyItem(at: firstSource, to: secondSource)
        for sourceCount in [1, 2] {
            let destination = directory.appendingPathComponent("outputs-\(sourceCount)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let harness = ApplicationFFmpegRunnerHarness(blocksFirstRun: true)
            let liveRunner = ApplicationFFmpegRunner.live()
            let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
                run: { conversion, progress in
                    let result = await liveRunner.run(conversion, progress)
                    // Suspend delivery of the authoritative completion until
                    // cancellation arrives after the real output was published.
                    _ = await harness.run(conversion: conversion, progress: progress)
                    return result
                },
                cancel: {
                    await liveRunner.cancel()
                    await harness.cancel()
                },
                validatesPlannedOutput: true
            ))
            let store = ApplicationJobStore(fileURL: destination.appendingPathComponent("jobs.json"))
            let service = ApplicationJobService(
                store: store, fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor
            )
            let plan = try await service.plan(makeRequest(
                sourceURLs: Array([firstSource, secondSource].prefix(sourceCount)),
                destinationFolderURL: destination, presetID: .streamCopy
            ))
            let accepted = try await service.submit(planID: plan.id)
            for _ in 0..<500 {
                if await harness.runCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let startedCount = await harness.runCount()
            XCTAssertEqual(startedCount, 1)
            _ = try await service.requestCancellation(accepted.record.id)
            let record = try await waitForRecord(service: service, jobID: accepted.record.id, state: .cancelled)
            XCTAssertEqual(record.outputURLs, [plan.outputs[0].outputURL])
            XCTAssertEqual(record.diagnostic, "Conversion cancelled.")
            let runCount = await harness.runCount()
            XCTAssertEqual(runCount, 1)
            if sourceCount == 2 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: plan.outputs[1].outputURL.path))
            }
            let restored = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
            let restoredRecord = try await restored.record(for: record.id)
            XCTAssertEqual(restoredRecord?.outputURLs, record.outputURLs)
            try runBundledFFmpeg([
                "-hide_banner", "-loglevel", "error", "-i", plan.outputs[0].outputURL.path,
                "-map", "0", "-f", "null", "-"
            ])
        }
    }

    func testFFmpegAdapterRejectsUnrepresentableCapturedSettingsBeforeLaunching() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("invalid.mov")
        try Data("source".utf8).write(to: sourceURL)
        let defaults = try makeDefaults()
        let captured = ApplicationPresetSettings(presetID: .h264, defaults: defaults)
        let invalid = ApplicationPresetSettings(
            presetID: .h264,
            containerID: .mp4,
            video: ApplicationVideoSettings(
                encoderID: .libx264,
                profileID: .hevcMain10,
                quality: 23,
                bitrate: nil,
                speed: "medium",
                maximumHeight: nil
            ),
            audio: captured.audio,
            preserveMetadata: captured.preserveMetadata,
            keepSubtitles: captured.keepSubtitles,
            fileName: captured.fileName
        )

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .h264,
            presetSettings: invalid,
            idempotencyKey: nil
        ))
        let accepted = try await service.submit(planID: plan.id)
        let failed = try await waitForRecord(
            service: service,
            jobID: accepted.record.id,
            state: .failed
        )

        XCTAssertEqual(
            failed.diagnostic,
            "The accepted preset settings cannot be represented by the conversion engine."
        )
        let runCount = await harness.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testAgentToolsAdvertiseOnlySupportedPresetsWithCapturedSettings() throws {
        let defaults = try makeDefaults()
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(AudioOnlyFormat.flac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        let defaultsFixture = ApplicationAgentDefaultsFixture(defaults)
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            presetSettingsProvider: {
                ApplicationPresetSettings(presetID: $0, defaults: defaultsFixture.value)
            }
        )

        let presets = tools.listPresets()

        XCTAssertEqual(presets.map(\.id), ApplicationPresetID.allCases)
        XCTAssertEqual(presets.map(\.displayName), [
            "H.264 / AVC", "H.265 / HEVC", "ProRes", "Proxy", "Audio Only", "Stream Copy"
        ])
        XCTAssertTrue(presets.allSatisfy { $0.supportedOverrides.isEmpty })
        XCTAssertEqual(presets.first { $0.id == .h264 }?.settings.containerID, .mkv)
        XCTAssertEqual(presets.first { $0.id == .audioOnly }?.settings.containerID, .flac)
        XCTAssertNoThrow(try JSONDecoder().decode(
            [ApplicationPresetDescriptor].self,
            from: JSONEncoder().encode(presets)
        ))
    }

    func testAgentToolsInspectionRetainsAccessAndReturnsCodableMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("clip.mov")
        try Data("fixture".utf8).write(to: sourceURL)
        let leaseState = ApplicationJobLeaseState()
        let expected = ApplicationMediaInspection(
            sourceURL: sourceURL,
            durationSeconds: 12.5,
            formatName: "mov",
            containerName: "QuickTime",
            sizeBytes: 4_096,
            bitRate: 2_000_000,
            timecode: "01:00:00:00",
            timecodes: [],
            frameCount: 300,
            warnings: ["fixture warning"],
            videoStreams: [ApplicationMediaVideoStream(
                index: 0,
                codec: "h264",
                profile: "High",
                width: 1920,
                height: 1080,
                pixelFormat: "yuv420p",
                hasAlpha: false,
                pixelAspectRatio: nil,
                displayAspectRatio: nil,
                frameRate: ApplicationMediaRational(numerator: 24_000, denominator: 1_001, value: 23.976),
                bitDepth: 8,
                bitRate: 1_800_000,
                durationSeconds: 12.5,
                chromaSubsampling: "4:2:0",
                colorPrimaries: "bt709",
                colorTransfer: "bt709",
                colorSpace: "bt709",
                colorRange: "tv",
                fieldOrder: "progressive",
                isInterlaced: false,
                title: nil,
                isDefault: true,
                isForced: false
            )],
            audioStreams: [],
            subtitleStreams: []
        )
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { url, mode in
                guard url == sourceURL, mode == .read else { return nil }
                return leaseState.acquire()
            },
            mediaInspector: ApplicationMediaInspector { url in
                XCTAssertEqual(url, sourceURL)
                XCTAssertEqual(leaseState.activeCount, 1)
                return expected
            }
        )

        let inspection = try await tools.inspectMedia(at: sourceURL)

        XCTAssertEqual(inspection, expected)
        XCTAssertEqual(leaseState.activeCount, 0)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ApplicationMediaInspection.self,
                from: JSONEncoder().encode(inspection)
            ),
            expected
        )
    }

    func testMediaInspectionMapsProbeStreamsAndExactFrameRate() throws {
        let sourceURL = URL(fileURLWithPath: "/approved/clip.mov")
        let metadata = VideoMetadata(
            duration: 10,
            formatName: "mov",
            containerLongName: "QuickTime",
            sizeBytes: 1_024,
            bitRate: 900_000,
            comment: nil,
            timecode: "10:00:00:00",
            timecodes: [TimecodeEntry(value: "10:00:00:00", source: .tmcdTrack, frameRate: 23.976)],
            frameCount: 240,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [VideoMetadata.VideoStream(
                codec: "h264",
                codecLongName: "H.264",
                profile: "High",
                width: 1920,
                height: 1080,
                pixelFormat: "yuv420p",
                hasAlpha: false,
                pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                frameRate: VideoMetadata.FrameRate(frameRateString: "24000/1001"),
                bitDepth: 8,
                bitRate: 800_000,
                duration: 10,
                chromaSubsampling: "4:2:0",
                colorPrimaries: "bt709",
                colorTransfer: "bt709",
                colorSpace: "bt709",
                colorRange: "tv",
                chromaLocation: "left",
                fieldOrder: "progressive",
                isInterlaced: false,
                title: "Picture",
                isDefault: true,
                isForced: false
            )],
            audioStreams: [VideoMetadata.AudioStream(
                index: 1,
                languageCode: "eng",
                title: "Main",
                codec: "aac",
                codecLongName: "AAC",
                profile: "LC",
                sampleRate: 48_000,
                channels: 2,
                channelLayout: "stereo",
                bitDepth: nil,
                bitRate: 96_000,
                isDefault: true
            )],
            subtitleStreams: [VideoMetadata.SubtitleStream(
                index: 2,
                languageCode: "nor",
                title: "Norsk",
                codec: "mov_text",
                codecLongName: "MOV text",
                isDefault: false,
                isForced: true,
                isHearingImpaired: false,
                duration: 9.5
            )]
        )

        let inspection = ApplicationMediaInspection(sourceURL: sourceURL, metadata: metadata)

        XCTAssertEqual(inspection.videoStreams[0].frameRate?.numerator, 24_000)
        XCTAssertEqual(inspection.videoStreams[0].frameRate?.denominator, 1_001)
        XCTAssertEqual(inspection.videoStreams[0].displayAspectRatio?.value, 16.0 / 9.0)
        XCTAssertEqual(inspection.videoStreams[0].width, 1920)
        XCTAssertEqual(inspection.audioStreams[0].channelLayout, "stereo")
        XCTAssertEqual(inspection.subtitleStreams[0].languageCode, "nor")
        XCTAssertEqual(inspection.timecodes, metadata.timecodes)
    }

    func testAgentToolsInspectionRejectsMissingApprovalAndMapsFailures() async throws {
        let sourceURL = URL(fileURLWithPath: "/not-approved/clip.mov")
        let unknownJob = ApplicationJobID(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { _, _ in nil },
            mediaInspector: ApplicationMediaInspector { _ in
                XCTFail("Inspection must not run without an approved bookmark")
                throw CancellationError()
            }
        )

        do {
            _ = try await tools.inspectMedia(at: sourceURL)
            XCTFail("Expected source access rejection")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
            XCTAssertEqual(
                ApplicationAgentToolFailure(error: error),
                ApplicationAgentToolFailure(
                    code: .sourceAccessDenied,
                    message: "Access to the source has not been approved in the app: clip.mov."
                )
            )
        }

        XCTAssertEqual(
            ApplicationAgentToolFailure(error: ApplicationJobError.unknownJob(unknownJob)).code,
            .unknownJob
        )
        XCTAssertEqual(
            ApplicationAgentToolFailure(error: CocoaError(.fileReadUnknown)).code,
            .internalError
        )
    }

    func testAgentToolsInspectionReportsUnavailableApprovedSource() async throws {
        let directory = try makeTemporaryDirectory()
        let missingSource = directory.appendingPathComponent("unmounted.mov")
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            mediaInspector: ApplicationMediaInspector { _ in
                XCTFail("Inspection must not run for an unavailable source")
                throw CancellationError()
            }
        )

        do {
            _ = try await tools.inspectMedia(at: missingSource)
            XCTFail("Expected an unavailable source to be rejected before inspection")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceUnavailable(missingSource))
            XCTAssertEqual(ApplicationAgentToolFailure(error: error).code, .sourceUnavailable)
        }
    }

    func testAgentToolsInspectionReportsSourceLostDuringProbe() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("external.mov")
        try Data("source".utf8).write(to: sourceURL)
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            mediaInspector: ApplicationMediaInspector { url in
                try FileManager.default.removeItem(at: url)
                throw CocoaError(.fileReadUnknown)
            }
        )

        do {
            _ = try await tools.inspectMedia(at: sourceURL)
            XCTFail("Expected a source lost during probing to be reported as unavailable")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceUnavailable(sourceURL))
            XCTAssertEqual(ApplicationAgentToolFailure(error: error).code, .sourceUnavailable)
        }
    }

    func testAgentToolsInspectionKeepsProbeFailureForAvailableSource() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("invalid.mov")
        try Data("not media".utf8).write(to: sourceURL)
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            mediaInspector: ApplicationMediaInspector { _ in
                throw CocoaError(.fileReadCorruptFile)
            }
        )

        do {
            _ = try await tools.inspectMedia(at: sourceURL)
            XCTFail("Expected a present, invalid media source to fail inspection")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .mediaInspectionFailed(sourceURL))
            XCTAssertEqual(ApplicationAgentToolFailure(error: error).code, .mediaInspectionFailed)
        }
    }

    func testAgentToolsInspectionRejectsDirectoryBeforeProbe() async throws {
        let directory = try makeTemporaryDirectory()
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            mediaInspector: ApplicationMediaInspector { _ in
                XCTFail("A directory must not be sent to the media probe")
                throw CocoaError(.fileReadUnknown)
            }
        )

        do {
            _ = try await tools.inspectMedia(at: directory)
            XCTFail("Expected a directory to be rejected as an unavailable media source")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceUnavailable(directory))
        }
    }

    func testAgentToolsPlanSubmitGetAndCancelUseSharedJobService() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let instant = Date(timeIntervalSince1970: 1_800_123_456)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let tools = ApplicationAgentTools(
            jobService: service,
            fileAccessAuthorizer: .unrestricted,
            now: { instant }
        )
        let input = ApplicationPlanConversionInput(
            requesterID: "mcp-client",
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .hevc,
            idempotencyKey: "agent-request-1"
        )

        let plan = try await tools.planConversion(input)
        XCTAssertEqual(plan.request.origin, .localAgent)
        XCTAssertEqual(plan.request.requesterID, "mcp-client")
        XCTAssertEqual(plan.request.capturedAt, instant)
        XCTAssertEqual(plan.createdAt, instant)
        XCTAssertEqual(plan.request.presetSettings.presetID, .hevc)

        let accepted = try await tools.submitConversion(planID: plan.id)
        let acceptedRecord = try await tools.getJob(jobID: accepted.record.id)
        XCTAssertEqual(acceptedRecord, accepted.record)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ApplicationJobAcceptance.self,
                from: JSONEncoder().encode(accepted)
            ),
            accepted
        )

        let cancelled = try await tools.cancelJob(jobID: accepted.record.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        let cancelledRecord = try await tools.getJob(jobID: accepted.record.id)
        XCTAssertEqual(cancelledRecord.state, .cancelled)
    }

    func testAgentTransportDispatchesTypedToolsAndRejectsInvalidArguments() async throws {
        let dispatcher = ApplicationAgentRequestDispatcher(
            tools: ApplicationAgentTools(
                jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
                fileAccessAuthorizer: .unrestricted
            )
        )
        let listRequest = ApplicationAgentIPCRequest(tool: .listPresets)
        let listResponse = await dispatcher.response(to: listRequest)

        XCTAssertEqual(listResponse.requestID, listRequest.requestID)
        XCTAssertNil(listResponse.failure)
        guard case .array(let presets)? = listResponse.result else {
            return XCTFail("Expected a preset array")
        }
        XCTAssertEqual(presets.count, ApplicationPresetID.allCases.count)

        let invalidRequest = ApplicationAgentIPCRequest(
            tool: .inspectMedia,
            arguments: ["source_path": .string("relative.mov")]
        )
        let invalidResponse = await dispatcher.response(to: invalidRequest)
        XCTAssertNil(invalidResponse.result)
        XCTAssertEqual(invalidResponse.failure?.code, .invalidArguments)
        XCTAssertEqual(
            invalidResponse.failure?.message,
            "source_path must be an absolute local path."
        )

        let directory = try makeTemporaryDirectory()
        let missingSource = directory.appendingPathComponent("unmounted.mov")
        let unavailableInspection = await dispatcher.response(to: ApplicationAgentIPCRequest(
            tool: .inspectMedia,
            arguments: ["source_path": .string(missingSource.path)]
        ))
        XCTAssertEqual(unavailableInspection.failure?.code, .sourceUnavailable)

        let unavailablePlan = await dispatcher.response(to: ApplicationAgentIPCRequest(
            tool: .planConversion,
            arguments: [
                "source_paths": .array([.string(missingSource.path)]),
                "destination_path": .string(directory.path),
                "preset_id": .string("h264"),
                "requester_id": .string("Codex")
            ]
        ))
        XCTAssertEqual(unavailablePlan.failure?.code, .sourceUnavailable)

        let unexpectedArgumentResponse = await dispatcher.response(to: ApplicationAgentIPCRequest(
            tool: .listPresets,
            arguments: ["ignored": .bool(true)]
        ))
        XCTAssertEqual(unexpectedArgumentResponse.failure?.code, .invalidArguments)
        XCTAssertEqual(
            unexpectedArgumentResponse.failure?.message,
            "Unexpected argument: ignored."
        )

        let encoded = try JSONEncoder().encode(listResponse)
        XCTAssertEqual(
            try JSONDecoder().decode(ApplicationAgentIPCResponse.self, from: encoded),
            listResponse
        )
    }

    func testAgentMessagePortRoundTripKeepsRequestIdentity() throws {
        let portName = "com.aagedal.tests.agent.\(UUID().uuidString)"
        let server = ApplicationAgentIPCServer(
            portName: portName,
            dispatcher: ApplicationAgentRequestDispatcher(
                tools: ApplicationAgentTools(
                    jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
                    fileAccessAuthorizer: .unrestricted
                )
            )
        )
        try server.start()
        defer { server.stop() }

        let request = ApplicationAgentIPCRequest(tool: .listPresets)
        let response = try ApplicationAgentIPCClient(portName: portName).send(
            request,
            receiveTimeout: 10
        )

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertNil(response.failure)
        guard case .array(let presets)? = response.result else {
            return XCTFail("Expected a preset array")
        }
        XCTAssertEqual(presets.count, ApplicationPresetID.allCases.count)

        server.stop()
        XCTAssertFalse(server.isRunning)
        try server.start()
        let restartedResponse = try ApplicationAgentIPCClient(portName: portName).send(
            request,
            receiveTimeout: 10
        )
        XCTAssertEqual(restartedResponse.requestID, request.requestID)
        XCTAssertNil(restartedResponse.failure)
    }

    func testDisablingAgentAccessDuringDelayedStartupCannotReopenEndpoint() async throws {
        final class AccessState: @unchecked Sendable {
            private let lock = NSLock()
            private var enabled = true
            private var running = false

            func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
            func isEnabled() -> Bool { lock.withLock { enabled } }
            func start() { lock.withLock { running = true } }
            func stop() { lock.withLock { running = false } }
            func isRunning() -> Bool { lock.withLock { running } }
        }

        let state = AccessState()
        let startupEntered = expectation(description: "Endpoint startup began")
        let finishStartup = DispatchSemaphore(value: 0)
        defer { finishStartup.signal() }
        let lifecycle = ApplicationAgentAccessLifecycle(
            isEnabled: { state.isEnabled() },
            start: {
                startupEntered.fulfill()
                _ = finishStartup.wait(timeout: .now() + 5)
                state.start()
            },
            stop: { state.stop() }
        )

        let startup = Task { try await lifecycle.reconcile() }
        await fulfillment(of: [startupEntered], timeout: 5)
        state.setEnabled(false)
        let disabling = Task { try await lifecycle.reconcile() }
        finishStartup.signal()

        let startupResult = try await startup.value
        let disablingResult = try await disabling.value
        XCTAssertFalse(startupResult)
        XCTAssertFalse(disablingResult)
        XCTAssertFalse(state.isRunning())
    }

    func testPackagedMCPHelperReturnsObjectResultsAndOwnsRequesterID() throws {
        let portID = UUID()
        let server = ApplicationAgentIPCServer(
            portName: "com.aagedal.tests.agent.\(portID.uuidString)",
            dispatcher: ApplicationAgentRequestDispatcher(
                tools: ApplicationAgentTools(
                    jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
                    fileAccessAuthorizer: .unrestricted
                )
            )
        )
        try server.start()
        defer { server.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data([0]).write(to: sourceURL)

        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "clientInfo": ["name": "Codex"]
                ]
            ],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "list_presets", "arguments": [:]]
            ],
            [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": [
                    "name": "plan_conversion",
                    "arguments": [
                        "source_paths": [sourceURL.path],
                        "destination_path": directory.path,
                        "preset_id": "h264",
                        "requester_id": "forged-client"
                    ]
                ]
            ]
        ]
        let responses = try runPackagedMCPHelper(portID: portID, messages: messages)
        XCTAssertEqual(responses.count, 3)
        let presetResult = try XCTUnwrap(responses[1]["result"] as? [String: Any])
        XCTAssertEqual(presetResult["isError"] as? Bool, false)
        let presetContent = try XCTUnwrap(presetResult["structuredContent"] as? [String: Any])
        XCTAssertEqual((presetContent["presets"] as? [[String: Any]])?.count, 6)
        let presetText = try XCTUnwrap((presetResult["content"] as? [[String: Any]])?.first?["text"] as? String)
        let textContent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(presetText.utf8)) as? [String: Any]
        )
        XCTAssertEqual((textContent["presets"] as? [[String: Any]])?.count, 6)

        let planResult = try XCTUnwrap(responses[2]["result"] as? [String: Any])
        XCTAssertEqual(planResult["isError"] as? Bool, false)
        let planContent = try XCTUnwrap(planResult["structuredContent"] as? [String: Any])
        let request = try XCTUnwrap(planContent["request"] as? [String: Any])
        XCTAssertEqual(request["requesterID"] as? String, "Codex")
    }

    func testPackagedMCPHelperRejectsNonObjectToolArguments() throws {
        let responses = try runPackagedMCPHelper(portID: UUID(), messages: [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "clientInfo": ["name": "Codex"]
            ]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "list_presets", "arguments": []
            ]]
        ])
        XCTAssertEqual(responses.count, 2)
        let error = try XCTUnwrap(responses[1]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "Tool arguments must be an object.")
    }

    func testPackagedMCPHelperRejectsIncompatibleAppResponses() throws {
        final class RunLoopState: @unchecked Sendable {
            let source: CFRunLoopSource
            private let lock = NSLock()
            private var storedRunLoop: CFRunLoop?

            init(source: CFRunLoopSource) { self.source = source }

            var runLoop: CFRunLoop? { lock.withLock { storedRunLoop } }

            func store(_ runLoop: CFRunLoop) {
                lock.withLock { storedRunLoop = runLoop }
            }
        }

        let portID = UUID()
        var shouldFreeInfo = DarwinBoolean(false)
        let port = try XCTUnwrap(CFMessagePortCreateLocal(
            nil,
            "com.aagedal.tests.agent.\(portID.uuidString)" as CFString,
            { _, _, data, _ in
                guard let data,
                      let request = try? JSONSerialization.jsonObject(with: data as Data)
                        as? [String: Any],
                      let requestID = request["requestID"] as? String else { return nil }
                var payload: [String: Any] = [
                    "schemaVersion": request["tool"] as? String == "get_job" ? 1 : 2,
                    "requestID": requestID,
                    "result": ["presets": []]
                ]
                if request["tool"] as? String == "get_job" {
                    payload["failure"] = [
                        "code": "internal_error", "message": "An ambiguous result."
                    ]
                }
                guard let response = try? JSONSerialization.data(withJSONObject: payload) else {
                    return nil
                }
                return Unmanaged.passRetained(response as CFData)
            },
            nil,
            &shouldFreeInfo
        ))
        let source = try XCTUnwrap(CFMessagePortCreateRunLoopSource(nil, port, 0))
        let runLoopState = RunLoopState(source: source)
        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.aagedal.tests.malformed-agent-response").async {
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                stopped.signal()
                return
            }
            runLoopState.store(runLoop)
            CFRunLoopAddSource(runLoop, runLoopState.source, .defaultMode)
            ready.signal()
            CFRunLoopRun()
            stopped.signal()
        }
        defer {
            CFMessagePortInvalidate(port)
            if let runLoop = runLoopState.runLoop { CFRunLoopStop(runLoop) }
            _ = stopped.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)

        let responses = try runPackagedMCPHelper(portID: portID, messages: [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "clientInfo": ["name": "Codex"]
            ]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "list_presets", "arguments": [:]
            ]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                "name": "get_job", "arguments": ["job_id": UUID().uuidString]
            ]]
        ])
        XCTAssertEqual(responses.count, 3)
        for response in responses.dropFirst() {
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            let error = try XCTUnwrap(structured["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "transport_unavailable")
            XCTAssertEqual(error["message"] as? String,
                           "Aagedal Media Converter returned an invalid response.")
        }
    }

    func testPackagedMCPHelperRechecksAccessAndKeepsJobsAcrossClientReconnect() throws {
        final class GrantState: @unchecked Sendable {
            private let lock = NSLock()
            private var sourceApproved = true

            func setSourceApproved(_ approved: Bool) {
                lock.withLock { sourceApproved = approved }
            }

            func acquire(_ mode: ApplicationFileAccessMode) -> ApplicationFileAccessLease? {
                lock.withLock {
                    guard mode == .write || sourceApproved else { return nil }
                    return ApplicationFileAccessLease {}
                }
            }
        }

        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: sourceURL)
        let grants = GrantState()
        let service = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            _, mode in grants.acquire(mode)
        })
        let portID = UUID()
        let server = ApplicationAgentIPCServer(
            portName: "com.aagedal.tests.agent.\(portID.uuidString)",
            dispatcher: ApplicationAgentRequestDispatcher(tools: ApplicationAgentTools(
                jobService: service,
                fileAccessAuthorizer: .unrestricted
            ))
        )
        try server.start()
        defer { server.stop() }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "Codex"]]
        ]
        let initialized: [String: Any] = [
            "jsonrpc": "2.0", "method": "notifications/initialized"
        ]
        let planned = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "plan_conversion", "arguments": [
                    "source_paths": [sourceURL.path],
                    "destination_path": directory.path,
                    "preset_id": "h264",
                    "idempotency_key": "reconnect-test"
                ]
            ]]
        ])
        let plan = try XCTUnwrap(planned[1]["result"] as? [String: Any])
        XCTAssertEqual(plan["isError"] as? Bool, false)
        let planID = try XCTUnwrap(
            (plan["structuredContent"] as? [String: Any])?["id"] as? String
        )

        grants.setSourceApproved(false)
        let denied = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "submit_conversion", "arguments": ["plan_id": planID]
            ]]
        ])
        let denial = try XCTUnwrap(denied[1]["result"] as? [String: Any])
        XCTAssertEqual(denial["isError"] as? Bool, true)
        XCTAssertEqual(
            ((denial["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String,
            "source_access_denied"
        )

        grants.setSourceApproved(true)
        let submitted = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "submit_conversion", "arguments": ["plan_id": planID]
            ]]
        ])
        let acceptance = try XCTUnwrap(
            (submitted[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(acceptance["wasAlreadyAccepted"] as? Bool, false)
        let jobID = try XCTUnwrap((acceptance["record"] as? [String: Any])?["id"] as? String)

        let reconnected = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "get_job", "arguments": ["job_id": jobID]
            ]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                "name": "cancel_job", "arguments": ["job_id": jobID]
            ]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [
                "name": "submit_conversion", "arguments": ["plan_id": planID]
            ]]
        ])
        let lookedUp = try XCTUnwrap(
            (reconnected[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(lookedUp["id"] as? String, jobID)
        XCTAssertEqual(lookedUp["state"] as? String, "queued")
        let cancelled = try XCTUnwrap(
            (reconnected[2]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(cancelled["state"] as? String, "cancelled")
        let duplicate = try XCTUnwrap(
            (reconnected[3]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(duplicate["wasAlreadyAccepted"] as? Bool, true)
        XCTAssertEqual((duplicate["record"] as? [String: Any])?["id"] as? String, jobID)
        XCTAssertEqual((duplicate["record"] as? [String: Any])?["state"] as? String, "cancelled")
    }

    func testPackagedMCPHelperInspectsAndCompletesLiveStreamCopy() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        let destinationURL = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=5.1:sample_rate=48000",
            "-timecode", "01:02:03:04",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", sourceURL.path
        ])

        let adapter = ApplicationFFmpegJobExecutor(runner: .live())
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let portID = UUID()
        let server = ApplicationAgentIPCServer(
            portName: "com.aagedal.tests.agent.\(portID.uuidString)",
            dispatcher: ApplicationAgentRequestDispatcher(tools: ApplicationAgentTools(
                jobService: service,
                fileAccessAuthorizer: .unrestricted
            ))
        )
        try server.start()
        defer { server.stop() }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "Codex"]]
        ]
        let initialized: [String: Any] = [
            "jsonrpc": "2.0", "method": "notifications/initialized"
        ]
        let preparation = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "inspect_media", "arguments": ["source_path": sourceURL.path]
            ]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                "name": "plan_conversion", "arguments": [
                    "source_paths": [sourceURL.path],
                    "destination_path": destinationURL.path,
                    "preset_id": "stream_copy",
                    "idempotency_key": "live-stream-copy"
                ]
            ]]
        ])
        let inspection = try XCTUnwrap(
            (preparation[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(inspection["sourceURL"] as? String, sourceURL.absoluteString)
        XCTAssertEqual(
            (inspection["videoStreams"] as? [[String: Any]])?.first?["codec"] as? String,
            "avc1"
        )
        XCTAssertEqual(
            (inspection["audioStreams"] as? [[String: Any]])?.first?["channels"] as? Int,
            6
        )
        XCTAssertEqual(inspection["timecode"] as? String, "01:02:03:04")
        let planResult = try XCTUnwrap(
            (preparation[2]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        let planID = try XCTUnwrap(planResult["id"] as? String)
        let plannedOutput = try XCTUnwrap(
            (planResult["outputs"] as? [[String: Any]])?.first?["outputURL"] as? String
        )

        let submission = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "submit_conversion", "arguments": ["plan_id": planID]
            ]]
        ])
        let acceptance = try XCTUnwrap(
            (submission[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(acceptance["wasAlreadyAccepted"] as? Bool, false)
        let jobID = try XCTUnwrap((acceptance["record"] as? [String: Any])?["id"] as? String)
        let record = try await waitForRecord(
            service: service,
            jobID: ApplicationJobID(try XCTUnwrap(UUID(uuidString: jobID))),
            state: .succeeded
        )
        XCTAssertEqual(record.outputURLs.map(\.absoluteString), [plannedOutput])
        let outputURL = try XCTUnwrap(record.outputURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let copiedMetadata = try runBundledFFmpeg([
            "-hide_banner", "-i", outputURL.path,
            "-map", "0", "-f", "null", "-"
        ])
        XCTAssertTrue(copiedMetadata.contains("Video: h264"), copiedMetadata)
        XCTAssertTrue(copiedMetadata.contains("Audio: aac"), copiedMetadata)
        XCTAssertTrue(copiedMetadata.contains("48000 Hz, 5.1"), copiedMetadata)
        // The v1 agent contract has no timecode override. Its absent execution
        // settings mean disabled, even when the source has a timecode track.
        XCTAssertFalse(copiedMetadata.contains("01:02:03:04"), copiedMetadata)
        XCTAssertTrue(record.request.acceptedSettingsSummary(sourceIndex: nil).contains("Timecode: Disabled"))

        let followUp = try runPackagedMCPHelper(portID: portID, messages: [
            initialize, initialized,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "get_job", "arguments": ["job_id": jobID]
            ]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                "name": "submit_conversion", "arguments": ["plan_id": planID]
            ]]
        ])
        let completed = try XCTUnwrap(
            (followUp[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(completed["state"] as? String, "succeeded")
        let retry = try XCTUnwrap(
            (followUp[2]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        )
        XCTAssertEqual(retry["wasAlreadyAccepted"] as? Bool, true)
        XCTAssertEqual((retry["record"] as? [String: Any])?["id"] as? String, jobID)
    }

    func testLiveFirstPartyStreamCopyPreservesConfiguredTimecodeAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        let destinationURL = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=5.1:sample_rate=48000",
            "-timecode", "01:02:03:04",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", sourceURL.path
        ])

        let adapter = ApplicationFFmpegJobExecutor(runner: .live())
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let request = makeRequest(
            origin: .manual,
            sourceURLs: [sourceURL],
            destinationFolderURL: destinationURL,
            presetID: .streamCopy,
            executionSettings: ApplicationRequestExecutionSettings(
                includeDateTag: false,
                timecodeConfig: TimecodeConfig(mode: .preserveSource)
            ),
            idempotencyKey: nil
        )
        let plan = try await service.plan(request)
        let accepted = try await service.submit(planID: plan.id)
        let record = try await waitForRecord(
            service: service, jobID: accepted.record.id, state: .succeeded
        )
        let outputURL = try XCTUnwrap(record.outputURLs.first)
        XCTAssertEqual(outputURL, plan.outputs.first?.outputURL)
        let metadata = try runBundledFFmpeg([
            "-hide_banner", "-i", outputURL.path,
            "-map", "0", "-f", "null", "-"
        ])
        XCTAssertTrue(metadata.contains("48000 Hz, 5.1"), metadata)
        XCTAssertTrue(metadata.contains("timecode        : 01:02:03:04"), metadata)
    }

    func testLiveBatchRejectsOutputCreatedAfterExecutionValidation() async throws {
        let directory = try makeTemporaryDirectory()
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", firstSource.path
        ])
        try FileManager.default.copyItem(at: firstSource, to: secondSource)
        let destination = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existingContents = Data("Output published by another operation".utf8)
        let liveRunner = ApplicationFFmpegRunner.live()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                if conversion.request.inputURL == secondSource {
                    guard let outputURL = conversion.request.requiredOutputURL else {
                        return .failed("Missing accepted output path")
                    }
                    do {
                        try existingContents.write(to: outputURL)
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
                return await liveRunner.run(conversion, progress)
            },
            cancel: liveRunner.cancel,
            validatesPlannedOutput: true
        ))
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(
            store: store,
            fileAccessAuthorizer: .unrestricted, executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: destination,
            presetID: .streamCopy
        ))
        let accepted = try await service.submit(planID: plan.id)
        let record = try await waitForRecord(
            service: service, jobID: accepted.record.id, state: .failed
        )
        XCTAssertEqual(record.diagnostic, ApplicationJobErrorCode.outputCollision.rawValue)
        XCTAssertEqual(record.outputURLs, [plan.outputs[0].outputURL])
        let restoredService = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let restoredRecord = try await restoredService.record(for: record.id)
        XCTAssertEqual(restoredRecord?.outputURLs, record.outputURLs)
        XCTAssertEqual(try Data(contentsOf: plan.outputs[1].outputURL), existingContents)
        let files = try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),
                       Set(plan.outputs.map { $0.outputURL.lastPathComponent }))
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-i", plan.outputs[0].outputURL.path,
            "-map", "0", "-f", "null", "-"
        ])
    }

    func testLiveSupportedPresetJobsCreateTheirPlannedOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try runBundledFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", sourceURL.path
        ])
        let defaults = try makeDefaults()
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set(H265Encoder.software.rawValue, forKey: AppConstants.h265EncoderKey)
        let adapter = ApplicationFFmpegJobExecutor(runner: .live())
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )

        for (presetID, expectedExtension, videoCodec, audioCodec) in [
            (ApplicationPresetID.h264, "mp4", "h264", "aac"),
            (.hevc, "mp4", "hevc", "aac"),
            (.proRes, "mov", "prores", "pcm_s24le"),
            (.proxy, "mov", "hevc", "pcm_s24le"),
            (.audioOnly, "wav", nil, "pcm_s24le")
        ] {
            let destinationURL = directory.appendingPathComponent(
                presetID.rawValue, isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: destinationURL, withIntermediateDirectories: true
            )
            let plan = try await service.plan(makeRequest(
                sourceURLs: [sourceURL],
                destinationFolderURL: destinationURL,
                presetID: presetID,
                idempotencyKey: nil,
                defaults: defaults
            ))
            let plannedURL = try XCTUnwrap(plan.outputs.first?.outputURL)
            XCTAssertEqual(plannedURL.pathExtension, expectedExtension)
            let accepted = try await service.submit(planID: plan.id)
            let record = try await waitForRecord(
                service: service, jobID: accepted.record.id, state: .succeeded
            )
            XCTAssertEqual(record.outputURLs, [plannedURL])
            XCTAssertTrue(FileManager.default.fileExists(atPath: plannedURL.path))
            let metadata = try runBundledFFmpeg([
                "-hide_banner", "-i", plannedURL.path,
                "-map", "0", "-f", "null", "-"
            ])
            if let videoCodec {
                XCTAssertTrue(metadata.contains("Video: \(videoCodec)"), metadata)
            } else {
                XCTAssertFalse(metadata.contains("Video:"), metadata)
            }
            XCTAssertTrue(metadata.contains("Audio: \(audioCodec)"), metadata)
        }
    }

    @discardableResult
    private func runBundledFFmpeg(_ arguments: [String]) throws -> String {
        let binaryURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let diagnostic = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ApplicationJobContractTests.FFmpeg", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: diagnostic])
        }
        return diagnostic
    }

    private func runPackagedMCPHelper(
        portID: UUID,
        messages: [[String: Any]]
    ) throws -> [[String: Any]] {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/aagedal-media-converter-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))

        let process = Process()
        process.executableURL = helperURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AMC_UI_TEST_AGENT_PORT_ID": portID.uuidString
        ]) { _, replacement in replacement }
        let input = Pipe()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        process.standardInput = input
        process.standardOutput = output
        try process.run()

        let lines = try messages.map { message in
            try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        }
        input.fileHandleForWriting.write(lines.reduce(Data(), +))
        try input.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        return try output.fileHandleForReading.readDataToEndOfFile()
            .split(separator: 0x0A)
            .map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            }
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
        executionSettings: ApplicationRequestExecutionSettings? = nil,
        sourceSettings: [ApplicationSourceExecutionSettings]? = nil,
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
            executionSettings: executionSettings,
            sourceSettings: sourceSettings,
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationJobContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeExecutingService(
        harness: ApplicationJobExecutorHarness
    ) -> ApplicationJobService {
        ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in
                    await harness.cancel(jobID: jobID)
                }
            )
        )
    }

    private func waitForRecord(
        service: ApplicationJobService,
        jobID: ApplicationJobID,
        state: ApplicationJobState
    ) async throws -> ApplicationJobRecord {
        for _ in 0..<200 {
            if let record = try await service.record(for: jobID), record.state == state {
                return record
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for job \(jobID) to reach \(state.rawValue)")
        let lastRecord = try await service.record(for: jobID)
        return try XCTUnwrap(lastRecord)
    }
}

private final class ApplicationAgentDefaultsFixture: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private actor ApplicationFFmpegRunnerHarness {
    struct Snapshot: Sendable {
        let preset: ExportPreset
        let outputURL: URL
        let ffmpegArguments: [String]
        let audioOnlyFormat: AudioOnlyFormat?
        let keepsSubtitles: Bool
        let includeDateTag: Bool
        let manualTimecode: String?
        let comment: String
        let trimStart: Double?
        let trimEnd: Double?
        let cropConfig: CropConfig?
        let isMuted: Bool
        let audioRoutingConfig: AudioRoutingConfig?
        let commentPrefix: String?
    }

    private let blocksFirstRun: Bool
    private var recordedSnapshots: [Snapshot] = []
    private var cancellationCount = 0
    private var cancellationRequested = false
    private var firstRunContinuation: CheckedContinuation<Void, Never>?

    init(blocksFirstRun: Bool = false) {
        self.blocksFirstRun = blocksFirstRun
    }

    func run(
        conversion: ApplicationFFmpegConversion,
        progress: ApplicationFFmpegProgressSink
    ) async -> ApplicationFFmpegRunResult {
        let manualTimecode: String? = if case .manual(let value)? = conversion.request.timecodeConfig?.mode {
            value
        } else {
            nil
        }
        recordedSnapshots.append(Snapshot(
            preset: conversion.request.preset,
            outputURL: conversion.request.outputURL,
            ffmpegArguments: conversion.audioOnlySettings?.ffmpegArguments
                ?? conversion.codecSettings?.ffmpegArguments
                ?? [],
            audioOnlyFormat: conversion.audioOnlySettings?.format,
            keepsSubtitles: conversion.subtitleSettings.keepSubtitles,
            includeDateTag: conversion.request.includeDateTag,
            manualTimecode: manualTimecode,
            comment: conversion.request.comment,
            trimStart: conversion.request.trimStart,
            trimEnd: conversion.request.trimEnd,
            cropConfig: conversion.request.cropConfig,
            isMuted: conversion.request.isMuted,
            audioRoutingConfig: conversion.request.audioRoutingConfig,
            commentPrefix: conversion.commentSettings?.prefix
        ))
        progress.send(0.5, status: "Encoding")
        if blocksFirstRun, recordedSnapshots.count == 1, !cancellationRequested {
            await withCheckedContinuation { continuation in
                if cancellationRequested {
                    continuation.resume()
                } else {
                    firstRunContinuation = continuation
                }
            }
        }
        return cancellationRequested ? .failed("Conversion cancelled") : .succeeded
    }

    func cancel() {
        cancellationCount += 1
        cancellationRequested = true
        firstRunContinuation?.resume()
        firstRunContinuation = nil
    }

    func snapshots() -> [Snapshot] {
        recordedSnapshots
    }

    func cancelCount() -> Int {
        cancellationCount
    }

    func runCount() -> Int {
        recordedSnapshots.count
    }
}

private actor ApplicationJobExecutorHarness {
    struct Snapshot: Sendable {
        let startedIDs: [ApplicationJobID]
        let cancelledIDs: Set<ApplicationJobID>
        let maximumConcurrentExecutions: Int
    }

    private let blocksFirstExecution: Bool
    private var startedIDs: [ApplicationJobID] = []
    private var cancelledIDs: Set<ApplicationJobID> = []
    private var activeExecutions = 0
    private var maximumConcurrentExecutions = 0
    private var firstExecutionContinuation: CheckedContinuation<Void, Never>?
    private var firstExecutionReleaseRequested = false

    init(blocksFirstExecution: Bool) {
        self.blocksFirstExecution = blocksFirstExecution
    }

    func execute(
        jobID: ApplicationJobID,
        plan: ApplicationConversionPlan,
        progress: ApplicationJobProgressReporter
    ) async -> ApplicationJobExecutionResult {
        startedIDs.append(jobID)
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        await progress.report(ApplicationJobProgressUpdate(progress: 0.5, stage: "Encoding"))
        if blocksFirstExecution, startedIDs.count == 1 {
            await withCheckedContinuation { continuation in
                if firstExecutionReleaseRequested || cancelledIDs.contains(jobID) {
                    continuation.resume()
                } else {
                    firstExecutionContinuation = continuation
                }
            }
        }
        activeExecutions -= 1
        if cancelledIDs.contains(jobID) {
            return .cancelled(diagnostic: "Cancelled by requester")
        }
        return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
    }

    func cancel(jobID: ApplicationJobID) {
        cancelledIDs.insert(jobID)
        firstExecutionContinuation?.resume()
        firstExecutionContinuation = nil
    }

    func releaseFirstExecution() {
        firstExecutionReleaseRequested = true
        firstExecutionContinuation?.resume()
        firstExecutionContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startedIDs: startedIDs,
            cancelledIDs: cancelledIDs,
            maximumConcurrentExecutions: maximumConcurrentExecutions
        )
    }
}

private final class ApplicationJobLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var activeCount: Int {
        lock.withLock { count }
    }

    func acquire() -> ApplicationFileAccessLease {
        lock.withLock { count += 1 }
        return ApplicationFileAccessLease { [weak self] in
            self?.lock.withLock { self?.count -= 1 }
        }
    }
}
