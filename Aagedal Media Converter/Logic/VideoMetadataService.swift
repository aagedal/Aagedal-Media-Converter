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
    let audioStreams: [AudioStream]
}

enum VideoMetadataError: Error {
    case ffprobeMissing
    case processFailed(String)
    case decodingFailed(String)
    case timeout
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

        let formatResponse = try await fetchFFprobeResponse(
            url: url,
            ffprobePath: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_format",
                "-of", "json"
            ]
        )

        let videoResponse = try await fetchFFprobeResponse(
            url: url,
            ffprobePath: ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "v",
                "-show_streams",
                "-of", "json"
            ],
            allowNoStreams: true
        )

        let audioResponse = try await fetchFFprobeResponse(
            url: url,
            ffprobePath: ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "a",
                "-show_streams",
                "-of", "json"
            ],
            allowNoStreams: true
        )

        let metadata = try buildMetadata(
            format: formatResponse.format,
            videoStreams: videoResponse.streams,
            audioStreams: audioResponse.streams
        )
        cache.setObject(CachedMetadata(metadata: metadata), forKey: url as NSURL)
        return metadata
    }

    private func runFFprobeJSON(url: URL, ffprobePath: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobePath)
                var args = arguments
                args.append(url.path)
                process.arguments = args

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

                // Wait with timeout (10 seconds - must be less than fetchMetadata timeout)
                let timeoutSeconds: TimeInterval = 10
                let checkInterval: TimeInterval = 0.5
                var elapsed: TimeInterval = 0
                
                while process.isRunning && elapsed < timeoutSeconds {
                    try? await Task.sleep(for: .seconds(checkInterval))
                    elapsed += checkInterval
                }
                
                if process.isRunning {
                    // Timeout - terminate the process
                    process.terminate()
                    try? await Task.sleep(for: .seconds(0.1))  // Give it a moment to terminate
                    if process.isRunning {
                        process.interrupt()  // Force kill if still running
                    }
                    continuation.resume(throwing: VideoMetadataError.timeout)
                    return
                }

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

    private func fetchFFprobeResponse(url: URL, ffprobePath: String, arguments: [String], allowNoStreams: Bool = false) async throws -> FFprobeResponse {
        do {
            let data = try await runFFprobeJSON(url: url, ffprobePath: ffprobePath, arguments: arguments)
            return try decodeFFprobeResponse(jsonData: data)
        } catch VideoMetadataError.processFailed(let message) {
            if allowNoStreams, message.contains("Stream specifier") {
                return FFprobeResponse(format: nil, streams: [])
            }
            throw VideoMetadataError.processFailed(message)
        }
    }

    private func decodeFFprobeResponse(jsonData: Data) throws -> FFprobeResponse {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(FFprobeResponse.self, from: jsonData)
        } catch {
            let message = String(data: jsonData, encoding: .utf8) ?? "<non-UTF8>"
            logger.error("Failed to decode ffprobe JSON: \(message)")
            throw VideoMetadataError.decodingFailed(error.localizedDescription)
        }
    }

    private func buildMetadata(format: FFprobeResponse.Format?, videoStreams: [FFprobeResponse.Stream], audioStreams: [FFprobeResponse.Stream]) throws -> VideoMetadata {
        let primaryVideoStream = videoStreams.first { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic != 1
        }

        let filteredAudioStreams = audioStreams.filter { $0.codecType == "audio" }

        let formatComment = format?.tags?.comment ?? primaryVideoStream?.tags?.comment ?? filteredAudioStreams.first?.tags?.comment

        let video = primaryVideoStream.map { stream -> VideoMetadata.VideoStream in
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
                isInterlaced: stream.fieldOrder.map {
                    let value = $0.lowercased()
                    return value != "progressive" && value != "unknown"
                }
            )
        }

        let audio = filteredAudioStreams.map { stream -> VideoMetadata.AudioStream in
            VideoMetadata.AudioStream(
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
            duration: format?.duration.flatMap { Double($0) },
            formatName: format?.formatName,
            containerLongName: format?.formatLongName,
            sizeBytes: format?.size.flatMap { Int64($0) },
            bitRate: format?.bitRate.flatMap { Int64($0) },
            comment: formatComment,
            videoStream: video,
            audioStreams: audio
        )
    }

}

private struct FFprobeResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case format
        case streams
    }

    let format: Format?
    let streams: [Stream]

    init(format: Format?, streams: [Stream]) {
        self.format = format
        self.streams = streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try container.decodeIfPresent(Format.self, forKey: .format)
        self.streams = try container.decodeIfPresent([Stream].self, forKey: .streams) ?? []
    }

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
            let attachedPic: Int?
        }
    }

    struct Tags: Decodable {
        let comment: String?
    }

    func toVideoMetadata() -> VideoMetadata {
        let formatMetadata = format

        // Find first video stream that is NOT an attached picture (cover art)
        let videoStream = streams.first { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic != 1
        }
        
        // Get all audio streams
        let audioStreams = streams.filter { $0.codecType == "audio" }

        let formatComment = formatMetadata?.tags?.comment ?? videoStream?.tags?.comment

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
                isInterlaced: stream.fieldOrder.map { 
                    let value = $0.lowercased()
                    // Field order values: progressive, tt (top first), bb (bottom first), tb, bt
                    // Anything other than "progressive" or "unknown" is interlaced
                    return value != "progressive" && value != "unknown"
                }
            )
        }

        let audio = audioStreams.map { stream -> VideoMetadata.AudioStream in
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
            audioStreams: audio
        )
    }
}
