import XCTest
@testable import Aagedal_Media_Converter

final class YTDLPPreviewStreamTests: XCTestCase {
    private func format(
        _ id: String, protocol proto: String = "https", vcodec: String?, acodec: String?,
        height: Int? = nil, tbr: Double? = nil, fps: Double? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = ["format_id": id, "url": "https://cdn.example/\(id)", "protocol": proto]
        if let vcodec { json["vcodec"] = vcodec }
        if let acodec { json["acodec"] = acodec }
        if let height { json["height"] = height; json["width"] = height * 16 / 9 }
        if let tbr { json["tbr"] = tbr }
        if let fps { json["fps"] = fps }
        return json.merging(extra) { $1 }
    }

    /// Mirrors yt-dlp-rs's YouTube formats: storyboards, HLS, DRC audio, many codecs.
    func testYouTubePrefersAdaptiveH264At720WithOriginalAACAudio() throws {
        let headers = ["User-Agent": "Mozilla/5.0", "Accept": "text/html,application/xhtml+xml"]
        let json: [String: Any] = ["fps": 60, "formats": [
            format("sb0", protocol: "mhtml", vcodec: "none", acodec: "none", height: 180),
            format("140-drc", vcodec: "none", acodec: "mp4a.40.2", tbr: 129),
            format("140", vcodec: "none", acodec: "mp4a.40.2", tbr: 129, extra: ["language_preference": 10]),
            format("251", vcodec: "none", acodec: "opus", tbr: 128, extra: ["language_preference": 10]),
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, tbr: 360),
            format("311", protocol: "m3u8_native", vcodec: "avc1.4D4020", acodec: "none", height: 720, tbr: 4553),
            format("136", vcodec: "avc1.4D401F", acodec: "none", height: 720, tbr: 1100, fps: 30,
                   extra: ["http_headers": headers]),
            format("247", vcodec: "vp9", acodec: "none", height: 720, tbr: 709),
            format("398", vcodec: "av01.0.08M.08", acodec: "none", height: 720, tbr: 898),
            format("299", vcodec: "avc1.64002A", acodec: "none", height: 1080, tbr: 3247),
        ]]

        let stream = try XCTUnwrap(YTDLPPreviewStream.select(fromMetadata: json))
        XCTAssertEqual(stream.videoURL.lastPathComponent, "136")
        XCTAssertEqual(stream.audioURL?.lastPathComponent, "140")
        XCTAssertEqual(stream.height, 720)
        XCTAssertEqual(stream.frameRate, 30)
        XCTAssertEqual(stream.httpHeaders, headers)
    }

    /// YouTube can refuse every H.264 URL of a probe while VP9 and HLS play,
    /// so fallbacks cover other codecs and protocols before near-duplicates.
    func testCandidatesFallBackAcrossCodecAndProtocolFamilies() {
        let json: [String: Any] = ["formats": [
            format("140", vcodec: "none", acodec: "mp4a.40.2", tbr: 129),
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360),
            format("136", vcodec: "avc1.4D401F", acodec: "none", height: 720, tbr: 1100),
            format("298", vcodec: "avc1.4D4020", acodec: "none", height: 720, tbr: 1500),
            format("247", vcodec: "vp9", acodec: "none", height: 720, tbr: 709),
            format("311", protocol: "m3u8_native", vcodec: "avc1.4D4020", acodec: "none", height: 720),
        ]]
        let candidates = YTDLPPreviewStream.candidates(fromMetadata: json)
        XCTAssertEqual(candidates.map(\.videoURL.lastPathComponent), ["136", "311", "247", "298"])
        XCTAssertTrue(candidates.allSatisfy { $0.audioURL?.lastPathComponent == "140" })
        XCTAssertEqual(YTDLPPreviewStream.select(fromMetadata: json)?.videoURL.lastPathComponent, "136")
    }

    func testMuxedStreamWinsWhenAtLeastAsTall() throws {
        let json: [String: Any] = ["formats": [
            format("hls-720", protocol: "m3u8_native", vcodec: "avc1", acodec: "mp4a", height: 720),
            format("http-720", vcodec: "avc1", acodec: "mp4a", height: 720),
            format("http-1080", vcodec: "avc1", acodec: "mp4a", height: 1080),
        ]]
        let stream = try XCTUnwrap(YTDLPPreviewStream.select(fromMetadata: json))
        XCTAssertEqual(stream.videoURL.lastPathComponent, "http-720")
        XCTAssertNil(stream.audioURL)
    }

    func testOnlyTallFormatsPickTheSmallest() throws {
        let json: [String: Any] = ["formats": [
            format("2160", vcodec: "avc1", acodec: "mp4a", height: 2160),
            format("1080", vcodec: "avc1", acodec: "mp4a", height: 1080),
        ]]
        XCTAssertEqual(try XCTUnwrap(YTDLPPreviewStream.select(fromMetadata: json)).height, 1080)
    }

    func testUnknownCodecsWithDimensionsCountAsMuxedVideo() throws {
        let json: [String: Any] = ["formats": [format("mp4", vcodec: nil, acodec: nil, height: 480)]]
        let stream = try XCTUnwrap(YTDLPPreviewStream.select(fromMetadata: json))
        XCTAssertEqual(stream.videoURL.lastPathComponent, "mp4")
        XCTAssertNil(stream.audioURL)
    }

    func testSingleFormatInfoDictUsesTopLevelURL() throws {
        let json = format("direct", vcodec: "h264", acodec: "aac", height: 720)
        XCTAssertEqual(try XCTUnwrap(YTDLPPreviewStream.select(fromMetadata: json)).videoURL.lastPathComponent, "direct")
    }

    func testUnplayableFormatsGiveNoPreview() {
        let json: [String: Any] = ["formats": [
            format("sb0", protocol: "mhtml", vcodec: "none", acodec: "none", height: 90),
            format("dash", protocol: "http_dash_segments", vcodec: "avc1", acodec: "none", height: 720),
            format("audio", vcodec: "none", acodec: "mp4a.40.2"),
        ]]
        XCTAssertNil(YTDLPPreviewStream.select(fromMetadata: json))
    }
}
