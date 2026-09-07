// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol WhisperModelDownloadOperation: Sendable {
    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func cancel()
}

typealias WhisperModelDownloadOperationFactory = @Sendable (
    _ sourceURL: URL,
    _ expectedByteCount: Int64
) -> any WhisperModelDownloadOperation

/// Manages whisper.cpp model downloads and storage
actor WhisperModelManager {
    static let shared = WhisperModelManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WhisperModelManager")
    private nonisolated let modelsDirectory: URL
    private let operationFactory: WhisperModelDownloadOperationFactory
    private var activeDownloads: [WhisperModel: ActiveDownload] = [:]

    private struct ActiveDownload: Sendable {
        let id: UUID
        let operation: any WhisperModelDownloadOperation
        let progress: @Sendable (Double) -> Void
    }

    init(
        modelsDirectory: URL = AppConstants.whisperModelsDirectory,
        operationFactory: @escaping WhisperModelDownloadOperationFactory = { sourceURL, expectedByteCount in
            URLSessionWhisperModelDownloadOperation(
                sourceURL: sourceURL,
                expectedByteCount: expectedByteCount
            )
        }
    ) {
        self.modelsDirectory = modelsDirectory
        self.operationFactory = operationFactory
    }

    /// Returns the file URL for a given model
    nonisolated func modelPath(for model: WhisperModel) -> URL {
        if model.isCustom, let customURL = customModelURL() {
            return customURL
        }
        return modelsDirectory.appendingPathComponent(model.fileName)
    }

    nonisolated func customModelURL() -> URL? {
        let rawPath = UserDefaults.standard.string(forKey: AppConstants.whisperCustomModelPathKey) ?? ""
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    /// Checks if a model is downloaded
    nonisolated func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let path = modelPath(for: model)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Gets the status of a model
    func getModelStatus(_ model: WhisperModel) -> WhisperModelStatus {
        if isModelDownloaded(model) {
            return .downloaded
        }
        if activeDownloads[model] != nil {
            return .downloading(progress: 0)
        }
        return .notDownloaded
    }

    /// Gets all downloaded models
    nonisolated func getDownloadedModels() -> [WhisperModel] {
        WhisperModel.downloadableCases.filter { isModelDownloaded($0) }
    }

    /// Gets the currently selected model from settings
    nonisolated func getSelectedModel() -> WhisperModel {
        let rawValue = UserDefaults.standard.string(forKey: AppConstants.whisperModelKey) ?? AppConstants.defaultWhisperModel
        return WhisperModel(rawValue: rawValue) ?? .base
    }

    /// Sets the selected model in settings
    func setSelectedModel(_ model: WhisperModel) {
        UserDefaults.standard.set(model.rawValue, forKey: AppConstants.whisperModelKey)
        logger.info("Selected model changed to: \(model.displayName)")
    }

    /// Gets the total size of all downloaded models
    func getTotalModelsSize() -> Int64 {
        var totalSize: Int64 = 0
        let fm = FileManager.default

        for model in WhisperModel.downloadableCases {
            let path = modelPath(for: model)
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }

        return totalSize
    }

    /// Downloads a model with progress tracking
    func downloadModel(
        _ model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard model.isDownloadable, let downloadURL = model.downloadURL else {
            throw WhisperModelError.modelNotFound
        }
        // Check if already downloading
        if activeDownloads[model] != nil {
            logger.warning("Model \(model.rawValue) is already being downloaded")
            return
        }

        // Check if already downloaded
        if isModelDownloaded(model) {
            logger.info("Model \(model.rawValue) is already downloaded")
            progress(1.0)
            return
        }

        logger.info("Starting download of model: \(model.displayName) (\(model.fileSize))")
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        let downloadID = UUID()
        let operation = operationFactory(downloadURL, model.fileSizeBytes)
        activeDownloads[model] = ActiveDownload(
            id: downloadID,
            operation: operation,
            progress: progress
        )

        var temporaryURL: URL?
        defer {
            if activeDownloads[model]?.id == downloadID {
                activeDownloads.removeValue(forKey: model)
            }
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        temporaryURL = try await withTaskCancellationHandler {
            try await operation.run { [weak self] value in
                Task {
                    await self?.publishProgress(value, for: model, downloadID: downloadID)
                }
            }
        } onCancel: {
            operation.cancel()
            Task { await self.invalidateDownload(for: model, matching: downloadID) }
        }

        try Task.checkCancellation()
        guard activeDownloads[model]?.id == downloadID else {
            throw CancellationError()
        }

        guard let downloadedURL = temporaryURL else {
            throw WhisperModelError.downloadFailed
        }
        let destinationURL = modelPath(for: model)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            logger.info("Model \(model.rawValue) was installed while its download was running")
            progress(1.0)
            return
        }
        try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
        temporaryURL = nil

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WhisperModelError.installFailed
        }

        progress(1.0)
        logger.info("Successfully downloaded model: \(model.displayName)")
    }

    private func publishProgress(_ progress: Double, for model: WhisperModel, downloadID: UUID) {
        guard let activeDownload = activeDownloads[model], activeDownload.id == downloadID else {
            return
        }
        activeDownload.progress(min(max(progress, 0), 1))
    }

    /// Cancels an ongoing model download
    func cancelDownload(for model: WhisperModel) {
        guard let activeDownload = activeDownloads.removeValue(forKey: model) else { return }
        activeDownload.operation.cancel()
        logger.info("Cancelled download of model: \(model.displayName)")
    }

    private func invalidateDownload(for model: WhisperModel, matching downloadID: UUID) {
        guard activeDownloads[model]?.id == downloadID else { return }
        activeDownloads.removeValue(forKey: model)
    }

    /// Deletes a downloaded model
    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else {
            logger.warning("Tried to delete model that doesn't exist: \(model.displayName)")
            return
        }

        try fm.removeItem(at: path)
        logger.info("Deleted model: \(model.displayName)")

        // If this was the selected model, switch to a different downloaded model or base
        let selected = getSelectedModel()
        if selected == model {
            let downloaded = getDownloadedModels()
            if let firstAvailable = downloaded.first {
                setSelectedModel(firstAvailable)
            } else {
                setSelectedModel(.base)
            }
        }
    }

    /// Deletes all downloaded models
    func deleteAllModels() throws {
        for model in getDownloadedModels() {
            try deleteModel(model)
        }
        logger.info("Deleted all models")
    }

    /// Ensures the selected model is downloaded, or falls back to a downloaded model
    func ensureModelAvailable() async throws -> WhisperModel {
        let selected = getSelectedModel()

        if isModelDownloaded(selected) {
            return selected
        }

        if selected.isCustom {
            logger.info("Custom model not available, falling back to a downloaded model")
        }

        // Check if any model is downloaded
        let downloaded = getDownloadedModels()
        if let available = downloaded.first {
            logger.info("Selected model \(selected.displayName) not available, using \(available.displayName)")
            return available
        }

        // No models downloaded - download the base model
        logger.info("No models available, downloading base model")
        try await downloadModel(.base) { _ in }
        return .base
    }
}

