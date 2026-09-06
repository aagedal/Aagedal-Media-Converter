// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Upload Configuration

/// Configuration for uploading files to a remote server
struct UploadConfig: Codable, Sendable, Equatable {
    var server: String
    var port: Int
    var username: String
    var remotePath: String
    var useFTPS: Bool
    var backendType: UploadBackendType

    // SFTP-specific
    var sftpKeyFilePath: String?

    // SMB-specific
    var smbShare: String?
    var smbDomain: String?

    // S3-specific
    var s3Bucket: String?
    var s3Region: String?
    var s3Endpoint: String?
    var s3AccessKeyID: String?

    init(
        server: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useFTPS: Bool = false,
        backendType: UploadBackendType = .ftp,
        sftpKeyFilePath: String? = nil,
        smbShare: String? = nil,
        smbDomain: String? = nil,
        s3Bucket: String? = nil,
        s3Region: String? = nil,
        s3Endpoint: String? = nil,
        s3AccessKeyID: String? = nil
    ) {
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useFTPS = useFTPS
        self.backendType = backendType
        self.sftpKeyFilePath = sftpKeyFilePath
        self.smbShare = smbShare
        self.smbDomain = smbDomain
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.s3Endpoint = s3Endpoint
        self.s3AccessKeyID = s3AccessKeyID
    }

    /// Whether the configuration has minimum required fields filled
    var isConfigured: Bool {
        switch backendType {
        case .ftp, .sftp:
            return !server.isEmpty && !username.isEmpty
        case .smb:
            return !server.isEmpty && !username.isEmpty && !(smbShare ?? "").isEmpty
        case .s3:
            return !(s3Bucket ?? "").isEmpty && !(s3AccessKeyID ?? "").isEmpty
        case .gdrive:
            return false // Not yet implemented
        }
    }

    /// Builds the rclone remote path string
    /// e.g., ":ftp:/uploads/videos" or ":s3:bucket/folder"
    var rcloneRemotePath: String {
        let backend = backendType.rcloneBackendName
        switch backendType {
        case .ftp, .sftp:
            let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
            return ":\(backend):\(path)"
        case .smb:
            // SMB format: :smb:share/path
            let share = smbShare ?? ""
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            if path.isEmpty {
                return ":\(backend):\(share)"
            }
            return ":\(backend):\(share)/\(path)"
        case .s3:
            // S3 format: :s3:bucket/path
            let bucket = s3Bucket ?? ""
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            if path.isEmpty {
                return ":\(backend):\(bucket)"
            }
            return ":\(backend):\(bucket)/\(path)"
        case .gdrive:
            let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
            return ":\(backend):\(path)"
        }
    }
}

// MARK: - Upload Profiles

/// A single upload destination. The `backend` property determines which of the
/// backend-specific fields are meaningful; unused fields are simply ignored.
struct UploadProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Profile"
    var backend: UploadBackendType = .ftp

    // Shared (FTP, SFTP, SMB)
    var server: String = ""
    var port: Int = AppConstants.defaultUploadPort
    var username: String = ""
    var remotePath: String = "/"

    // FTP
    var useFTPS: Bool = false

    // SFTP
    var useKeyAuth: Bool = false
    var keyFilePath: String = ""

    // SMB
    var smbShare: String = ""
    var smbDomain: String = ""

    // S3
    var bucket: String = ""
    var region: String = "us-east-1"
    var endpoint: String = ""
    var accessKeyID: String = ""

    /// Label shown in profile pickers, e.g. "My Server (FTP)".
    var displayLabel: String {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
        return "\(displayName) (\(backend.displayName))"
    }

    /// A fresh profile configured for the given backend's defaults.
    static func new(backend: UploadBackendType = .ftp) -> UploadProfile {
        UploadProfile(
            name: "New \(backend.displayName) Profile",
            backend: backend,
            port: backend.defaultPort > 0 ? backend.defaultPort : AppConstants.defaultUploadPort
        )
    }
}

enum UploadProfileStore {
    static func loadProfiles(defaults: UserDefaults = .standard) -> [UploadProfile] {
        guard let data = defaults.data(forKey: AppConstants.uploadProfilesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([UploadProfile].self, from: data)) ?? []
    }

