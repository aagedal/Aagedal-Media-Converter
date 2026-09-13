// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftMediaMetadata

/// Versioned identifiers exposed at the application boundary. These values stay
/// independent of localized preset names and mutable user-facing labels.
enum ApplicationPresetID: String, CaseIterable, Codable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"
    case proRes = "prores"
    case proxy = "proxy"
    case audioOnly = "audio_only"
    case streamCopy = "stream_copy"

    var exportPreset: ExportPreset {
        switch self {
        case .h264: .h264
        case .hevc: .h265
        case .proRes: .prores
        case .proxy: .proxy
        case .audioOnly: .audioOnly
        case .streamCopy: .streamCopy
        }
    }
}

enum ApplicationJobOrigin: String, Codable, Sendable {
    case manual
    case appIntent = "app_intent"
    case localAgent = "local_agent"
}

/// Stable, transport-facing identifiers for the resolved settings that affect an
/// accepted conversion. They deliberately do not reuse localized UI raw values.
enum ApplicationContainerID: String, Codable, Sendable {
    case source
    case mp4
    case mov
    case mkv
    case mxf
    case wav
    case m4a
    case flac
}

enum ApplicationVideoEncoderID: String, Codable, Sendable {
    case libx264
    case libx265
    case h264VideoToolbox = "h264_videotoolbox"
    case hevcVideoToolbox = "hevc_videotoolbox"
    case proResVideoToolbox = "prores_videotoolbox"
    case dnxhd
    case streamCopy = "stream_copy"
}

enum ApplicationVideoProfileID: String, Codable, Sendable {
    case h264High = "h264_high"
    case hevcMain10 = "hevc_main10"
    case proResProxy = "prores_proxy"
    case proResLT = "prores_lt"
    case proRes422 = "prores_422"
    case proResHQ = "prores_hq"
    case proRes4444 = "prores_4444"
    case proRes4444XQ = "prores_4444_xq"
    case dnxhrLB = "dnxhr_lb"
}

enum ApplicationAudioCodecID: String, Codable, Sendable {
    case aac
    case opus
    case pcm16 = "pcm_s16le"
    case pcm24 = "pcm_s24le"
    case pcm32 = "pcm_s32le"
    case flac
    case streamCopy = "stream_copy"
}

enum ApplicationSpecialCharacterRemovalModeID: String, Codable, Sendable {
    case off
    case loose
    case strict
}

struct ApplicationVideoSettings: Codable, Equatable, Sendable {
    let encoderID: ApplicationVideoEncoderID
    let profileID: ApplicationVideoProfileID?
    let quality: Int?
    let bitrate: String?
    let speed: String?
    let maximumHeight: Int?
}

struct ApplicationAudioSettings: Codable, Equatable, Sendable {
    let codecID: ApplicationAudioCodecID
    let bitrate: String?
}

struct ApplicationFileNameSettings: Codable, Equatable, Sendable {
    let processingEnabled: Bool
    let replaceSpaces: Bool
    let replaceScandinavianCharacters: Bool
    let specialCharacterRemovalMode: ApplicationSpecialCharacterRemovalModeID
    let includePresetSuffix: Bool
    let customTemplateEnabled: Bool
    let template: String
    let dateFormat: String
    let counterPadding: Int
    let counterStart: Int
    let presetSuffix: String

    private enum CodingKeys: String, CodingKey {
        case processingEnabled
        case replaceSpaces
        case replaceScandinavianCharacters
        case specialCharacterRemovalMode
        case includePresetSuffix
        case customTemplateEnabled
        case template
        case dateFormat
        case counterPadding
        case counterStart
        case presetSuffix
    }

    init(preset: ExportPreset, defaults: UserDefaults) {
        let settings = FileNameSettings(defaults: defaults).snapshot
        let context = FileNameTemplateContext(preset: preset, defaults: defaults)
        processingEnabled = settings.isEnabled
        replaceSpaces = settings.replaceSpaces
        replaceScandinavianCharacters = settings.replaceScandinavianCharacters
        specialCharacterRemovalMode = switch settings.specialCharacterRemovalMode {
        case .off: .off
        case .loose: .loose
        case .strict: .strict
        }
        includePresetSuffix = settings.includePresetSuffix
        customTemplateEnabled = settings.customTemplateEnabled
        template = settings.template
        dateFormat = settings.dateFormat
        counterPadding = settings.counterPadding
        counterStart = defaults.object(forKey: AppConstants.customFileNameCounterValueKey) as? Int
            ?? AppConstants.defaultCustomFileNameCounterValue
        presetSuffix = context.presetSuffix
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processingEnabled = try values.decode(Bool.self, forKey: .processingEnabled)
        replaceSpaces = try values.decode(Bool.self, forKey: .replaceSpaces)
        replaceScandinavianCharacters = try values.decode(Bool.self, forKey: .replaceScandinavianCharacters)
        specialCharacterRemovalMode = try values.decode(
            ApplicationSpecialCharacterRemovalModeID.self,
            forKey: .specialCharacterRemovalMode
        )
        includePresetSuffix = try values.decode(Bool.self, forKey: .includePresetSuffix)
        customTemplateEnabled = try values.decode(Bool.self, forKey: .customTemplateEnabled)
        template = try values.decode(String.self, forKey: .template)
        dateFormat = try values.decode(String.self, forKey: .dateFormat)
        counterPadding = try values.decode(Int.self, forKey: .counterPadding)
        counterStart = try values.decodeIfPresent(Int.self, forKey: .counterStart)
            ?? AppConstants.defaultCustomFileNameCounterValue
        presetSuffix = try values.decode(String.self, forKey: .presetSuffix)
    }

    fileprivate var fileNamePreferences: FileNamePreferences {
        let removalMode: SpecialCharacterRemovalMode = switch specialCharacterRemovalMode {
        case .off: .off
        case .loose: .loose
        case .strict: .strict
        }
        return FileNamePreferences(
            isEnabled: processingEnabled,
            replaceSpaces: replaceSpaces,
            replaceScandinavianCharacters: replaceScandinavianCharacters,
            specialCharacterRemovalMode: removalMode,
            includePresetSuffix: includePresetSuffix,
            customTemplateEnabled: customTemplateEnabled,
            template: template,
            dateFormat: dateFormat,
            counterPadding: counterPadding
        )
    }
}

/// An immutable semantic snapshot of the mutable preferences behind a supported
/// preset. A request keeps this value through planning and execution, so a later
/// Settings change cannot silently alter already accepted work.
struct ApplicationPresetSettings: Codable, Equatable, Sendable {
    let presetID: ApplicationPresetID
    let containerID: ApplicationContainerID
    let video: ApplicationVideoSettings?
    let audio: ApplicationAudioSettings?
    let preserveMetadata: Bool
    let keepSubtitles: Bool
    let fileName: ApplicationFileNameSettings

    init(
        presetID: ApplicationPresetID,
        containerID: ApplicationContainerID,
        video: ApplicationVideoSettings?,
        audio: ApplicationAudioSettings?,
        preserveMetadata: Bool,
        keepSubtitles: Bool,
        fileName: ApplicationFileNameSettings
    ) {
        self.presetID = presetID
        self.containerID = containerID
        self.video = video
        self.audio = audio
        self.preserveMetadata = preserveMetadata
        self.keepSubtitles = keepSubtitles
        self.fileName = fileName
    }

