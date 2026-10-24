// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// File-system layout for versioned, app-managed tools:
///
///     <root>/versions/<tool>/<version>/<executable>
///     <root>/versions/<tool>/.staging-<uuid>/<executable>   (not yet published)
///     <root>/<executable> -> versions/<tool>/<version>/<executable>   (yt-dlp, deno)
///
/// New versions are staged and verified in a hidden directory, then published
/// with a directory rename. The stable link is replaced with `rename(2)`, so a
/// process that already started keeps running from its own version directory.
struct ManagedToolStore: Sendable {
    let root: URL

    init(root: URL = AppConstants.ytdlpToolsDirectory) {
        self.root = root
    }

    private var fileManager: FileManager { FileManager.default }

    func versionsDirectory(for tool: ManagedTool) -> URL {
        root.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(tool.rawValue, isDirectory: true)
    }

    func versionDirectory(for tool: ManagedTool, version: String) -> URL {
        versionsDirectory(for: tool).appendingPathComponent(version, isDirectory: true)
    }

    func executableURL(for tool: ManagedTool, version: String) -> URL {
        versionDirectory(for: tool, version: version).appendingPathComponent(tool.executableName)
    }

    /// `tools/<executable>`; the path yt-dlp/deno resolution has always used.
    func stableLinkURL(for tool: ManagedTool) -> URL {
        root.appendingPathComponent(tool.executableName)
    }

    /// Published versions that contain their executable.
    func installedVersions(for tool: ManagedTool) -> [String] {
        let directory = versionsDirectory(for: tool)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { name in
            !name.hasPrefix(".")
                && fileManager.isExecutableFile(atPath: executableURL(for: tool, version: name).path)
        }
    }

    /// Version the stable link currently points at, if it is a managed link.
    func linkedVersion(for tool: ManagedTool) -> String? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: stableLinkURL(for: tool).path) else {
            return nil
        }
        let components = destination.split(separator: "/").map(String.init)
        guard components.count == 4, components[0] == "versions", components[1] == tool.rawValue,
              components[3] == tool.executableName else { return nil }
        return components[2]
    }

    /// True when `tools/<executable>` is a plain file from before versioning.
    func hasLegacyInstall(for tool: ManagedTool) -> Bool {
        let path = stableLinkURL(for: tool).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    /// Moves a legacy install into the versioned layout (no download). The
    /// legacy path is replaced atomically by a link, so it never disappears.
    func migrateLegacyInstall(for tool: ManagedTool, plan: ManagedToolLegacyMigration) throws {
        let legacy = stableLinkURL(for: tool)
        switch plan {
        case .adopt(let version):
            let directory = versionDirectory(for: tool, version: version)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = executableURL(for: tool, version: version)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.linkItem(at: legacy, to: destination)
                } catch {
                    try fileManager.copyItem(at: legacy, to: destination)
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            try pointStableLink(for: tool, to: version)
        case .linkExisting(let version):
            try pointStableLink(for: tool, to: version)
        }
    }

    /// Creates an empty hidden staging directory for a new version.
    func makeStagingDirectory(for tool: ManagedTool) throws -> URL {
        let directory = versionsDirectory(for: tool)
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Moves a verified download into a staging directory, clears quarantine
    /// and makes it executable. Returns the staged executable.
    func stageExecutable(for tool: ManagedTool, from source: URL, in staging: URL) throws -> URL {
        let destination = staging.appendingPathComponent(tool.executableName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        try prepareExecutable(at: destination)
        return destination
    }

    func prepareExecutable(at url: URL) throws {
        clearQuarantine(under: url.deletingLastPathComponent())
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Moves an extracted multi-file build (e.g. yt-dlp's onedir build:
    /// `yt-dlp_macos` + `_internal/`) into a staging directory, renaming its
    /// executable to the tool's executable name. Returns the staged executable.
    func stageDirectoryContents(
        for tool: ManagedTool,
        from extracted: URL,
        executableName: String,
        in staging: URL
    ) throws -> URL {
        guard fileManager.fileExists(atPath: extracted.appendingPathComponent(executableName).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for name in try fileManager.contentsOfDirectory(atPath: extracted.path) where name != "__MACOSX" {
            let target = name == executableName ? tool.executableName : name
            try fileManager.moveItem(
                at: extracted.appendingPathComponent(name),
                to: staging.appendingPathComponent(target)
            )
        }
        let executable = staging.appendingPathComponent(tool.executableName)
        try prepareExecutable(at: executable)
        return executable
    }

    /// Whether `version` is a multi-file (onedir) build with `_internal/`.
    func hasSupportDirectory(for tool: ManagedTool, version: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = versionDirectory(for: tool, version: version).appendingPathComponent("_internal").path
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Removes `com.apple.quarantine` from a directory tree.
    func clearQuarantine(under directory: URL) {
        _ = removexattr(directory.path, "com.apple.quarantine", 0)
        guard let enumerator = fileManager.enumerator(atPath: directory.path) else { return }
        for case let relative as String in enumerator {
            _ = removexattr(directory.appendingPathComponent(relative).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Publishes a staged directory as `version`. Reinstalling an existing
    /// version swaps the directories so the path is never missing.
    func publish(staging: URL, for tool: ManagedTool, version: String) throws {
        let destination = versionDirectory(for: tool, version: version)
        if fileManager.fileExists(atPath: destination.path) {
            let replaced = versionsDirectory(for: tool)
                .appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
            try rename(destination, to: replaced)
            do {
                try rename(staging, to: destination)
            } catch {
                try? rename(replaced, to: destination)
                throw error
            }
            try? fileManager.removeItem(at: replaced)
        } else {
            try rename(staging, to: destination)
        }
    }

    /// Atomically points `tools/<executable>` at `version`.
    func pointStableLink(for tool: ManagedTool, to version: String) throws {
        let link = stableLinkURL(for: tool)
        let temporary = root.appendingPathComponent(".\(tool.executableName)-link-\(UUID().uuidString)")
        let target = "versions/\(tool.rawValue)/\(version)/\(tool.executableName)"
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        do {
            try rename(temporary, to: link)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the stable link (e.g. when every managed version is gone).
    func removeStableLinkIfManaged(for tool: ManagedTool) {
        guard linkedVersion(for: tool) != nil else { return }
        try? fileManager.removeItem(at: stableLinkURL(for: tool))
    }

    func remove(_ version: String, for tool: ManagedTool) throws {
        try fileManager.removeItem(at: versionDirectory(for: tool, version: version))
    }

    /// Drops staging/replaced leftovers from interrupted installs.
    func removeLeftovers(for tool: ManagedTool) {
        let directory = versionsDirectory(for: tool)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".staging-") || name.hasPrefix(".replaced-") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        if let rootNames = try? fileManager.contentsOfDirectory(atPath: root.path) {
            for name in rootNames where name.hasPrefix(".\(tool.executableName)-link-") {
                try? fileManager.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    private func rename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
