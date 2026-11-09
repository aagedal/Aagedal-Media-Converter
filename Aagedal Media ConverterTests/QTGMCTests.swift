// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import XCTest
@testable import Aagedal_Media_Converter

final class QTGMCTests: XCTestCase {
    // MARK: - Y4M

    func testY4MHeaderParsesTenBitInterlacedLayout() throws {
        let format = try Y4MFormat(headerLine: "YUV4MPEG2 W720 H576 F25:1 It A16:15 C422p10 XYSCSS=422P10 XCOLORRANGE=LIMITED")
        XCTAssertEqual(format.width, 720)
        XCTAssertEqual(format.height, 576)
        XCTAssertEqual(format.interlacing, .topFieldFirst)
        XCTAssertEqual(format.bitDepth, 10)
        XCTAssertEqual(format.maxSampleValue, 1023)
        XCTAssertEqual(format.chromaShiftX, 1)
        XCTAssertEqual(format.chromaShiftY, 0)
        XCTAssertEqual(format.frameByteCount, 720 * 576 * 2 + 2 * 360 * 576 * 2)
        XCTAssertEqual(
            format.headerLine(progressiveAtRateMultiplier: 2),
            "YUV4MPEG2 W720 H576 F50:1 Ip A16:15 C422p10 XYSCSS=422P10 XCOLORRANGE=LIMITED\n"
        )
    }

    func testY4MHeaderReducesNTSCRateAndHandlesOddChromaSizes() throws {
        let format = try Y4MFormat(headerLine: "YUV4MPEG2 W721 H487 F30000:1001 Ib A10:11 C420mpeg2")
        XCTAssertEqual(format.interlacing, .bottomFieldFirst)
        XCTAssertEqual(format.planeWidth(1), 361)
        XCTAssertEqual(format.planeHeight(1), 244)
        XCTAssertEqual(format.bytesPerSample, 1)
        XCTAssertTrue(format.headerLine(progressiveAtRateMultiplier: 2).contains(" F60000:1001 Ip "))
    }

    func testY4MRejectsAlphaAndUnknownColorSpaces() {
        XCTAssertThrowsError(try Y4MFormat(headerLine: "YUV4MPEG2 W8 H8 F25:1 C444alpha"))
        XCTAssertThrowsError(try Y4MFormat(headerLine: "YUV4MPEG2 W8 H8 F25:1 Cmono"))
        XCTAssertThrowsError(try Y4MFormat(headerLine: "RIFF W8 H8"))
    }

    func testY4MReaderAssemblesFramesFromArbitraryChunks() throws {
        let header = "YUV4MPEG2 W4 H2 F25:1 It A1:1 C444\n"
        let frameSize = 4 * 2 * 3
        let frames: [[UInt8]] = (0..<3).map { index in (0..<frameSize).map { UInt8(($0 * 7 + index * 31) & 0xFF) } }
        var stream = Data(header.utf8)
        for (index, frame) in frames.enumerated() {
            // Frame payloads may contain newlines; a frame header may carry parameters.
            stream.append(Data((index == 1 ? "FRAME Ixyz\n" : "FRAME\n").utf8))
            stream.append(contentsOf: frame.map { $0 == 3 ? 0x0A : $0 })
        }

        var reader = Y4MReader()
        var received: [[UInt8]] = []
        var offset = 0
        for size in [1, 5, 2, 40, 3, 100] where offset < stream.count {
            let end = min(stream.count, offset + size)
            try reader.consume(stream.subdata(in: offset..<end)) { format, bytes in
                XCTAssertEqual(format.frameByteCount, frameSize)
                received.append([UInt8](bytes))
            }
            offset = end
        }
        XCTAssertEqual(received, frames.map { frame in frame.map { $0 == 3 ? 0x0A : $0 } })
        XCTAssertEqual(reader.pendingByteCount, 0)
    }

    // MARK: - Plan and command adaptation