    init(presetID: ApplicationPresetID, defaults: UserDefaults = .standard) {
        let preset = presetID.exportPreset
        self.presetID = presetID
        preserveMetadata = defaults.bool(forKey: AppConstants.preserveMetadataPreferenceKey)
        keepSubtitles = preset != .streamCopy
            && preset != .audioOnly
            && defaults.bool(forKey: AppConstants.keepSubtitlesKey)
        fileName = ApplicationFileNameSettings(preset: preset, defaults: defaults)

        switch presetID {
        case .h264:
            let container = Self.codecContainer(
                defaults.string(forKey: AppConstants.h264ContainerKey),
                fallback: AppConstants.defaultH264Container
            )
            let encoder = H264Encoder(
                rawValue: defaults.string(forKey: AppConstants.h264EncoderKey)
                    ?? AppConstants.defaultH264Encoder
            ) ?? .software
            let resolution = CodecResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.h264ResolutionLimitKey)
                    ?? AppConstants.defaultH264ResolutionLimit
            ) ?? .unlimited
            let audio = Self.codecAudio(
                formatRaw: defaults.string(forKey: AppConstants.h264AudioFormatKey),
                fallbackFormat: AppConstants.defaultH264AudioFormat,
                bitrateRaw: defaults.string(forKey: AppConstants.h264AudioBitrateKey),
                fallbackBitrate: AppConstants.defaultH264AudioBitrate,
                container: container
            )
            containerID = Self.containerID(container)
            video = ApplicationVideoSettings(
                encoderID: encoder == .hardware ? .h264VideoToolbox : .libx264,
                profileID: .h264High,
                quality: encoder == .software ? Self.codecQuality(
                    defaults.string(forKey: AppConstants.h264QualityKey),
                    fallback: AppConstants.defaultH264Quality
                ).crfValue : nil,
                bitrate: encoder == .hardware
                    ? defaults.string(forKey: AppConstants.h264BitrateKey) ?? AppConstants.defaultH264Bitrate
                    : nil,
                speed: encoder == .software
                    ? Self.encodingSpeed(
                        defaults.string(forKey: AppConstants.h264SpeedKey),
                        fallback: AppConstants.defaultH264Speed
                    ).ffmpegPreset
                    : nil,
                maximumHeight: resolution.maxHeight
            )
            self.audio = audio
        case .hevc:
            let container = Self.codecContainer(
                defaults.string(forKey: AppConstants.h265ContainerKey),
                fallback: AppConstants.defaultH265Container
            )
            let encoder = H265Encoder(
                rawValue: defaults.string(forKey: AppConstants.h265EncoderKey)
                    ?? AppConstants.defaultH265Encoder
            ) ?? .software
            let resolution = CodecResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.h265ResolutionLimitKey)
                    ?? AppConstants.defaultH265ResolutionLimit
            ) ?? .unlimited
            let audio = Self.codecAudio(
                formatRaw: defaults.string(forKey: AppConstants.h265AudioFormatKey),
                fallbackFormat: AppConstants.defaultH265AudioFormat,
                bitrateRaw: defaults.string(forKey: AppConstants.h265AudioBitrateKey),
                fallbackBitrate: AppConstants.defaultH265AudioBitrate,
                container: container
            )
            containerID = Self.containerID(container)
            video = ApplicationVideoSettings(
                encoderID: encoder == .hardware ? .hevcVideoToolbox : .libx265,
                profileID: .hevcMain10,
                quality: encoder == .software ? Self.codecQuality(
                    defaults.string(forKey: AppConstants.h265QualityKey),
                    fallback: AppConstants.defaultH265Quality
                ).crfValue : nil,
                bitrate: encoder == .hardware
                    ? defaults.string(forKey: AppConstants.h265BitrateKey) ?? AppConstants.defaultH265Bitrate
                    : nil,
                speed: encoder == .software
                    ? Self.encodingSpeed(
                        defaults.string(forKey: AppConstants.h265SpeedKey),
                        fallback: AppConstants.defaultH265Speed
                    ).ffmpegPreset
                    : nil,
                maximumHeight: resolution.maxHeight
            )
            self.audio = audio
        case .proRes:
            let profile = ProResProfile(
                rawValue: defaults.string(forKey: AppConstants.proResProfileKey)
                    ?? ProResProfile.standard.rawValue
            ) ?? .standard
            containerID = .mov
            video = ApplicationVideoSettings(
                encoderID: .proResVideoToolbox,
                profileID: Self.proResProfileID(profile),
                quality: nil,
                bitrate: nil,
                speed: nil,
                maximumHeight: nil
            )
            audio = ApplicationAudioSettings(codecID: .pcm24, bitrate: nil)
        case .proxy:
            let codec = ProxyCodec(
                rawValue: defaults.string(forKey: AppConstants.proxyCodecKey)
                    ?? AppConstants.defaultProxyCodec
            ) ?? .hevc
            let resolution = ProxyResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.proxyResolutionLimitKey)
                    ?? AppConstants.defaultProxyResolutionLimit
            ) ?? .r1080
            containerID = codec == .dnxhd ? .mxf : .mov
            video = ApplicationVideoSettings(
                encoderID: Self.proxyEncoderID(codec),
                profileID: Self.proxyProfileID(codec),
                quality: nil,
                bitrate: codec == .hevc ? resolution.bitrate : nil,
                speed: nil,
                maximumHeight: resolution.maxHeight
            )
            audio = ApplicationAudioSettings(codecID: .pcm24, bitrate: nil)
        case .audioOnly:
            let settings = AudioOnlySettings(defaults: defaults)
            containerID = Self.audioContainerID(settings.format)
            video = nil
            audio = Self.audioOnlySettings(settings)
        case .streamCopy:
            let container = StreamCopyContainer(
                rawValue: defaults.string(forKey: AppConstants.streamCopyContainerKey)
                    ?? AppConstants.defaultStreamCopyContainer
            ) ?? .keepCurrent
            containerID = Self.streamCopyContainerID(container)
            video = ApplicationVideoSettings(
                encoderID: .streamCopy,
                profileID: nil,
                quality: nil,
                bitrate: nil,
                speed: nil,
                maximumHeight: nil
            )
            audio = ApplicationAudioSettings(codecID: .streamCopy, bitrate: nil)
        }
    }

    private static func codecContainer(_ raw: String?, fallback: String) -> CodecContainer {
        CodecContainer(rawValue: raw ?? fallback) ?? .mp4
    }

    private static func containerID(_ container: CodecContainer) -> ApplicationContainerID {
        switch container {
        case .mp4: .mp4
        case .mov: .mov
        case .mkv: .mkv
        }
    }

    private static func codecQuality(_ raw: String?, fallback: String) -> CodecQualityLevel {
        CodecQualityLevel(rawValue: raw ?? fallback)
            ?? CodecQualityLevel(rawValue: fallback)
            ?? .good
    }

    private static func encodingSpeed(_ raw: String?, fallback: String) -> EncodingSpeed {
        EncodingSpeed(rawValue: raw ?? fallback) ?? .medium
    }

    private static func codecAudio(
        formatRaw: String?,
        fallbackFormat: String,
        bitrateRaw: String?,
        fallbackBitrate: String,
        container: CodecContainer
    ) -> ApplicationAudioSettings {
        var format = CodecAudioFormat(rawValue: formatRaw ?? fallbackFormat) ?? .aac
        if format == .opus && container != .mkv { format = .aac }
        let bitrate = AudioBitrate(rawValue: bitrateRaw ?? fallbackBitrate) ?? .k192
        return ApplicationAudioSettings(
            codecID: audioCodecID(format),
            bitrate: format.requiresBitrate ? bitrate.ffmpegValue : nil
        )
    }

    private static func audioCodecID(_ format: CodecAudioFormat) -> ApplicationAudioCodecID {
        switch format {
        case .aac: .aac
        case .opus: .opus
        case .pcm16: .pcm16
        case .pcm24: .pcm24
        case .pcm32: .pcm32
        }
    }

    private static func proResProfileID(_ profile: ProResProfile) -> ApplicationVideoProfileID {
        switch profile {
        case .proxy: .proResProxy
        case .lt: .proResLT
        case .standard: .proRes422
        case .hq: .proResHQ
        case .fourFourFourFour: .proRes4444
        case .fourFourFourFourXQ: .proRes4444XQ
        }
    }

    private static func proxyEncoderID(_ codec: ProxyCodec) -> ApplicationVideoEncoderID {
        switch codec {
        case .hevc: .hevcVideoToolbox
        case .prores: .proResVideoToolbox
        case .dnxhd: .dnxhd
        }
    }

    private static func proxyProfileID(_ codec: ProxyCodec) -> ApplicationVideoProfileID {
        switch codec {
        case .hevc: .hevcMain10
        case .prores: .proResProxy
        case .dnxhd: .dnxhrLB
        }
    }

    private static func audioContainerID(_ format: AudioOnlyFormat) -> ApplicationContainerID {
        switch format {
        case .wav: .wav
        case .aac: .m4a
        case .mp4: .mp4
        case .flac: .flac
        }
    }

    private static func audioOnlySettings(_ settings: AudioOnlySettings) -> ApplicationAudioSettings {
        switch settings.format {
        case .wav:
            let codec: ApplicationAudioCodecID = switch settings.bitDepth {
            case .pcm16: .pcm16
            case .pcm24: .pcm24
            case .pcm32: .pcm32
            }
            return ApplicationAudioSettings(codecID: codec, bitrate: nil)
        case .aac:
            return ApplicationAudioSettings(codecID: .aac, bitrate: settings.aacBitrate.ffmpegValue)
        case .mp4:
            let codec: ApplicationAudioCodecID = switch settings.mp4Codec {
            case .aac: .aac
            case .pcm16: .pcm16
            case .pcm24: .pcm24
            case .pcm32: .pcm32
            }
            return ApplicationAudioSettings(
                codecID: codec,
                bitrate: settings.mp4Codec.requiresBitrate ? settings.mp4Bitrate.ffmpegValue : nil
            )
        case .flac:
            return ApplicationAudioSettings(codecID: .flac, bitrate: nil)
        }
    }

    private static func streamCopyContainerID(_ container: StreamCopyContainer) -> ApplicationContainerID {
        switch container {
        case .keepCurrent: .source
        case .mov: .mov
        case .mp4: .mp4
        case .mkv: .mkv
        }
    }
}

struct ApplicationJobID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = UUID(uuidString: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID job identifier."
            )
        }
        self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    var description: String { rawValue.uuidString.lowercased() }
}

/// A transport-neutral request accepted by the shared application job boundary.
/// More conversion overrides will be added only after the feasibility matrix has
/// established which settings can be represented and validated reliably.
struct ApplicationConversionRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let origin: ApplicationJobOrigin
    let requesterID: String
    let sourceURLs: [URL]
    let destinationFolderURL: URL
    let presetID: ApplicationPresetID
    let presetSettings: ApplicationPresetSettings
    let idempotencyKey: String?
    let capturedAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: UUID = UUID(),
        origin: ApplicationJobOrigin,
        requesterID: String,
        sourceURLs: [URL],
        destinationFolderURL: URL,
        presetID: ApplicationPresetID,
        presetSettings: ApplicationPresetSettings? = nil,
        idempotencyKey: String? = nil,
        capturedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.origin = origin
        self.requesterID = requesterID
        self.sourceURLs = sourceURLs
        self.destinationFolderURL = destinationFolderURL
        self.presetID = presetID
        self.presetSettings = presetSettings
            ?? ApplicationPresetSettings(presetID: presetID, defaults: defaults)
        self.idempotencyKey = idempotencyKey
        self.capturedAt = capturedAt
    }

    fileprivate func hasSamePayload(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion
            && origin == other.origin
            && requesterID == other.requesterID
            && sourceURLs == other.sourceURLs
            && destinationFolderURL == other.destinationFolderURL
            && presetID == other.presetID
            && presetSettings == other.presetSettings
    }
}

enum ApplicationJobState: String, CaseIterable, Codable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: true
        case .queued, .running, .cancelling: false
        }
    }
}

struct ApplicationJobRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: ApplicationJobID
    let request: ApplicationConversionRequest
    let createdAt: Date
    var updatedAt: Date
    var state: ApplicationJobState
    var stage: String?
    var progress: Double?
    var outputURLs: [URL]
    var diagnostic: String?
}

struct ApplicationJobAcceptance: Codable, Equatable, Sendable {
    let record: ApplicationJobRecord
    let wasAlreadyAccepted: Bool
}

enum ApplicationJobError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidRequesterID
    case noSources
    case duplicateSource(URL)
    case nonFileURL(URL)
    case invalidIdempotencyKey
    case presetSettingsMismatch
    case idempotencyConflict
    case unknownJob(ApplicationJobID)
    case invalidTransition(from: ApplicationJobState, to: ApplicationJobState)
    case invalidProgress(Double)
    case unknownPlan(ApplicationPlanID)
    case expiredPlan(ApplicationPlanID)
    case sourceUnavailable(URL)
    case sourceAccessDenied(URL)
    case sourceChanged(URL)
    case destinationUnavailable(URL)
    case destinationAccessDenied(URL)
    case unsupportedSourceExtension(URL)
    case duplicateOutput(URL)
    case outputCollision(URL)
    case mediaInspectionFailed(URL)

    var code: ApplicationJobErrorCode {
        switch self {
        case .unsupportedSchema: .unsupportedSchema
        case .invalidRequesterID: .invalidRequesterID
        case .noSources: .noSources
        case .duplicateSource: .duplicateSource
        case .nonFileURL: .nonFileURL
        case .invalidIdempotencyKey: .invalidIdempotencyKey
        case .presetSettingsMismatch: .presetSettingsMismatch
        case .idempotencyConflict: .idempotencyConflict
        case .unknownJob: .unknownJob
        case .invalidTransition: .invalidTransition
        case .invalidProgress: .invalidProgress
        case .unknownPlan: .unknownPlan
        case .expiredPlan: .expiredPlan
        case .sourceUnavailable: .sourceUnavailable
        case .sourceAccessDenied: .sourceAccessDenied
        case .sourceChanged: .sourceChanged
        case .destinationUnavailable: .destinationUnavailable
        case .destinationAccessDenied: .destinationAccessDenied
        case .unsupportedSourceExtension: .unsupportedSourceExtension
        case .duplicateOutput: .duplicateOutput
        case .outputCollision: .outputCollision
        case .mediaInspectionFailed: .mediaInspectionFailed
        }
    }
}

