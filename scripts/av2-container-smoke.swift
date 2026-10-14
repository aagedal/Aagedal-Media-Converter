// Compile alongside the app's IVF and Matroska sources to exercise the real muxer.
import Foundation

@main
struct AV2ContainerSmoke {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let segments = ["segment0.ivf", "segment1.ivf"].map { directory.appendingPathComponent($0) }
        let joined = directory.appendingPathComponent("joined.ivf")
        let result = try IVFConcatenator.concatenate(segmentURLs: segments, into: joined)
        precondition(result.totalFrames == 12 && result.keyframeIndices == [0, 6])
        var frames: [MatroskaMuxer.VideoFrame] = []
        try IVFConcatenator.forEachFrame(in: joined) { payload, timestamp in
            precondition(timestamp == UInt64(frames.count))
            frames.append(.init(data: payload, isKeyframe: result.keyframeIndices.contains(frames.count)))
        }
        let privateData = try Data(contentsOf: directory.appendingPathComponent("codec-private.bin"))
        precondition(!privateData.isEmpty)
        let video = MatroskaMuxer.VideoTrackInfo(
            codecPrivate: privateData, width: result.width, height: result.height,
            fpsNumerator: result.fpsNumerator, fpsDenominator: result.fpsDenominator
        )
        let aac = AV2AACParser.parse(try Data(contentsOf: directory.appendingPathComponent("audio.aac")))!
        let audio = MatroskaMuxer.AudioTrackInfo(
            codecID: "A_AAC", codecPrivate: aac.audioSpecificConfig,
            sampleRate: aac.sampleRate, channels: aac.channels
        )
        try MatroskaMuxer.write(
            to: directory.appendingPathComponent("joined.mkv"), video: video, videoFrames: frames,
            audio: audio, audioFrames: aac.frames.map { .init(data: $0, durationSamples: 1024) }
        )
    }
}
