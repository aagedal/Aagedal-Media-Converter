// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import XCTest
@testable import Aagedal_Media_Converter

final class TrimEditorTests: XCTestCase {
    private let accuracy = 1e-9
    /// 10 s at 25 fps: one frame is 0.04 s.
    private let editor = TrimEditor(duration: 10, frameRate: 25)

    func testStepIsOneFrameOrTheFallback() {
        XCTAssertEqual(editor.step, 0.04, accuracy: accuracy)
        XCTAssertEqual(TrimEditor(duration: 10, frameRate: 30000.0 / 1001.0).step, 1001.0 / 30000.0, accuracy: accuracy)
        XCTAssertEqual(TrimEditor(duration: 10, frameRate: nil).step, TrimEditor.fallbackStep)
        XCTAssertEqual(TrimEditor(duration: 10, frameRate: 0).step, TrimEditor.fallbackStep)
    }

    func testHandlesSnapToFramesAndKeepOneFrameApart() {
        XCTAssertEqual(editor.start(1.013, end: 5), 1.0, accuracy: accuracy)
        XCTAssertEqual(editor.start(6, end: 5), 4.96, accuracy: accuracy)
        XCTAssertEqual(editor.start(-1, end: 5), 0, accuracy: accuracy)

        XCTAssertEqual(editor.end(4.987, start: 1), 5.0, accuracy: accuracy)
        XCTAssertEqual(editor.end(0.5, start: 1), 1.04, accuracy: accuracy)
        XCTAssertEqual(editor.end(12, start: 1), 10, accuracy: accuracy)
    }

    func testSymmetricScalingStopsEvenlyAtTheBounds() {
        let grown = editor.symmetric(start: 2, end: 9, growth: 3)
        XCTAssertEqual(grown.start, 1, accuracy: accuracy)
        XCTAssertEqual(grown.end, 10, accuracy: accuracy)

        let shrunk = editor.symmetric(start: 4, end: 6, growth: -5)
        XCTAssertEqual(shrunk.end - shrunk.start, 0.04, accuracy: accuracy)
        XCTAssertEqual((shrunk.start + shrunk.end) / 2, 5, accuracy: accuracy)
    }

    func testSlidingKeepsTheRangeLengthExactly() {
        let moved = editor.slid(start: 1.013, end: 3.027, by: 0.51)
        XCTAssertEqual(moved.end - moved.start, 2.014, accuracy: accuracy)
        XCTAssertEqual(moved.start, 1.013 + 0.52, accuracy: accuracy)

        let atStart = editor.slid(start: 1.013, end: 3.027, by: -5)
        XCTAssertEqual(atStart.start, 0, accuracy: accuracy)
        XCTAssertEqual(atStart.end, 2.014, accuracy: accuracy)

        let atEnd = editor.slid(start: 1, end: 3, by: 20)
        XCTAssertEqual(atEnd.start, 8, accuracy: accuracy)
        XCTAssertEqual(atEnd.end, 10, accuracy: accuracy)
    }

    func testInPointPastTheOutPointClearsTheOutPoint() {
        let past = editor.settingIn(7, end: 5)
        XCTAssertEqual(past.start, 7)
        XCTAssertNil(past.end)

        let same = editor.settingIn(5, end: 5)
        XCTAssertEqual(same.start, 5)
        XCTAssertNil(same.end)

        let before = editor.settingIn(2, end: 5)
        XCTAssertEqual(before.start, 2)
        XCTAssertEqual(before.end, 5)
    }

    func testOutPointBeforeTheInPointClearsTheInPoint() {
        let before = editor.settingOut(2, start: 4)
        XCTAssertNil(before.start)
        XCTAssertEqual(before.end, 2)

        let after = editor.settingOut(6, start: 4)
        XCTAssertEqual(after.start, 4)
        XCTAssertEqual(after.end, 6)
    }

    func testPointsWithinHalfAFrameOfTheEdgesAreCleared() {
        XCTAssertNil(editor.settingIn(0.015, end: nil).start)
        XCTAssertEqual(editor.settingIn(0.04, end: nil).start, 0.04)
        XCTAssertNil(editor.settingOut(9.985, start: nil).end)
        XCTAssertEqual(editor.settingOut(9.96, start: nil).end, 9.96)
    }

    func testInPointAtTheVeryEndLeavesOneFrame() throws {
        let range = editor.settingIn(10, end: nil)
        XCTAssertEqual(try XCTUnwrap(range.start), 9.96, accuracy: accuracy)
        XCTAssertNil(range.end)
    }

    func testTrimFrameRateUsesTheVideoStreamOnly() {
        var item = VideoItem(
            url: URL(fileURLWithPath: "/tmp/clip.mov"), name: "clip",
            size: 0, duration: "--:--", thumbnailData: nil, status: .waiting,
            progress: 0, eta: nil, outputURL: nil
        )
        XCTAssertNil(item.trimFrameRate)
        item.hasVideoStream = false
        XCTAssertNil(item.trimFrameRate)
    }
}
