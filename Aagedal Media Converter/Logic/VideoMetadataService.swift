import Foundation
import OSLog

struct VideoMetadata: Equatable, Sendable {
    struct Ratio: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var doubleValue: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(numerator: Int, denominator: Int) {
            guard denominator != 0 else { return nil }
            self.numerator = numerator
            self.denominator = denominator
            self.stringValue = "\(numerator):\(denominator)"
        }

        init?(ratioString: String) {
            let trimmed = ratioString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let parsed = Ratio.parse(trimmed, separator: ":") ?? Ratio.parse(trimmed, separator: "/") {
                self = parsed
                return
            }

            if let value = Double(trimmed) {
                let scaledNumerator = Int((value * 10_000).rounded())
                self.numerator = scaledNumerator
                self.denominator = 10_000
                self.stringValue = String(format: value >= 10 ? "%.2f" : "%.4f", value)
                return
            }

            return nil
        }

        static func parse(_ string: String, separator: Character) -> Ratio? {
            let parts = string.split(separator: separator)
            guard parts.count == 2,
                  let numerator = Int(parts[0]),
                  let denominator = Int(parts[1]),
                  denominator != 0 else {
                return nil
            }
            return Ratio(numerator: numerator, denominator: denominator)
        }
    }

    struct FrameRate: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var value: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(frameRateString: String) {
            let trimmed = frameRateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let ratio = Ratio.parse(trimmed, separator: "/") {
                self.numerator = ratio.numerator
                self.denominator = ratio.denominator
                if let value = ratio.doubleValue {
                    self.stringValue = String(format: "%.3f", value)
                } else {
                    self.stringValue = trimmed
                }
                return
            }

            if let value = Double(trimmed), value > 0 {
                self.numerator = Int((value * 1_000).rounded())
                self.denominator = 1_000
                self.stringValue = String(format: "%.3f", value)
                return
            }

            return nil
        }
    }

    let duration: Double?
    let formatName: String?
    let containerLongName: String?
    let sizeBytes: Int64?
    let bitRate: Int64?
    let comment: String?

    struct VideoStream: Equatable, Sendable {
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pixelAspectRatio: Ratio?
        let displayAspectRatio: Ratio?
        let frameRate: FrameRate?
        let bitDepth: Int?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let colorRange: String?
        let chromaLocation: String?
        let fieldOrder: String?
        let isInterlaced: Bool?
    }

    struct AudioStream: Equatable, Sendable {
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let sampleRate: Int?
        let channels: Int?
        let channelLayout: String?
        let bitDepth: Int?
        let bitRate: Int64?
    }

    let videoStream: VideoStream?
    let audioStream: AudioStream?
}

enum VideoMetadataError: Error {
    case ffprobeMissing
    case processFailed(String)
    case decodingFailed(String)
}

actor VideoMetadataService {
    static let shared = VideoMetadataService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoMetadata")
    private let cache = NSCache<NSURL, CachedMetadata>()

    private final class CachedMetadata: NSObject {
        let metadata: VideoMetadata
        init(metadata: VideoMetadata) {
            self.metadata = metadata
        }
    }

    func metadata(for url: URL) async throws -> VideoMetadata {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.metadata
        }

        var didStartDirectAccess = false
        var didStartBookmarkAccess = false
        if url.startAccessingSecurityScopedResource() {
            didStartDirectAccess = true
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            didStartBookmarkAccess = true
        }

        defer {
            if didStartDirectAccess {
                url.stopAccessingSecurityScopedResource()
            } else if didStartBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            }
        }

        guard let ffprobePath = Bundle.main.path(forResource: "ffprobe", ofType: nil) else {
            throw VideoMetadataError.ffprobeMissing
        }

        let jsonData = try await runFFprobeJSON(url: url, ffprobePath: ffprobePath)
        let metadata = try parseMetadata(jsonData: jsonData)
        cache.setObject(CachedMetadata(metadata: metadata), forKey: url as NSURL)
        return metadata
    }

    private func runFFprobeJSON(url: URL, ffprobePath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobePath)
                process.arguments = [
                    "-v", "error",
                    "-show_format",
                    "-show_streams",
                    "-print_format", "json",
                    url.path
                ]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdoutData)
                } else {
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown ffprobe error"
                    continuation.resume(throwing: VideoMetadataError.processFailed(message))
                }
            }
        }
    }

    private func parseMetadata(jsonData: Data) throws -> VideoMetadata {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(FFprobeResponse.self, from: jsonData)
            return response.toVideoMetadata()
        } catch {
            let message = String(data: jsonData, encoding: .utf8) ?? "<non-UTF8>"
            logger.error("Failed to decode ffprobe JSON: \(message)")
            throw VideoMetadataError.decodingFailed(error.localizedDescription)
        }
    }
}