    static func saveProfiles(_ profiles: [UploadProfile], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: AppConstants.uploadProfilesKey)
    }

    static func loadSelectedProfileID(defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: AppConstants.uploadSelectedProfileIDKey),
              let id = UUID(uuidString: raw) else {
            return nil
        }
        return id
    }

    static func saveSelectedProfileID(_ id: UUID?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id.uuidString, forKey: AppConstants.uploadSelectedProfileIDKey)
        } else {
            defaults.removeObject(forKey: AppConstants.uploadSelectedProfileIDKey)
        }
    }

    static func resolveSelectedProfile(from profiles: [UploadProfile], defaults: UserDefaults = .standard) -> UploadProfile? {
        guard !profiles.isEmpty else { return nil }
        if let selectedID = loadSelectedProfileID(defaults: defaults),
           let match = profiles.first(where: { $0.id == selectedID }) {
            return match
        }
        return profiles.first
    }

    /// One-shot migration from the pre-unified per-backend stores to a single list.
    /// Safe to call on every launch; guarded by `uploadProfileMigrationV2Key`.
    static func migrateLegacyProfilesIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: AppConstants.uploadProfileMigrationV2Key) else { return }

        // A modern list (including an explicitly empty one) owns the user's current
        // choices. Never resurrect old destinations or replace a newer selection.
        // Keep legacy data available for recovery when no migration is needed.
        if defaults.object(forKey: AppConstants.uploadProfilesKey) != nil {
            defaults.set(true, forKey: AppConstants.uploadProfileMigrationV2Key)
            return
        }

        // Legacy schemas — kept local so the rest of the codebase can forget about them.
        struct LegacyFTP: Codable { var id: UUID; var name: String; var server: String; var port: Int; var username: String; var remotePath: String; var useFTPS: Bool }
        struct LegacySFTP: Codable { var id: UUID; var name: String; var server: String; var port: Int; var username: String; var remotePath: String; var useKeyAuth: Bool; var keyFilePath: String }
        struct LegacySMB: Codable { var id: UUID; var name: String; var server: String; var port: Int; var username: String; var remotePath: String; var smbShare: String; var smbDomain: String }
        struct LegacyS3: Codable { var id: UUID; var name: String; var bucket: String; var region: String; var endpoint: String; var accessKeyID: String; var remotePath: String }

        func decodeLegacy<T: Decodable>(_ type: [T].Type, key: String) throws -> [T] {
            guard let value = defaults.object(forKey: key) else { return [] }
            guard let data = value as? Data else {
                throw CocoaError(.coderReadCorrupt)
            }
            return try JSONDecoder().decode(type, from: data)
        }

        var unified: [UploadProfile] = []

        do {
            for l in try decodeLegacy([LegacyFTP].self, key: "uploadFTPProfiles") {
                unified.append(UploadProfile(
                    id: l.id, name: l.name, backend: .ftp,
                    server: l.server, port: l.port, username: l.username, remotePath: l.remotePath,
                    useFTPS: l.useFTPS
                ))
            }
            for l in try decodeLegacy([LegacySFTP].self, key: "uploadSFTPProfiles") {
                unified.append(UploadProfile(
                    id: l.id, name: l.name, backend: .sftp,
                    server: l.server, port: l.port, username: l.username, remotePath: l.remotePath,
                    useKeyAuth: l.useKeyAuth, keyFilePath: l.keyFilePath
                ))
            }
            for l in try decodeLegacy([LegacySMB].self, key: "uploadSMBProfiles") {
                unified.append(UploadProfile(
                    id: l.id, name: l.name, backend: .smb,
                    server: l.server, port: l.port, username: l.username, remotePath: l.remotePath,
                    smbShare: l.smbShare, smbDomain: l.smbDomain
                ))
            }
            for l in try decodeLegacy([LegacyS3].self, key: "uploadS3Profiles") {
                unified.append(UploadProfile(
                    id: l.id, name: l.name, backend: .s3,
                    remotePath: l.remotePath,
                    bucket: l.bucket, region: l.region, endpoint: l.endpoint, accessKeyID: l.accessKeyID
                ))
            }
        } catch {
            // Leave every legacy key and the marker untouched so recovery/retry is possible.
            return
        }

        // Preserve previously selected profile by mapping through legacy backend → legacy selection key.
        let legacyBackend = defaults.string(forKey: "uploadBackendType") ?? "ftp"
        let legacySelectionKey: String = {
            switch legacyBackend {
            case "sftp": return "uploadSFTPSelectedProfileID"
            case "smb":  return "uploadSMBSelectedProfileID"
            case "s3":   return "uploadS3SelectedProfileID"
            default:     return "uploadFTPSelectedProfileID"
            }
        }()
        if let raw = defaults.string(forKey: legacySelectionKey),
           let id = UUID(uuidString: raw),
           unified.contains(where: { $0.id == id }) {
            saveSelectedProfileID(id, defaults: defaults)
        } else if let first = unified.first {
            saveSelectedProfileID(first.id, defaults: defaults)
        }

        if !unified.isEmpty {
            saveProfiles(unified, defaults: defaults)
        }

        // Clear all legacy keys (profile lists, selections, and transient editing-state fields).
        let legacyKeys = [
            "uploadFTPProfiles", "uploadFTPSelectedProfileID",
            "uploadSFTPProfiles", "uploadSFTPSelectedProfileID",
            "uploadSMBProfiles", "uploadSMBSelectedProfileID",
            "uploadS3Profiles", "uploadS3SelectedProfileID",
            "uploadBackendType",
            "uploadServer", "uploadPort", "uploadUsername", "uploadRemotePath", "uploadUseFTPS",
            "uploadSFTPKeyFile", "uploadSFTPKeyFileBookmark",
            "uploadSMBShare", "uploadSMBDomain",
            "uploadS3Bucket", "uploadS3Region", "uploadS3Endpoint", "uploadS3AccessKey"
        ]
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: AppConstants.uploadProfileMigrationV2Key)
    }
}