/// Stable machine-readable error identifiers. Human-readable and localized
/// recovery text belongs at the UI or protocol adapter layer.
enum ApplicationJobErrorCode: String, Codable, Sendable {
    case unsupportedSchema = "unsupported_schema"
    case invalidRequesterID = "invalid_requester_id"
    case noSources = "no_sources"
    case duplicateSource = "duplicate_source"
    case nonFileURL = "non_file_url"
    case invalidIdempotencyKey = "invalid_idempotency_key"
    case presetSettingsMismatch = "preset_settings_mismatch"
    case idempotencyConflict = "idempotency_conflict"
    case unknownJob = "unknown_job"
    case invalidTransition = "invalid_transition"
    case invalidProgress = "invalid_progress"
    case unknownPlan = "unknown_plan"
    case expiredPlan = "expired_plan"
    case sourceUnavailable = "source_unavailable"
    case sourceAccessDenied = "source_access_denied"
    case sourceChanged = "source_changed"
    case destinationUnavailable = "destination_unavailable"
    case destinationAccessDenied = "destination_access_denied"
    case unsupportedSourceExtension = "unsupported_source_extension"
    case duplicateOutput = "duplicate_output"
    case outputCollision = "output_collision"
    case mediaInspectionFailed = "media_inspection_failed"
    case invalidArguments = "invalid_arguments"
    case cancelled
    case internalError = "internal_error"
}

enum ApplicationJobPersistenceError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateJobID(ApplicationJobID)
    case duplicatePlanID(ApplicationPlanID)
    case duplicateIdempotencyIdentity
    case duplicateSubmittedPlan(ApplicationPlanID)
    case missingSubmittedPlan(ApplicationPlanID)
    case missingSubmittedJob(ApplicationJobID)
}

private struct ApplicationSubmittedPlan: Codable, Equatable, Sendable {
    let planID: ApplicationPlanID
    let jobID: ApplicationJobID
}

private struct ApplicationJobPersistenceSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let records: [ApplicationJobRecord]
    let plans: [ApplicationConversionPlan]
    let submittedPlans: [ApplicationSubmittedPlan]
}

/// A single versioned file is used so plan/job/idempotency state is published
/// atomically. A damaged file is surfaced to the caller and is never replaced
/// implicitly during startup recovery.
struct ApplicationJobStore: Sendable {
    let fileURL: URL

    static let live = ApplicationJobStore(fileURL: {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportDirectory
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("AgentAccess", isDirectory: true)
            .appendingPathComponent("application-jobs.json")
    }())

    fileprivate func load() throws -> ApplicationJobPersistenceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            ApplicationJobPersistenceSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    fileprivate func save(_ snapshot: ApplicationJobPersistenceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

/// Owns stable identities and lifecycle state before work is attached to a view.
/// Persistence and conversion execution are deliberately separate follow-up
/// layers; the registry can therefore be tested without starting helper tools.
actor ApplicationJobRegistry {
    private struct IdempotencyIdentity: Hashable, Sendable {
        let requesterID: String
        let key: String
    }

    private struct AcceptedRequest: Sendable {
        let jobID: ApplicationJobID
        let request: ApplicationConversionRequest
    }

    private var records: [ApplicationJobID: ApplicationJobRecord] = [:]
    private var orderedIDs: [ApplicationJobID] = []
    private var acceptedRequests: [IdempotencyIdentity: AcceptedRequest] = [:]

    func accept(
        _ request: ApplicationConversionRequest,
        now: Date = Date()
    ) throws -> ApplicationJobAcceptance {
        try Self.validate(request)

        if let record = try acceptedRecord(for: request) {
            return ApplicationJobAcceptance(record: record, wasAlreadyAccepted: true)
        }

        let jobID = ApplicationJobID()
        let record = ApplicationJobRecord(
            schemaVersion: ApplicationConversionRequest.currentSchemaVersion,
            id: jobID,
            request: request,
            createdAt: now,
            updatedAt: now,
            state: .queued,
            stage: nil,
            progress: nil,
            outputURLs: [],
            diagnostic: nil
        )
        records[jobID] = record
        orderedIDs.append(jobID)
        if let key = request.idempotencyKey {
            acceptedRequests[IdempotencyIdentity(requesterID: request.requesterID, key: key)] =
                AcceptedRequest(jobID: jobID, request: request)
        }
        return ApplicationJobAcceptance(record: record, wasAlreadyAccepted: false)
    }

    func acceptedRecord(for request: ApplicationConversionRequest) throws -> ApplicationJobRecord? {
        try Self.validate(request)
        guard let key = request.idempotencyKey else { return nil }
        let identity = IdempotencyIdentity(requesterID: request.requesterID, key: key)
        guard let accepted = acceptedRequests[identity] else { return nil }
        guard accepted.request.hasSamePayload(as: request) else {
            throw ApplicationJobError.idempotencyConflict
        }
        guard let record = records[accepted.jobID] else {
            preconditionFailure("An idempotency record must reference an accepted job.")
        }
        return record
    }

    func record(for jobID: ApplicationJobID) -> ApplicationJobRecord? {
        records[jobID]
    }

    func allRecords() -> [ApplicationJobRecord] {
        orderedIDs.compactMap { records[$0] }
    }

    /// Restores the authoritative ordering and requester-scoped idempotency
    /// identities. Validation happens before replacing live state so a damaged
    /// snapshot cannot partially restore.
    func restore(_ restoredRecords: [ApplicationJobRecord]) throws {
        var restoredByID: [ApplicationJobID: ApplicationJobRecord] = [:]
        var restoredIDs: [ApplicationJobID] = []
        var restoredRequests: [IdempotencyIdentity: AcceptedRequest] = [:]

        for record in restoredRecords {
            guard record.schemaVersion == ApplicationConversionRequest.currentSchemaVersion else {
                throw ApplicationJobPersistenceError.unsupportedSchema(record.schemaVersion)
            }
            try Self.validate(record.request)
            guard restoredByID[record.id] == nil else {
                throw ApplicationJobPersistenceError.duplicateJobID(record.id)
            }
            restoredByID[record.id] = record
            restoredIDs.append(record.id)
            if let key = record.request.idempotencyKey {
                let identity = IdempotencyIdentity(requesterID: record.request.requesterID, key: key)
                guard restoredRequests[identity] == nil else {
                    throw ApplicationJobPersistenceError.duplicateIdempotencyIdentity
                }
                restoredRequests[identity] = AcceptedRequest(jobID: record.id, request: record.request)
            }
        }

        records = restoredByID
        orderedIDs = restoredIDs
        acceptedRequests = restoredRequests
    }

    /// Idempotency identities have the same lifetime as their retained record.
    /// Active work is never removed by retention cleanup.
    func removeTerminalRecords(updatedBefore cutoff: Date) -> Set<ApplicationJobID> {
        let removedIDs = Set(orderedIDs.filter { jobID in
            guard let record = records[jobID] else { return false }
            return record.state.isTerminal && record.updatedAt < cutoff
        })
        guard !removedIDs.isEmpty else { return [] }
        orderedIDs.removeAll { removedIDs.contains($0) }
        for jobID in removedIDs {
            records.removeValue(forKey: jobID)
        }
        acceptedRequests = acceptedRequests.filter { !removedIDs.contains($0.value.jobID) }
        return removedIDs
    }

    @discardableResult
    func transition(
        _ jobID: ApplicationJobID,
        to newState: ApplicationJobState,
        outputURLs: [URL] = [],
        diagnostic: String? = nil,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        guard var record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        guard Self.canTransition(from: record.state, to: newState) else {
            throw ApplicationJobError.invalidTransition(from: record.state, to: newState)
        }
        record.state = newState
        record.updatedAt = now
        record.outputURLs = outputURLs
        record.diagnostic = diagnostic
        if newState == .succeeded { record.progress = 1 }
        records[jobID] = record
        return record
    }

    /// Queued jobs have no helper to drain, so cancellation is immediately
    /// terminal. Running jobs first become cancelling and remain observable there
    /// until their execution owner confirms that helpers have drained.
    @discardableResult
    func requestCancellation(
        _ jobID: ApplicationJobID,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        guard let record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        switch record.state {
        case .queued:
            return try transition(jobID, to: .cancelled, now: now)
        case .running:
            return try transition(jobID, to: .cancelling, now: now)
        case .cancelling:
            return record
        case .succeeded, .failed, .cancelled, .interrupted:
            throw ApplicationJobError.invalidTransition(from: record.state, to: .cancelling)
        }
    }

    @discardableResult
    func updateProgress(
        _ jobID: ApplicationJobID,
        progress: Double?,
        stage: String?,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        if let progress, !(0...1).contains(progress) {
            throw ApplicationJobError.invalidProgress(progress)
        }
        guard var record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        guard record.state == .running || record.state == .cancelling else {
            throw ApplicationJobError.invalidTransition(from: record.state, to: record.state)
        }
        record.progress = progress
        record.stage = stage
        record.updatedAt = now
        records[jobID] = record
        return record
    }

    /// Called after restoring persisted records. Incomplete work is made terminal
    /// and visible instead of being restarted without user intent.
    @discardableResult
    func interruptInFlightJobs(
        diagnostic: String,
        now: Date = Date()
    ) -> [ApplicationJobRecord] {
        var interrupted: [ApplicationJobRecord] = []
        for jobID in orderedIDs {
            guard var record = records[jobID], !record.state.isTerminal else { continue }
            record.state = .interrupted
            record.updatedAt = now
            record.diagnostic = diagnostic
            records[jobID] = record
            interrupted.append(record)
        }
        return interrupted
    }

    static func validate(_ request: ApplicationConversionRequest) throws {
        guard request.schemaVersion == ApplicationConversionRequest.currentSchemaVersion else {
            throw ApplicationJobError.unsupportedSchema(request.schemaVersion)
        }
        let requesterID = request.requesterID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedRequesterCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard requesterID == request.requesterID,
              !requesterID.isEmpty,
              requesterID.count <= 64,
              requesterID.unicodeScalars.allSatisfy(allowedRequesterCharacters.contains) else {
            throw ApplicationJobError.invalidRequesterID
        }
        guard !request.sourceURLs.isEmpty else { throw ApplicationJobError.noSources }
        var sources = Set<URL>()
        for sourceURL in request.sourceURLs {
            guard sourceURL.isFileURL else { throw ApplicationJobError.nonFileURL(sourceURL) }
            guard sources.insert(sourceURL.standardizedFileURL).inserted else {
                throw ApplicationJobError.duplicateSource(sourceURL)
            }
        }
        guard request.destinationFolderURL.isFileURL else {
            throw ApplicationJobError.nonFileURL(request.destinationFolderURL)
        }
        guard request.presetID == request.presetSettings.presetID else {
            throw ApplicationJobError.presetSettingsMismatch
        }
        if let key = request.idempotencyKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == trimmed,
                  !key.isEmpty,
                  key.count <= 128,
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ApplicationJobError.invalidIdempotencyKey
            }
        }
    }

    private static func canTransition(
        from current: ApplicationJobState,
        to next: ApplicationJobState
    ) -> Bool {
        switch (current, next) {
        case (.queued, .running), (.queued, .cancelled), (.queued, .failed), (.queued, .interrupted),
             (.running, .cancelling), (.running, .succeeded), (.running, .failed),
             (.running, .cancelled), (.running, .interrupted),
             (.cancelling, .cancelled), (.cancelling, .failed), (.cancelling, .interrupted):
            true
        default:
            false
        }
    }
}