    private func interlacedStream(
        fieldOrder: String? = "tt",
        chroma: String = "4:2:2",
        bitDepth: Int = 10,
        interlaced: Bool? = true
    ) -> VideoMetadata.VideoStream {
        VideoMetadata.VideoStream(
            codec: "prores", codecLongName: nil, profile: nil,
            width: 1920, height: 1080, pixelFormat: "yuv422p10le", hasAlpha: false,
            pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
            displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
            frameRate: VideoMetadata.FrameRate(frameRateString: "25/1"),
            bitDepth: bitDepth, bitRate: nil, duration: 60, chromaSubsampling: chroma,
            colorPrimaries: "bt709", colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv",
            chromaLocation: nil, fieldOrder: fieldOrder, isInterlaced: interlaced,
            title: nil, isDefault: true, isForced: false
        )
    }

    private let qtgmc = DeinterlacerSettings(engine: .qtgmc, preset: .medium, doubleRate: true)

    func testPlanRequiresQTGMCAndAnInterlacedSource() {
        let url = URL(fileURLWithPath: "/media/in.mov")
        XCTAssertNil(QTGMCPipelinePlan(inputURL: url, stream: interlacedStream(), trimStart: nil, trimEnd: nil, settings: .standard))
        XCTAssertNil(QTGMCPipelinePlan(inputURL: url, stream: interlacedStream(interlaced: false), trimStart: nil, trimEnd: nil, settings: qtgmc))
        XCTAssertNil(QTGMCPipelinePlan(inputURL: url, stream: interlacedStream(interlaced: nil), trimStart: nil, trimEnd: nil, settings: qtgmc))
        XCTAssertNil(QTGMCPipelinePlan(inputURL: url, stream: nil, trimStart: nil, trimEnd: nil, settings: qtgmc))
        XCTAssertNotNil(QTGMCPipelinePlan(inputURL: url, stream: interlacedStream(), trimStart: nil, trimEnd: nil, settings: qtgmc))
    }

    func testPlanDecodesWithPrerollAndSeeksTheSourceInput() throws {
        let url = URL(fileURLWithPath: "/media/in.mov")
        let plan = try XCTUnwrap(QTGMCPipelinePlan(
            inputURL: url, stream: interlacedStream(fieldOrder: "bb"), trimStart: 10, trimEnd: 12, settings: qtgmc
        ))
        XCTAssertFalse(plan.topFieldFirst)
        XCTAssertEqual(plan.decoderPixelFormat, "yuv422p10le")
        // Three frames of pre-roll at 25 fps, dropped as six double-rate output frames.
        XCTAssertEqual(plan.droppedOutputFrames, 6)
        let seek = try XCTUnwrap(plan.decoderArguments.firstIndex(of: "-ss"))
        XCTAssertEqual(Double(plan.decoderArguments[seek + 1]) ?? -1, 9.88, accuracy: 0.0005)
        let duration = try XCTUnwrap(plan.decoderArguments.firstIndex(of: "-t"))
        XCTAssertEqual(Double(plan.decoderArguments[duration + 1]) ?? -1, 2.0 + 7.0 / 25.0, accuracy: 0.0005)
        XCTAssertEqual(Array(plan.decoderArguments.suffix(5)), ["-strict", "-1", "-f", "yuv4mpegpipe", "pipe:1"])
        XCTAssertEqual(
            Array(plan.encoderInputArguments.prefix(6)),
            ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        )
        XCTAssertEqual(
            Array(plan.encoderInputArguments.suffix(8)),
            ["-f", "yuv4mpegpipe", "-i", "pipe:0", "-ss", "10.000", "-i", url.path]
        )
    }