// MARK: - Backend Types

/// Supported upload backend types (rclone remotes)
enum UploadBackendType: String, Codable, CaseIterable, Sendable {
    case ftp = "ftp"
    case sftp = "sftp"
    case smb = "smb"
    case s3 = "s3"
    case gdrive = "drive"

    var displayName: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .smb: return "SMB"
        case .s3: return "Amazon S3"
        case .gdrive: return "Google Drive"
        }
    }

    var rcloneBackendName: String {
        return rawValue
    }

    /// Icon name for this backend
    var iconName: String {
        switch self {
        case .ftp, .sftp: return "externaldrive.connected.to.line.below"
        case .smb: return "externaldrive.fill.badge.person.crop"
        case .s3: return "cloud"
        case .gdrive: return "folder"
        }
    }

    /// Whether this backend requires a password (vs OAuth or key-based auth)
    var requiresPassword: Bool {
        switch self {
        case .ftp, .smb: return true
        case .sftp: return true  // Can also use SSH key, handled separately
        case .s3, .gdrive: return false
        }
    }

    /// Default port for this backend
    var defaultPort: Int {
        switch self {
        case .ftp: return AppConstants.defaultUploadPort  // 21
        case .sftp: return AppConstants.defaultSFTPPort   // 22
        case .smb: return AppConstants.defaultSMBPort     // 445
        case .s3, .gdrive: return 0  // Not applicable
        }
    }

    /// Whether this backend is currently implemented
    var isImplemented: Bool {
        switch self {
        case .ftp, .sftp, .smb, .s3: return true
        case .gdrive: return false
        }
    }
}

// MARK: - Upload Status

/// Status of an upload operation
enum UploadStatus: Equatable, Sendable {
    case notQueued
    case pending
    case uploading
    case uploaded
    case failed(String)
    case cancelled

    var displayText: String {
        switch self {
        case .notQueued: return ""
        case .pending: return "Waiting to upload"
        case .uploading: return "Uploading..."
        case .uploaded: return "Uploaded"
        case .failed(let error): return "Upload failed: \(error)"
        case .cancelled: return "Upload cancelled"
        }
    }

    var isActive: Bool {
        switch self {
        case .pending, .uploading: return true
        default: return false
        }
    }

    var isComplete: Bool {
        switch self {
        case .uploaded: return true
        default: return false
        }
    }

    var hasFailed: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Upload Result

/// Result of a completed upload operation
struct UploadResult: Sendable {
    let success: Bool
    let remotePath: String?
    let bytesTransferred: Int64
    let duration: TimeInterval
    let errorMessage: String?

    static func success(remotePath: String, bytes: Int64, duration: TimeInterval) -> UploadResult {
        UploadResult(
            success: true,
            remotePath: remotePath,
            bytesTransferred: bytes,
            duration: duration,
            errorMessage: nil
        )
    }

    static func failure(error: String) -> UploadResult {
        UploadResult(
            success: false,
            remotePath: nil,
            bytesTransferred: 0,
            duration: 0,
            errorMessage: error
        )
    }
}

// MARK: - Upload Progress

/// Progress information for an upload operation
struct UploadProgress: Sendable {
    let bytesTransferred: Int64
    let totalBytes: Int64
    let percentage: Double
    let speed: String?
    let eta: String?

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let transferred = formatter.string(fromByteCount: bytesTransferred)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(transferred) / \(total)"
    }
}

// MARK: - Upload Error

enum UploadError: Error, LocalizedError {
    case rcloneNotFound
    case configurationMissing
    case connectionFailed(String)
    case authenticationFailed
    case uploadFailed(String)
    case cancelled
    case passwordNotFound

    var errorDescription: String? {
        switch self {
        case .rcloneNotFound:
            return "rclone is not installed. Please download it in Settings > Upload."
        case .configurationMissing:
            return "Upload configuration is incomplete. Please configure in Settings > Upload."
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .authenticationFailed:
            return "Authentication failed. Please check your username and password."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .cancelled:
            return "Upload was cancelled"
        case .passwordNotFound:
            return "Password not found in Keychain. Please re-enter your password in Settings."
        }
    }
}