struct ApplicationPlanID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = UUID(uuidString: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID plan identifier."
            )
        }
        self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    var description: String { rawValue.uuidString.lowercased() }
}

struct ApplicationSourceIdentity: Codable, Equatable, Sendable {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date?
    let fileIdentifier: String?
}

struct ApplicationPlannedOutput: Codable, Equatable, Sendable {
    let sourceURL: URL
    let outputURL: URL
}

enum ApplicationPlanWarningCode: String, Codable, Sendable {
    case outputAlreadyExists = "output_already_exists"
}

struct ApplicationPlanWarning: Codable, Equatable, Sendable {
    let code: ApplicationPlanWarningCode
    let url: URL
}

struct ApplicationConversionPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: ApplicationPlanID
    let request: ApplicationConversionRequest
    let createdAt: Date
    let expiresAt: Date
    let sources: [ApplicationSourceIdentity]
    let outputs: [ApplicationPlannedOutput]
    let warnings: [ApplicationPlanWarning]
}

struct ApplicationJobProgressUpdate: Equatable, Sendable {
    let progress: Double?
    let stage: String?
}

enum ApplicationJobExecutionResult: Equatable, Sendable {
    case succeeded(outputURLs: [URL])
    case failed(diagnostic: String)
    case cancelled(diagnostic: String?)
}

/// The shared job service owns ordering and lifecycle state; an adapter owns the
/// concrete conversion implementation. Keeping this boundary free of SwiftUI
/// bindings lets manual, App Intent, and local-agent work use the same queue.
struct ApplicationJobExecutor: Sendable {
    typealias ProgressHandler = @Sendable (ApplicationJobProgressUpdate) async -> Void
    typealias Execute = @Sendable (
        ApplicationJobID,
        ApplicationConversionPlan,
        ApplicationJobProgressReporter
    ) async -> ApplicationJobExecutionResult
    typealias Cancel = @Sendable (ApplicationJobID) async -> Void

    let execute: Execute
    let cancel: Cancel
}

final class ApplicationJobProgressReporter: @unchecked Sendable {
    private let handler: ApplicationJobExecutor.ProgressHandler

    init(handler: @escaping ApplicationJobExecutor.ProgressHandler) {
        self.handler = handler
    }

    func report(_ update: ApplicationJobProgressUpdate) async {
        await handler(update)
    }
}

/// A single planned source/output conversion with every mutable preference
/// resolved into the existing immutable execution settings.
struct ApplicationFFmpegConversion: Sendable {
    let request: ConversionRequest
    let audioOnlySettings: AudioOnlySettings?
    let codecSettings: CodecExportSettings?
    let subtitleSettings: SubtitleExportSettings
}

/// Injectable wrapper around the concrete FFmpeg actor. Tests can exercise the
/// application adapter without launching a bundled helper process.
struct ApplicationFFmpegRunner: Sendable {
    typealias ProgressHandler = @Sendable (Double, String?) -> Void
    typealias Run = @Sendable (
        ApplicationFFmpegConversion,
        ApplicationFFmpegProgressSink
    ) async -> ApplicationFFmpegRunResult

    let run: Run
    let cancel: @Sendable () async -> Void

    static func live(converter: FFMPEGConverter = FFMPEGConverter()) -> Self {
        Self(
            run: { conversion, progress in
                let completion = ApplicationFFmpegCompletion()
                await converter.convert(
                    request: conversion.request,
                    audioOnlySettings: conversion.audioOnlySettings,
                    codecSettings: conversion.codecSettings,
                    subtitleSettings: conversion.subtitleSettings,
                    progressUpdate: { value, status in
                        progress.send(value, status: status)
                    }
                ) { success, diagnostic in
                    completion.resolve(success: success, diagnostic: diagnostic)
                }
                return completion.result
                    ?? .failed("FFmpeg returned without reporting a conversion result.")
            },
            cancel: {
                await converter.cancelConversion()
            }
        )
    }
}

final class ApplicationFFmpegProgressSink: @unchecked Sendable {
    private let handler: ApplicationFFmpegRunner.ProgressHandler

    init(handler: @escaping ApplicationFFmpegRunner.ProgressHandler) {
        self.handler = handler
    }

    func send(_ progress: Double, status: String?) {
        handler(progress, status)
    }
}

enum ApplicationFFmpegRunResult: Equatable, Sendable {
    case succeeded
    case failed(String)
}

private final class ApplicationFFmpegCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: ApplicationFFmpegRunResult?

    var result: ApplicationFFmpegRunResult? {
        lock.withLock { storedResult }
    }

    func resolve(success: Bool, diagnostic: String?) {
        lock.withLock {
            guard storedResult == nil else { return }
            storedResult = success
                ? .succeeded
                : .failed(diagnostic ?? "FFmpeg conversion failed without a diagnostic.")
        }
    }
}

/// Converts accepted application plans with the existing bundled FFmpeg engine.
/// The job service owns inter-job ordering; this actor owns the active engine
/// call and prevents a cancellation for one job from reaching another job.
actor ApplicationFFmpegJobExecutor {
    static let shared = ApplicationFFmpegJobExecutor(runner: .live())

    private let runner: ApplicationFFmpegRunner
    private var activeJobID: ApplicationJobID?
    private var cancellationRequested: Set<ApplicationJobID> = []

    init(runner: ApplicationFFmpegRunner) {
        self.runner = runner
    }

    nonisolated var jobExecutor: ApplicationJobExecutor {
        ApplicationJobExecutor(
            execute: { [self] jobID, plan, progress in
                await execute(jobID: jobID, plan: plan, progress: progress)
            },
            cancel: { [self] jobID in
                await cancel(jobID: jobID)
            }
        )
    }

    private func execute(
        jobID: ApplicationJobID,
        plan: ApplicationConversionPlan,
        progress: ApplicationJobProgressReporter
    ) async -> ApplicationJobExecutionResult {
        guard activeJobID == nil else {
            return .failed(diagnostic: "The FFmpeg execution adapter was already busy.")
        }
        activeJobID = jobID
        cancellationRequested.remove(jobID)
        defer {
            if activeJobID == jobID { activeJobID = nil }
            cancellationRequested.remove(jobID)
        }

        guard !plan.outputs.isEmpty else {
            return .failed(diagnostic: "The accepted conversion plan had no outputs.")
        }

        let outputCount = Double(plan.outputs.count)
        for (index, output) in plan.outputs.enumerated() {
            guard activeJobID == jobID, !cancellationRequested.contains(jobID) else {
                return .cancelled(diagnostic: "Conversion cancelled.")
            }

            let conversion: ApplicationFFmpegConversion
            do {
                conversion = try Self.makeConversion(plan: plan, output: output)
            } catch {
                return .failed(diagnostic: error.localizedDescription)
            }

            let itemIndex = Double(index)
            let fallbackStage = plan.outputs.count == 1
                ? "Converting"
                : "Converting file \(index + 1) of \(plan.outputs.count)"
            await progress.report(ApplicationJobProgressUpdate(
                progress: itemIndex / outputCount,
                stage: fallbackStage
            ))
            let progressSink = ApplicationFFmpegProgressSink { itemProgress, status in
                let boundedProgress = min(max(itemProgress, 0), 1)
                Task {
                    await progress.report(ApplicationJobProgressUpdate(
                        progress: (itemIndex + boundedProgress) / outputCount,
                        stage: status ?? fallbackStage
                    ))
                }
            }
            let result = await runner.run(conversion, progressSink)

            if cancellationRequested.contains(jobID) {
                return .cancelled(diagnostic: "Conversion cancelled.")
            }
            switch result {
            case .succeeded:
                break
            case .failed(let diagnostic):
                return .failed(diagnostic: diagnostic)
            }
        }

        return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
    }

    private func cancel(jobID: ApplicationJobID) async {
        guard activeJobID == jobID, !cancellationRequested.contains(jobID) else { return }
        cancellationRequested.insert(jobID)
        await runner.cancel()
    }

    private static func makeConversion(
        plan: ApplicationConversionPlan,
        output: ApplicationPlannedOutput
    ) throws -> ApplicationFFmpegConversion {
        let settings = plan.request.presetSettings
        let defaults = try ApplicationExecutionDefaults(settings: settings)
        return ApplicationFFmpegConversion(
            request: ConversionRequest(
                inputURL: output.sourceURL,
                outputURL: output.outputURL,
                preset: plan.request.presetID.exportPreset,
                includeDateTag: false
            ),
            audioOnlySettings: plan.request.presetID == .audioOnly
                ? AudioOnlySettings(defaults: defaults.value) : nil,
            codecSettings: CodecExportSettings(
                preset: plan.request.presetID.exportPreset,
                defaults: defaults.value
            ),
            subtitleSettings: SubtitleExportSettings(defaults: defaults.value)
        )
    }
}

private final class ApplicationExecutionDefaults {
    let value: UserDefaults
    private let suiteName: String

    init(settings: ApplicationPresetSettings) throws {
        let suiteName = "ApplicationFFmpegJobExecutor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ApplicationExecutionSettingsError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.suiteName = suiteName

        defaults.set(settings.preserveMetadata, forKey: AppConstants.preserveMetadataPreferenceKey)
        defaults.set(settings.keepSubtitles, forKey: AppConstants.keepSubtitlesKey)
        try Self.populatePresetSettings(settings, defaults: defaults)
        value = defaults
    }

    deinit {
        value.removePersistentDomain(forName: suiteName)
    }

