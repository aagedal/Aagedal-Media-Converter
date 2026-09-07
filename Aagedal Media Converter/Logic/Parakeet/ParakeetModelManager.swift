// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import OSLog

protocol ParakeetModelNetworkOperation: Sendable {
    func cancel()
}

struct ParakeetModelMetadata: Decodable, Sendable {
    let sha: String
    let siblings: [File]

    struct File: Decodable, Sendable {
        let rfilename: String
        let size: Int64?
        let lfs: LFSInfo?

        struct LFSInfo: Decodable, Sendable {
            let sha256: String
        }
    }
}

protocol ParakeetModelMetadataOperation: ParakeetModelNetworkOperation {
    func run() async throws -> ParakeetModelMetadata
}

struct ParakeetFileDownloadResult: Sendable {
    let temporaryURL: URL
    let statusCode: Int?
    let expectedContentLength: Int64
    let eTag: String?
}

protocol ParakeetFileDownloadOperation: ParakeetModelNetworkOperation {
    func run(
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ totalExpected: Int64) -> Void
    ) async throws -> ParakeetFileDownloadResult
}

typealias ParakeetModelMetadataOperationFactory = @Sendable (
    _ sourceURL: URL
) -> any ParakeetModelMetadataOperation

typealias ParakeetFileDownloadOperationFactory = @Sendable (
    _ sourceURL: URL,
    _ expectedByteCount: Int64
) -> any ParakeetFileDownloadOperation

private final class ParakeetOperationCancellation: ParakeetModelNetworkOperation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }
}

