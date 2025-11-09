// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Handles AVAssetResourceLoader callbacks for FFmpeg-backed preview assets without spinning up an HTTP server.
final class PreviewAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let session: HLSPreviewSession
    private let playlistURL: URL
    private let customScheme: String
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewLoader")
    private let queue = DispatchQueue(label: "com.aagedal.MediaConverter.preview-loader")

    private lazy var assetURL: URL = {
        var components = URLComponents()
        components.scheme = customScheme
        components.host = session.itemID.uuidString
        components.path = "/preview.m3u8"
        return components.url ?? playlistURL
    }()

    init(session: HLSPreviewSession, playlistURL: URL, customScheme: String = "amc-preview") {
        self.session = session
        self.playlistURL = playlistURL
        self.customScheme = customScheme
    }

    func makePlayerItem() -> AVPlayerItem {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        asset.resourceLoader.preloadsEligibleContentKeys = true
        return AVPlayerItem(asset: asset)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return false
        }

        queue.async { [weak self, session = session, logger = logger, customScheme = customScheme] in
            guard let self else { return }
            do {
                if url.path.hasSuffix(".m3u8") {
                    let playlistData = try self.rewrittenPlaylistData(session: session, customScheme: customScheme)
                    self.fillContentInformation(for: loadingRequest, fileExtension: "m3u8", contentLength: Int64(playlistData.count))
                    if let dataRequest = loadingRequest.dataRequest {
                        logger.debug("Serving playlist for item \(session.itemID, privacy: .public) size=\(playlistData.count, privacy: .public)")
                        self.respond(to: dataRequest, with: playlistData)
                    }
                    loadingRequest.finishLoading()
                    return
                }

                let relativePath = Self.relativePath(for: url)
                let fileURL = session.resolveResource(relativePath: relativePath)
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                logger.debug("Serving segment \(fileURL.lastPathComponent, privacy: .public) size=\(fileSize, privacy: .public) for item \(session.itemID, privacy: .public)")
                self.fillContentInformation(for: loadingRequest, fileExtension: fileURL.pathExtension, contentLength: fileSize)

                if let dataRequest = loadingRequest.dataRequest {
                    try self.respond(to: dataRequest, fileURL: fileURL, fileSize: fileSize)
                }
                loadingRequest.finishLoading()
            } catch {
                logger.error("Failed to serve preview resource: \(error.localizedDescription, privacy: .public)")
                loadingRequest.finishLoading(with: error)
            }
        }

        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.async {
            loadingRequest.finishLoading()
        }
    }

    // MARK: - Helpers

    private func rewrittenPlaylistData(session: HLSPreviewSession, customScheme: String) throws -> Data {
        let original = try String(contentsOf: playlistURL, encoding: .utf8)
        let lines = original.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        let rewritten = lines.map { slice -> String in
            let line = String(slice)
            guard !line.isEmpty else { return line }
            if line.first == "#" {
                return line
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return "\(customScheme)://\(session.itemID.uuidString)/\(trimmed)"
        }
        return rewritten.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private func fillContentInformation(for loadingRequest: AVAssetResourceLoadingRequest, fileExtension: String, contentLength: Int64) {
        guard let info = loadingRequest.contentInformationRequest else { return }
        if let type = UTType(filenameExtension: fileExtension.lowercased()) {
            info.contentType = type.identifier
        } else if fileExtension.isEmpty, let type = UTType(filenameExtension: "bin") {
            info.contentType = type.identifier
        }
        info.contentLength = contentLength
        info.isByteRangeAccessSupported = true
    }

    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest, with data: Data) {
        let requestedOffset = Int(dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset)
        guard requestedOffset < data.count else { return }

        let endOffset: Int
        if dataRequest.requestsAllDataToEndOfResource || dataRequest.requestedLength == 0 {
            endOffset = data.count
        } else {
            endOffset = min(data.count, requestedOffset + Int(dataRequest.requestedLength))
        }

        guard endOffset > requestedOffset else { return }
        let chunk = data[requestedOffset..<endOffset]
        dataRequest.respond(with: chunk)
    }

    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest, fileURL: URL, fileSize: Int64) throws {
        let requestedOffset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        guard requestedOffset < fileSize else { return }

        let remainingLength: Int64
        if dataRequest.requestsAllDataToEndOfResource || dataRequest.requestedLength == 0 {
            remainingLength = fileSize - requestedOffset
        } else {
            remainingLength = min(Int64(dataRequest.requestedLength), fileSize - requestedOffset)
        }

        guard remainingLength > 0 else { return }

        logger.debug("Segment request offset=\(requestedOffset, privacy: .public) length=\(remainingLength, privacy: .public) for \(fileURL.lastPathComponent, privacy: .public)")

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(requestedOffset))

        var bytesRemaining = remainingLength
        while bytesRemaining > 0 {
            let chunkSize = Int(min(bytesRemaining, Int64(64 * 1024)))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            dataRequest.respond(with: chunk)
            bytesRemaining -= Int64(chunk.count)
        }

        if bytesRemaining > 0 {
            logger.error("Segment request for \(fileURL.lastPathComponent, privacy: .public) ended with \(bytesRemaining, privacy: .public) bytes remaining")
        }
    }

    private static func relativePath(for url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/") {
            return String(path.dropFirst())
        }
        return path
    }
}