    private static func populatePresetSettings(
        _ settings: ApplicationPresetSettings,
        defaults: UserDefaults
    ) throws {
        switch settings.presetID {
        case .h264:
            try populateCodecSettings(
                settings, defaults: defaults,
                containerKey: AppConstants.h264ContainerKey,
                encoderKey: AppConstants.h264EncoderKey,
                qualityKey: AppConstants.h264QualityKey,
                bitrateKey: AppConstants.h264BitrateKey,
                speedKey: AppConstants.h264SpeedKey,
                resolutionKey: AppConstants.h264ResolutionLimitKey,
                audioFormatKey: AppConstants.h264AudioFormatKey,
                audioBitrateKey: AppConstants.h264AudioBitrateKey
            )
        case .hevc:
            try populateCodecSettings(
                settings, defaults: defaults,
                containerKey: AppConstants.h265ContainerKey,
                encoderKey: AppConstants.h265EncoderKey,
                qualityKey: AppConstants.h265QualityKey,
                bitrateKey: AppConstants.h265BitrateKey,
                speedKey: AppConstants.h265SpeedKey,
                resolutionKey: AppConstants.h265ResolutionLimitKey,
                audioFormatKey: AppConstants.h265AudioFormatKey,
                audioBitrateKey: AppConstants.h265AudioBitrateKey
            )
        case .proRes:
            guard let video = settings.video,
                  video.encoderID == .proResVideoToolbox,
                  video.quality == nil,
                  video.bitrate == nil,
                  video.speed == nil,
                  video.maximumHeight == nil,
                  let profileID = video.profileID,
                  let profile = proResProfile(for: profileID),
                  settings.containerID == .mov,
                  settings.audio?.codecID == .pcm24,
                  settings.audio?.bitrate == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(profile.rawValue, forKey: AppConstants.proResProfileKey)
        case .proxy:
            guard let video = settings.video,
                  let codec = proxyCodec(for: video.encoderID),
                  let resolution = proxyResolution(maximumHeight: video.maximumHeight),
                  settings.containerID == (codec == .dnxhd ? .mxf : .mov),
                  video.profileID == proxyProfile(for: codec),
                  video.quality == nil,
                  video.speed == nil,
                  video.bitrate == (codec == .hevc ? resolution.bitrate : nil),
                  settings.audio?.codecID == .pcm24,
                  settings.audio?.bitrate == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(codec.rawValue, forKey: AppConstants.proxyCodecKey)
            defaults.set(resolution.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
        case .audioOnly:
            try populateAudioOnlySettings(settings, defaults: defaults)
        case .streamCopy:
            guard settings.video?.encoderID == .streamCopy,
                  settings.video?.profileID == nil,
                  settings.video?.quality == nil,
                  settings.video?.bitrate == nil,
                  settings.video?.speed == nil,
                  settings.video?.maximumHeight == nil,
                  settings.audio?.codecID == .streamCopy,
                  settings.audio?.bitrate == nil,
                  let container = streamCopyContainer(for: settings.containerID) else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(container.rawValue, forKey: AppConstants.streamCopyContainerKey)
        }
    }

    private static func populateCodecSettings(
        _ settings: ApplicationPresetSettings,
        defaults: UserDefaults,
        containerKey: String,
        encoderKey: String,
        qualityKey: String,
        bitrateKey: String,
        speedKey: String,
        resolutionKey: String,
        audioFormatKey: String,
        audioBitrateKey: String
    ) throws {
        guard let video = settings.video,
              let audio = settings.audio,
              let container = codecContainer(for: settings.containerID),
              let resolution = CodecResolutionLimit.allCases.first(where: {
                  $0.maxHeight == video.maximumHeight
              }),
              let audioFormat = codecAudioFormat(for: audio.codecID),
              video.profileID == (settings.presetID == .h264 ? .h264High : .hevcMain10),
              audioFormat != .opus || container == .mkv else {
            throw ApplicationExecutionSettingsError.invalidPresetSettings
        }
        defaults.set(container.rawValue, forKey: containerKey)
        defaults.set(resolution.rawValue, forKey: resolutionKey)
        defaults.set(audioFormat.rawValue, forKey: audioFormatKey)

        if audioFormat.requiresBitrate {
            guard let bitrate = audio.bitrate,
                  let resolvedBitrate = audioBitrate(for: bitrate) else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(resolvedBitrate.rawValue, forKey: audioBitrateKey)
        } else if audio.bitrate != nil {
            throw ApplicationExecutionSettingsError.invalidPresetSettings
        }

        switch video.encoderID {
        case .libx264, .libx265:
            let expectedEncoder: ApplicationVideoEncoderID = settings.presetID == .h264
                ? .libx264 : .libx265
            guard video.encoderID == expectedEncoder,
                  let quality = video.quality,
                  let resolvedQuality = CodecQualityLevel.allCases.first(where: {
                      $0.crfValue == quality
                  }),
                  let speed = video.speed,
                  let resolvedSpeed = EncodingSpeed.allCases.first(where: {
                      $0.ffmpegPreset == speed
                  }),
                  video.bitrate == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(
                settings.presetID == .h264 ? H264Encoder.software.rawValue : H265Encoder.software.rawValue,
                forKey: encoderKey
            )
            defaults.set(resolvedQuality.rawValue, forKey: qualityKey)
            defaults.set(resolvedSpeed.rawValue, forKey: speedKey)
        case .h264VideoToolbox, .hevcVideoToolbox:
            let expectedEncoder: ApplicationVideoEncoderID = settings.presetID == .h264
                ? .h264VideoToolbox : .hevcVideoToolbox
            guard video.encoderID == expectedEncoder,
                  let bitrate = video.bitrate,
                  video.quality == nil,
                  video.speed == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(
                settings.presetID == .h264 ? H264Encoder.hardware.rawValue : H265Encoder.hardware.rawValue,
                forKey: encoderKey
            )
            defaults.set(bitrate, forKey: bitrateKey)
        default:
            throw ApplicationExecutionSettingsError.invalidPresetSettings
        }
    }

    private static func populateAudioOnlySettings(
        _ settings: ApplicationPresetSettings,
        defaults: UserDefaults
    ) throws {
        guard settings.video == nil, let audio = settings.audio else {
            throw ApplicationExecutionSettingsError.invalidPresetSettings
        }
        let format: AudioOnlyFormat
        switch settings.containerID {
        case .wav:
            format = .wav
            guard let depth = audioBitDepth(for: audio.codecID), audio.bitrate == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(depth.rawValue, forKey: AppConstants.audioOnlyBitDepthKey)
        case .m4a:
            format = .aac
            guard audio.codecID == .aac,
                  let bitrate = audio.bitrate.flatMap(audioBitrate(for:)) else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(bitrate.rawValue, forKey: AppConstants.audioOnlyAACBitrateKey)
        case .mp4:
            format = .mp4
            guard let codec = audioOnlyMP4Codec(for: audio.codecID) else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
            defaults.set(codec.rawValue, forKey: AppConstants.audioOnlyMP4CodecKey)
            if codec.requiresBitrate {
                guard let bitrate = audio.bitrate.flatMap(audioBitrate(for:)) else {
                    throw ApplicationExecutionSettingsError.invalidPresetSettings
                }
                defaults.set(bitrate.rawValue, forKey: AppConstants.audioOnlyMP4BitrateKey)
            } else if audio.bitrate != nil {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
        case .flac:
            format = .flac
            guard audio.codecID == .flac, audio.bitrate == nil else {
                throw ApplicationExecutionSettingsError.invalidPresetSettings
            }
        default:
            throw ApplicationExecutionSettingsError.invalidPresetSettings
        }
        defaults.set(format.rawValue, forKey: AppConstants.audioOnlyFormatKey)
    }

    private static func codecContainer(for id: ApplicationContainerID) -> CodecContainer? {
        switch id {
        case .mp4: .mp4
        case .mov: .mov
        case .mkv: .mkv
        default: nil
        }
    }

    private static func codecAudioFormat(for id: ApplicationAudioCodecID) -> CodecAudioFormat? {
        switch id {
        case .aac: .aac
        case .opus: .opus
        case .pcm16: .pcm16
        case .pcm24: .pcm24
        case .pcm32: .pcm32
        default: nil
        }
    }

    private static func audioBitrate(for ffmpegValue: String) -> AudioBitrate? {
        AudioBitrate.allCases.first { $0.ffmpegValue == ffmpegValue }
    }

    private static func audioBitDepth(for id: ApplicationAudioCodecID) -> AudioOnlyBitDepth? {
        switch id {
        case .pcm16: .pcm16
        case .pcm24: .pcm24
        case .pcm32: .pcm32
        default: nil
        }
    }

    private static func audioOnlyMP4Codec(for id: ApplicationAudioCodecID) -> AudioOnlyMP4Codec? {
        switch id {
        case .aac: .aac
        case .pcm16: .pcm16
        case .pcm24: .pcm24
        case .pcm32: .pcm32
        default: nil
        }
    }

    private static func proResProfile(for id: ApplicationVideoProfileID) -> ProResProfile? {
        switch id {
        case .proResProxy: .proxy
        case .proResLT: .lt
        case .proRes422: .standard
        case .proResHQ: .hq
        case .proRes4444: .fourFourFourFour
        case .proRes4444XQ: .fourFourFourFourXQ
        default: nil
        }
    }

    private static func proxyCodec(for id: ApplicationVideoEncoderID) -> ProxyCodec? {
        switch id {
        case .hevcVideoToolbox: .hevc
        case .proResVideoToolbox: .prores
        case .dnxhd: .dnxhd
        default: nil
        }
    }

    private static func proxyProfile(for codec: ProxyCodec) -> ApplicationVideoProfileID {
        switch codec {
        case .hevc: .hevcMain10
        case .prores: .proResProxy
        case .dnxhd: .dnxhrLB
        }
    }

    private static func proxyResolution(maximumHeight: Int?) -> ProxyResolutionLimit? {
        ProxyResolutionLimit.allCases.first { $0.maxHeight == maximumHeight }
    }

    private static func streamCopyContainer(for id: ApplicationContainerID) -> StreamCopyContainer? {
        switch id {
        case .source: .keepCurrent
        case .mov: .mov
        case .mp4: .mp4
        case .mkv: .mkv
        default: nil
        }
    }
}

private enum ApplicationExecutionSettingsError: LocalizedError {
    case defaultsUnavailable
    case invalidPresetSettings

    var errorDescription: String? {
        switch self {
        case .defaultsUnavailable:
            "Unable to create isolated conversion settings."
        case .invalidPresetSettings:
            "The accepted preset settings cannot be represented by the conversion engine."
        }
    }
}

enum ApplicationFileAccessMode: Equatable, Sendable {
    case read
    case write
}

/// A balanced security-scope lease. Planning and submission retain all source
/// and destination grants for the full filesystem validation operation.
final class ApplicationFileAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        releaseAction = release
    }

    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}

struct ApplicationFileAccessAuthorizer: Sendable {
    typealias Acquire = @Sendable (URL, ApplicationFileAccessMode) -> ApplicationFileAccessLease?

    let acquire: Acquire

    static let live = ApplicationFileAccessAuthorizer { url, mode in
        let access = SecurityScopedBookmarkManager.shared.startAccessingStoredBookmark(
            containing: url,
            requiresWriteAccess: mode == .write
        )
        guard case .none = access else {
            return ApplicationFileAccessLease {
                SecurityScopedBookmarkManager.shared.stopAccessing(access)
            }
        }
        return nil
    }

    /// Explicit opt-out for isolated tests whose temporary paths do not carry
    /// App Sandbox bookmarks.
    static let unrestricted = ApplicationFileAccessAuthorizer { _, _ in
        ApplicationFileAccessLease {}
    }
}