    func testPlanWithoutTrimDecodesFromTheStart() throws {
        let plan = try XCTUnwrap(QTGMCPipelinePlan(
            inputURL: URL(fileURLWithPath: "/media/in.mxf"),
            stream: interlacedStream(chroma: "4:2:0", bitDepth: 8),
            trimStart: nil, trimEnd: nil,
            settings: DeinterlacerSettings(engine: .qtgmc, preset: .fast, doubleRate: false)
        ))
        XCTAssertFalse(plan.decoderArguments.contains("-ss"))
        XCTAssertFalse(plan.decoderArguments.contains("-t"))
        XCTAssertEqual(plan.decoderPixelFormat, "yuv420p")
        XCTAssertEqual(plan.droppedOutputFrames, 0)
        XCTAssertFalse(plan.doubleRate)
        XCTAssertEqual(plan.parameters, QTGMCParameters(preset: .fast))
    }

    func testDecoderPixelFormatKeepsChromaLayoutAndDepth() {
        XCTAssertEqual(QTGMCPipelinePlan.decoderPixelFormat(chromaSubsampling: "4:1:1", bitDepth: 8), "yuv411p")
        XCTAssertEqual(QTGMCPipelinePlan.decoderPixelFormat(chromaSubsampling: "4:1:1", bitDepth: 10), "yuv422p10le")
        XCTAssertEqual(QTGMCPipelinePlan.decoderPixelFormat(chromaSubsampling: "4:4:4", bitDepth: 12), "yuv444p12le")
        XCTAssertEqual(QTGMCPipelinePlan.decoderPixelFormat(chromaSubsampling: nil, bitDepth: nil), "yuv422p")
        XCTAssertEqual(QTGMCPipelinePlan.decoderPixelFormat(chromaSubsampling: "4:2:0", bitDepth: 16), "yuv420p16le")
    }

