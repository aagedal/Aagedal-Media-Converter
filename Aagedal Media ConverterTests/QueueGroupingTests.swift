import XCTest
@testable import Aagedal_Media_Converter

final class QueueGroupingTests: XCTestCase {
    private func clip(_ name: String) -> VideoItem {
        VideoItem(url: URL(fileURLWithPath: "/tmp/\(name).mov"), name: name, size: 0, duration: "",
                  status: .waiting, progress: 0, eta: nil, outputURL: nil)
    }

    func testGroupingUsesDisplayOrderAndPreservesTrimsAndOtherRows() {
        var first = clip("First")
        first.trimStart = 2
        first.trimEnd = 8
        let middle = clip("Middle")
        let last = clip("Last")
        var files = [last, middle, first]
        var groups: [EncodingGroup] = []
        var order = [first.id, middle.id, last.id]
        var group = EncodingGroup(name: "New Group")
        XCTAssertTrue(QueueGrouping.move([last.id, first.id], into: &group,
                                         files: &files, groups: &groups, order: &order))
        XCTAssertEqual(group.items.map(\.id), [first.id, last.id])
        XCTAssertEqual(group.items.first?.trimStart, 2)
        XCTAssertEqual(group.items.first?.trimEnd, 8)
        XCTAssertEqual(files.map(\.id), [middle.id])
        XCTAssertEqual(order, [group.id, middle.id])
        XCTAssertEqual(groups, [group])
    }

    func testMovingFromGroupsRenumbersRemainingSequentialNames() {
        let first = clip("First")
        let second = clip("Second")
        var source = EncodingGroup(name: "Source", items: [first, second], sequentialNamingEnabled: true)
        source.normalizeSequentialNaming()
        var files: [VideoItem] = []
        var groups = [source]
        var order = [source.id]
        var destination = EncodingGroup(name: "Destination", sequentialNamingEnabled: true)
        XCTAssertTrue(QueueGrouping.move([first.id], into: &destination,
                                         files: &files, groups: &groups, order: &order))
        XCTAssertEqual(groups[0].items.map(\.id), [second.id])
        XCTAssertEqual(groups[0].items[0].outputFileNameOverride, "Source_001")
        XCTAssertEqual(destination.items[0].outputFileNameOverride, "Destination_001")
        XCTAssertEqual(order, [destination.id, source.id])
    }

    func testMixedBusySelectionIsRejectedWithoutMovingAnyFiles() {
        let first = clip("First")
        var busy = clip("Busy")
        busy.status = .converting
        var files = [first, busy]
        var groups: [EncodingGroup] = []
        var order = [first.id, busy.id]
        var group = EncodingGroup(name: "New Group")
        XCTAssertFalse(QueueGrouping.move([first.id, busy.id], into: &group,
                                          files: &files, groups: &groups, order: &order))
        XCTAssertEqual(files, [first, busy])
        XCTAssertTrue(groups.isEmpty)
        XCTAssertEqual(order, [first.id, busy.id])
    }

    func testUnknownSelectionAndConvertingSourceGroupAreRejected() {
        let first = clip("First")
        var busy = clip("Busy")
        busy.status = .converting
        let source = EncodingGroup(name: "Source", items: [first, busy])
        XCTAssertFalse(QueueGrouping.canMove([first.id], files: [], groups: [source]))
        XCTAssertFalse(QueueGrouping.canMove([UUID()], files: [first], groups: []))
        XCTAssertFalse(QueueGrouping.canMove([], files: [first], groups: []))
    }
}
