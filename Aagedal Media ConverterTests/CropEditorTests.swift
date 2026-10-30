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

final class CropEditorTests: XCTestCase {
    private let accuracy = 1e-9
    private let widescreen = CropEditor(displayAspectRatio: 16.0 / 9.0)

    // MARK: - Free-form resizing

    func testDraggingAnEdgePastTheFrameKeepsTheOppositeEdge() {
        let start = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

        let left = widescreen.resized(start, handle: .left, by: CGSize(width: -0.3, height: 0))
        XCTAssertEqual(left.x, 0, accuracy: accuracy)
        XCTAssertEqual(left.x + left.width, 0.7, accuracy: accuracy)

        let top = widescreen.resized(start, handle: .top, by: CGSize(width: 0, height: -0.5))
        XCTAssertEqual(top.y, 0, accuracy: accuracy)
        XCTAssertEqual(top.y + top.height, 0.7, accuracy: accuracy)
    }

    func testDraggingAnEdgePastTheOppositeEdgeStopsAtTheMinimumSize() {
        let start = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let result = widescreen.resized(start, handle: .left, by: CGSize(width: 0.9, height: 0))

        XCTAssertEqual(result.width, CropEditor.minimumFraction, accuracy: accuracy)
        XCTAssertEqual(result.x + result.width, 0.7, accuracy: accuracy)
    }

    func testCenterResizeIsSymmetricAndStopsAtTheNearestFrameEdge() {
        let start = CropRect(x: 0.1, y: 0.25, width: 0.4, height: 0.5)
        let result = widescreen.resized(start, handle: .right, by: CGSize(width: 0.3, height: 0), fromCenter: true)

        // Center x = 0.3, so the box can only grow to 0.0...0.6.
        XCTAssertEqual(result.x, 0, accuracy: accuracy)
        XCTAssertEqual(result.width, 0.6, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.25, accuracy: accuracy)
    }

    // MARK: - Aspect-ratio lock

    func testLockedCornerFollowsAVerticalDrag() {
        let start = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let ratio = widescreen.displayAspectRatio(of: start)
        let result = widescreen.resized(start, handle: .bottomRight, by: CGSize(width: 0, height: 0.2), aspectRatio: ratio)

        XCTAssertEqual(result.height, 0.5, accuracy: accuracy)
        XCTAssertEqual(widescreen.displayAspectRatio(of: result), ratio, accuracy: 1e-6)
        XCTAssertEqual(result.x, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.1, accuracy: accuracy)
    }

    func testLockedCornerStopsAtTheFrameWithoutMovingItsAnchor() {
        let start = CropRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        let result = widescreen.resized(start, handle: .bottomRight, by: CGSize(width: 1, height: 1), aspectRatio: 1)

        XCTAssertEqual(result.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.5, accuracy: accuracy)
        XCTAssertEqual(result.y + result.height, 1, accuracy: accuracy)
        XCTAssertEqual(widescreen.displayAspectRatio(of: result), 1, accuracy: 1e-6)
    }

    func testLockedTopLeftCornerKeepsTheBottomRightCorner() {
        let start = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let result = widescreen.resized(start, handle: .topLeft, by: CGSize(width: -0.1, height: -0.3), aspectRatio: 1)

        XCTAssertEqual(result.x + result.width, 0.6, accuracy: accuracy)
        XCTAssertEqual(result.y + result.height, 0.6, accuracy: accuracy)
        XCTAssertEqual(widescreen.displayAspectRatio(of: result), 1, accuracy: 1e-6)
    }

    func testLockedEdgeGrowsThePerpendicularAxisInsideTheFrame() {
        let start = CropRect(x: 0.3, y: 0.0, width: 0.2, height: 0.2)
        let result = widescreen.resized(start, handle: .right, by: CGSize(width: 0.2, height: 0), aspectRatio: 16.0 / 9.0)

        XCTAssertEqual(result.x, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.width, 0.4, accuracy: accuracy)
        XCTAssertEqual(result.height, 0.4, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(result.y, 0)
    }

    // MARK: - Fitting, scaling and positioning

    func testFittingAnUncroppedFrameGivesTheLargestBoxInTheRatio() {
        let square = widescreen.fitted(.fullFrame, to: 1)
        XCTAssertEqual(square.height, 1, accuracy: accuracy)
        XCTAssertEqual(square.width, 9.0 / 16.0, accuracy: accuracy)
        XCTAssertEqual(square.x, (1 - 9.0 / 16.0) / 2, accuracy: accuracy)

        let vertical = widescreen.fitted(.fullFrame, to: 9.0 / 16.0)
        XCTAssertEqual(widescreen.displayAspectRatio(of: vertical), 9.0 / 16.0, accuracy: 1e-6)
    }

    func testScalingALockedBoxKeepsItsRatioAndCenter() {
        let start = widescreen.fitted(CropRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), to: 1)
        let result = widescreen.scaled(start, by: 1.5, aspectRatio: 1)

        XCTAssertEqual(widescreen.displayAspectRatio(of: result), 1, accuracy: 1e-6)
        XCTAssertEqual(result.x + result.width / 2, start.x + start.width / 2, accuracy: 1e-9)
        XCTAssertEqual(result.width, start.width * 1.5, accuracy: 1e-9)
    }