/// Owns transport-neutral plans, submit-time validation, output reservations,
/// serialized execution handoff, and job lifecycle state. The injected executor
/// keeps this boundary testable without SwiftUI bindings or helper processes.
actor ApplicationJobService {
    typealias SourceIdentityProvider = @Sendable (URL) throws -> ApplicationSourceIdentity
    typealias ItemExistsProvider = @Sendable (URL) -> Bool

    static let shared = ApplicationJobService(
        store: .live,
        executor: ApplicationFFmpegJobExecutor.shared.jobExecutor
    )

    private let registry: ApplicationJobRegistry
    private let sourceIdentityProvider: SourceIdentityProvider
    private let itemExists: ItemExistsProvider
    private let fileAccessAuthorizer: ApplicationFileAccessAuthorizer
    private let executor: ApplicationJobExecutor?
    private let planLifetime: TimeInterval
    private let recordRetentionLifetime: TimeInterval
    private let store: ApplicationJobStore?
    private var didRestore = false
    private var plans: [ApplicationPlanID: ApplicationConversionPlan] = [:]
    private var submittedPlans: [ApplicationPlanID: ApplicationJobAcceptance] = [:]
    private var reservedOutputs: [URL: ApplicationJobID] = [:]
    private var outputsByJob: [ApplicationJobID: Set<URL>] = [:]
    private var pendingExecutions: [(jobID: ApplicationJobID, plan: ApplicationConversionPlan)] = []
    private var isExecutionDraining = false
    private var activeExecutionJobID: ApplicationJobID?
    private var cancellationSignals: Set<ApplicationJobID> = []

    init(
        registry: ApplicationJobRegistry = ApplicationJobRegistry(),
        planLifetime: TimeInterval = 15 * 60,
        recordRetentionLifetime: TimeInterval = 30 * 24 * 60 * 60,
        store: ApplicationJobStore? = nil,
        fileAccessAuthorizer: ApplicationFileAccessAuthorizer = .live,
        executor: ApplicationJobExecutor? = nil,
        sourceIdentityProvider: SourceIdentityProvider? = nil,
        itemExists: @escaping ItemExistsProvider = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.registry = registry
        self.planLifetime = planLifetime
        self.recordRetentionLifetime = recordRetentionLifetime
        self.store = store
        self.fileAccessAuthorizer = fileAccessAuthorizer
        self.executor = executor
        self.sourceIdentityProvider = sourceIdentityProvider ?? Self.liveSourceIdentity
        self.itemExists = itemExists
    }

    /// Loads the last atomically published snapshot once per service lifetime.
    /// Accepted work is not restarted: every queued/running/cancelling record is
    /// made terminal and remains available to reconnecting clients.
    @discardableResult
    func restorePersistedState(
        now: Date = Date(),
        interruptionDiagnostic: String = "Application restarted before the conversion completed."
    ) async throws -> [ApplicationJobRecord] {
        guard !didRestore else { return [] }
        guard let store, let snapshot = try store.load() else {
            didRestore = true
            return []
        }
        guard snapshot.schemaVersion == ApplicationJobPersistenceSnapshot.currentSchemaVersion else {
            throw ApplicationJobPersistenceError.unsupportedSchema(snapshot.schemaVersion)
        }

        try await registry.restore(snapshot.records)
        var restoredPlans: [ApplicationPlanID: ApplicationConversionPlan] = [:]
        for plan in snapshot.plans {
            guard plan.schemaVersion == ApplicationConversionPlan.currentSchemaVersion else {
                throw ApplicationJobPersistenceError.unsupportedSchema(plan.schemaVersion)
            }
            try ApplicationJobRegistry.validate(plan.request)
            guard restoredPlans[plan.id] == nil else {
                throw ApplicationJobPersistenceError.duplicatePlanID(plan.id)
            }
            restoredPlans[plan.id] = plan
        }
        plans = restoredPlans
        submittedPlans.removeAll(keepingCapacity: true)
        for submitted in snapshot.submittedPlans {
            guard plans[submitted.planID] != nil else {
                throw ApplicationJobPersistenceError.missingSubmittedPlan(submitted.planID)
            }
            guard submittedPlans[submitted.planID] == nil else {
                throw ApplicationJobPersistenceError.duplicateSubmittedPlan(submitted.planID)
            }
            guard let record = await registry.record(for: submitted.jobID) else {
                throw ApplicationJobPersistenceError.missingSubmittedJob(submitted.jobID)
            }
            submittedPlans[submitted.planID] = ApplicationJobAcceptance(
                record: record,
                wasAlreadyAccepted: false
            )
        }

        didRestore = true
        let interrupted = await registry.interruptInFlightJobs(
            diagnostic: interruptionDiagnostic,
            now: now
        )
        await removeExpiredState(now: now)
        try await persist()
        return interrupted
    }

    func plan(
        _ request: ApplicationConversionRequest,
        now: Date = Date()
    ) async throws -> ApplicationConversionPlan {
        try await ensureRestored(now: now)
        try ApplicationJobRegistry.validate(request)
        let accessLeases = try acquireAccess(for: request)
        defer { accessLeases.forEach { $0.release() } }
        try Self.validateDestination(request.destinationFolderURL)
        let sources = try request.sourceURLs.map { try sourceIdentityProvider($0.standardizedFileURL) }
        let outputs = try Self.plannedOutputs(for: request)

        var uniqueOutputs = Set<URL>()
        for output in outputs {
            let normalized = output.outputURL.standardizedFileURL
            guard uniqueOutputs.insert(normalized).inserted else {
                throw ApplicationJobError.duplicateOutput(output.outputURL)
            }
        }

        let warnings = outputs.compactMap { output in
            itemExists(output.outputURL)
                ? ApplicationPlanWarning(code: .outputAlreadyExists, url: output.outputURL)
                : nil
        }
        let plan = ApplicationConversionPlan(
            schemaVersion: ApplicationConversionPlan.currentSchemaVersion,
            id: ApplicationPlanID(),
            request: request,
            createdAt: now,
            expiresAt: now.addingTimeInterval(planLifetime),
            sources: sources,
            outputs: outputs,
            warnings: warnings
        )
        plans[plan.id] = plan
        await removeExpiredState(now: now)
        try await persist()
        return plan
    }

    /// Rechecks source identity and output ownership immediately before accepting
    /// work. Retrying a plan that was already submitted returns its original job.
    func submit(
        planID: ApplicationPlanID,
        now: Date = Date()
    ) async throws -> ApplicationJobAcceptance {
        try await ensureRestored(now: now)
        if let accepted = submittedPlans[planID] {
            let currentRecord = await registry.record(for: accepted.record.id) ?? accepted.record
            try await persist()
            return ApplicationJobAcceptance(record: currentRecord, wasAlreadyAccepted: true)
        }
        guard let plan = plans[planID] else {
            throw ApplicationJobError.unknownPlan(planID)
        }
        if let record = try await registry.acceptedRecord(for: plan.request) {
            let accepted = ApplicationJobAcceptance(record: record, wasAlreadyAccepted: true)
            submittedPlans[planID] = accepted
            try await persist()
            return accepted
        }
        guard now <= plan.expiresAt else {
            throw ApplicationJobError.expiredPlan(planID)
        }

        let accessLeases = try acquireAccess(for: plan.request)
        defer { accessLeases.forEach { $0.release() } }
        try Self.validateDestination(plan.request.destinationFolderURL)

        for captured in plan.sources {
            let current: ApplicationSourceIdentity
            do {
                current = try sourceIdentityProvider(captured.url)
            } catch {
                throw ApplicationJobError.sourceUnavailable(captured.url)
            }
            guard current == captured else {
                throw ApplicationJobError.sourceChanged(captured.url)
            }
        }

        for output in plan.outputs {
            let normalized = output.outputURL.standardizedFileURL
            guard !itemExists(output.outputURL), reservedOutputs[normalized] == nil else {
                throw ApplicationJobError.outputCollision(output.outputURL)
            }
        }

        let accepted = try await registry.accept(plan.request, now: now)
        let normalizedOutputs = Set(plan.outputs.map { $0.outputURL.standardizedFileURL })
        for output in normalizedOutputs {
            reservedOutputs[output] = accepted.record.id
        }
        outputsByJob[accepted.record.id, default: []].formUnion(normalizedOutputs)
        submittedPlans[planID] = accepted
        try await persist()
        enqueueExecution(jobID: accepted.record.id, plan: plan)
        return accepted
    }

    func plan(
        for planID: ApplicationPlanID,
        now: Date = Date()
    ) async throws -> ApplicationConversionPlan? {
        try await ensureRestored(now: now)
        return plans[planID]
    }

    func record(
        for jobID: ApplicationJobID,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord? {
        try await ensureRestored(now: now)
        return await registry.record(for: jobID)
    }

    func allRecords(now: Date = Date()) async throws -> [ApplicationJobRecord] {
        try await ensureRestored(now: now)
        return await registry.allRecords()
    }

    @discardableResult
    func transition(
        _ jobID: ApplicationJobID,
        to state: ApplicationJobState,
        outputURLs: [URL] = [],
        diagnostic: String? = nil,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        try await ensureRestored(now: now)
        let record = try await registry.transition(
            jobID, to: state, outputURLs: outputURLs, diagnostic: diagnostic, now: now
        )
        if state.isTerminal {
            releaseOutputReservations(for: jobID)
        }
        try await persist()
        return record
    }

    @discardableResult
    func requestCancellation(
        _ jobID: ApplicationJobID,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        try await ensureRestored(now: now)
        let record = try await registry.requestCancellation(jobID, now: now)
        if record.state.isTerminal {
            releaseOutputReservations(for: jobID)
        } else if record.state == .cancelling,
                  activeExecutionJobID == jobID,
                  !cancellationSignals.contains(jobID),
                  let executor {
            cancellationSignals.insert(jobID)
            Task {
                await executor.cancel(jobID)
            }
        }
        try await persist()
        return record
    }

    @discardableResult
    func updateProgress(
        _ jobID: ApplicationJobID,
        progress: Double?,
        stage: String?,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        try await ensureRestored(now: now)
        return try await registry.updateProgress(jobID, progress: progress, stage: stage, now: now)
    }

    @discardableResult
    func interruptInFlightJobs(
        diagnostic: String,
        now: Date = Date()
    ) async throws -> [ApplicationJobRecord] {
        try await ensureRestored(now: now)
        let interrupted = await registry.interruptInFlightJobs(diagnostic: diagnostic, now: now)
        for record in interrupted {
            releaseOutputReservations(for: record.id)
        }
        try await persist()
        return interrupted
    }

    /// Removes expired plans and terminal records older than the documented
    /// retention window. Submitted-plan links disappear with either their plan
    /// or retained job.
    @discardableResult
    private func removeExpiredState(now: Date) async -> Int {
        let expiredPlanIDs = Set(plans.compactMap { planID, plan in
            plan.expiresAt < now ? planID : nil
        })
        for planID in expiredPlanIDs {
            plans.removeValue(forKey: planID)
            submittedPlans.removeValue(forKey: planID)
        }

        let cutoff = now.addingTimeInterval(-recordRetentionLifetime)
        let removedJobIDs = await registry.removeTerminalRecords(updatedBefore: cutoff)
        if !removedJobIDs.isEmpty {
            submittedPlans = submittedPlans.filter { !removedJobIDs.contains($0.value.record.id) }
            for jobID in removedJobIDs {
                releaseOutputReservations(for: jobID)
            }
        }
        return expiredPlanIDs.count + removedJobIDs.count
    }

    private func persist() async throws {
        guard let store else { return }
        let records = await registry.allRecords()
        let snapshot = ApplicationJobPersistenceSnapshot(
            schemaVersion: ApplicationJobPersistenceSnapshot.currentSchemaVersion,
            records: records,
            plans: plans.values.sorted { $0.createdAt < $1.createdAt },
            submittedPlans: submittedPlans.map { planID, acceptance in
                ApplicationSubmittedPlan(planID: planID, jobID: acceptance.record.id)
            }.sorted { $0.planID.description < $1.planID.description }
        )
        try store.save(snapshot)
    }

    private func ensureRestored(now: Date) async throws {
        guard store != nil, !didRestore else { return }
        _ = try await restorePersistedState(now: now)
    }

    private func releaseOutputReservations(for jobID: ApplicationJobID) {
        guard let outputs = outputsByJob.removeValue(forKey: jobID) else { return }
        for output in outputs where reservedOutputs[output] == jobID {
            reservedOutputs.removeValue(forKey: output)
        }
    }

    private func enqueueExecution(
        jobID: ApplicationJobID,
        plan: ApplicationConversionPlan
    ) {
        guard executor != nil else { return }
        pendingExecutions.append((jobID, plan))
        guard !isExecutionDraining else { return }
        isExecutionDraining = true
        Task {
            await self.drainExecutionQueue()
        }
    }

    private func drainExecutionQueue() async {
        while !pendingExecutions.isEmpty {
            let pending = pendingExecutions.removeFirst()
            await execute(pending)
        }
        isExecutionDraining = false
    }

    private func execute(
        _ pending: (jobID: ApplicationJobID, plan: ApplicationConversionPlan)
    ) async {
        guard let executor,
              let queuedRecord = await registry.record(for: pending.jobID),
              queuedRecord.state == .queued else { return }

        let accessLeases: [ApplicationFileAccessLease]
        do {
            accessLeases = try acquireAccess(for: pending.plan.request)
            try Self.validateDestination(pending.plan.request.destinationFolderURL)
            for capturedSource in pending.plan.sources {
                let currentSource: ApplicationSourceIdentity
                do {
                    currentSource = try sourceIdentityProvider(capturedSource.url)
                } catch {
                    throw ApplicationJobError.sourceUnavailable(capturedSource.url)
                }
                guard currentSource == capturedSource else {
                    throw ApplicationJobError.sourceChanged(capturedSource.url)
                }
            }
            for output in pending.plan.outputs where itemExists(output.outputURL) {
                throw ApplicationJobError.outputCollision(output.outputURL)
            }
        } catch {
            let diagnostic = Self.executionDiagnostic(for: error)
            _ = try? await transition(pending.jobID, to: .failed, diagnostic: diagnostic)
            return
        }
        defer { accessLeases.forEach { $0.release() } }

        do {
            _ = try await transition(pending.jobID, to: .running)
        } catch {
            return
        }
        activeExecutionJobID = pending.jobID

        let progressReporter = ApplicationJobProgressReporter { update in
            _ = try? await self.updateProgress(
                pending.jobID,
                progress: update.progress,
                stage: update.stage
            )
        }
        let result = await executor.execute(pending.jobID, pending.plan, progressReporter)

        activeExecutionJobID = nil
        cancellationSignals.remove(pending.jobID)
        guard let currentRecord = await registry.record(for: pending.jobID) else { return }

        do {
            if currentRecord.state == .cancelling {
                let diagnostic: String?
                if case .cancelled(let executorDiagnostic) = result {
                    diagnostic = executorDiagnostic
                } else {
                    diagnostic = nil
                }
                _ = try await transition(
                    pending.jobID,
                    to: .cancelled,
                    diagnostic: diagnostic
                )
                return
            }
            guard currentRecord.state == .running else { return }

            switch result {
            case .succeeded(let outputURLs):
                let expected = pending.plan.outputs.map { $0.outputURL.standardizedFileURL }
                let actual = outputURLs.map(\.standardizedFileURL)
                guard actual == expected else {
                    _ = try await transition(
                        pending.jobID,
                        to: .failed,
                        diagnostic: "Executor outputs did not match the accepted conversion plan."
                    )
                    return
                }
                _ = try await transition(
                    pending.jobID,
                    to: .succeeded,
                    outputURLs: outputURLs
                )
            case .failed(let diagnostic):
                _ = try await transition(
                    pending.jobID,
                    to: .failed,
                    diagnostic: diagnostic
                )
            case .cancelled(let diagnostic):
                _ = try await transition(
                    pending.jobID,
                    to: .cancelled,
                    diagnostic: diagnostic
                )
            }
        } catch {
            // Persistence or a competing terminal transition is authoritative;
            // never revive or rewrite a record from a late executor callback.
        }
    }

    private static func executionDiagnostic(for error: Error) -> String {
        if let error = error as? ApplicationJobError {
            return error.code.rawValue
        }
        return error.localizedDescription
    }

    private func acquireAccess(
        for request: ApplicationConversionRequest
    ) throws -> [ApplicationFileAccessLease] {
        var leases: [ApplicationFileAccessLease] = []
        do {
            for sourceURL in request.sourceURLs {
                guard let lease = fileAccessAuthorizer.acquire(sourceURL, .read) else {
                    throw ApplicationJobError.sourceAccessDenied(sourceURL)
                }
                leases.append(lease)
            }
            guard let destinationLease = fileAccessAuthorizer.acquire(
                request.destinationFolderURL,
                .write
            ) else {
                throw ApplicationJobError.destinationAccessDenied(request.destinationFolderURL)
            }
            leases.append(destinationLease)
            return leases
        } catch {
            leases.forEach { $0.release() }
            throw error
        }
    }

    private static func validateDestination(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw ApplicationJobError.destinationUnavailable(url)
            }
        } catch let error as ApplicationJobError {
            throw error
        } catch {
            throw ApplicationJobError.destinationUnavailable(url)
        }
    }

    private static func plannedOutputs(
        for request: ApplicationConversionRequest
    ) throws -> [ApplicationPlannedOutput] {
        let naming = request.presetSettings.fileName
        let preferences = naming.fileNamePreferences
        let context = FileNameTemplateContext(
            presetSuffix: naming.presetSuffix,
            resolution: request.presetSettings.video?.maximumHeight.map { "\($0)p" } ?? "",
            framerate: ""
        )

        return try request.sourceURLs.enumerated().map { index, sourceURL in
            let counterResult = naming.counterStart.addingReportingOverflow(index)
            let counter = counterResult.overflow ? Int.max : counterResult.partialValue
            let baseName = FileNameProcessor.outputBaseName(
                inputURL: sourceURL,
                counter: counter,
                preset: request.presetID.exportPreset,
                settings: preferences,
                context: context,
                date: request.capturedAt
            )
            let fileExtension = try outputExtension(
                for: request.presetSettings.containerID,
                sourceURL: sourceURL
            )
            let fileName = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
            return ApplicationPlannedOutput(
                sourceURL: sourceURL,
                outputURL: request.destinationFolderURL.appendingPathComponent(fileName)
            )
        }
    }

    private static func outputExtension(
        for containerID: ApplicationContainerID,
        sourceURL: URL
    ) throws -> String {
        guard containerID == .source else { return containerID.rawValue }
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard !sourceExtension.isEmpty else {
            throw ApplicationJobError.unsupportedSourceExtension(sourceURL)
        }
        return sourceExtension
    }

    private static func liveSourceIdentity(for url: URL) throws -> ApplicationSourceIdentity {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                .fileResourceIdentifierKey
            ])
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw ApplicationJobError.sourceUnavailable(url)
            }
            return ApplicationSourceIdentity(
                url: url.standardizedFileURL,
                fileSize: Int64(fileSize),
                modificationDate: values.contentModificationDate,
                fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
            )
        } catch let error as ApplicationJobError {
            throw error
        } catch {
            throw ApplicationJobError.sourceUnavailable(url)
        }
    }
}