    func testRemovingBuiltInDeinterlacerKeepsTheRestOfTheChain() {
        let stage = QTGMCPipelinePlan.builtInDeinterlaceStage
        XCTAssertEqual(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: "\(stage),scale=1920:1080").0, "scale=1920:1080")
        XCTAssertEqual(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: "crop=10:10,\(stage)").0, "crop=10:10")
        XCTAssertEqual(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: "a,\(stage),b").0, "a,b")
        XCTAssertEqual(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: stage).0, "null")
        XCTAssertEqual(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: "[0:v]\(stage)[v]").0, "[0:v]null[v]")
        XCTAssertFalse(QTGMCPipelinePlan.removingBuiltInDeinterlacer(from: "yadif=1").1)
    }

    func testEncoderArgumentsReadVideoFromThePipeAndEverythingElseFromTheSource() throws {
        let stage = QTGMCPipelinePlan.builtInDeinterlaceStage
        let built = [
            "-hide_banner", "-y", "-ss", "10.000",
            "-color_primaries", "bt709", "-f", "yuv4mpegpipe", "-i", "pipe:0",
            "-ss", "10.000", "-i", "/media/in.mov",
            "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-map", "-0:d",
            "-vf", "\(stage),scale=1920:1080",
            "-filter_complex", "[0:a:0][0:a:1]amerge=inputs=2[a]",
            "-map_chapters", "0", "-map_metadata:s:a:0", "0:s:a:0",
            "-t", "2.000", "/media/out.mov",
        ]
        let adapted = try XCTUnwrap(QTGMCPipelinePlan.encoderArguments(fromBuilt: built))
        XCTAssertEqual(adapted, [
            "-hide_banner", "-y",
            "-color_primaries", "bt709", "-f", "yuv4mpegpipe", "-i", "pipe:0",
            "-ss", "10.000", "-i", "/media/in.mov",
            "-map", "0:v:0", "-map", "1:a?", "-map", "1:s?", "-map", "-1:d",
            "-vf", "scale=1920:1080",
            "-filter_complex", "[1:a:0][1:a:1]amerge=inputs=2[a]",
            "-map_chapters", "1", "-map_metadata:s:a:0", "1:s:a:0",
            "-t", "2.000", "/media/out.mov",
        ])
    }

    func testEncoderArgumentsAddSourceMetadataAndExpandWholeInputMaps() throws {
        let built = [
            "-f", "yuv4mpegpipe", "-i", "pipe:0", "-i", "/media/in.mov",
            "-map", "0", "-vf", QTGMCPipelinePlan.builtInDeinterlaceStage, "/media/out.mkv",
        ]
        let adapted = try XCTUnwrap(QTGMCPipelinePlan.encoderArguments(fromBuilt: built))
        XCTAssertEqual(adapted, [
            "-f", "yuv4mpegpipe", "-i", "pipe:0", "-i", "/media/in.mov",
            "-map", "0:v:0", "-map", "1", "-map", "-1:v", "-vf", "null",
            "-map_metadata", "1", "/media/out.mkv",
        ])
    }

    func testEncoderArgumentsAreNilWhenTheExportDoesNotDeinterlace() {
        XCTAssertNil(QTGMCPipelinePlan.encoderArguments(fromBuilt: [
            "-f", "yuv4mpegpipe", "-i", "pipe:0", "-i", "/media/in.mov", "-vf", "scale=640:360", "/out.mp4",
        ]))
        XCTAssertNil(QTGMCPipelinePlan.encoderArguments(fromBuilt: [
            "-i", "/media/in.mov", "-vf", QTGMCPipelinePlan.builtInDeinterlaceStage, "/out.mp4",
        ]))
    }

    // MARK: - Frame transform

    private final class FakeDeinterlacer: QTGMCDeinterlacing {
        var processed = 0
        var failure: Error?

        func process(frame: UnsafeRawBufferPointer) throws -> [Data] {
            if let failure { throw failure }
            processed += 1
            // Two output frames per input frame, tagged with a running counter.
            return [Data(repeating: UInt8(2 * processed - 1), count: frame.count),
                    Data(repeating: UInt8(2 * processed), count: frame.count)]
        }

        func finish() throws -> [Data] { [] }
    }

    private final class Collector: @unchecked Sendable {
        var data = Data()
        var closed = false
    }

    private func y4mStream(frames: Int) -> Data {
        var stream = Data("YUV4MPEG2 W2 H2 F25:1 It A1:1 C444\n".utf8)
        for index in 0..<frames {
            stream.append(Data("FRAME\n".utf8))
            stream.append(Data(repeating: UInt8(100 + index), count: 12))
        }
        return stream
    }

    private func makePlan(droppingPreroll trimStart: Double?) throws -> QTGMCPipelinePlan {
        try XCTUnwrap(QTGMCPipelinePlan(
            inputURL: URL(fileURLWithPath: "/media/in.mov"), stream: interlacedStream(),
            trimStart: trimStart, trimEnd: nil, settings: qtgmc
        ))
    }

    func testTransformWritesDoubledHeaderAndDropsPrerollFrames() throws {
        let fake = FakeDeinterlacer()
        let plan = try makePlan(droppingPreroll: 1)  // 3 frames of pre-roll → 6 dropped outputs
        let transform = QTGMCFrameTransform(plan: plan, weightsURL: URL(fileURLWithPath: "/dev/null")) { format, tff, _, _ in
            XCTAssertTrue(tff)
            XCTAssertEqual(format.width, 2)
            return fake
        }
        let collector = Collector()
        let writer = SubprocessStandardInputWriter(write: { collector.data.append($0) }, finish: { collector.closed = true })
        let stream = y4mStream(frames: 5)
        try transform.process(stream.prefix(20), into: writer)
        try transform.process(stream.dropFirst(20), into: writer)
        try transform.finish(into: writer)

        var reader = Y4MReader()
        var tags: [UInt8] = []
        try reader.consume(collector.data) { format, bytes in
            XCTAssertEqual(format.frameRateNumerator, 50)
            XCTAssertEqual(format.interlacing, .progressive)
            tags.append(bytes[0])
        }
        XCTAssertEqual(tags, [7, 8, 9, 10])
        XCTAssertNil(transform.failureReason)
    }

    func testTransformRecordsProcessingFailuresButNotAClosedEncoder() throws {
        let failing = FakeDeinterlacer()
        failing.failure = QTGMCMetalDeinterlacer.DeinterlacerError.gpuFailure("test")
        let plan = try makePlan(droppingPreroll: nil)
        let transform = QTGMCFrameTransform(plan: plan, weightsURL: URL(fileURLWithPath: "/dev/null")) { _, _, _, _ in failing }
        let writer = SubprocessStandardInputWriter(write: { _ in }, finish: {})
        XCTAssertThrowsError(try transform.process(y4mStream(frames: 1), into: writer))
        XCTAssertNotNil(transform.failureReason)

        struct Closed: Error {}
        let closedTransform = QTGMCFrameTransform(plan: plan, weightsURL: URL(fileURLWithPath: "/dev/null")) { _, _, _, _ in FakeDeinterlacer() }
        let closedWriter = SubprocessStandardInputWriter(write: { _ in throw Closed() }, finish: {})
        XCTAssertThrowsError(try closedTransform.process(y4mStream(frames: 1), into: closedWriter))
        XCTAssertNil(closedTransform.failureReason)
    }

    func testTransformWithoutVideoFailsOnFinish() throws {
        let transform = QTGMCFrameTransform(plan: try makePlan(droppingPreroll: nil), weightsURL: URL(fileURLWithPath: "/dev/null")) { _, _, _, _ in
            FakeDeinterlacer()
        }
        XCTAssertThrowsError(try transform.finish(into: SubprocessStandardInputWriter(write: { _ in }, finish: {})))
        XCTAssertNotNil(transform.failureReason)
    }

    // MARK: - Pipeline transform hook

    private final class UppercasingTransform: SubprocessPipelineTransform, @unchecked Sendable {
        func process(_ data: Data, into output: SubprocessStandardInputWriter) throws {
            try output.write(Data(String(decoding: data, as: UTF8.self).uppercased().utf8))
        }

        func finish(into output: SubprocessStandardInputWriter) throws {
            try output.write(Data("!".utf8))
        }
    }

    func testSubprocessPipelineAppliesTransformAndFlushesIt() async throws {
        let result = try await SubprocessRunner().runPipeline(
            producer: SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'deinterlace me'"],
                standardOutputCaptureLimit: 0
            ),
            consumer: SubprocessRequest(executableURL: URL(fileURLWithPath: "/bin/cat")),
            transform: UppercasingTransform()
        )
        XCTAssertEqual(result.consumer.standardOutputText, "DEINTERLACE ME!")
        guard case .completed(let producer) = result.producer else {
            return XCTFail("Expected the producer to complete")
        }
        XCTAssertTrue(producer.succeeded)
    }

    // MARK: - NNEDI3 weights and Metal pipeline

    func testBundledWeightsLoadSelectedModel() throws {
        let url = try XCTUnwrap(QTGMCNNEDIWeights.bundledURL(), "nnedi3_weights.bin must be bundled")
        let weights = try QTGMCNNEDIWeights.load(from: url, neighbourhood: .s16x6, neurons: .n32, qualityPasses: 2)
        XCTAssertEqual(weights.prescreener.count, 4 * 64 + 4 + 16 + 4)
        XCTAssertEqual(weights.predictor.count, 2 * (2 * 32 * 96 + 2 * 32))
        XCTAssertTrue(weights.predictor.allSatisfy(\.isFinite))
        // Prescreener layer-0 kernels are mean-free after FFmpeg's adjustment.
        for neuron in 0..<4 {
            let sum = weights.prescreener[(neuron * 64)..<(neuron * 64 + 64)].reduce(0, +)
            XCTAssertEqual(sum, 0, accuracy: 1e-4)
        }
        XCTAssertThrowsError(try QTGMCNNEDIWeights(
            data: Data(count: 16), neighbourhood: .s16x6, neurons: .n32, qualityPasses: 1
        ))
    }

    /// Progressive ground truth: a smooth texture with thin diagonal lines panning
    /// diagonally, sampled per field time.
    private func groundTruth(field: Int, width: Int, height: Int) -> [UInt8] {
        var plane = [UInt8](repeating: 0, count: width * height)
        let t = Double(field)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) + 1.7 * t
                let v = Double(y) + 0.9 * t
                var value = 0.5 + 0.18 * sin(u * 0.21) * cos(v * 0.17) + 0.08 * sin((u + v) * 0.05)
                if (u * 0.8 + v * 0.6).truncatingRemainder(dividingBy: 23) < 1.6 { value = 0.9 }
                plane[y * width + x] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
        }
        return plane
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let mse = zip(a, b).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(a.count)
        return 10 * log10(255 * 255 / max(mse, 1e-9))
    }

    func testMetalPipelineDeinterlacesBetterThanBobAndKeepsSourceLines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let url = try XCTUnwrap(QTGMCNNEDIWeights.bundledURL())
        let width = 160
        let height = 96
        let format = try Y4MFormat(headerLine: "YUV4MPEG2 W\(width) H\(height) F25:1 It A1:1 C420jpeg")
        let parameters = QTGMCParameters(preset: .medium)
        let weights = try QTGMCNNEDIWeights.load(
            from: url, neighbourhood: parameters.neighbourhood, neurons: parameters.neurons,
            qualityPasses: parameters.nnediQualityPasses
        )
        let deinterlacer = try QTGMCMetalDeinterlacer(
            format: format, topFieldFirst: true, doubleRate: true, parameters: parameters, weights: weights
        )

        let frameCount = 10
        let chromaSize = format.planeByteCount(1)
        let truths = (0..<(2 * frameCount)).map { groundTruth(field: $0, width: width, height: height) }
        var outputs: [Data] = []
        var inputs: [[UInt8]] = []
        for frame in 0..<frameCount {
            var luma = truths[2 * frame]
            for y in stride(from: 1, to: height, by: 2) {
                for x in 0..<width { luma[y * width + x] = truths[2 * frame + 1][y * width + x] }
            }
            inputs.append(luma)
            let bytes = luma + [UInt8](repeating: 128, count: 2 * chromaSize)
            outputs += try bytes.withUnsafeBytes { try deinterlacer.process(frame: $0) }
        }
        outputs += try deinterlacer.finish()
        XCTAssertEqual(outputs.count, 2 * frameCount)
        XCTAssertTrue(outputs.allSatisfy { $0.count == format.frameByteCount })

        var qtgmcPSNR = 0.0
        var bobPSNR = 0.0
        let measured = Array(2..<(2 * frameCount - 2))
        for field in measured {
            let output = [UInt8](outputs[field])
            let luma = Array(output[0..<(width * height)])
            let parity = field % 2
            let source = inputs[field / 2]
            // Lossless: the field's own lines are the source lines.
            for y in stride(from: parity, to: height, by: 2) {
                XCTAssertEqual(luma[(y * width)..<(y * width + width)], source[(y * width)..<(y * width + width)])
            }
            XCTAssertTrue(output[(width * height)...].allSatisfy { abs(Int($0) - 128) <= 1 }, "flat chroma stays flat")

            var bob = source
            for y in stride(from: 1 - parity, to: height, by: 2) {
                let above = max(y - 1, parity)
                let below = min(y + 1, height - 2 + parity)
                for x in 0..<width {
                    bob[y * width + x] = UInt8((Int(source[above * width + x]) + Int(source[below * width + x]) + 1) / 2)
                }
            }
            qtgmcPSNR += psnr(luma, truths[field])
            bobPSNR += psnr(bob, truths[field])
        }
        qtgmcPSNR /= Double(measured.count)
        bobPSNR /= Double(measured.count)
        XCTAssertGreaterThan(qtgmcPSNR, bobPSNR, "QTGMC \(qtgmcPSNR) dB vs bob \(bobPSNR) dB")
        XCTAssertGreaterThan(qtgmcPSNR, 25)
    }
}
