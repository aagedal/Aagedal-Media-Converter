// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Checks picture and IMF audio dependencies before output creation or encoding.
/// Does not launch helpers: version flags are not safe for every bundled encoder.
struct ConversionDependencyPreflight: Sendable {
    enum Helper: String, Sendable {
        case asdcpWrap = "asdcp-wrap"
        case raw2bmx
        case bmxtranswrap
        case avmenc
        case avmdec

        var bundledPath: String? {
            switch self {
            case .asdcpWrap: BinaryPathResolver.asdcpWrapPath
            case .raw2bmx: BinaryPathResolver.raw2bmxPath
            case .bmxtranswrap: BinaryPathResolver.bmxtranswrapPath
            case .avmenc: BinaryPathResolver.avmencPath
            case .avmdec: BinaryPathResolver.avmdecPath
            }
        }
    }

    private let pathProvider: @Sendable (Helper) -> String?

    init(pathProvider: @escaping @Sendable (Helper) -> String? = { $0.bundledPath }) {
        self.pathProvider = pathProvider
    }

    /// Unknown audio layouts must remain false so silent or custom inputs are not blocked.
    func failure(for preset: ExportPreset, sourceAudioKnownPresent: Bool = false) -> String? {
        let helper: Helper
        switch preset {
        case .dcp: helper = .asdcpWrap
        case .imfJ2K: helper = .raw2bmx
        case .imfProRes: helper = .bmxtranswrap
        case .av2: helper = .avmenc
        default: return nil
        }

        if let failure = Self.failure(for: helper, path: pathProvider(helper)) { return failure }
        if (preset == .imfJ2K || preset == .imfProRes), sourceAudioKnownPresent {
            return Self.failure(for: .asdcpWrap, path: pathProvider(.asdcpWrap))
        }
        return nil
    }

    /// Mirrors package extraction's source resolution, including companion audio and concat inputs.
    /// Only probe when the missing audio wrapper could actually prevent this export.
    func audioFailure(
        for request: ConversionRequest,
        timeout: Duration = FFMPEGProbeService.defaultTimeout,
        audioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) async throws -> String? {
        try Task.checkCancellation()
        guard request.preset == .imfJ2K || request.preset == .imfProRes,
              !(request.audioRoutingConfig.map { $0.isCustomized && $0.outputTracks.isEmpty } ?? false),
              let failure = Self.failure(for: .asdcpWrap, path: pathProvider(.asdcpWrap)) else {
            return nil
        }
        let source = FFMPEGConverter.packageAudioInput(
            inputURL: request.inputURL, customInputArguments: request.customInputArguments
        )
        guard let probeURL = source.probeURL else { return nil }
        // Extraction treats explicit audio-only sources as one stream even without metadata.
        if source.assumesSingleAudioStreamIfProbeUnavailable { return failure }
        if request.customInputArguments == nil, let metadata = request.sourceMetadata {
            return metadata.audioStreams.isEmpty ? nil : failure
        }
        do {
            let streams = try await NonJoiningTaskDeadline.run(timeout: timeout) {
                await audioStreamProvider(probeURL)
            }
            try Task.checkCancellation()
            return streams?.isEmpty == false ? failure : nil
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Unknown topology retains extraction's existing fallback policy.
            return nil
        }
    }

    static func failure(for helper: Helper, path: String?) -> String? {
        if let path {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return nil
            }
        }
        let name = helper.rawValue
        return String(localized: "Export requires the bundled \(name) helper, which is missing or not executable. Open Settings > Tool Diagnostics to inspect the tools, or reinstall the app.", comment: "Early conversion failure when a required bundled package wrapper or AV2 encoder is unavailable.")
    }
}
