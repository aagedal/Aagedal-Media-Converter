// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Exports the full metadata payload shown in the metadata view to disk as
/// either JSON or PDF. The JSON schema is intentionally slightly richer than
/// `MetadataSidecarGenerator` — it also includes C2PA fields and subtitle
/// streams, matching everything the UI displays.
enum MetadataExporter {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MetadataExporter")

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case json = "JSON"
        case pdf = "PDF"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .pdf: return "pdf"
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .pdf: return .pdf
            }
        }
    }

    enum ExportError: Error, LocalizedError {
        case savePanelCancelled
        case pdfRenderingFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .savePanelCancelled: return "Export cancelled."
            case .pdfRenderingFailed: return "Could not render PDF."
            case .writeFailed(let msg): return "Could not write file: \(msg)"
            }
        }
    }

    // MARK: - Entry points

    /// Prompts the user for a save location and writes the chosen format to disk.
    /// Returns the URL on success, nil if the user cancelled, and throws on I/O errors.
    @MainActor
    @discardableResult
    static func exportWithSavePanel(item: VideoItem, format: Format) throws -> URL? {
        let suggestedName = defaultFileName(for: item, format: format)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Metadata"
        panel.message = "Choose where to save \(format.rawValue.lowercased()) metadata for \(item.name)"

        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else {
            return nil
        }

        try exportSync(item: item, to: destination, format: format)
        return destination
    }

    /// Writes the chosen format to the given URL without prompting.
    @MainActor
    static func exportSync(item: VideoItem, to url: URL, format: Format) throws {
        switch format {
        case .json:
            let data = try makeJSONData(for: item)
            do {
                try data.write(to: url, options: .atomic)
                logger.info("Wrote metadata JSON to \(url.lastPathComponent, privacy: .public)")
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
        case .pdf:
            try renderPDF(for: item, to: url)
            logger.info("Wrote metadata PDF to \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - Filename

    static func defaultFileName(for item: VideoItem, format: Format) -> String {
        let base = (item.url.lastPathComponent as NSString).deletingPathExtension
        let cleaned = base.isEmpty ? "Metadata" : base
        return "\(cleaned)_Metadata.\(format.fileExtension)"
    }

    // MARK: - JSON

    static func makeJSONData(for item: VideoItem) throws -> Data {
        let dict = buildJSONDictionary(for: item)
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Trailing newline matches MetadataSidecarGenerator convention.
        return data + Data([0x0A])
    }

    private static func buildJSONDictionary(for item: VideoItem) -> [String: Any] {
        var root: [String: Any] = [:]
        root["sourceFile"] = item.url.lastPathComponent
        root["sourceFilePath"] = item.url.path
        root["generatedBy"] = "Aagedal Media Converter"
        root["generatedAt"] = ISO8601DateFormatter().string(from: Date())

        // General / container
        var general: [String: Any] = [:]
        if let size = item.metadata?.sizeBytes ?? Optional(item.size) {
            general["sizeBytes"] = size
            general["sizeHuman"] = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        let formatter = ISO8601DateFormatter()
        let creationDate = item.metadata?.containerCreationDate
            ?? (try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 }
        if let creationDate {
            general["creationDate"] = formatter.string(from: creationDate)
            general["creationDateSource"] = item.metadata?.containerCreationDate != nil ? "container" : "filesystem"
        }
        let modificationDate = item.metadata?.containerModificationDate
            ?? (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }
        if let modificationDate {
            general["modificationDate"] = formatter.string(from: modificationDate)
            general["modificationDateSource"] = item.metadata?.containerModificationDate != nil ? "container" : "filesystem"
        }

        if let m = item.metadata {
            if let v = m.formatName { general["format"] = v }
            if let v = m.containerLongName { general["formatLongName"] = v }
            if let v = m.duration { general["duration"] = v }
            if let v = m.bitRate { general["bitRate"] = v }
            if let v = m.timecode { general["timecode"] = v }
            if !m.timecodes.isEmpty {
                general["timecodes"] = m.timecodes.map { tc -> [String: Any] in
                    var dict: [String: Any] = [
                        "value": tc.value,
                        "source": tc.source.rawValue
                    ]
                    if let fr = tc.frameRate { dict["frameRate"] = fr }
                    return dict
                }
            }
            if let v = m.frameCount { general["frameCount"] = v }
            if let v = m.title { general["title"] = v }
            if let v = m.artist { general["artist"] = v }
            if let lat = m.gpsLatitude, let lon = m.gpsLongitude {
                var gps: [String: Any] = ["latitude": lat, "longitude": lon]
                if let alt = m.gpsAltitude { gps["altitude"] = alt }
                general["gps"] = gps
            }
            if let v = m.comment { general["comment"] = v }
            if let v = m.description { general["description"] = v }
            if let v = m.sourceURL { general["sourceURL"] = v }
            if !m.warnings.isEmpty { general["warnings"] = m.warnings }
        }
        if !general.isEmpty {
            root["general"] = general
        }

        // Streams
        if let streams = item.metadata?.videoStreams, !streams.isEmpty {
            root["videoStreams"] = streams.map(videoStreamDict(_:))
        }
        if let streams = item.metadata?.audioStreams, !streams.isEmpty {
            root["audioStreams"] = streams.map(audioStreamDict(_:))
        }
        if let streams = item.metadata?.subtitleStreams, !streams.isEmpty {
            root["subtitleStreams"] = streams.map(subtitleStreamDict(_:))
        }

        // Camera
        if let camera = item.cameraMetadata, camera.hasAnyData {
            root["camera"] = cameraDict(from: camera)
        }

        // C2PA
        if let c2pa = item.c2paMetadata {
            root["c2pa"] = c2paDict(from: c2pa)
        }

        return root
    }

    private static func videoStreamDict(_ stream: VideoMetadata.VideoStream) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = stream.codec { dict["codec"] = v }
        if let v = stream.codecLongName { dict["codecLongName"] = v }
        if let v = stream.profile { dict["profile"] = v }
        if let v = stream.title { dict["title"] = v }
        if let v = stream.width { dict["width"] = v }
        if let v = stream.height { dict["height"] = v }
        if let v = stream.frameRate { dict["frameRate"] = v.stringValue }
        if let v = stream.pixelAspectRatio { dict["pixelAspectRatio"] = v.stringValue }
        if let v = stream.displayAspectRatio { dict["displayAspectRatio"] = v.stringValue }
        if let v = stream.bitDepth { dict["bitDepth"] = v }
        if let v = stream.bitRate { dict["bitRate"] = v }
        if let v = stream.duration { dict["duration"] = v }
        if let v = stream.chromaSubsampling { dict["chromaSubsampling"] = v }
        if let v = stream.chromaLocation { dict["chromaLocation"] = v }
        if let v = stream.pixelFormat { dict["pixelFormat"] = v }
        if let v = stream.colorPrimaries { dict["colorPrimaries"] = v }
        if let v = stream.colorTransfer { dict["colorTransfer"] = v }
        if let v = stream.colorSpace { dict["colorSpace"] = v }
        if let v = stream.colorRange { dict["colorRange"] = v }
        if let v = stream.fieldOrder { dict["fieldOrder"] = v }
        if let v = stream.isInterlaced { dict["isInterlaced"] = v }
        dict["hasAlpha"] = stream.hasAlpha
        dict["isDefault"] = stream.isDefault
        dict["isForced"] = stream.isForced
        return dict
    }

    private static func audioStreamDict(_ stream: VideoMetadata.AudioStream) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = stream.index { dict["index"] = v }
        if let v = stream.codec { dict["codec"] = v }
        if let v = stream.codecLongName { dict["codecLongName"] = v }
        if let v = stream.profile { dict["profile"] = v }
        if let v = stream.languageCode { dict["language"] = v }
        if let v = stream.title { dict["title"] = v }
        if let v = stream.sampleRate { dict["sampleRate"] = v }
        if let v = stream.channels { dict["channels"] = v }
        if let v = stream.channelLayout { dict["channelLayout"] = v }
        if let v = stream.bitDepth { dict["bitDepth"] = v }
        if let v = stream.bitRate { dict["bitRate"] = v }
        dict["isDefault"] = stream.isDefault
        return dict
    }

    private static func subtitleStreamDict(_ stream: VideoMetadata.SubtitleStream) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = stream.index { dict["index"] = v }
        if let v = stream.codec { dict["codec"] = v }
        if let v = stream.codecLongName { dict["codecLongName"] = v }
        if let v = stream.languageCode { dict["language"] = v }
        if let v = stream.title { dict["title"] = v }
        if let v = stream.duration { dict["duration"] = v }
        dict["isDefault"] = stream.isDefault
        dict["isForced"] = stream.isForced
        dict["isHearingImpaired"] = stream.isHearingImpaired
        return dict
    }

    private static func cameraDict(from camera: CameraMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = camera.deviceManufacturer { dict["manufacturer"] = v }
        if let v = camera.deviceModelName { dict["model"] = v }
        if let v = camera.deviceSerialNumber { dict["serialNumber"] = v }
        if let v = camera.lensModelName { dict["lens"] = v }
        if let v = camera.captureGammaEquation { dict["gammaEquation"] = v }
        if let v = camera.recordingModeType { dict["recordingMode"] = v }
        if let v = camera.captureFps { dict["captureFps"] = v }
        if let v = camera.timeZone { dict["timeZone"] = v }
        if let date = camera.creationDate {
            dict["creationDate"] = ISO8601DateFormatter().string(from: date)
        }
        if let entries = camera.userDescriptiveMetadata, !entries.isEmpty {
            dict["userDescriptiveMetadata"] = entries.map { [
                "name": $0.name,
                "content": $0.content
            ] }
        }
        return dict
    }

    private static func c2paDict(from c2pa: C2PAMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["hasContentCredentials"] = c2pa.hasContentCredentials
        dict["hasSignature"] = c2pa.hasSignature
        if let v = c2pa.claimGenerator { dict["claimGenerator"] = v }
        if let v = c2pa.claimGeneratorInfoName { dict["claimGeneratorInfoName"] = v }
        if let v = c2pa.actionsAction { dict["actionsAction"] = v }
        if let v = c2pa.actionsDigitalSourceType { dict["actionsDigitalSourceType"] = v }
        if let v = c2pa.manifestStore { dict["manifestStore"] = v }
        if let v = c2pa.assertions { dict["assertions"] = v }
        return dict
    }

    // MARK: - PDF

    @MainActor
    private static func renderPDF(for item: VideoItem, to url: URL) throws {
        // US Letter width in points (8.5") with 0.5" margins on each side.
        let contentWidth: CGFloat = 612 - 72

        let exportView = MetadataExportView(item: item)
            .frame(width: contentWidth)
            .padding(36)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: exportView)
        renderer.proposedSize = ProposedViewSize(width: 612, height: nil)

        var succeeded = false
        var writeError: Error?
        renderer.render { size, renderBlock in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL) else {
                writeError = ExportError.pdfRenderingFailed
                return
            }
            guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                writeError = ExportError.pdfRenderingFailed
                return
            }
            ctx.beginPDFPage(nil)
            renderBlock(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            succeeded = true
        }

        if let writeError {
            throw writeError
        }
        guard succeeded else {
            throw ExportError.pdfRenderingFailed
        }
    }
}
