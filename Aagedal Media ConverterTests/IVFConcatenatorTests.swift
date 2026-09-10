import XCTest
@testable import Aagedal_Media_Converter

final class IVFConcatenatorTests: XCTestCase {
    func testConcatenationPreservesPayloadsAndRestampsSegmentBoundaries() throws {
        try withDirectory { directory in
            let first = directory.appendingPathComponent("first.ivf")
            let second = directory.appendingPathComponent("second.ivf")
            let output = directory.appendingPathComponent("output.ivf")
            try fixture(payloads: [[1, 2], [3]]).write(to: first)
            try fixture(payloads: [[4, 5, 6]]).write(to: second)
            let result = try IVFConcatenator.concatenate(segmentURLs: [first, second], into: output)
            XCTAssertEqual(result.totalFrames, 3)
            XCTAssertEqual(result.keyframeIndices, [0, 2])
            XCTAssertEqual(IVFHeaderParser.parse(url: output)?.frameCount, 3)
            var payloads: [Data] = []
            var timestamps: [UInt64] = []
            try IVFConcatenator.forEachFrame(in: output) { payloads.append($0); timestamps.append($1) }
            XCTAssertEqual(payloads, [Data([1, 2]), Data([3]), Data([4, 5, 6])])
            XCTAssertEqual(timestamps, [0, 1, 2])
        }
    }

    func testMismatchedAndInvalidRatesFailBeforeCreatingOutput() throws {
        try withDirectory { directory in
            let first = directory.appendingPathComponent("first.ivf")
            let second = directory.appendingPathComponent("second.ivf")
            let output = directory.appendingPathComponent("output.ivf")
            try fixture(payloads: [[1]]).write(to: first)
            for rate in [0, 25] {
                try fixture(payloads: [[2]], rate: rate).write(to: second)
                XCTAssertThrowsError(try IVFConcatenator.concatenate(segmentURLs: [first, second], into: output))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testDamagedRecordsRejectAndRemovePartialOutput() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("input.ivf")
            let output = directory.appendingPathComponent("output.ivf")
            let valid = fixture(payloads: [[1, 2], [3, 4]])
            var wrongCount = valid
            wrongCount[24] = 3
            var extendedHeader = valid
            extendedHeader[6] = 40
            let damaged = [Data(valid.dropLast()), valid + Data([1]), wrongCount,
                           extendedHeader, fixture(payloads: [[]]), fixture(payloads: [])]
            for data in damaged {
                try data.write(to: input)
                XCTAssertThrowsError(try IVFConcatenator.concatenate(segmentURLs: [input], into: output))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testUnspecifiedFrameCountIsResolvedFromCompleteRecords() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("input.ivf")
            var data = fixture(payloads: [[7], [8]])
            data[24] = 0
            try data.write(to: input)
            var count = 0
            try IVFConcatenator.forEachFrame(in: input) { _, _ in count += 1 }
            XCTAssertEqual(count, 2)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func fixture(payloads: [[UInt8]], rate: Int = 24) -> Data {
        var data = Data("DKIF".utf8)
        func append(_ value: Int, bytes: Int) {
            for shift in 0..<bytes { data.append(UInt8((value >> (shift * 8)) & 255)) }
        }
        append(0, bytes: 2)
        append(32, bytes: 2)
        data.append(Data("AV02".utf8))
        append(16, bytes: 2)
        append(16, bytes: 2)
        append(rate, bytes: 4)
        append(1, bytes: 4)
        append(payloads.count, bytes: 4)
        append(0, bytes: 4)
        for payload in payloads {
            append(payload.count, bytes: 4)
            append(42, bytes: 8)
            data.append(contentsOf: payload)
        }
        return data
    }
}
