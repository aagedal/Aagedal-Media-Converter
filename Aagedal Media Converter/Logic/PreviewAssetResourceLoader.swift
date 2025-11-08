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
                let data: Data
                if url.path.hasSuffix(".m3u8") {
                    let playlistData = try self.rewrittenPlaylistData(session: session, customScheme: customScheme)
                    self.fillContentInformation(for: loadingRequest, mimeType: "application/vnd.apple.mpegurl", contentLength: Int64(playlistData.count))
                    data = playlistData
                } else {
                    let relativePath = Self.relativePath(for: url)
                    let fileURL = session.resolveResource(relativePath: relativePath)
                    data = try Data(contentsOf: fileURL)
                    let mimeType = fileURL.pathExtension == "mp4" ? "video/mp4" : "video/MP2T"
                    self.fillContentInformation(for: loadingRequest, mimeType: mimeType, contentLength: Int64(data.count))
                }

                if let dataRequest = loadingRequest.dataRequest {
                    dataRequest.respond(with: data)
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

    private func fillContentInformation(for loadingRequest: AVAssetResourceLoadingRequest, mimeType: String, contentLength: Int64) {
        guard let info = loadingRequest.contentInformationRequest else { return }
        info.contentType = mimeType
        info.contentLength = contentLength
        info.isByteRangeAccessSupported = true
    }

    private static func relativePath(for url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/") {
            return String(path.dropFirst())
        }
        return path
    }
}
