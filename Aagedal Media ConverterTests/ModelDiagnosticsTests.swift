import Foundation
import Darwin
import XCTest
@testable import Aagedal_Media_Converter

final class ModelDiagnosticsTests: XCTestCase {
    func testModelFileRejectsMissingEmptyAndDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.bin")
        XCTAssertFalse(ModelDiagnostics.fileIsAvailable(at: file))
        XCTAssertFalse(ModelDiagnostics.fileIsAvailable(at: root))
        try Data().write(to: file)
        XCTAssertFalse(ModelDiagnostics.fileIsAvailable(at: file))
        try Data([1, 2, 3]).write(to: file)
        XCTAssertTrue(ModelDiagnostics.fileIsAvailable(at: file))
    }

    func testCacheRequiresSnapshotConfigurationAndReadableWeights() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent("refs")
        let snapshot = root.appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("abc123\n".utf8).write(to: refs.appendingPathComponent("main"))
        XCTAssertFalse(ModelDiagnostics.cacheIsAvailable(at: root))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let weights = snapshot.appendingPathComponent("model.safetensors")
        let blob = root.appendingPathComponent("weights")
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: blob)
        XCTAssertFalse(ModelDiagnostics.cacheIsAvailable(at: root))
        try Data([1]).write(to: blob)
        XCTAssertTrue(ModelDiagnostics.cacheIsAvailable(at: root))
        try Data().write(to: blob)
        XCTAssertFalse(ModelDiagnostics.cacheIsAvailable(at: root))
    }

    func testCacheRejectsMalformedAndOversizedReferences() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        for value in ["", ".", "..", "../outside", "/tmp/model", "abc/def", String(repeating: "a", count: 257)] {
            try Data(value.utf8).write(to: refs.appendingPathComponent("main"))
            XCTAssertFalse(ModelDiagnostics.cacheIsAvailable(at: root), value)
        }
    }

    func testCacheRejectsNamedPipeReferenceWithoutWaitingForWriter() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        let ref = refs.appendingPathComponent("main")
        XCTAssertEqual(mkfifo(ref.path, 0o600), 0)
        XCTAssertFalse(ModelDiagnostics.cacheIsAvailable(at: root))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
