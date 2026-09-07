// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftMediaMetadata

/// In-process replacement for `ExifToolService` backed by the SwiftMediaMetadata package.
/// Returns the same `C2PAMetadata` / `CameraMetadata` structs so existing callers
/// (and the UI) need no changes.
actor SwiftExifMetadataService {
    static let shared = SwiftExifMetadataService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "SwiftExifMetadataService")

    private init() {}

    /// Always true — SwiftMediaMetadata is bundled with the app, there is no external binary to detect.
    nonisolated var isAvailable: Bool { true }

    /// File extensions whose container layout SwiftMediaMetadata can parse. Anything else
    /// (mkv, webm, avi, mp3, m4a, …) is resolved as "no metadata" without a read attempt.
    private static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf"]

    private static func isParsableContainer(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - C2PA

    func getC2PAMetadata(for url: URL) async throws -> C2PAMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftExifMetadataError.fileNotFound
        }
        guard Self.isParsableContainer(url) else { return nil }

        let videoMetadata: SwiftMediaMetadata.VideoMetadata
        do {
            videoMetadata = try await readVideoMetadata(from: url)
        } catch {
            // The file's extension said it should be parsable but SwiftMediaMetadata couldn't
            // read it — log once at debug level and treat as "no metadata", matching
            // ExifTool's old behavior on malformed/partial files.
            logger.debug("SwiftMediaMetadata read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return Self.makeC2PAMetadata(from: videoMetadata)
    }

    // MARK: - Camera

    func getCameraMetadata(for url: URL) async throws -> CameraMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftExifMetadataError.fileNotFound
        }
        guard Self.isParsableContainer(url) else { return nil }

        let cam: SwiftMediaMetadata.CameraMetadata?
        do {
            cam = try await SwiftMediaMetadata.readVideoCameraMetadata(from: url)
        } catch {
            logger.debug("SwiftMediaMetadata camera read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let cam else { return nil }
        let mapped = Self.makeCameraMetadata(from: cam)
        return mapped.hasAnyData ? mapped : nil
    }

    // MARK: - Convenience variants matching ExifToolService's API

    func checkC2PAIfEnabled(for url: URL) async -> C2PAMetadata? {
        do { return try await getC2PAMetadata(for: url) } catch {
            logger.warning("C2PA check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func checkCameraMetadataIfEnabled(for url: URL) async -> CameraMetadata? {
        do { return try await getCameraMetadata(for: url) } catch {
            logger.warning("Camera metadata check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Mapping

    static func makeC2PAMetadata(from video: SwiftMediaMetadata.VideoMetadata) -> C2PAMetadata? {
        // Only surface C2PA when the container actually carries a C2PA manifest.
        // Sony NRT camera XML (video.camera.userMeta*, video.camera.creationDate) is
        // *not* C2PA — previously it was routed here and produced false positives.
        guard let manifest = video.c2pa?.activeManifest else { return nil }

        let firstActionAssertion = manifest.assertions.first { assertion in
            assertion.label.hasPrefix("c2pa.actions")
        }
        let firstAction: C2PAAction? = {
            guard let content = firstActionAssertion?.content,
                  case .actions(let actions) = content else { return nil }
            return actions.actions.first
        }()

        let assertionLabels = manifest.assertions.map { $0.label }
        let hasSignature = !manifest.signature.signatureBytes.isEmpty

        return C2PAMetadata(
            hasContentCredentials: true,
            hasSignature: hasSignature,
            actionsAction: firstAction?.action,
            actionsDigitalSourceType: firstAction?.digitalSourceType,
            claimGenerator: manifest.claim.claimGenerator,
            claimGeneratorInfoName: manifest.claim.claimGeneratorInfo?.name,
            manifestStore: manifest.label,
            assertions: assertionLabels.isEmpty ? nil : assertionLabels
        )
    }

    static func makeCameraMetadata(from cam: SwiftMediaMetadata.CameraMetadata) -> CameraMetadata {
        // SwiftMediaMetadata surfaces the `<Meta>` entries as two parallel arrays; zip them
        // back into name/content pairs and drop any empty ones.
        let userMetadata: [UserMetadataEntry]? = {
            let pairs = zip(cam.userMetaNames, cam.userMetaContents).compactMap { name, content -> UserMetadataEntry? in
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty || !c.isEmpty else { return nil }
                return UserMetadataEntry(name: n, content: c)
            }
            return pairs.isEmpty ? nil : pairs
        }()

        return CameraMetadata(
            deviceManufacturer: cam.deviceManufacturer,
            deviceModelName: cam.deviceModelName,
            deviceSerialNumber: cam.deviceSerialNumber,
            lensModelName: cam.lensModelName,
            timeZone: cam.timeZone,
            captureGammaEquation: cam.captureGammaEquation,
            recordingModeType: cam.recordingModeType,
            captureFps: cam.captureFps.map { fps in
                fps.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", fps)
                    : String(format: "%.3f", fps)
            },
            creationDate: cam.creationDate,
            userDescriptiveMetadata: userMetadata
        )
    }

    private func readVideoMetadata(from url: URL) async throws -> SwiftMediaMetadata.VideoMetadata {
        try await SwiftMediaMetadata.readVideoMetadata(from: url)
    }
}

enum SwiftExifMetadataError: Error, LocalizedError {
    case fileNotFound
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found"
        case .readFailed(let msg): return "SwiftMediaMetadata read failed: \(msg)"
        }
    }
}
