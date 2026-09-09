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
    private let rcloneService: any RcloneUploading
    private let configurationProvider: @MainActor () -> UploadConfig?
    private let rcloneAvailability: @MainActor () -> Bool
    @ObservationIgnored private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var uploadAttempts: [UUID: UploadAttempt] = [:]
    @ObservationIgnored private var outputUploadTasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    /// Reference to video items for updating status
    var videoItems: Binding<[VideoItem]>?

    /// Cached upload configuration status — call `refreshConfiguredStatus()` when settings change.
    private(set) var isConfigured: Bool = false

    /// Whether rclone is installed
    private(set) var isRcloneInstalled: Bool = false

    init(
        rcloneService: any RcloneUploading = RcloneService(),
        configurationProvider: @escaping @MainActor () -> UploadConfig? = UploadManager.selectedUploadConfig,
        rcloneAvailability: @escaping @MainActor () -> Bool = {
            RcloneUpdateService.shared.getInstallationStatus().isAvailable
        }
    ) {
        self.rcloneService = rcloneService
        self.configurationProvider = configurationProvider
        self.rcloneAvailability = rcloneAvailability
        refreshConfiguredStatus()
    }

    deinit {
        for task in uploadTasks.values {
            task.cancel()
        }
    }

    /// Recomputes `isConfigured` and `isRcloneInstalled` from current settings.
    func refreshConfiguredStatus() {
        isRcloneInstalled = rcloneAvailability()
        guard let config = loadUploadConfig() else {
            isConfigured = false
            return
        }
        isConfigured = config.isConfigured && isRcloneInstalled
    }

    // MARK: - Public Methods

    /// Queues an upload for a completed conversion.
    func queueUpload(itemID: UUID) {
        startUpload(itemID: itemID)
    }

    /// Replaces the current attempt synchronously, then waits for its subprocess to
    /// drain before uploading again to the same destination.
    @discardableResult
    func startUpload(itemID: UUID) -> Task<Void, Never>? {
        let previousTask = uploadTasks[itemID]
        previousTask?.cancel()

        guard let index = findItemIndex(itemID), let item = videoItems?.wrappedValue[index] else {
            logger.warning("Cannot start upload: item \(itemID) not found")
            return nil
        }

        videoItems?.wrappedValue[index].uploadOperationID = nil
        videoItems?.wrappedValue[index].uploadProgress = 0
        videoItems?.wrappedValue[index].uploadSpeed = nil
        videoItems?.wrappedValue[index].uploadedRemotePath = nil

        guard let config = loadUploadConfig(), config.isConfigured else {
            videoItems?.wrappedValue[index].uploadStatus = .failed("Upload not configured")
            return nil
        }
        guard let fileURL = item.fileToUpload else {
            videoItems?.wrappedValue[index].uploadStatus = .failed(item.uploadSourceFile ? "No source file" : "No output file")
            return nil
        }

        guard item.uploadSourceFile || item.status == .done else {
            videoItems?.wrappedValue[index].uploadStatus = .failed("Output is not ready for upload")
            return nil
        }

        let attempt = UploadAttempt(item: item, fileURL: fileURL)
        videoItems?.wrappedValue[index].uploadOperationID = attempt.id
        videoItems?.wrappedValue[index].uploadStatus = .pending
        uploadAttempts[itemID] = attempt

        // Keep only weak UI ownership across service awaits. The task still owns its
        // service and predecessor until cancellation has finished draining them.
        let task = Task { [weak self, rcloneService] in
            defer { self?.finish(attempt) }
            await previousTask?.value
            guard !Task.isCancelled, self?.begin(attempt) == true else { return }

            do {
                let result = try await rcloneService.upload(localFile: fileURL, config: config) { [weak self] progress, speed in
                    Task { @MainActor [weak self] in
                        self?.apply(attempt) { item in
                            item.uploadProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
                            item.uploadSpeed = speed
                        }
                    }
                }
                try Task.checkCancellation()
                self?.apply(attempt) { item in
                    item.uploadStatus = result.success ? .uploaded : .failed(result.errorMessage ?? "Unknown error")
                    item.uploadedRemotePath = result.success ? result.remotePath : nil
                    item.uploadSpeed = nil
                    item.uploadOperationID = nil
                    if result.success { item.uploadProgress = 1 }
                }
            } catch {
                self?.apply(attempt) { item in
                    item.uploadStatus = error is CancellationError || Task.isCancelled
                        ? .cancelled : .failed(error.localizedDescription)
                    item.uploadSpeed = nil
                    item.uploadOperationID = nil
                }
            }
        }
        uploadTasks[itemID] = task
        if !attempt.isSourceUpload {
            outputUploadTasks[itemID] = (attempt.id, task)
        }
        return task
    }

    /// Invalidates UI callbacks immediately and waits for the cancelled process to exit.
    func cancelUpload(itemID: UUID) async {
        let task = uploadTasks[itemID]
        task?.cancel()
        if let index = findItemIndex(itemID) {
            videoItems?.wrappedValue[index].uploadOperationID = nil
            videoItems?.wrappedValue[index].uploadStatus = .cancelled
            videoItems?.wrappedValue[index].uploadProgress = 0
            videoItems?.wrappedValue[index].uploadSpeed = nil
            videoItems?.wrappedValue[index].uploadedRemotePath = nil
        }
        await task?.value
    }

    /// Re-encoding must not replace a local output while an old upload still reads it.
    func cancelUploadBeforeConversion(itemID: UUID) async {
        guard let outputUpload = outputUploadTasks[itemID] else { return }
        if uploadAttempts[itemID]?.id == outputUpload.id {
            await cancelUpload(itemID: itemID)
        } else {
            // A source upload may already be waiting for this old output attempt.
            // Drain the output reader without cancelling the source replacement.
            outputUpload.task.cancel()
            await outputUpload.task.value
        }
    }

    func retryUpload(itemID: UUID) async {
        startUpload(itemID: itemID)
    }

    /// Cancels a snapshot so a later retry cannot be cancelled by this drain.
    func cancelAllUploads() async {
        let tasks = uploadTasks
        for (itemID, task) in tasks {
            task.cancel()
            if let index = findItemIndex(itemID) {
                videoItems?.wrappedValue[index].uploadOperationID = nil
                videoItems?.wrappedValue[index].uploadStatus = .cancelled
                videoItems?.wrappedValue[index].uploadProgress = 0
                videoItems?.wrappedValue[index].uploadSpeed = nil
                videoItems?.wrappedValue[index].uploadedRemotePath = nil
            }
        }
        for task in tasks.values {
            await task.value
        }
    }

    private func begin(_ attempt: UploadAttempt) -> Bool {
        apply(attempt) { $0.uploadStatus = .uploading }
    }

    @discardableResult
    private func apply(_ attempt: UploadAttempt, update: (inout VideoItem) -> Void) -> Bool {
        guard uploadAttempts[attempt.itemID]?.id == attempt.id,
              let task = uploadTasks[attempt.itemID], !task.isCancelled,
              let binding = videoItems,
              let index = attempt.index(in: binding.wrappedValue) else { return false }
        update(&binding.wrappedValue[index])
        return true
    }

    private func finish(_ attempt: UploadAttempt) {
        if outputUploadTasks[attempt.itemID]?.id == attempt.id {
            outputUploadTasks.removeValue(forKey: attempt.itemID)
        }
        guard uploadAttempts[attempt.itemID]?.id == attempt.id else { return }
        if let index = findItemIndex(attempt.itemID),
           videoItems?.wrappedValue[index].uploadOperationID == attempt.id {
            // A path/mode change can reject publication without scheduling an
            // explicit cancellation. End only the row still owned by this attempt.
            videoItems?.wrappedValue[index].uploadOperationID = nil
            if videoItems?.wrappedValue[index].uploadStatus.isActive == true {
                videoItems?.wrappedValue[index].uploadStatus = .cancelled
                videoItems?.wrappedValue[index].uploadProgress = 0
                videoItems?.wrappedValue[index].uploadSpeed = nil
                videoItems?.wrappedValue[index].uploadedRemotePath = nil
            }
        }
        uploadTasks.removeValue(forKey: attempt.itemID)
        uploadAttempts.removeValue(forKey: attempt.itemID)
    }

    // MARK: - Configuration

    /// Loads the current upload configuration from the selected profile.
    func loadUploadConfig() -> UploadConfig? {
        configurationProvider()
    }

    static func selectedUploadConfig() -> UploadConfig? {
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

/// Resolves the same source, output, and row operation after every asynchronous hop.
private struct UploadAttempt: Sendable {
    let id = UUID()
    let itemID: UUID
    let sourceURL: URL
    let fileURL: URL
    let isSourceUpload: Bool

    init(item: VideoItem, fileURL: URL) {
        itemID = item.id
        sourceURL = item.url
        self.fileURL = fileURL
        isSourceUpload = item.uploadSourceFile
    }

    func index(in items: [VideoItem]) -> Int? {
        items.firstIndex {
            $0.id == itemID && $0.url == sourceURL && $0.fileToUpload == fileURL
                && $0.uploadSourceFile == isSourceUpload && $0.uploadOperationID == id
                && $0.uploadStatus.isActive && (isSourceUpload || $0.status == .done)
        }
    }
}
