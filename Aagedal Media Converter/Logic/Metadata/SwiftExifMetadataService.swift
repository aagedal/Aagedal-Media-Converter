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
        guard let store = video.c2pa, let manifest = store.activeManifest else { return nil }

        let details = C2PAManifestDetails(manifest)
        let firstAction = details.actions.first
        let assertionLabels = manifest.assertions.map { $0.label }
        let hasSignature = !manifest.signature.signatureBytes.isEmpty

        var metadata = C2PAMetadata(
            hasContentCredentials: true,
            hasSignature: hasSignature,
            actionsAction: firstAction?.action,
            actionsDigitalSourceType: firstAction?.digitalSourceType,
            claimGenerator: manifest.claim.claimGenerator,
            claimGeneratorInfoName: manifest.claim.claimGeneratorInfo?.name,
            manifestStore: manifest.label,
            assertions: assertionLabels.isEmpty ? nil : assertionLabels
        )
        metadata.claimGeneratorVersion = manifest.claim.claimGeneratorInfo?.version
        metadata.title = manifest.claim.title
        metadata.format = manifest.claim.format
        metadata.authors = details.authors.isEmpty ? nil : details.authors
        metadata.copyright = details.copyright
        metadata.actions = details.actions.isEmpty ? nil : details.actions
        metadata.ingredients = details.ingredients.isEmpty ? nil : details.ingredients
        metadata.trainingMining = details.trainingMining.isEmpty ? nil : details.trainingMining
        metadata.hasIdentityAssertion = details.hasIdentityAssertion
        metadata.redactionCount = details.redactionCount > 0 ? details.redactionCount : nil
        metadata.claimThumbnail = details.claimThumbnail
        metadata.ingredientThumbnail = details.ingredientThumbnail
        if hasSignature {
            metadata.signature = makeSignatureInfo(manifest.signature)
        }
        metadata.history = store.manifests.map { manifest in
            let generator = manifest.claim.claimGeneratorInfo.map { info in
                [info.name, info.version].compactMap { $0 }.joined(separator: " ")
            } ?? manifest.claim.claimGenerator
            let signer = C2PACertificateReader.details(fromChain: manifest.signature.certificateChain)
            return C2PAManifestSummary(
                label: manifest.label,
                generator: generator.isEmpty ? nil : generator,
                signer: signer.organization ?? signer.commonName,
                actions: C2PAManifestDetails(manifest).actions.map(\.displayName)
            )
        }
        return metadata
    }

    private static func makeSignatureInfo(_ signature: SwiftMediaMetadata.C2PASignature) -> C2PASignatureInfo {
        let certificate = C2PACertificateReader.details(fromChain: signature.certificateChain)
        return C2PASignatureInfo(
            signer: certificate.commonName,
            signerOrganization: certificate.organization,
            issuer: certificate.issuer,
            algorithm: signature.algorithm?.description,
            timestamp: signature.timestamp.flatMap(C2PATimestampReader.signingTime(fromToken:)),
            hasTimestamp: signature.timestamp?.isEmpty == false,
            certificateExpiry: certificate.expiry
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

/// Assertion contents of one manifest, collected in a single pass.
private struct C2PAManifestDetails {
    var actions: [C2PAActionInfo] = []
    var ingredients: [C2PAIngredientInfo] = []
    var authors: [String] = []
    var copyright: String?
    var trainingMining: [C2PATrainingPermission] = []
    var hasIdentityAssertion = false
    var redactionCount = 0
    var claimThumbnail: Data?
    var ingredientThumbnail: Data?

    init(_ manifest: SwiftMediaMetadata.C2PAManifest) {
        for assertion in manifest.assertions {
            switch assertion.content {
            case .actions(let box):
                actions += box.actions.map {
                    C2PAActionInfo(
                        action: $0.action, softwareAgent: $0.softwareAgent,
                        digitalSourceType: $0.digitalSourceType, description: $0.description
                    )
                }
            case .ingredient(let ingredient):
                ingredients.append(C2PAIngredientInfo(
                    title: ingredient.title, format: ingredient.format, relationship: ingredient.relationship
                ))
            case .schemaOrgCreativeWork(let work):
                authors += work.authors
                copyright = copyright ?? work.copyrightNotice ?? work.copyrightHolder
            case .json(let data) where assertion.label.hasPrefix("stds.schema-org.CreativeWork"):
                // Older writers deliver CreativeWork as JSON rather than CBOR.
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                if let list = json["author"] as? [[String: Any]] {
                    authors += list.compactMap { $0["name"] as? String }
                } else if let single = json["author"] as? [String: Any], let name = single["name"] as? String {
                    authors.append(name)
                }
                copyright = copyright ?? json["copyrightNotice"] as? String
            case .iptc(let iptc):
                authors += iptc.creators
                copyright = copyright ?? iptc.rights
            case .trainingMining(let declaration):
                trainingMining += declaration.entries.map {
                    C2PATrainingPermission(category: $0.category, use: $0.use, constraintInfo: $0.constraintInfo)
                }
            case .identityAssertion:
                hasIdentityAssertion = true
            case .redactions(let redactions):
                redactionCount += redactions.redactions.count
            case .thumbnail(let data, _):
                if assertion.label.contains("ingredient") {
                    ingredientThumbnail = ingredientThumbnail ?? data
                } else {
                    claimThumbnail = claimThumbnail ?? data
                }
            default:
                break
            }
        }
        var seen: Set<String> = []
        authors = authors.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