private struct FFprobeResponse: Decodable {
    let format: Format?
    let streams: [Stream]

    struct Format: Decodable {
        let duration: String?
        let formatName: String?
        let formatLongName: String?
        let size: String?
        let bitRate: String?
        let tags: Tags?
    }

    struct Stream: Decodable {
        let index: Int?
        let codecName: String?
        let codecLongName: String?
        let profile: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let sampleAspectRatio: String?
        let displayAspectRatio: String?
        let avgFrameRate: String?
        let rFrameRate: String?
        let bitRate: String?
        let bitsPerRawSample: String?
        let sampleRate: String?
        let channels: Int?
        let channelLayout: String?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let colorRange: String?
        let chromaLocation: String?
        let fieldOrder: String?
        let maxBitRate: String?
        let disposition: Disposition?
        let tags: Tags?

        struct Disposition: Decodable {
            let defaultStream: Int?
        }
    }

    struct Tags: Decodable {
        let comment: String?
    }

    func toVideoMetadata() -> VideoMetadata {
        let formatMetadata = format

        let videoStream = streams.first { $0.codecType == "video" }
        let audioStream = streams.first { $0.codecType == "audio" }

        let formatComment = formatMetadata?.tags?.comment ?? videoStream?.tags?.comment ?? audioStream?.tags?.comment

        let video = videoStream.map { stream -> VideoMetadata.VideoStream in
            let frameRateString = stream.avgFrameRate ?? stream.rFrameRate
            return VideoMetadata.VideoStream(
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                width: stream.width,
                height: stream.height,
                pixelAspectRatio: stream.sampleAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                displayAspectRatio: stream.displayAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                frameRate: frameRateString.flatMap(VideoMetadata.FrameRate.init(frameRateString:)),
                bitDepth: stream.bitsPerRawSample.flatMap { Int($0) },
                colorPrimaries: stream.colorPrimaries,
                colorTransfer: stream.colorTransfer,
                colorSpace: stream.colorSpace,
                colorRange: stream.colorRange,
                chromaLocation: stream.chromaLocation,
                fieldOrder: stream.fieldOrder,
                isInterlaced: stream.fieldOrder.map { $0.lowercased().contains("interlaced") }
            )
        }

        let audio = audioStream.map { stream -> VideoMetadata.AudioStream in
            return VideoMetadata.AudioStream(
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                sampleRate: stream.sampleRate.flatMap { Int($0) },
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                bitDepth: stream.bitsPerRawSample.flatMap { Int($0) },
                bitRate: stream.bitRate.flatMap { Int64($0) }
            )
        }

        return VideoMetadata(
            duration: formatMetadata?.duration.flatMap { Double($0) },
            formatName: formatMetadata?.formatName,
            containerLongName: formatMetadata?.formatLongName,
            sizeBytes: formatMetadata?.size.flatMap { Int64($0) },
            bitRate: formatMetadata?.bitRate.flatMap { Int64($0) },
            comment: formatComment,
            videoStream: video,
            audioStream: audio
        )
    }
}