// MARK: - URLSession Download Operation

final class URLSessionWhisperModelDownloadOperation: NSObject,
    WhisperModelDownloadOperation, URLSessionDownloadDelegate, @unchecked Sendable
{
    static let resourceTimeout: TimeInterval = 12 * 60 * 60

    private let sourceURL: URL
    private let expectedByteCount: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var resolvedResult: Result<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var temporaryURL: URL?
    private var progressHandler: (@Sendable (Double) -> Void)?

    init(sourceURL: URL, expectedByteCount: Int64) {
        self.sourceURL = sourceURL
        self.expectedByteCount = expectedByteCount
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let session = URLSession(
            configuration: Self.makeConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: sourceURL)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = lock.withLock { () -> (Result<URL, Error>?, Bool) in
                    if let resolvedResult {
                        return (resolvedResult, false)
                    }
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    progressHandler = progress
                    return (nil, true)
                }

                if let result = state.0 {
                    session.invalidateAndCancel()
                    continuation.resume(with: result)
                } else if state.1 {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()), cancelSession: true)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : expectedByteCount
        guard expectedBytes > 0 else { return }
        let handler = lock.withLock { resolvedResult == nil ? progressHandler : nil }
        handler?(min(Double(totalBytesWritten) / Double(expectedBytes), 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let persistentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".bin")
            try FileManager.default.moveItem(at: location, to: persistentURL)
            let accepted = lock.withLock { () -> Bool in
                guard resolvedResult == nil else { return false }
                temporaryURL = persistentURL
                return true
            }
            if !accepted {
                try? FileManager.default.removeItem(at: persistentURL)
            }
        } catch {
            resolve(.failure(error), cancelSession: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                resolve(.failure(CancellationError()), cancelSession: false)
            } else {
                resolve(.failure(error), cancelSession: false)
            }
            return
        }

        let downloadedURL = lock.withLock { temporaryURL }
        if let downloadedURL {
            resolve(.success(downloadedURL), cancelSession: false)
        } else {
            resolve(.failure(URLError(.badServerResponse)), cancelSession: false)
        }
    }

    private func resolve(_ result: Result<URL, Error>, cancelSession: Bool) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<URL, Error>?,
            URLSession?,
            URLSessionDownloadTask?,
            URL?
        )? in
            guard resolvedResult == nil else { return nil }
            resolvedResult = result
            let shouldDeleteTemporaryURL: URL?
            switch result {
            case .success:
                shouldDeleteTemporaryURL = nil
            case .failure:
                shouldDeleteTemporaryURL = temporaryURL
            }
            let pending = (continuation, session, task, shouldDeleteTemporaryURL)
            continuation = nil
            session = nil
            task = nil
            temporaryURL = nil
            progressHandler = nil
            return pending
        }

        guard let pending else { return }
        if cancelSession {
            pending.2?.cancel()
            pending.1?.invalidateAndCancel()
        } else {
            pending.1?.finishTasksAndInvalidate()
        }
        if let temporaryURL = pending.3 {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        pending.0?.resume(with: result)
    }
}

// MARK: - Error Types

enum WhisperModelError: Error, LocalizedError {
    case downloadFailed
    case installFailed
    case modelNotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download model"
        case .installFailed: return "Failed to install model"
        case .modelNotFound: return "Model file not found"
        case .cancelled: return "Download was cancelled"
        }
    }
}
