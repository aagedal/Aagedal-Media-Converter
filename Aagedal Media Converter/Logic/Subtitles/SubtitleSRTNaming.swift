// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation
import os

/// OCR includes both Tesseract and Apple Vision bitmap recognition.
enum SubtitleSRTMethod: String, CaseIterable, Codable, Sendable {
    case ocr
    case whisper
    case parakeet
}

/// Coordinates all engines and service instances. An existing SRT is reusable only
/// when its hidden ownership record identifies this source and engine, and its
/// contents have not been edited. Legacy or externally created SRTs remain untouched.
final class SubtitleSRTNaming: Sendable {
    static let shared = SubtitleSRTNaming()
    private static let ownershipAttribute = "com.aagedal.MediaConverter.subtitle-owner"
    private let reservations = OSAllocatedUnfairLock(initialState: [String: UUID]())
    private let persistOwnership: @Sendable (URL, Data) -> Bool

    init(persistOwnership: @escaping @Sendable (URL, Data) -> Bool = SubtitleSRTNaming.writeOwnership) {
        self.persistOwnership = persistOwnership
    }

    func reserve(directory: URL, sourceFile: URL, method: SubtitleSRTMethod) -> SubtitleSRTReservation {
        let owner = SubtitleSRTOwner(
            sourceIdentityDigest: Data(SHA256.hash(data: Data(Self.pathKey(sourceFile).utf8))),
            method: method
        )
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let bare = Self.candidate(directory: directory, baseName: baseName, suffix: "")
        let suffixed = Self.candidate(directory: directory, baseName: baseName, suffix: ".\(method.rawValue)")

        return reservations.withLock { reserved in
            // Find a prior numbered output as well, so removing another engine's
            // bare file does not change where a successful retry writes.
            let existing = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ))?.map { directory.appendingPathComponent($0.lastPathComponent) } ?? []
            let candidates = [bare, suffixed] + existing.filter {
                $0.pathExtension.lowercased() == "srt" && $0 != bare && $0 != suffixed
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in candidates where reserved[Self.pathKey(candidate)] == nil {
                guard let previous = Self.ownedFile(at: candidate, by: owner) else { continue }
                return reserve(candidate, owner: owner, previous: previous, in: &reserved)
            }

            var index = 0
            while true {
                let suffix = index == 0 ? "" : index == 1 ? ".\(method.rawValue)" : ".\(method.rawValue)-\(index)"
                let candidate = Self.candidate(directory: directory, baseName: baseName, suffix: suffix)
                if reserved[Self.pathKey(candidate)] == nil && !Self.exists(candidate) {
                    return reserve(candidate, owner: owner, previous: nil, in: &reserved)
                }
                index += 1
            }
        }
    }

    private func reserve(
        _ url: URL,
        owner: SubtitleSRTOwner,
        previous: SubtitleSRTOwnedFile?,
        in reserved: inout [String: UUID]
    ) -> SubtitleSRTReservation {
        let id = UUID()
        let key = Self.pathKey(url)
        reserved[key] = id
        return SubtitleSRTReservation(
            url: url, key: key, id: id, owner: owner, previous: previous, coordinator: self
        )
    }

    fileprivate func release(_ reservation: SubtitleSRTReservation) {
        reservations.withLock {
            if $0[reservation.key] == reservation.id { $0.removeValue(forKey: reservation.key) }
        }
    }

    fileprivate func publish(stagedURL: URL, reservation: SubtitleSRTReservation) throws {
        try reservations.withLock { reserved in
            guard reserved[reservation.key] == reservation.id else { throw CancellationError() }
            let destination = reservation.url
            // All app processes publishing in this directory must serialize the
            // ownership check and replacement. Lock the directory inode itself so
            // aliases share the lock, without leaving sidecars or stale lock files.
            // Never block the main actor waiting for another app process.
            let directoryDescriptor = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(directoryDescriptor) }
            guard flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { flock(directoryDescriptor, LOCK_UN) }

            let record = SubtitleSRTOwnershipRecord(
                owner: reservation.owner,
                destinationName: destination.lastPathComponent,
                generation: UUID(),
                contentDigest: try Self.contentDigest(at: stagedURL)
            )
            let data = try JSONEncoder().encode(record)
            // Some external filesystems do not support xattrs. Publication still
            // succeeds there, but later runs treat the output as unowned and choose
            // a fresh name instead of making an unsafe replacement assumption.
            _ = persistOwnership(stagedURL, data)
            try Task.checkCancellation()
            if let previous = reservation.previous {
                guard Self.ownedFile(at: destination, by: reservation.owner) == previous else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else if Self.exists(destination) {
                // Another writer may have appeared while transcription was running.
                throw CocoaError(.fileWriteFileExists)
            }

            if reservation.previous != nil {
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: stagedURL, options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destination)
            }
        }
    }

    private static func candidate(directory: URL, baseName: String, suffix: String) -> URL {
        let ending = suffix + ".srt"
        let maximumBaseBytes = max(255 - ending.utf8.count, 1)
        var shortenedBase = baseName
        while shortenedBase.utf8.count > maximumBaseBytes { shortenedBase.removeLast() }
        return directory.appendingPathComponent(shortenedBase + ending)
    }

    private static func pathKey(_ url: URL) -> String {
        // Resolve the existing parent separately: Foundation can leave an entire
        // path unresolved when the destination leaf has not been created yet.
        let standardized = url.standardizedFileURL
        let resolved = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent).resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        let caseSensitive = try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        let path = resolved.path.precomposedStringWithCanonicalMapping
        return caseSensitive == true ? path : path.lowercased()
    }

    private static func exists(_ url: URL) -> Bool {
        // Unlike fileExists, this also detects dangling symbolic links.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func ownedFile(at url: URL, by owner: SubtitleSRTOwner) -> SubtitleSRTOwnedFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let data = readOwnership(at: url),
              let record = try? JSONDecoder().decode(SubtitleSRTOwnershipRecord.self, from: data),
              record.owner == owner, record.destinationName == url.lastPathComponent,
              let digest = try? contentDigest(at: url), digest == record.contentDigest else { return nil }
        return SubtitleSRTOwnedFile(record: record, inode: inode.uint64Value, device: device.uint64Value)
    }

    private static func contentDigest(at url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private static func writeOwnership(at url: URL, data: Data) -> Bool {
        data.withUnsafeBytes {
            setxattr(url.path, ownershipAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) == 0
        }
    }

    private static func readOwnership(at url: URL) -> Data? {
        let count = getxattr(url.path, ownershipAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count <= 16 * 1024 else { return nil }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes {
            getxattr(url.path, ownershipAttribute, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
        }
        return readCount == count ? data : nil
    }
}

/// A reservation is held through publication and released on every success, failure,
/// and cancellation path. Its identity prevents an old release from freeing a retry.
final class SubtitleSRTReservation: Sendable {
    let url: URL
    fileprivate let key: String
    fileprivate let id: UUID
    fileprivate let owner: SubtitleSRTOwner
    fileprivate let previous: SubtitleSRTOwnedFile?
    private let coordinator: SubtitleSRTNaming

    fileprivate init(
        url: URL, key: String, id: UUID, owner: SubtitleSRTOwner,
        previous: SubtitleSRTOwnedFile?, coordinator: SubtitleSRTNaming
    ) {
        self.url = url
        self.key = key
        self.id = id
        self.owner = owner
        self.previous = previous
        self.coordinator = coordinator
    }

    func release() { coordinator.release(self) }
    func publish(stagedURL: URL) throws { try coordinator.publish(stagedURL: stagedURL, reservation: self) }
    deinit { release() }
}

private struct SubtitleSRTOwner: Codable, Equatable, Sendable {
    // Shared SRTs must not disclose the source's local directory in their xattrs.
    let sourceIdentityDigest: Data
    let method: SubtitleSRTMethod
}

private struct SubtitleSRTOwnershipRecord: Codable, Equatable, Sendable {
    let owner: SubtitleSRTOwner
    let destinationName: String
    let generation: UUID
    let contentDigest: Data
}

private struct SubtitleSRTOwnedFile: Equatable, Sendable {
    let record: SubtitleSRTOwnershipRecord
    let inode: UInt64
    let device: UInt64
}