    func testMatchingKeepsTheEditedDimension() {
        let start = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3)
        let keepWidth = widescreen.matching(start, aspectRatio: 1, keepingWidth: true)
        XCTAssertEqual(keepWidth.width, 0.5, accuracy: accuracy)
        XCTAssertEqual(widescreen.displayAspectRatio(of: keepWidth), 1, accuracy: 1e-6)

        let keepHeight = widescreen.matching(start, aspectRatio: 1, keepingWidth: false)
        XCTAssertEqual(keepHeight.height, 0.3, accuracy: accuracy)
        XCTAssertEqual(widescreen.displayAspectRatio(of: keepHeight), 1, accuracy: 1e-6)
    }

    func testClampingRepairsInvalidRects() {
        let result = widescreen.clamped(CropRect(x: -0.5, y: .nan, width: 1.5, height: 0))
        XCTAssertEqual(result, CropRect(x: 0, y: 0, width: 1, height: CropEditor.minimumFraction))
    }

    func testCenteringKeepsTheSize() {
        let result = widescreen.centered(CropRect(x: 0, y: 0, width: 0.4, height: 0.2))
        XCTAssertEqual(result.x, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.4, accuracy: accuracy)
    }

    // MARK: - Non-square pixels

    func testSquareLockOnAnamorphicSourceProducesSquareOutput() throws {
        // 1440x1080 stored with 4:3 pixels displays as 16:9.
        let frame = CropFrame(pixelWidth: 1440, pixelHeight: 1080, displayAspectRatio: 16.0 / 9.0)
        XCTAssertEqual(frame.pixelAspectRatio, 4.0 / 3.0, accuracy: 1e-9)

        var config = CropConfig(normalizedRect: .fullFrame)
        config.lockAspectRatio(.ratio1_1, using: CropEditor(frame: frame))

        let pixels = config.pixelRect(sourceWidth: frame.pixelWidth, sourceHeight: frame.pixelHeight)
        XCTAssertEqual(pixels, PixelCropRect(x: 315, y: 0, width: 810, height: 1080))
        let output = try XCTUnwrap(frame.outputSize(for: config))
        XCTAssertEqual(output.width, 1080)
        XCTAssertEqual(output.height, 1080)
    }

    func testDraggingOnAnamorphicSourceKeepsTheDisplayedRatio() throws {
        let frame = CropFrame(pixelWidth: 720, pixelHeight: 576, displayAspectRatio: 16.0 / 9.0)
        let editor = CropEditor(frame: frame)
        let start = editor.fitted(CropRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), to: 16.0 / 9.0)
        let config = CropConfig(normalizedRect: editor.resized(
            start, handle: .bottomRight, by: CGSize(width: 0.1, height: 0.05), aspectRatio: 16.0 / 9.0
        ))

        let output = try XCTUnwrap(frame.outputSize(for: config))
        XCTAssertEqual(Double(output.width) / Double(output.height), 16.0 / 9.0, accuracy: 0.02)
    }

    func testSquarePixelOutputSizeIsTheEvenPixelArea() throws {
        let frame = CropFrame(pixelWidth: 1920, pixelHeight: 1080)
        let config = CropConfig(normalizedRect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let output = try XCTUnwrap(frame.outputSize(for: config))
        XCTAssertEqual(output.width, 960)
        XCTAssertEqual(output.height, 540)
    }

    // MARK: - Rotation

    func testQuarterTurnStreamIsOrientedLikeTheDisplay() throws {
        let portrait = stream(width: 1920, height: 1080, par: (1, 1), dar: (9, 16), rotation: -90)
        XCTAssertEqual(portrait.orientedWidth, 1080)
        XCTAssertEqual(portrait.orientedHeight, 1920)
        XCTAssertEqual(try XCTUnwrap(portrait.orientedPixelAspectRatio), 1, accuracy: 1e-9)

        let geometry = try XCTUnwrap(FFMPEGCommandBuilder.SourceGeometry(stream: portrait))
        XCTAssertEqual(geometry.width, 1080)
        XCTAssertEqual(geometry.height, 1920)

        let upsideDown = stream(width: 1920, height: 1080, par: (1, 1), dar: (16, 9), rotation: 180)
        XCTAssertEqual(upsideDown.orientedWidth, 1920)
        XCTAssertEqual(upsideDown.orientedHeight, 1080)
    }

    func testRotatedAnamorphicStreamInvertsItsPixelAspectRatio() throws {
        // 1440x1080 with 4:3 pixels, turned a quarter: filters see 1080x1440 with 3:4 pixels.
        let rotated = stream(width: 1440, height: 1080, par: (4, 3), dar: (9, 16), rotation: 90)
        let geometry = try XCTUnwrap(FFMPEGCommandBuilder.SourceGeometry(stream: rotated))
        XCTAssertEqual(geometry.width, 1080)
        XCTAssertEqual(geometry.height, 1440)
        XCTAssertEqual(try XCTUnwrap(geometry.pixelAspectRatio), 3.0 / 4.0, accuracy: 1e-9)

        let frame = CropFrame(pixelWidth: 1080, pixelHeight: 1440, displayAspectRatio: 9.0 / 16.0)
        XCTAssertEqual(frame.pixelAspectRatio, 3.0 / 4.0, accuracy: 1e-9)
        var config = CropConfig(normalizedRect: .fullFrame)
        config.lockAspectRatio(.ratio1_1, using: CropEditor(frame: frame))
        let output = try XCTUnwrap(frame.outputSize(for: config))
        XCTAssertEqual(output.width, output.height)
    }

    func testAV2KeepsPortraitDimensionsForRotatedSources() async throws {
        // Isolated defaults: the user's saved AV2 resolution limit must not affect the result.
        let suite = "CropEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CodecResolutionLimit.unlimited.rawValue, forKey: AppConstants.av2ResolutionLimitKey)
        let settings = AV2Settings(defaults: defaults)

        let portrait = metadata(stream: stream(width: 1920, height: 1080, par: (1, 1), dar: (9, 16), rotation: -90))
        let uncropped = await AV2CommandBuilder.build(
            inputURL: URL(fileURLWithPath: "/unused/portrait.mov"),
            outputURL: URL(fileURLWithPath: "/unused/output.ivf"), trimStart: nil, trimEnd: nil,
            cropConfig: nil, metadataSource: .resolved(portrait), settings: settings
        )
        let full = try XCTUnwrap(uncropped)
        XCTAssertEqual(full.outputWidth, 1080)
        XCTAssertEqual(full.outputHeight, 1920)

        let cropped = await AV2CommandBuilder.build(
            inputURL: URL(fileURLWithPath: "/unused/portrait.mov"),
            outputURL: URL(fileURLWithPath: "/unused/output.ivf"), trimStart: nil, trimEnd: nil,
            cropConfig: CropConfig(normalizedRect: CropRect(x: 0, y: 0.25, width: 1, height: 0.5)),
            metadataSource: .resolved(portrait), settings: settings
        )
        let landscape = try XCTUnwrap(cropped)
        XCTAssertEqual(landscape.outputWidth, 1080)
        XCTAssertEqual(landscape.outputHeight, 960)
    }

    // MARK: - Hit testing

    func testHitTestingFindsHandlesAlongWholeEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 95, y: 95), in: rect), .topLeft)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 305, y: 205), in: rect), .bottomRight)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 150, y: 96), in: rect), .top)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 105, y: 150), in: rect), .left)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 200, y: 150), in: rect), .move)
        XCTAssertNil(CropHandle.hitTest(CGPoint(x: 50, y: 150), in: rect))
    }

    func testSmallBoxesStayMovable() {
        let rect = CGRect(x: 100, y: 100, width: 16, height: 16)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 108, y: 108), in: rect), .move)
        XCTAssertEqual(CropHandle.hitTest(CGPoint(x: 96, y: 108), in: rect), .left)
    }

    // MARK: - Helpers

    private func metadata(stream: VideoMetadata.VideoStream) -> VideoMetadata {
        VideoMetadata(
            duration: 1, formatName: "mov", containerLongName: "QuickTime / MOV",
            sizeBytes: nil, bitRate: nil, comment: nil, timecode: nil, timecodes: [],
            frameCount: nil, containerCreationDate: nil, containerModificationDate: nil,
            title: nil, artist: nil, gpsLatitude: nil, gpsLongitude: nil, gpsAltitude: nil,
            warnings: [], videoStreams: [stream], audioStreams: [], subtitleStreams: []
        )
    }

    private func stream(
        width: Int, height: Int, par: (Int, Int), dar: (Int, Int), rotation: Int?
    ) -> VideoMetadata.VideoStream {
        VideoMetadata.VideoStream(
            codec: "h264", codecLongName: nil, profile: nil,
            width: width, height: height,
            pixelFormat: "yuv420p", hasAlpha: false,
            pixelAspectRatio: VideoMetadata.Ratio(numerator: par.0, denominator: par.1),
            displayAspectRatio: VideoMetadata.Ratio(numerator: dar.0, denominator: dar.1),
            frameRate: nil, bitDepth: 8, bitRate: nil, duration: 1,
            chromaSubsampling: "4:2:0", colorPrimaries: nil, colorTransfer: nil,
            colorSpace: nil, colorRange: nil, chromaLocation: nil,
            fieldOrder: nil, isInterlaced: false, title: nil,
            isDefault: true, isForced: false,
            rotation: rotation
        )
    }
}
