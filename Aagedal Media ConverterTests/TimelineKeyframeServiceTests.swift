import XCTest
@testable import Aagedal_Media_Converter

final class TimelineKeyframeServiceTests: XCTestCase {
    func testLongRequestsAreBoundedAndNearbyRegionsReuseQuantization() {
        XCTAssertEqual(TimelineKeyframeService.boundedRange(0...7200, duration: 7200), 3540...3660)
        XCTAssertEqual(TimelineKeyframeService.boundedRange(11...39, duration: 100), 10...40)
        XCTAssertEqual(TimelineKeyframeService.boundedRange(12...38, duration: 100), 10...40)
        XCTAssertEqual(TimelineKeyframeService.boundedRange(-20...14, duration: 12), 0...12)
        XCTAssertNil(TimelineKeyframeService.boundedRange(0...10, duration: .infinity))
        XCTAssertNil(TimelineKeyframeService.boundedRange(120...130, duration: 100))
    }

    func testSourceIdentityDetectsReplacementAtSameURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let first = try XCTUnwrap(TimelineKeyframeService.SourceIdentity.read(url))
        try Data([2, 3]).write(to: url, options: .atomic)
        let second = try XCTUnwrap(TimelineKeyframeService.SourceIdentity.read(url))
        XCTAssertNotEqual(first, second)
    }

    func testInvalidSourceDoesNotClaimScannedCoverage() async throws {
        let result = try await TimelineKeyframeService().scan(
            url: URL(fileURLWithPath: "/nonexistent-keyframe-fixture.mov"), range: 0...10, duration: 10)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.scannedRange)
        XCTAssertTrue(result.times.isEmpty)
    }

    func testCancelledRequestThrowsWithoutPublishingCandidates() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TimelineKeyframeService().scan(
                url: URL(fileURLWithPath: "/unused.mov"), range: 0...10, duration: 10)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNativeScanSelectsVideoTrackAndKeepsBoundedCoverage() async throws {
        guard let executable = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) else {
            throw XCTSkip("Bundled ffmpeg unavailable in this test host")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SubprocessRequest(executableURL: executable, arguments: [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64:r=10:d=6",
            "-map", "0:v", "-map", "0:v", "-c:v", "libx264", "-g:v:0", "10", "-g:v:1", "20",
            "-sc_threshold", "0", "-bf", "0", "-y", url.path
        ], timeout: .seconds(15))
        let generated = try await SubprocessRunner().run(request)
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        guard generated.succeeded else { return }
        let service = TimelineKeyframeService()
        let first = try await service.scan(url: url, videoTrackOrdinal: 0, range: 0...5, duration: 6)
        let second = try await service.scan(url: url, videoTrackOrdinal: 1, range: 0...5, duration: 6)
        XCTAssertEqual(first.status, .complete)
        XCTAssertEqual(second.status, .complete)
        XCTAssertEqual(first.scannedRange, 0...Double(5).nextDown)
        XCTAssertFalse(first.scannedRange?.contains(5) ?? true, "Reader upper endpoint is exclusive")
        XCTAssertFalse(first.times.contains(5), "A sync sample at the exclusive end cannot establish coverage")
        XCTAssertTrue(first.times.contains { abs($0 - 1) < 0.01 })
        XCTAssertFalse(second.times.contains { abs($0 - 1) < 0.01 })
        XCTAssertTrue(second.times.contains { abs($0 - 2) < 0.01 })
        XCTAssertTrue(first.times.allSatisfy { (0...5).contains($0) })
        let missing = try await service.scan(url: url, videoTrackOrdinal: 2, range: 0...5, duration: 6)
        XCTAssertEqual(missing.status, .unavailable)
        try Data("replacement is not media".utf8).write(to: url, options: .atomic)
        let replacement = try await service.scan(url: url, videoTrackOrdinal: 0, range: 0...5, duration: 6)
        XCTAssertEqual(replacement.status, .unavailable)
        XCTAssertTrue(replacement.times.isEmpty, "Replacing a URL must not return its cached keyframes")
    }
}
