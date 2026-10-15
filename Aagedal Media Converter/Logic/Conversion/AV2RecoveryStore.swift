// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit
import Darwin

/// A private, exclusively leased checkpoint. A manifest entry is published only after
/// successful encoding, structural IVF validation, hashing and atomic file installation.
/// Incomplete files never become candidates for reuse, even after an app crash.
/// A conversion serializes access; detached file operations are always joined before reuse.
final class AV2RecoveryStore: @unchecked Sendable {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.aagedal.Aagedal-Media-Converter", isDirectory: true)
            .appendingPathComponent("AV2Recovery", isDirectory: true)
    }

    enum RecoveryError: LocalizedError {
        case sourceChanged
        var errorDescription: String? { "The source file changed during AV2 encoding. Retry to start a compatible encode." }
    }
    private struct SourceStamp: Equatable, Sendable {
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
        let inode: UInt64
        let device: Int32

        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanos = Int64(info.st_ctimespec.tv_nsec)
            inode = info.st_ino
            device = info.st_dev
        }
    }

    struct Artifact: Codable {
        let sha256: String
        let bytes: UInt64
    }
    struct Manifest: Codable {
        let version: Int
        let identity: String
        var completed: [String: Artifact]
    }
    struct Identity: Encodable {
        let version: Int
        let sourcePath: String
        let sourceDigest: String
        let ffmpegDigest: String
        let encoderDigest: String
        let width: Int
        let height: Int
        let bitDepth: Int
        let frames: Int
        let commands: [[String]]
    }

    let directory: URL
    private let lockFD: Int32
    private var manifest: Manifest
    private let plan: AV2CommandBuilder.AV2SegmentPlan
    private let sourceStamp: SourceStamp

    private init(directory: URL, lockFD: Int32, manifest: Manifest, plan: AV2CommandBuilder.AV2SegmentPlan, sourceStamp: SourceStamp) {
        self.directory = directory
        self.lockFD = lockFD
        self.manifest = manifest
        self.plan = plan
        self.sourceStamp = sourceStamp
    }

    deinit {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        Darwin.close(lockFD)
    }

    static func open(plan: AV2CommandBuilder.AV2SegmentPlan, ffmpeg: URL, encoder: URL, root: URL) throws -> AV2RecoveryStore? {
        guard let source = plan.recoverySourceURL else { return nil }
        let stamp = try SourceStamp(source)
        let commands = plan.segments.flatMap { segment -> [[String]] in
            var av = segment.avmencArguments
            if let output = av.firstIndex(of: "-o"), output + 1 < av.count { av[output + 1] = "OUTPUT" }
            return [segment.ffmpegArguments, av, [String(segment.index), String(segment.frameCount)]]
        }
        let identity = Identity(version: 1, sourcePath: source.standardizedFileURL.path,
            sourceDigest: try digest(source), ffmpegDigest: try digest(ffmpeg), encoderDigest: try digest(encoder),
            width: plan.outputWidth, height: plan.outputHeight, bitDepth: plan.bitDepth,
            frames: plan.totalFrames, commands: commands)
        guard (try? SourceStamp(source)) == stamp else { throw RecoveryError.sourceChanged }
        let json = JSONEncoder()
        json.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: try json.encode(identity)).map { String(format: "%02x", $0) }.joined()
        try privateDirectory(root, createParents: true)
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try privateDirectory(directory)
        guard let fd = acquireLock(directory) else { return nil }
        var transferred = false
        do {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            var manifest = Manifest(version: 1, identity: key, completed: [:])
            let lastUse = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let expired = Date().timeIntervalSince(lastUse) > 7 * 24 * 3600
            if !expired, regularFile(manifestURL), let size = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size < 1024 * 1024, let data = try? Data(contentsOf: manifestURL),
               let existing = try? JSONDecoder().decode(Manifest.self, from: data),
               existing.version == 1, existing.identity == key { manifest = existing }
            let store = AV2RecoveryStore(directory: directory, lockFD: fd, manifest: manifest, plan: plan, sourceStamp: stamp)
            transferred = true
            try store.saveManifest()
            store.removeUncommittedFiles()
            // Bound abandoned recovery work without touching any active conversion.
            prune(root: root, excluding: directory)
            return store
        } catch {
            if !transferred { Darwin.close(fd) }
            throw error
        }
    }

    func validateSource() throws {
        guard let source = plan.recoverySourceURL, (try? SourceStamp(source)) == sourceStamp else { throw RecoveryError.sourceChanged }
    }

    func restore(_ segment: AV2CommandBuilder.AV2SegmentCommand) throws -> Bool {
        try validateSource()
        guard let artifact = manifest.completed[String(segment.index)] else { return false }
        let file = chunkURL(segment.index)
        let accepted: Bool
        do {
            if Self.regularFile(file), try valid(file, segment: segment),
               let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               UInt64(bytes) == artifact.bytes, try Self.digest(file) == artifact.sha256 {
                accepted = true
            } else { accepted = false }
        } catch is CancellationError { throw CancellationError() }
        catch { accepted = false }
        guard accepted else {
            manifest.completed.removeValue(forKey: String(segment.index))
            try? FileManager.default.removeItem(at: file)
            try? saveManifest()
            return false
        }
        try Self.copy(file, to: segment.outputURL)
        try validateSource()
        return true
    }

    func store(_ segment: AV2CommandBuilder.AV2SegmentCommand) throws {
        try validateSource()
        guard try valid(segment.outputURL, segment: segment) else { return }
        let artifact = Artifact(sha256: try Self.digest(segment.outputURL),
            bytes: UInt64(try segment.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        let retainedBytes = manifest.completed.filter { $0.key != String(segment.index) }.values.reduce(UInt64(0)) { $0 + $1.bytes }
        guard artifact.bytes <= 20 * 1024 * 1024 * 1024, retainedBytes <= 20 * 1024 * 1024 * 1024 - artifact.bytes else { return }
        let destination = chunkURL(segment.index)
        let temporary = directory.appendingPathComponent("pending_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.copy(segment.outputURL, to: temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
        try validateSource()
        manifest.completed[String(segment.index)] = artifact
        try saveManifest()
        Self.prune(root: directory.deletingLastPathComponent(), excluding: directory)
    }

    private func valid(_ url: URL, segment: AV2CommandBuilder.AV2SegmentCommand) throws -> Bool {
        guard Self.regularFile(url), let header = IVFHeaderParser.parse(url: url), header.isAV2,
              header.width == plan.outputWidth, header.height == plan.outputHeight,
              let rate = plan.frameRate, abs(Double(header.fpsNumerator) / Double(max(1, header.fpsDenominator)) - rate) < 0.001 else { return false }
        return try IVFConcatenator.frameRecords(in: url).count == segment.frameCount
    }

    private func removeUncommittedFiles() {
        let keep = Set(manifest.completed.keys.map { "chunk_\($0).ivf" })
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in children where Self.regularFile(file) {
            let name = file.lastPathComponent
            if name.hasPrefix("pending_") || (name.hasPrefix("chunk_") && !keep.contains(name)) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func chunkURL(_ index: Int) -> URL { directory.appendingPathComponent("chunk_\(index).ivf") }
    private func saveManifest() throws {
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// Called only after the final IVF/MKV export has succeeded. Mux failures retain work.
    static func discard(_ directory: URL) {
        guard cacheName(directory), secureDirectory(directory), let fd = acquireLock(directory) else { return }
        defer { Darwin.close(fd) }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = Darwin.open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        completed = true
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.count == 64 && name.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    private static func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private static func secureDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }
    private static func privateDirectory(_ url: URL, createParents: Bool = false) throws {
        if createParents { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        if Darwin.mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EACCES) }
        guard secureDirectory(url) else { throw POSIXError(.EACCES) }
    }
    private static func acquireLock(_ directory: URL) -> Int32? {
        guard secureDirectory(directory) else { return nil }
        let fd = Darwin.open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// Retain failed work for seven days, up to 20 GiB. Oldest idle jobs go first.
    /// Enumerating file sizes does not read payloads, and leased jobs are never evicted.
    static func prune(root: URL, excluding: URL? = nil, now: Date = Date(), maximumBytes: UInt64 = 20 * 1024 * 1024 * 1024) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var jobs: [(url: URL, date: Date, bytes: UInt64)] = []
        for url in entries where cacheName(url) && secureDirectory(url) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = children.filter(regularFile).reduce(UInt64(0)) {
                $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            jobs.append((url, date, bytes))
        }
        var total = jobs.reduce(UInt64(0)) { $0 + $1.bytes }
        for job in jobs.sorted(by: { $0.date < $1.date }) where job.url != excluding {
            guard now.timeIntervalSince(job.date) > 7 * 24 * 3600 || total > maximumBytes,
                  let fd = acquireLock(job.url) else { continue }
            defer { Darwin.close(fd) }
            if (try? FileManager.default.removeItem(at: job.url)) != nil { total = total >= job.bytes ? total - job.bytes : 0 }
        }
    }
}