/// Manages parakeet-mlx model detection and cache management via HuggingFace Hub
actor ParakeetModelManager {
    static let shared = ParakeetModelManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ParakeetModelManager")
    private nonisolated let cacheDirectory: URL
    private let isParakeetInstalled: @Sendable () -> Bool
    private let metadataOperationFactory: ParakeetModelMetadataOperationFactory
    private let fileDownloadOperationFactory: ParakeetFileDownloadOperationFactory
    private var activeDownloads: [ParakeetModel: ActiveDownload] = [:]
    private var pendingDownloadFailures: [ParakeetModel: String] = [:]

    private struct ActiveDownload: Sendable {
        let id: UUID
        var operation: (any ParakeetModelNetworkOperation)?
        var latestProgress: ModelDownloadProgress?
        let progress: @Sendable (ModelDownloadProgress) -> Void
    }

    init(
        cacheDirectory: URL = AppConstants.huggingFaceCacheDirectory,
        isParakeetInstalled: @escaping @Sendable () -> Bool = {
            BinaryPathResolver.parakeetMlxPath != nil
        },
        metadataOperationFactory: @escaping ParakeetModelMetadataOperationFactory = { sourceURL in
            URLSessionParakeetModelMetadataOperation(sourceURL: sourceURL)
        },
        fileDownloadOperationFactory: @escaping ParakeetFileDownloadOperationFactory = {
            sourceURL, expectedByteCount in
            URLSessionParakeetFileDownloadOperation(
                sourceURL: sourceURL,
                expectedByteCount: expectedByteCount
            )
        }
    ) {
        self.cacheDirectory = cacheDirectory
        self.isParakeetInstalled = isParakeetInstalled
        self.metadataOperationFactory = metadataOperationFactory
        self.fileDownloadOperationFactory = fileDownloadOperationFactory
    }

    // MARK: - Model Path Resolution

    /// Returns the HuggingFace Hub cache directory name for a model
    /// e.g. "mlx-community/parakeet-tdt-0.6b-v3" -> "models--mlx-community--parakeet-tdt-0.6b-v3"
    nonisolated func cacheDirectoryName(for model: ParakeetModel) -> String {
        "models--" + model.id.replacingOccurrences(of: "/", with: "--")
    }

    /// Returns the full cache path for a model
    nonisolated func modelCachePath(for model: ParakeetModel) -> URL {
        cacheDirectory
            .appendingPathComponent(cacheDirectoryName(for: model))
    }

    // MARK: - Model Status

    /// Checks if a model is downloaded in the HuggingFace Hub cache
    nonisolated func isModelDownloaded(_ model: ParakeetModel) -> Bool {
        let refsMain = modelCachePath(for: model)
            .appendingPathComponent("refs/main")
        return FileManager.default.fileExists(atPath: refsMain.path)
    }

    /// Gets the status of a model
    func getModelStatus(_ model: ParakeetModel) -> ParakeetModelStatus {
        if activeDownloads[model] != nil {
            return .downloading
        }
        if isModelDownloaded(model) {
            return .downloaded
        }
        return .notDownloaded
    }

    /// Returns the latest progress for a model whose download is still active.
    func getDownloadProgress(_ model: ParakeetModel) -> ModelDownloadProgress? {
        activeDownloads[model]?.latestProgress
    }

    /// Returns and clears a terminal download failure so a recreated Settings view can report it.
    func takeDownloadFailure(_ model: ParakeetModel) -> String? {
        pendingDownloadFailures.removeValue(forKey: model)
    }

    /// Gets all downloaded models
    nonisolated func getDownloadedModels() -> [ParakeetModel] {
        ParakeetModel.allModels.filter { isModelDownloaded($0) }
    }

    // MARK: - Model Selection

    /// Gets the currently selected model from settings
    nonisolated func getSelectedModel() -> ParakeetModel {
        let modelId = UserDefaults.standard.string(forKey: AppConstants.parakeetModelKey)
            ?? AppConstants.defaultParakeetModel
        return ParakeetModel.model(for: modelId)
            ?? ParakeetModel.allModels.first { $0.id == AppConstants.defaultParakeetModel }
            ?? ParakeetModel.allModels[0]
    }

    /// Sets the selected model in settings
    func setSelectedModel(_ model: ParakeetModel) {
        UserDefaults.standard.set(model.id, forKey: AppConstants.parakeetModelKey)
        logger.info("Selected Parakeet model changed to: \(model.displayName)")
    }

    // MARK: - Model Size

    /// Gets the on-disk size of a downloaded model by walking the snapshots directory
    func getModelSizeOnDisk(_ model: ParakeetModel) -> Int64 {
        let cachePath = modelCachePath(for: model)
        let snapshotsPath = cachePath.appendingPathComponent("snapshots")
        let fm = FileManager.default

        guard fm.fileExists(atPath: snapshotsPath.path) else { return 0 }

        var totalSize: Int64 = 0
        if let enumerator = fm.enumerator(at: snapshotsPath, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      resourceValues.isRegularFile == true,
                      let fileSize = resourceValues.fileSize else {
                    continue
                }
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    /// Gets the total size of all downloaded Parakeet models
    func getTotalModelsSize() -> Int64 {
        var total: Int64 = 0
        for model in getDownloadedModels() {
            total += getModelSizeOnDisk(model)
        }
        return total
    }

    // MARK: - Model Download

    /// Downloads a model directly from HuggingFace using native URLSession.
    /// Files are stored in the standard HuggingFace Hub cache format for compatibility with huggingface_hub.
    func downloadModel(
        _ model: ParakeetModel,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        guard isParakeetInstalled() else {
            throw ParakeetModelDownloadError.parakeetNotInstalled
        }

        guard activeDownloads[model] == nil else {
            logger.warning("Model \(model.id) is already being downloaded")
            throw ParakeetModelDownloadError.downloadAlreadyInProgress
        }

        guard !isModelDownloaded(model) else {
            logger.info("Model \(model.id) is already downloaded")
            progress(ModelDownloadProgress.completed)
            return
        }

        logger.info("Starting download of Parakeet model: \(model.displayName)")

        let downloadID = UUID()
        activeDownloads[model] = ActiveDownload(
            id: downloadID,
            operation: nil,
            latestProgress: nil,
            progress: progress
        )
        pendingDownloadFailures.removeValue(forKey: model)

        let stagingCacheDir = cacheDirectory.appendingPathComponent(
            ".parakeet-download-\(downloadID.uuidString)",
            isDirectory: true
        )
        defer {
            if activeDownloads[model]?.id == downloadID {
                activeDownloads.removeValue(forKey: model)
            }
            try? FileManager.default.removeItem(at: stagingCacheDir)
        }

        do {
            // 1. Fetch model metadata from HuggingFace API
            let apiURLString = "https://huggingface.co/api/models/\(model.id)?blobs=true"
            guard let apiURL = URL(string: apiURLString) else {
                throw ParakeetModelDownloadError.downloadFailed("Invalid model ID: \(model.id)")
            }

            let metadataOperation = metadataOperationFactory(apiURL)
            setActiveOperation(metadataOperation, for: model, downloadID: downloadID)
            let modelInfo = try await runMetadataOperation(
                metadataOperation,
                for: model,
                downloadID: downloadID
            )
            try ensureActive(model, downloadID: downloadID)
            let commitHash = modelInfo.sha
            guard Self.validatedBlobName(commitHash), !modelInfo.siblings.isEmpty else {
                throw ParakeetModelDownloadError.downloadFailed(
                    "HuggingFace returned incomplete model metadata"
                )
            }

            // 2. Prepare cache directory structure (matches huggingface_hub format)
            let blobsDir = stagingCacheDir.appendingPathComponent("blobs")
            let snapshotsDir = stagingCacheDir.appendingPathComponent("snapshots")
                .appendingPathComponent(commitHash)
            let refsDir = stagingCacheDir.appendingPathComponent("refs")

            let fm = FileManager.default
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)

            // 3. Calculate total download size from API metadata
            let files = modelInfo.siblings
            var totalBytes: Int64 = 0
            for file in files {
                guard let size = file.size else { continue }
                guard size >= 0 else {
                    throw ParakeetModelDownloadError.downloadFailed(
                        "HuggingFace returned an invalid model file size"
                    )
                }
                let addition = totalBytes.addingReportingOverflow(size)
                guard !addition.overflow else {
                    throw ParakeetModelDownloadError.downloadFailed(
                        "HuggingFace returned an invalid total model size"
                    )
                }
                totalBytes = addition.partialValue
            }
            let expectedTotalBytes = totalBytes
            var completedBytes: Int64 = 0
            let downloadStartTime = Date()

            // 4. Download each file with progress tracking
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()

                guard let relativeComponents = Self.validatedRelativePathComponents(file.rfilename) else {
                    throw ParakeetModelDownloadError.downloadFailed(
                        "Model metadata contained an unsafe file path"
                    )
                }
                let encodedFilename = relativeComponents.map {
                    $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
                }.joined(separator: "/")
                guard let fileURL = URL(string:
                    "https://huggingface.co/\(model.id)/resolve/main/\(encodedFilename)"
                ) else {
                    logger.warning("Skipping file with invalid URL: \(file.rfilename)")
                    continue
                }

                logger.info("Downloading file \(index + 1)/\(files.count): \(file.rfilename)")

                let fileCompletedBytes = completedBytes
                let fileCount = files.count
                let fileName = file.rfilename

                let fileOperation = fileDownloadOperationFactory(fileURL, file.size ?? 0)
                setActiveOperation(fileOperation, for: model, downloadID: downloadID)
                let downloadResult = try await runFileOperation(
                    fileOperation,
                    for: model,
                    downloadID: downloadID
                ) { [weak self] bytesWritten, totalExpected in
                    let safeBytesWritten = max(bytesWritten, 0)
                    let currentTotal = Self.clampedAddition(fileCompletedBytes, safeBytesWritten)
                    let overallFraction: Double
                    if expectedTotalBytes > 0 {
                        overallFraction = min(
                            Double(currentTotal) / Double(expectedTotalBytes), 0.99
                        )
                    } else {
                        let filePct = totalExpected > 0
                            ? Double(bytesWritten) / Double(totalExpected) : 0
                        overallFraction = min(
                            (Double(index) + filePct) / Double(fileCount), 0.99
                        )
                    }

                    let fileFraction = totalExpected > 0
                        ? min(Double(bytesWritten) / Double(totalExpected), 1.0) : 0

                    let elapsed = Date().timeIntervalSince(downloadStartTime)
                    let bytesPerSecond = elapsed > 0.5 ? Double(currentTotal) / elapsed : 0

                    let update = ModelDownloadProgress(
                        overallFraction: overallFraction,
                        currentFileName: fileName,
                        currentFileIndex: index + 1,
                        totalFileCount: fileCount,
                        currentFileFraction: fileFraction,
                        bytesPerSecond: bytesPerSecond
                    )
                    Task {
                        await self?.publishProgress(update, for: model, downloadID: downloadID)
                    }
                }
                defer { try? fm.removeItem(at: downloadResult.temporaryURL) }
                try ensureActive(model, downloadID: downloadID)
                guard downloadResult.statusCode == nil
                        || (200...299).contains(downloadResult.statusCode ?? 0) else {
                    try? fm.removeItem(at: downloadResult.temporaryURL)
                    throw ParakeetModelDownloadError.downloadFailed(
                        "HuggingFace returned HTTP \(downloadResult.statusCode ?? 0)"
                    )
                }
                if let expectedFileSize = file.size {
                    let resourceValues = try downloadResult.temporaryURL.resourceValues(
                        forKeys: [.fileSizeKey]
                    )
                    guard let actualFileSize = resourceValues.fileSize,
                          Int64(actualFileSize) == expectedFileSize else {
                        throw ParakeetModelDownloadError.downloadFailed(
                            "A downloaded model file had an unexpected size"
                        )
                    }
                }
                if let expectedSHA256 = file.lfs?.sha256 {
                    guard expectedSHA256.count == 64,
                          expectedSHA256.allSatisfy({ $0.isHexDigit }) else {
                        throw ParakeetModelDownloadError.downloadFailed(
                            "HuggingFace returned an invalid model checksum"
                        )
                    }
                    let checksumCancellation = ParakeetOperationCancellation()
                    setActiveOperation(checksumCancellation, for: model, downloadID: downloadID)
                    let actualSHA256 = try await Self.sha256(
                        of: downloadResult.temporaryURL,
                        cancellation: checksumCancellation
                    )
                    try ensureActive(model, downloadID: downloadID)
                    guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                        throw ParakeetModelDownloadError.downloadFailed(
                            "A downloaded model file failed checksum verification"
                        )
                    }
                }

                // Determine blob name for huggingface_hub cache compatibility:
                // - LFS files: use the sha256 from the API (matches X-Linked-ETag)
                // - Non-LFS files: use the ETag from the HTTP response
                let blobName: String
                if let lfsSha = file.lfs?.sha256 {
                    blobName = lfsSha
                } else {
                    let rawETag = downloadResult.eTag ?? ""
                    blobName = rawETag.isEmpty
                        ? UUID().uuidString
                        : Self.normalizeETag(rawETag)
                }
                guard Self.validatedBlobName(blobName) else {
                    try? fm.removeItem(at: downloadResult.temporaryURL)
                    throw ParakeetModelDownloadError.downloadFailed(
                        "HuggingFace returned an unsafe file identifier"
                    )
                }

                // Store file as blob
                let blobPath = blobsDir.appendingPathComponent(blobName)
                if fm.fileExists(atPath: blobPath.path) {
                    try fm.removeItem(at: blobPath)
                }
                do {
                    try fm.moveItem(at: downloadResult.temporaryURL, to: blobPath)
                } catch {
                    try? fm.removeItem(at: downloadResult.temporaryURL)
                    throw error
                }

                // Create symlink in snapshots directory (matches huggingface_hub layout)
                let snapshotFilePath = relativeComponents.reduce(snapshotsDir) {
                    $0.appendingPathComponent($1)
                }
                let snapshotFileDir = snapshotFilePath.deletingLastPathComponent()
                if !fm.fileExists(atPath: snapshotFileDir.path) {
                    try fm.createDirectory(at: snapshotFileDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: snapshotFilePath.path) {
                    try fm.removeItem(at: snapshotFilePath)
                }

                // Relative symlink: snapshots/{commit}/{file} -> ../../blobs/{etag}
                // Add extra ../ for each subdirectory level in the filename
                let subdirDepth = file.rfilename.components(separatedBy: "/").count - 1
                let relativePrefix = String(repeating: "../", count: 2 + subdirDepth)
                try fm.createSymbolicLink(
                    atPath: snapshotFilePath.path,
                    withDestinationPath: relativePrefix + "blobs/" + blobName
                )

                // Track completed bytes (use actual Content-Length if API didn't provide size)
                let actualFileSize = file.size
                    ?? downloadResult.expectedContentLength
                completedBytes = Self.clampedAddition(completedBytes, max(actualFileSize, 0))
            }

            // 5. Write refs/main with commit hash
            let refsMainPath = refsDir.appendingPathComponent("main")
            try commitHash.write(to: refsMainPath, atomically: true, encoding: .utf8)

            // 6. Publish only after the complete staged cache passes its final ownership check.
            try ensureActive(model, downloadID: downloadID)
            let cacheDir = modelCachePath(for: model)
            if isModelDownloaded(model) {
                progress(.completed)
                return
            }
            try publishStagedCache(stagingCacheDir, to: cacheDir)

            // 7. Verify the model is now in cache
            guard isModelDownloaded(model) else {
                throw ParakeetModelDownloadError.downloadFailed(
                    "Model not found in cache after download"
                )
            }

            progress(.completed)
            logger.info("Successfully downloaded Parakeet model: \(model.displayName)")
        } catch {
            if !(error is CancellationError), activeDownloads[model]?.id == downloadID {
                pendingDownloadFailures[model] = error.localizedDescription
            }
            throw error
        }
    }

    /// Cancels an ongoing model download
    func cancelDownload(for model: ParakeetModel) {
        guard let activeDownload = activeDownloads.removeValue(forKey: model) else { return }
        activeDownload.operation?.cancel()
        logger.info("Cancelled Parakeet model download: \(model.displayName)")
    }

    // MARK: - Download Helpers

    /// Normalizes an HTTP ETag to match huggingface_hub's blob naming convention
    private static func normalizeETag(_ etag: String) -> String {
        var result = etag
        if result.hasPrefix("W/") {
            result = String(result.dropFirst(2))
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func validatedRelativePathComponents(_ path: String) -> [String]? {
        guard !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    private static func validatedBlobName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func clampedAddition(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let addition = lhs.addingReportingOverflow(rhs)
        return addition.overflow ? Int64.max : addition.partialValue
    }

    private nonisolated static func sha256(
        of fileURL: URL,
        cancellation: ParakeetOperationCancellation
    ) async throws -> String {
        let hashingTask = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                try cancellation.checkCancellation()
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await hashingTask.value
        } onCancel: {
            cancellation.cancel()
            hashingTask.cancel()
        }
    }

    private func setActiveOperation(
        _ operation: any ParakeetModelNetworkOperation,
        for model: ParakeetModel,
        downloadID: UUID
    ) {
        guard activeDownloads[model]?.id == downloadID else {
            operation.cancel()
            return
        }
        activeDownloads[model]?.operation = operation
    }

    private func ensureActive(_ model: ParakeetModel, downloadID: UUID) throws {
        try Task.checkCancellation()
        guard activeDownloads[model]?.id == downloadID else {
            throw CancellationError()
        }
    }

    private func runMetadataOperation(
        _ operation: any ParakeetModelMetadataOperation,
        for model: ParakeetModel,
        downloadID: UUID
    ) async throws -> ParakeetModelMetadata {
        do {
            return try await withTaskCancellationHandler {
                try await operation.run()
            } onCancel: {
                operation.cancel()
                Task { await self.invalidateDownload(for: model, matching: downloadID) }
            }
        } catch {
            if Task.isCancelled || activeDownloads[model]?.id != downloadID {
                throw CancellationError()
            }
            throw error
        }
    }

    private func runFileOperation(
        _ operation: any ParakeetFileDownloadOperation,
        for model: ParakeetModel,
        downloadID: UUID,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ParakeetFileDownloadResult {
        do {
            return try await withTaskCancellationHandler {
                try await operation.run(progress: progress)
            } onCancel: {
                operation.cancel()
                Task { await self.invalidateDownload(for: model, matching: downloadID) }
            }
        } catch {
            if Task.isCancelled || activeDownloads[model]?.id != downloadID {
                throw CancellationError()
            }
            throw error
        }
    }

    private func publishProgress(
        _ progress: ModelDownloadProgress,
        for model: ParakeetModel,
        downloadID: UUID
    ) {
        guard let activeDownload = activeDownloads[model], activeDownload.id == downloadID else {
            return
        }
        activeDownloads[model]?.latestProgress = progress
        activeDownload.progress(progress)
    }

    private func invalidateDownload(for model: ParakeetModel, matching downloadID: UUID) {
        guard activeDownloads[model]?.id == downloadID else { return }
        activeDownloads.removeValue(forKey: model)
    }

    private func publishStagedCache(
        _ stagingCacheDir: URL,
        to cacheDir: URL
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDir.path) {
            _ = try fm.replaceItemAt(
                cacheDir,
                withItemAt: stagingCacheDir,
                backupItemName: nil,
                options: []
            )
        } else {
            try fm.moveItem(at: stagingCacheDir, to: cacheDir)
        }
    }

    // MARK: - Model Deletion

    /// Deletes a downloaded model from the HuggingFace Hub cache
    func deleteModel(_ model: ParakeetModel) throws {
        let cachePath = modelCachePath(for: model)
        let fm = FileManager.default

        guard fm.fileExists(atPath: cachePath.path) else {
            logger.warning("Tried to delete model that doesn't exist: \(model.displayName)")
            return
        }

        try fm.removeItem(at: cachePath)
        logger.info("Deleted Parakeet model: \(model.displayName)")

        // If this was the selected model, switch to a different downloaded model
        let selected = getSelectedModel()
        if selected.id == model.id {
            let downloaded = getDownloadedModels()
            if let firstAvailable = downloaded.first {
                setSelectedModel(firstAvailable)
            }
        }
    }

    /// Deletes all downloaded Parakeet models from cache
    func deleteAllModels() throws {
        for model in getDownloadedModels() {
            try deleteModel(model)
        }
        logger.info("Deleted all Parakeet models")
    }
}

// MARK: - URLSession Operations

final class URLSessionParakeetModelMetadataOperation: NSObject,
    ParakeetModelMetadataOperation, URLSessionDataDelegate, @unchecked Sendable
{
    static let resourceTimeout: TimeInterval = 5 * 60
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let sourceURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ParakeetModelMetadata, Error>?
    private var resolvedResult: Result<ParakeetModelMetadata, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedData = Data()

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    func run() async throws -> ParakeetModelMetadata {
        let session = URLSession(
            configuration: Self.makeConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: sourceURL)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = lock.withLock { () -> (Result<ParakeetModelMetadata, Error>?, Bool) in
                    if let resolvedResult {
                        return (resolvedResult, false)
                    }
                    self.continuation = continuation
                    self.session = session
                    self.task = task
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            completionHandler(.cancel)
            resolve(.failure(URLError(.badServerResponse)), cancelSession: true)
            return
        }
        if response.expectedContentLength > Self.maximumResponseBytes {
            completionHandler(.cancel)
            resolve(.failure(URLError(.dataLengthExceedsMaximum)), cancelSession: true)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let exceededLimit = lock.withLock { () -> Bool in
            guard resolvedResult == nil else { return false }
            guard data.count <= Self.maximumResponseBytes - receivedData.count else {
                return true
            }
            receivedData.append(data)
            return false
        }
        if exceededLimit {
            resolve(.failure(URLError(.dataLengthExceedsMaximum)), cancelSession: true)
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

        let data = lock.withLock { receivedData }
        do {
            resolve(
                .success(try JSONDecoder().decode(ParakeetModelMetadata.self, from: data)),
                cancelSession: false
            )
        } catch {
            resolve(.failure(error), cancelSession: false)
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()), cancelSession: true)
    }

    private func resolve(
        _ result: Result<ParakeetModelMetadata, Error>,
        cancelSession: Bool
    ) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<ParakeetModelMetadata, Error>?,
            URLSession?,
            URLSessionDataTask?
        )? in
            guard resolvedResult == nil else { return nil }
            resolvedResult = result
            let pending = (continuation, session, task)
            continuation = nil
            session = nil
            task = nil
            return pending
        }

        guard let pending else { return }
        if cancelSession {
            pending.2?.cancel()
            pending.1?.invalidateAndCancel()
        } else {
            pending.1?.finishTasksAndInvalidate()
        }
        pending.0?.resume(with: result)
    }
}