// MARK: - Local agent tool workflow

/// Stable wire representation of a rational value reported by the media probe.
struct ApplicationMediaRational: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int
    let value: Double
}

struct ApplicationMediaVideoStream: Codable, Equatable, Sendable {
    let index: Int
    let codec: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let pixelFormat: String?
    let hasAlpha: Bool
    let pixelAspectRatio: ApplicationMediaRational?
    let displayAspectRatio: ApplicationMediaRational?
    let frameRate: ApplicationMediaRational?
    let bitDepth: Int?
    let bitRate: Int64?
    let durationSeconds: Double?
    let chromaSubsampling: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let colorSpace: String?
    let colorRange: String?
    let fieldOrder: String?
    let isInterlaced: Bool?
    let title: String?
    let isDefault: Bool
    let isForced: Bool
}

struct ApplicationMediaAudioStream: Codable, Equatable, Sendable {
    let index: Int?
    let languageCode: String?
    let title: String?
    let codec: String?
    let profile: String?
    let sampleRate: Int?
    let channels: Int?
    let channelLayout: String?
    let bitDepth: Int?
    let bitRate: Int64?
    let isDefault: Bool
}

struct ApplicationMediaSubtitleStream: Codable, Equatable, Sendable {
    let index: Int?
    let languageCode: String?
    let title: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let durationSeconds: Double?
}

