// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftUI

/// Manages the upload queue and coordinates uploads after conversion
@MainActor
@Observable
class UploadManager {
    static let shared = UploadManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "UploadManager")
    private let rcloneService = RcloneService()
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var uploadExecutionIDs: [UUID: UUID] = [:]

    /// Reference to video items for updating status
    var videoItems: Binding<[VideoItem]>?

    /// Cached upload configuration status — call `refreshConfiguredStatus()` when settings change.
    private(set) var isConfigured: Bool = false

    /// Whether rclone is installed
    private(set) var isRcloneInstalled: Bool = false

    private init() {
        refreshConfiguredStatus()
    }

    /// Recomputes `isConfigured` and `isRcloneInstalled` from current settings.
    func refreshConfiguredStatus() {
        isRcloneInstalled = RcloneUpdateService.shared.getInstallationStatus().isAvailable
        guard let config = loadUploadConfig() else {
            isConfigured = false
            return
        }
        isConfigured = config.isConfigured && isRcloneInstalled
    }

    // MARK: - Public Methods

    /// Queues an upload for a completed conversion
    func queueUpload(itemID: UUID) {
        guard let index = findItemIndex(itemID) else {
            logger.warning("Cannot queue upload: item \(itemID) not found")
            return
        }

        videoItems?.wrappedValue[index].uploadStatus = .pending
        logger.info("Queued upload for item: \(itemID)")

        // Installs the tracked task synchronously so an immediate cancel cannot race
        // an untracked wrapper task that has not started yet.
        startUpload(itemID: itemID)
    }

    /// Starts upload for an item
    func startUpload(itemID: UUID) {
        logger.info("Starting upload for item: \(itemID)")
        let hasBinding = self.videoItems != nil
        logger.info("videoItems binding set: \(hasBinding)")

        guard let index = findItemIndex(itemID) else {
            logger.warning("Cannot start upload: item \(itemID) not found")
            let itemCount = self.videoItems?.wrappedValue.count ?? -1
            logger.warning("Total items in binding: \(itemCount)")
            return
        }

        let itemName = self.videoItems?.wrappedValue[index].name ?? "unknown"
        logger.info("Found item at index \(index): \(itemName)")

        guard let config = loadUploadConfig() else {
            logger.warning("Cannot start upload: no configuration")
            videoItems?.wrappedValue[index].uploadStatus = .failed("Upload not configured")
            return
        }

        logger.info("Upload config loaded: server=\(config.server), path=\(config.remotePath)")

        let item = videoItems?.wrappedValue[index]
        let isSourceUpload = item?.uploadSourceFile ?? false
        guard let fileURL = item?.fileToUpload else {
            let errorMsg = isSourceUpload ? "No source file" : "No output file"
            logger.warning("Cannot start upload: \(errorMsg)")
            videoItems?.wrappedValue[index].uploadStatus = .failed(errorMsg)
            return
        }

        logger.info("\(isSourceUpload ? "Source" : "Output") file: \(fileURL.path)")

        // Cancel any existing upload task for this item
        uploadTasks[itemID]?.cancel()
        let executionID = UUID()

        // Create new upload task
        let task = Task { [weak self] in
            guard let self = self else { return }

            await MainActor.run {
                if self.uploadExecutionIDs[itemID] == executionID,
                   let idx = self.findItemIndex(itemID) {
                    self.videoItems?.wrappedValue[idx].uploadStatus = .uploading
                    self.videoItems?.wrappedValue[idx].uploadProgress = 0.0
                }
            }

            do {
                let result = try await self.rcloneService.upload(
                    localFile: fileURL,
                    config: config
                ) { [weak self] progress, speed in
                    self?.logger.debug("[UploadManager] Progress callback: \(Int(progress * 100), privacy: .public)%, speed: \(speed ?? "nil", privacy: .public)")
                    Task { @MainActor in
                        guard let self = self,
                              self.uploadExecutionIDs[itemID] == executionID,
                              let binding = self.videoItems,
                              let idx = binding.wrappedValue.firstIndex(where: { $0.id == itemID }),
                              idx < binding.wrappedValue.count
                        else {
                            // Item was removed (e.g. its group was deleted) between the rclone
                            // callback firing and this MainActor hop. Drop the update — the upload
                            // task will be cancelled separately by the removal handler.
                            return
                        }
                        binding.wrappedValue[idx].uploadProgress = progress
                        binding.wrappedValue[idx].uploadSpeed = speed
                    }
                }

                await MainActor.run {
                    if self.uploadExecutionIDs[itemID] == executionID,
                       let idx = self.findItemIndex(itemID) {
                        if result.success {
                            self.videoItems?.wrappedValue[idx].uploadStatus = .uploaded
                            self.videoItems?.wrappedValue[idx].uploadedRemotePath = result.remotePath
                            self.videoItems?.wrappedValue[idx].uploadProgress = 1.0
                            self.logger.info("Upload complete for \(itemID)")
                        } else {
                            self.videoItems?.wrappedValue[idx].uploadStatus = .failed(result.errorMessage ?? "Unknown error")
                            self.logger.error("Upload failed for \(itemID): \(result.errorMessage ?? "Unknown")")
                        }
                    }
                }
            } catch is CancellationError {
                self.logger.info("Upload task cancelled for \(itemID)")
            } catch {
                await MainActor.run {
                    if self.uploadExecutionIDs[itemID] == executionID,
                       let idx = self.findItemIndex(itemID) {
                        self.videoItems?.wrappedValue[idx].uploadStatus = .failed(error.localizedDescription)
                        self.logger.error("Upload error for \(itemID): \(error.localizedDescription)")
                    }
                }
            }

            _ = await MainActor.run {
                if self.uploadExecutionIDs[itemID] == executionID {
                    self.uploadTasks.removeValue(forKey: itemID)
                    self.uploadExecutionIDs.removeValue(forKey: itemID)
                }
            }
        }

        uploadExecutionIDs[itemID] = executionID
        uploadTasks[itemID] = task
    }

    /// Cancels an upload in progress
    func cancelUpload(itemID: UUID) async {
        uploadTasks[itemID]?.cancel()
        uploadTasks.removeValue(forKey: itemID)
        uploadExecutionIDs.removeValue(forKey: itemID)

        if let index = findItemIndex(itemID) {
            videoItems?.wrappedValue[index].uploadStatus = .cancelled
            videoItems?.wrappedValue[index].uploadProgress = 0.0
            videoItems?.wrappedValue[index].uploadSpeed = nil
        }

        logger.info("Cancelled upload for item: \(itemID)")
    }

    /// Retries a failed upload
    func retryUpload(itemID: UUID) async {
        guard let index = findItemIndex(itemID) else { return }

        // Reset status
        videoItems?.wrappedValue[index].uploadStatus = .pending
        videoItems?.wrappedValue[index].uploadProgress = 0.0
        videoItems?.wrappedValue[index].uploadSpeed = nil

        startUpload(itemID: itemID)
    }

    /// Cancels all uploads
    func cancelAllUploads() async {
        for (itemID, task) in uploadTasks {
            task.cancel()
            if let index = findItemIndex(itemID) {
                videoItems?.wrappedValue[index].uploadStatus = .cancelled
            }
        }
        uploadTasks.removeAll()
        uploadExecutionIDs.removeAll()
    }

    // MARK: - Configuration

    /// Loads the current upload configuration from the selected profile.
    func loadUploadConfig() -> UploadConfig? {
        let profiles = UploadProfileStore.loadProfiles()
        guard let profile = UploadProfileStore.resolveSelectedProfile(from: profiles) else {
            return nil
        }

        let resolvedPort = profile.port > 0 ? profile.port : profile.backend.defaultPort
        var config = UploadConfig(
            server: profile.server,
            port: resolvedPort,
            username: profile.username,
            remotePath: profile.remotePath,
            useFTPS: profile.useFTPS,
            backendType: profile.backend
        )

        switch profile.backend {
        case .ftp:
            break
        case .sftp:
            config.sftpKeyFilePath = profile.useKeyAuth ? profile.keyFilePath : nil
        case .smb:
            config.smbShare = profile.smbShare
            config.smbDomain = profile.smbDomain
        case .s3:
            config.s3Bucket = profile.bucket
            config.s3Region = profile.region
            config.s3Endpoint = profile.endpoint
            config.s3AccessKeyID = profile.accessKeyID
        case .gdrive:
            break
        }

        return config.isConfigured ? config : nil
    }

    /// Tests the current upload configuration
    func testConnection() async throws -> Bool {
        guard let config = loadUploadConfig() else {
            throw UploadError.configurationMissing
        }

        return try await rcloneService.testConnection(config: config)
    }

    // MARK: - Private Methods

    private func findItemIndex(_ id: UUID) -> Int? {
        videoItems?.wrappedValue.firstIndex(where: { $0.id == id })
    }
}