final class URLSessionParakeetFileDownloadOperation: NSObject,
    ParakeetFileDownloadOperation, URLSessionDownloadDelegate, @unchecked Sendable
{
    static let resourceTimeout: TimeInterval = 12 * 60 * 60

    private let sourceURL: URL
    private let expectedByteCount: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ParakeetFileDownloadResult, Error>?
    private var resolvedResult: Result<ParakeetFileDownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var temporaryURL: URL?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?

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

    func run(
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ParakeetFileDownloadResult {
        let session = URLSession(
            configuration: Self.makeConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: sourceURL)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = lock.withLock { () -> (
                    Result<ParakeetFileDownloadResult, Error>?, Bool
                ) in
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
        let handler = lock.withLock { resolvedResult == nil ? progressHandler : nil }
        handler?(totalBytesWritten, expectedBytes)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let persistentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".download")
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

        let state = lock.withLock { (temporaryURL, task.response as? HTTPURLResponse) }
        guard let downloadedURL = state.0 else {
            resolve(.failure(URLError(.badServerResponse)), cancelSession: false)
            return
        }
        resolve(
            .success(
                ParakeetFileDownloadResult(
                    temporaryURL: downloadedURL,
                    statusCode: state.1?.statusCode,
                    expectedContentLength: state.1?.expectedContentLength ?? expectedByteCount,
                    eTag: state.1?.value(forHTTPHeaderField: "ETag")
                )
            ),
            cancelSession: false
        )
    }

    private func resolve(
        _ result: Result<ParakeetFileDownloadResult, Error>,
        cancelSession: Bool
    ) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<ParakeetFileDownloadResult, Error>?,
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

enum ParakeetModelDownloadError: Error, LocalizedError {
    case parakeetNotInstalled
    case downloadAlreadyInProgress
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .parakeetNotInstalled:
            return "parakeet-mlx is not installed. Install with: pip install -U parakeet-mlx"
        case .downloadAlreadyInProgress:
            return "This model is already being downloaded."
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        }
    }
}

// MARK: - Download Progress

/// Progress information for model downloads, supporting both overall and per-file tracking
struct ModelDownloadProgress: Sendable {
    var overallFraction: Double
    var currentFileName: String
    var currentFileIndex: Int
    var totalFileCount: Int
    var currentFileFraction: Double
    var bytesPerSecond: Double

    /// Terminal state indicating download completed
    static let completed = ModelDownloadProgress(
        overallFraction: 1.0,
        currentFileName: "",
        currentFileIndex: 0,
        totalFileCount: 0,
        currentFileFraction: 1.0,
        bytesPerSecond: 0
    )

    /// Formats the download speed for display (e.g. "12.5 MB/s" or "450 KB/s")
    var formattedSpeed: String {
        if bytesPerSecond <= 0 { return "" }
        let mbps = bytesPerSecond / 1_000_000
        if mbps >= 1.0 {
            return String(format: "%.1f MB/s", mbps)
        } else {
            let kbps = bytesPerSecond / 1_000
            return String(format: "%.0f KB/s", kbps)
        }
    }
}