/// Structured result returned by `inspect_media`. It intentionally exposes
/// factual source metadata rather than the app's display-formatted strings.
struct ApplicationMediaInspection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceURL: URL
    let durationSeconds: Double?
    let formatName: String?
    let containerName: String?
    let sizeBytes: Int64?
    let bitRate: Int64?
    let timecode: String?
    let timecodes: [TimecodeEntry]
    let frameCount: Int?
    let warnings: [String]
    let videoStreams: [ApplicationMediaVideoStream]
    let audioStreams: [ApplicationMediaAudioStream]
    let subtitleStreams: [ApplicationMediaSubtitleStream]

    init(
        schemaVersion: Int = currentSchemaVersion,
        sourceURL: URL,
        durationSeconds: Double?,
        formatName: String?,
        containerName: String?,
        sizeBytes: Int64?,
        bitRate: Int64?,
        timecode: String?,
        timecodes: [TimecodeEntry],
        frameCount: Int?,
        warnings: [String],
        videoStreams: [ApplicationMediaVideoStream],
        audioStreams: [ApplicationMediaAudioStream],
        subtitleStreams: [ApplicationMediaSubtitleStream]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.formatName = formatName
        self.containerName = containerName
        self.sizeBytes = sizeBytes
        self.bitRate = bitRate
        self.timecode = timecode
        self.timecodes = timecodes
        self.frameCount = frameCount
        self.warnings = warnings
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
    }

    init(sourceURL: URL, metadata: VideoMetadata) {
        self.init(
            sourceURL: sourceURL.standardizedFileURL,
            durationSeconds: metadata.duration,
            formatName: metadata.formatName,
            containerName: metadata.containerLongName,
            sizeBytes: metadata.sizeBytes,
            bitRate: metadata.bitRate,
            timecode: metadata.timecode,
            timecodes: metadata.timecodes,
            frameCount: metadata.frameCount,
            warnings: metadata.warnings,
            videoStreams: metadata.videoStreams.enumerated().map { index, stream in
                ApplicationMediaVideoStream(
                    index: index,
                    codec: stream.codec,
                    profile: stream.profile,
                    width: stream.width,
                    height: stream.height,
                    pixelFormat: stream.pixelFormat,
                    hasAlpha: stream.hasAlpha,
                    pixelAspectRatio: stream.pixelAspectRatio.map(ApplicationMediaRational.init),
                    displayAspectRatio: stream.displayAspectRatio.map(ApplicationMediaRational.init),
                    frameRate: stream.frameRate.map(ApplicationMediaRational.init),
                    bitDepth: stream.bitDepth,
                    bitRate: stream.bitRate,
                    durationSeconds: stream.duration,
                    chromaSubsampling: stream.chromaSubsampling,
                    colorPrimaries: stream.colorPrimaries,
                    colorTransfer: stream.colorTransfer,
                    colorSpace: stream.colorSpace,
                    colorRange: stream.colorRange,
                    fieldOrder: stream.fieldOrder,
                    isInterlaced: stream.isInterlaced,
                    title: stream.title,
                    isDefault: stream.isDefault,
                    isForced: stream.isForced
                )
            },
            audioStreams: metadata.audioStreams.map { stream in
                ApplicationMediaAudioStream(
                    index: stream.index,
                    languageCode: stream.languageCode,
                    title: stream.title,
                    codec: stream.codec,
                    profile: stream.profile,
                    sampleRate: stream.sampleRate,
                    channels: stream.channels,
                    channelLayout: stream.channelLayout,
                    bitDepth: stream.bitDepth,
                    bitRate: stream.bitRate,
                    isDefault: stream.isDefault
                )
            },
            subtitleStreams: metadata.subtitleStreams.map { stream in
                ApplicationMediaSubtitleStream(
                    index: stream.index,
                    languageCode: stream.languageCode,
                    title: stream.title,
                    codec: stream.codec,
                    isDefault: stream.isDefault,
                    isForced: stream.isForced,
                    isHearingImpaired: stream.isHearingImpaired,
                    durationSeconds: stream.duration
                )
            }
        )
    }

    init(sourceURL: URL, audioMetadata: SwiftMediaMetadata.AudioMetadata) {
        let fileSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        self.init(
            sourceURL: sourceURL.standardizedFileURL,
            durationSeconds: audioMetadata.duration,
            formatName: audioMetadata.format.rawValue,
            containerName: audioMetadata.format.rawValue,
            sizeBytes: fileSize.map(Int64.init),
            bitRate: audioMetadata.bitrate.map(Int64.init),
            timecode: nil,
            timecodes: [],
            frameCount: nil,
            warnings: audioMetadata.warnings,
            videoStreams: [],
            audioStreams: [ApplicationMediaAudioStream(
                index: 0,
                languageCode: nil,
                title: audioMetadata.title,
                codec: audioMetadata.codec,
                profile: audioMetadata.codecName,
                sampleRate: audioMetadata.sampleRate,
                channels: audioMetadata.channels,
                channelLayout: audioMetadata.channelLayout,
                bitDepth: audioMetadata.bitDepth,
                bitRate: audioMetadata.bitrate.map(Int64.init),
                isDefault: true
            )],
            subtitleStreams: []
        )
    }
}

private extension ApplicationMediaRational {
    init(_ ratio: VideoMetadata.Ratio) {
        self.init(
            numerator: ratio.numerator,
            denominator: ratio.denominator,
            value: ratio.doubleValue ?? 0
        )
    }

    init(_ frameRate: VideoMetadata.FrameRate) {
        self.init(
            numerator: frameRate.numerator,
            denominator: frameRate.denominator,
            value: frameRate.value ?? 0
        )
    }
}

struct ApplicationMediaInspector: Sendable {
    typealias Inspect = @Sendable (URL) async throws -> ApplicationMediaInspection

    let inspect: Inspect

    static let live = ApplicationMediaInspector { url in
        do {
            let metadata = try await BoundedVideoMetadataProbe.metadata(for: url)
            return ApplicationMediaInspection(sourceURL: url, metadata: metadata)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let audioMetadata = try await SwiftExifMediaProbe.readAudio(url)
            return ApplicationMediaInspection(sourceURL: url, audioMetadata: audioMetadata)
        }
    }
}

/// Stable identifiers reserved for the first per-file overrides. Preset
/// descriptors advertise none until the immutable request contract can execute
/// them faithfully.
enum ApplicationConversionOverrideID: String, Codable, Sendable {
    case trimStartSeconds = "trim_start_seconds"
    case trimEndSeconds = "trim_end_seconds"
    case muted
    case outputBaseName = "output_base_name"
}

struct ApplicationPresetDescriptor: Codable, Equatable, Sendable {
    let id: ApplicationPresetID
    let displayName: String
    let settings: ApplicationPresetSettings
    let supportedOverrides: [ApplicationConversionOverrideID]
}

struct ApplicationPlanConversionInput: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let requesterID: String
    let sourceURLs: [URL]
    let destinationFolderURL: URL
    let presetID: ApplicationPresetID
    let idempotencyKey: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: UUID = UUID(),
        requesterID: String,
        sourceURLs: [URL],
        destinationFolderURL: URL,
        presetID: ApplicationPresetID,
        idempotencyKey: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.requesterID = requesterID
        self.sourceURLs = sourceURLs
        self.destinationFolderURL = destinationFolderURL
        self.presetID = presetID
        self.idempotencyKey = idempotencyKey
    }
}

/// Transport-ready error payload. Unknown implementation errors deliberately do
/// not expose paths, command lines, or other potentially sensitive diagnostics.
struct ApplicationAgentToolFailure: Codable, Equatable, Sendable {
    let code: ApplicationJobErrorCode
    let message: String

    init(code: ApplicationJobErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    init(error: Error) {
        if let jobError = error as? ApplicationJobError {
            code = jobError.code
            message = jobError.agentMessage
        } else if error is CancellationError {
            code = .cancelled
            message = "The operation was cancelled."
        } else {
            code = .internalError
            message = "The operation failed inside Aagedal Media Converter."
        }
    }
}

private extension ApplicationJobError {
    var agentMessage: String {
        switch self {
        case .unsupportedSchema(let version):
            "Schema version \(version) is not supported."
        case .invalidRequesterID:
            "The requester identifier is empty or invalid."
        case .noSources:
            "At least one source file is required."
        case .duplicateSource(let url):
            "The source file appears more than once: \(url.lastPathComponent)."
        case .nonFileURL:
            "Only local file URLs are supported."
        case .invalidIdempotencyKey:
            "The idempotency key is empty or invalid."
        case .presetSettingsMismatch:
            "The captured settings do not match the requested preset."
        case .idempotencyConflict:
            "The idempotency key is already associated with a different request."
        case .unknownJob(let id):
            "No job exists with identifier \(id)."
        case .invalidTransition(let current, let requested):
            "The job cannot move from \(current.rawValue) to \(requested.rawValue)."
        case .invalidProgress:
            "Job progress must be between zero and one."
        case .unknownPlan(let id):
            "No conversion plan exists with identifier \(id)."
        case .expiredPlan:
            "The conversion plan expired. Create a new plan before submitting."
        case .sourceUnavailable(let url):
            "The source file is unavailable: \(url.lastPathComponent)."
        case .sourceAccessDenied(let url):
            "Access to the source has not been approved in the app: \(url.lastPathComponent)."
        case .sourceChanged(let url):
            "The source changed after planning: \(url.lastPathComponent)."
        case .destinationUnavailable:
            "The destination folder is unavailable or not writable."
        case .destinationAccessDenied:
            "Writable access to the destination has not been approved in the app."
        case .unsupportedSourceExtension(let url):
            "The source has no usable extension for stream copy: \(url.lastPathComponent)."
        case .duplicateOutput(let url):
            "The plan would create the same output more than once: \(url.lastPathComponent)."
        case .outputCollision(let url):
            "The output already exists or is reserved: \(url.lastPathComponent)."
        case .mediaInspectionFailed(let url):
            "Media inspection failed for \(url.lastPathComponent)."
        }
    }
}

/// Implements the proposed six-tool contract without assuming MCP, XPC, or any
/// other transport. A future helper only decodes input, calls these methods, and
/// encodes either the returned Codable value or `ApplicationAgentToolFailure`.
struct ApplicationAgentTools: Sendable {
    typealias PresetSettingsProvider = @Sendable (ApplicationPresetID) -> ApplicationPresetSettings
    typealias NowProvider = @Sendable () -> Date

    static let shared = ApplicationAgentTools(jobService: .shared)

    private let jobService: ApplicationJobService
    private let fileAccessAuthorizer: ApplicationFileAccessAuthorizer
    private let mediaInspector: ApplicationMediaInspector
    private let presetSettingsProvider: PresetSettingsProvider
    private let now: NowProvider

    init(
        jobService: ApplicationJobService,
        fileAccessAuthorizer: ApplicationFileAccessAuthorizer = .live,
        mediaInspector: ApplicationMediaInspector = .live,
        presetSettingsProvider: @escaping PresetSettingsProvider = {
            ApplicationPresetSettings(presetID: $0, defaults: .standard)
        },
        now: @escaping NowProvider = Date.init
    ) {
        self.jobService = jobService
        self.fileAccessAuthorizer = fileAccessAuthorizer
        self.mediaInspector = mediaInspector
        self.presetSettingsProvider = presetSettingsProvider
        self.now = now
    }

    func inspectMedia(at sourceURL: URL) async throws -> ApplicationMediaInspection {
        guard sourceURL.isFileURL else { throw ApplicationJobError.nonFileURL(sourceURL) }
        guard let lease = fileAccessAuthorizer.acquire(sourceURL, .read) else {
            throw ApplicationJobError.sourceAccessDenied(sourceURL)
        }
        defer { lease.release() }
        do {
            return try await mediaInspector.inspect(sourceURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApplicationJobError {
            throw error
        } catch {
            throw ApplicationJobError.mediaInspectionFailed(sourceURL)
        }
    }

    func listPresets() -> [ApplicationPresetDescriptor] {
        ApplicationPresetID.allCases.map { presetID in
            ApplicationPresetDescriptor(
                id: presetID,
                displayName: presetID.exportPreset.rawValue,
                settings: presetSettingsProvider(presetID),
                supportedOverrides: []
            )
        }
    }

    func planConversion(
        _ input: ApplicationPlanConversionInput
    ) async throws -> ApplicationConversionPlan {
        let capturedAt = now()
        let request = ApplicationConversionRequest(
            schemaVersion: input.schemaVersion,
            requestID: input.requestID,
            origin: .localAgent,
            requesterID: input.requesterID,
            sourceURLs: input.sourceURLs,
            destinationFolderURL: input.destinationFolderURL,
            presetID: input.presetID,
            presetSettings: presetSettingsProvider(input.presetID),
            idempotencyKey: input.idempotencyKey,
            capturedAt: capturedAt
        )
        return try await jobService.plan(request, now: capturedAt)
    }

    func submitConversion(
        planID: ApplicationPlanID
    ) async throws -> ApplicationJobAcceptance {
        try await jobService.submit(planID: planID, now: now())
    }

    func getJob(jobID: ApplicationJobID) async throws -> ApplicationJobRecord {
        guard let record = try await jobService.record(for: jobID, now: now()) else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        return record
    }

    func cancelJob(jobID: ApplicationJobID) async throws -> ApplicationJobRecord {
        try await jobService.requestCancellation(jobID, now: now())
    }
}
