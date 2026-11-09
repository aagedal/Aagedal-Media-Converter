// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Drives the QTGMC Metal kernels (QTGMC.metal) over a stream of interlaced
// planar YUV frames. Every input frame yields two fields; each field becomes one
// progressive output frame (or every other field at single rate).
//
// Field n flows through these stages, each needing a few neighbouring fields:
//   bob[n], edi[n]                      (spatial: cubic bob and NNEDI3)
//   srch[n-2]   = repair(blur(binomial5(bob[n-4...n])))
//   vectors     between srch fields up to two apart
//   sharp[n-4]  = limit(resharpen(MDegrain(edi[n-6...n-2])))
//   out[n-4-TR2] = repair(MDegrain(sharp[...]))
// The stream is padded with three repeated frames at each end so every real field
// has a full temporal neighbourhood.

import Foundation
import Metal

final class QTGMCMetalDeinterlacer {
    enum DeinterlacerError: Error, LocalizedError {
        case metalUnavailable
        case libraryUnavailable(String)
        case missingFunction(String)
        case allocationFailed
        case frameSizeMismatch(expected: Int, actual: Int)
        case gpuFailure(String)

        var errorDescription: String? {
            switch self {
            case .metalUnavailable:
                return "Metal is not available on this Mac"
            case .libraryUnavailable(let reason):
                return "The QTGMC Metal shaders could not be loaded: \(reason)"
            case .missingFunction(let name):
                return "The QTGMC Metal kernel \(name) is missing"
            case .allocationFailed:
                return "Not enough GPU memory for QTGMC deinterlacing"
            case .frameSizeMismatch(let expected, let actual):
                return "QTGMC received a frame of \(actual) bytes, expected \(expected)"
            case .gpuFailure(let reason):
                return "QTGMC GPU processing failed: \(reason)"
            }
        }
    }

    let format: Y4MFormat
    let parameters: QTGMCParameters
    let topFieldFirst: Bool
    let doubleRate: Bool

    /// Repeated frames added before the first and after the last real frame.
    static let paddingFrames = 3
    private static let ringSize = 10
    private static let maxPyramidLevels = 5
    private static let minPyramidSize = 32
    private static let coarseSearchRadius: Int32 = 4

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    private let prescreenerBuffer: MTLBuffer
    private let predictorBuffer: MTLBuffer
    private let weights: QTGMCNNEDIWeights
    private let uploadBuffer: MTLBuffer
    private let downloadBuffers: [MTLBuffer]
    private let sourcePlanes: [MTLTexture]
    private let predictMasks: [MTLTexture]
    private let searchTemp: MTLTexture
    private let degrainedPlanes: [MTLTexture]
    private let lowPlanes: [MTLTexture]
    private let highPlanes: [MTLTexture]
    private let smoothedPlanes: [MTLTexture]
    private let outputPlanes: [MTLTexture]
    private let pyramidSizes: [(width: Int, height: Int)]
    private let gridSizes: [(x: Int, y: Int)]
    private let motionScratch: [MTLBuffer]
    private let motionScratchB: MTLBuffer
    private let slots: [FieldSlot]

    private var nextFieldIndex = 0
    private var realFieldCount = 0
    private var lastRealFrame: [UInt8]?
    private var finished = false

    private var firstRealField: Int { 2 * Self.paddingFrames }

    private final class FieldSlot {
        var index = -1
        var parity = 0
        let interpolated: [MTLTexture]
        let sharpened: [MTLTexture]
        let bob: MTLTexture
        let search: [MTLTexture]
        var vectors: [Int: MTLBuffer]
        /// Scene-change block counts for offsets -2, -1, +1, +2.
        let sceneChange: MTLBuffer

        init(interpolated: [MTLTexture], sharpened: [MTLTexture], bob: MTLTexture,
             search: [MTLTexture], vectors: [Int: MTLBuffer], sceneChange: MTLBuffer) {
            self.interpolated = interpolated
            self.sharpened = sharpened
            self.bob = bob
            self.search = search
            self.vectors = vectors
            self.sceneChange = sceneChange
        }
    }

    private static let kernelNames = [
        "qtgmcUnpackPlane", "qtgmcPackPlane", "qtgmcBob", "qtgmcCopyKeptRows",
        "qtgmcNNEDIPrescreen", "qtgmcNNEDIPredict", "qtgmcSearchTemporal", "qtgmcBlur121",
        "qtgmcDownsample", "qtgmcMotionSearch", "qtgmcMotionCoherence", "qtgmcMotionSubpel",
        "qtgmcMotionFinalSAD", "qtgmcDegrain", "qtgmcResharpen", "qtgmcFinish",
        "qtgmcLosslessDiff", "qtgmcLosslessMinmod", "qtgmcLosslessApply",
    ]

    init(
        format: Y4MFormat,
        topFieldFirst: Bool,
        doubleRate: Bool,
        parameters: QTGMCParameters,
        weights: QTGMCNNEDIWeights,
        device providedDevice: MTLDevice? = nil
    ) throws {
        guard let device = providedDevice ?? MTLCreateSystemDefaultDevice() else {
            throw DeinterlacerError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else { throw DeinterlacerError.metalUnavailable }
        self.device = device
        self.queue = queue
        self.format = format
        self.parameters = parameters
        self.topFieldFirst = topFieldFirst
        self.doubleRate = doubleRate
        self.weights = weights

        let library = try Self.makeLibrary(device: device)
        var pipelineStates: [String: MTLComputePipelineState] = [:]
        for name in Self.kernelNames {
            guard let function = library.makeFunction(name: name) else {
                throw DeinterlacerError.missingFunction(name)
            }
            do {
                pipelineStates[name] = try device.makeComputePipelineState(function: function)
            } catch {
                throw DeinterlacerError.libraryUnavailable("\(name): \(error.localizedDescription)")
            }
        }
        pipelines = pipelineStates

        func buffer(_ length: Int, shared: Bool) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(
                length: max(length, 16),
                options: shared ? .storageModeShared : .storageModePrivate
            ) else { throw DeinterlacerError.allocationFailed }
            return buffer
        }
        func texture(_ width: Int, _ height: Int, _ pixelFormat: MTLPixelFormat = .r32Float) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DeinterlacerError.allocationFailed
            }
            return texture
        }
        func planes(_ pixelFormat: MTLPixelFormat = .r32Float) throws -> [MTLTexture] {
            try (0..<3).map { try texture(format.planeWidth($0), format.planeHeight($0), pixelFormat) }
        }

        guard let prescreenerBuffer = weights.prescreener.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }), let predictorBuffer = weights.predictor.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw DeinterlacerError.allocationFailed }
        self.prescreenerBuffer = prescreenerBuffer
        self.predictorBuffer = predictorBuffer

        uploadBuffer = try buffer(format.frameByteCount, shared: true)
        downloadBuffers = try (0..<2).map { _ in try buffer(format.frameByteCount, shared: true) }
        sourcePlanes = try planes()
        predictMasks = try planes(.r16Uint)
        degrainedPlanes = try planes()
        lowPlanes = try planes()
        highPlanes = try planes()
        smoothedPlanes = try planes()
        outputPlanes = try planes()
        searchTemp = try texture(format.width, format.height)

        var sizes = [(width: format.width, height: format.height)]
        while sizes.count < Self.maxPyramidLevels,
              min(sizes[sizes.count - 1].width, sizes[sizes.count - 1].height) / 2 >= Self.minPyramidSize {
            let last = sizes[sizes.count - 1]
            sizes.append(((last.width + 1) / 2, (last.height + 1) / 2))
        }
        pyramidSizes = sizes
        let block = parameters.blockSize
        let step = parameters.blockStep
        gridSizes = sizes.map { size in
            (x: Self.blockCount(size.width, block: block, step: step),
             y: Self.blockCount(size.height, block: block, step: step))
        }
        motionScratch = try gridSizes.map { try buffer($0.x * $0.y * 16, shared: false) }
        motionScratchB = try buffer(gridSizes[0].x * gridSizes[0].y * 16, shared: false)

        let finestBytes = gridSizes[0].x * gridSizes[0].y * 16
        var fieldSlots: [FieldSlot] = []
        for _ in 0..<Self.ringSize {
            var vectors: [Int: MTLBuffer] = [:]
            for offset in parameters.motionOffsets {
                vectors[offset] = try buffer(finestBytes, shared: false)
            }
            fieldSlots.append(FieldSlot(
                interpolated: try planes(),
                sharpened: try planes(),
                bob: try texture(format.width, format.height),
                search: try sizes.map { try texture($0.width, $0.height) },
                vectors: vectors,
                sceneChange: try buffer(4 * MemoryLayout<UInt32>.size, shared: true)
            ))
        }
        slots = fieldSlots
    }

    /// The kernels ship as Metal source and are compiled by the system Metal compiler
    /// at first use, so building the app does not need Xcode's optional Metal toolchain.
    static func makeLibrary(device: MTLDevice, bundle: Bundle = Bundle(for: QTGMCMetalDeinterlacer.self)) throws -> MTLLibrary {
        guard let url = bundle.url(forResource: "QTGMC", withExtension: "metal") else {
            throw DeinterlacerError.libraryUnavailable("QTGMC.metal is missing from the app bundle")
        }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let options = MTLCompileOptions()
            options.mathMode = .fast
            options.languageVersion = .version3_1
            return try device.makeLibrary(source: source, options: options)
        } catch {
            throw DeinterlacerError.libraryUnavailable(error.localizedDescription)
        }
    }

    static func blockCount(_ length: Int, block: Int, step: Int) -> Int {
        length > block ? (length - block + step - 1) / step + 1 : 1
    }

    // MARK: - Public API

    /// Processes one interlaced frame and returns any progressive frames that became
    /// ready (raw planar data in the input layout).
    func process(frame: UnsafeRawBufferPointer) throws -> [Data] {
        precondition(!finished, "process(frame:) after finish()")
        guard frame.count == format.frameByteCount else {
            throw DeinterlacerError.frameSizeMismatch(expected: format.frameByteCount, actual: frame.count)
        }
        let bytes = [UInt8](frame)
        var outputs: [Data] = []
        if lastRealFrame == nil {
            for _ in 0..<Self.paddingFrames {
                outputs += try processFrame(bytes, real: false)
            }
        }
        lastRealFrame = bytes
        outputs += try processFrame(bytes, real: true)
        return outputs
    }

    /// Flushes the frames still waiting for future fields.
    func finish() throws -> [Data] {
        guard !finished else { return [] }
        finished = true
        guard let last = lastRealFrame else { return [] }
        var outputs: [Data] = []
        for _ in 0..<Self.paddingFrames {
            outputs += try processFrame(last, real: false)
        }
        return outputs
    }

    // MARK: - Frame scheduling

    private func slot(_ index: Int) -> FieldSlot {
        slots[index % Self.ringSize]
    }

    private func processFrame(_ bytes: [UInt8], real: Bool) throws -> [Data] {
        bytes.withUnsafeBytes { raw in
            uploadBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        if real { realFieldCount += 2 }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DeinterlacerError.gpuFailure("could not create a command buffer")
        }
        for plane in 0..<3 {
            var io = planeIO(plane)
            encoder.setBuffer(uploadBuffer, offset: 0, index: 0)
            encoder.setBytes(&io, length: MemoryLayout<PlaneIOParams>.stride, index: 1)
            encoder.setTexture(sourcePlanes[plane], index: 0)
            dispatch(encoder, "qtgmcUnpackPlane", format.planeWidth(plane), format.planeHeight(plane))
        }

        var readyCount = 0
        for fieldInFrame in 0..<2 {
            let parity = (topFieldFirst ? 0 : 1) ^ fieldInFrame
            if encodeField(nextFieldIndex, parity: parity, encoder: encoder, downloadIndex: readyCount) {
                readyCount += 1
            }
            nextFieldIndex += 1
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw DeinterlacerError.gpuFailure(error.localizedDescription)
        }
        return (0..<readyCount).map { index in
            Data(bytes: downloadBuffers[index].contents(), count: format.frameByteCount)
        }
    }

    /// Encodes all work that becomes possible once field `n` exists. Returns true
    /// when an output frame was packed into `downloadBuffers[downloadIndex]`.
    private func encodeField(_ n: Int, parity: Int, encoder: MTLComputeCommandEncoder, downloadIndex: Int) -> Bool {
        let current = slot(n)
        current.index = n
        current.parity = parity
        memset(current.sceneChange.contents(), 0, current.sceneChange.length)

        // Spatial interpolation of the new field.
        var lumaField = FieldParams(width: UInt32(format.width), height: UInt32(format.height), parity: UInt32(parity))
        encoder.setTexture(sourcePlanes[0], index: 0)
        encoder.setTexture(current.bob, index: 1)
        encoder.setBytes(&lumaField, length: MemoryLayout<FieldParams>.stride, index: 0)
        dispatch(encoder, "qtgmcBob", format.width, format.height)
        for plane in 0..<3 {
            encodeNNEDI(plane: plane, parity: parity, destination: current.interpolated[plane], encoder: encoder)
        }

        // Search clip and motion vectors.
        let searchIndex = n - 2
        if searchIndex >= 2 {
            encodeSearchClip(searchIndex, encoder: encoder)
            let offsets = parameters.motionOffsets
            let pairs = [(searchIndex, -1), (searchIndex, -2), (searchIndex - 1, 1), (searchIndex - 2, 2)]
            for (cur, offset) in pairs where offsets.contains(offset) && cur >= 2 && cur + offset >= 2 {
                encodeMotion(current: slot(cur), reference: slot(cur + offset), offset: offset, encoder: encoder)
            }
        }

        // First motion-compensated smoothing and resharpening.
        let sharpenIndex = n - 4
        if sharpenIndex >= 4 {
            encodeSharpen(sharpenIndex, encoder: encoder)
        }

        // Final smoothing and output.
        let outputIndex = n - 4 - parameters.temporalRadius2
        let realEnd = firstRealField + realFieldCount
        guard outputIndex >= firstRealField, outputIndex < realEnd,
              doubleRate || (outputIndex - firstRealField) % 2 == 0 else { return false }
        encodeOutput(outputIndex, downloadIndex: downloadIndex, encoder: encoder)
        return true
    }

    // MARK: - Stages

    private func encodeNNEDI(plane: Int, parity: Int, destination: MTLTexture, encoder: MTLComputeCommandEncoder) {
        let width = format.planeWidth(plane)
        let height = format.planeHeight(plane)
        var field = FieldParams(width: UInt32(width), height: UInt32(height), parity: UInt32(parity))
        let keptRows = parity == 0 ? (height + 1) / 2 : height / 2
        let missingRows = height - keptRows

        encoder.setTexture(sourcePlanes[plane], index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&field, length: MemoryLayout<FieldParams>.stride, index: 0)
        dispatch(encoder, "qtgmcCopyKeptRows", width, keptRows)
        guard missingRows > 0 else { return }

        encoder.setTexture(predictMasks[plane], index: 2)
        encoder.setBuffer(prescreenerBuffer, offset: 0, index: 1)
        dispatch(encoder, "qtgmcNNEDIPrescreen", (width + 3) / 4, missingRows)

        var predictor = PredictorParams(
            width: UInt32(width), height: UInt32(height), parity: UInt32(parity),
            xdim: UInt32(weights.neighbourhood.xdim), ydim: UInt32(weights.neighbourhood.ydim),
            neurons: UInt32(weights.neurons.count), qualityPasses: UInt32(weights.qualityPasses)
        )
        encoder.setBytes(&predictor, length: MemoryLayout<PredictorParams>.stride, index: 0)
        encoder.setBuffer(predictorBuffer, offset: 0, index: 1)
        dispatch(encoder, "qtgmcNNEDIPredict", width, missingRows)
    }

    private func encodeSearchClip(_ index: Int, encoder: MTLComputeCommandEncoder) {
        for (textureIndex, offset) in (-2...2).enumerated() {
            encoder.setTexture(slot(index + offset).bob, index: textureIndex)
        }
        encoder.setTexture(searchTemp, index: 5)
        dispatch(encoder, "qtgmcSearchTemporal", format.width, format.height)

        let search = slot(index).search
        encoder.setTexture(searchTemp, index: 0)
        encoder.setTexture(search[0], index: 1)
        dispatch(encoder, "qtgmcBlur121", format.width, format.height)
        for level in 1..<search.count {
            encoder.setTexture(search[level - 1], index: 0)
            encoder.setTexture(search[level], index: 1)
            dispatch(encoder, "qtgmcDownsample", pyramidSizes[level].width, pyramidSizes[level].height)
        }
    }

    private func encodeMotion(current: FieldSlot, reference: FieldSlot, offset: Int, encoder: MTLComputeCommandEncoder) {
        guard let destination = current.vectors[offset] else { return }
        let coarsest = pyramidSizes.count - 1
        func motionParams(level: Int, radius: Int32, lambda: Float, subpel: Float = 0) -> MotionParams {
            let hasPrevious = level < coarsest && subpel == 0 && radius > 0
            return MotionParams(
                blocksX: UInt32(gridSizes[level].x), blocksY: UInt32(gridSizes[level].y),
                blockSize: UInt32(parameters.blockSize), step: UInt32(parameters.blockStep),
                previousBlocksX: hasPrevious ? UInt32(gridSizes[level + 1].x) : 0,
                previousBlocksY: hasPrevious ? UInt32(gridSizes[level + 1].y) : 0,
                radius: radius, lambda: lambda, subpelStep: subpel,
                sceneChangeSAD: parameters.sceneChangeSAD
            )
        }

        for level in stride(from: coarsest, through: 0, by: -1) {
            let radius: Int32 = level == coarsest ? Self.coarseSearchRadius : (level == 0 ? 1 : 2)
            var params = motionParams(level: level, radius: radius, lambda: parameters.lambda)
            encoder.setTexture(current.search[level], index: 0)
            encoder.setTexture(reference.search[level], index: 1)
            encoder.setBuffer(level < coarsest ? motionScratch[level + 1] : motionScratch[level], offset: 0, index: 0)
            encoder.setBuffer(motionScratch[level], offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<MotionParams>.stride, index: 2)
            dispatch(encoder, "qtgmcMotionSearch", gridSizes[level].x, gridSizes[level].y)
        }

        // Coherence pass, then sub-pixel refinement; the last pass writes `destination`.
        encoder.setTexture(current.search[0], index: 0)
        encoder.setTexture(reference.search[0], index: 1)
        let refinements = parameters.subpelSteps
        var input = motionScratch[0]
        var coherence = motionParams(level: 0, radius: 0, lambda: parameters.lambda)
        let coherenceOutput = refinements.isEmpty ? destination : motionScratchB
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(coherenceOutput, offset: 0, index: 1)
        encoder.setBytes(&coherence, length: MemoryLayout<MotionParams>.stride, index: 2)
        dispatch(encoder, "qtgmcMotionCoherence", gridSizes[0].x, gridSizes[0].y)
        input = coherenceOutput
        for (position, step) in refinements.enumerated() {
            let output: MTLBuffer
            if position == refinements.count - 1 {
                output = destination
            } else {
                output = input === motionScratchB ? motionScratch[0] : motionScratchB
            }
            var params = motionParams(level: 0, radius: 1, lambda: parameters.lambda * 0.5, subpel: step)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<MotionParams>.stride, index: 2)
            dispatch(encoder, "qtgmcMotionSubpel", gridSizes[0].x, gridSizes[0].y)
            input = output
        }

        var finalSAD = motionParams(level: 0, radius: 0, lambda: 0)
        encoder.setBuffer(destination, offset: 0, index: 0)
        encoder.setBytes(&finalSAD, length: MemoryLayout<MotionParams>.stride, index: 1)
        encoder.setBuffer(current.sceneChange, offset: Self.sceneChangeIndex(offset) * 4, index: 2)
        dispatch(encoder, "qtgmcMotionFinalSAD", gridSizes[0].x, gridSizes[0].y)
    }

    private static func sceneChangeIndex(_ offset: Int) -> Int {
        switch offset {
        case -2: return 0
        case -1: return 1
        case 1: return 2
        default: return 3
        }
    }

    private func encodeSharpen(_ index: Int, encoder: MTLComputeCommandEncoder) {
        let field = slot(index)
        let references: [(offset: Int, weight: Float)] = parameters.temporalRadius1 >= 2
            ? [(-2, 1.0 / 6.0), (-1, 4.0 / 6.0), (1, 4.0 / 6.0), (2, 1.0 / 6.0)]
            : [(-1, 0.5), (1, 0.5)]
        for plane in 0..<3 {
            encodeDegrain(
                field: field, plane: plane, references: references,
                source: { $0.interpolated[plane] }, threshold: parameters.thresholdSAD1,
                destination: degrainedPlanes[plane], encoder: encoder
            )
            var sharpen = SharpenParams(strength: parameters.sharpness, keepSourceRows: 0, parity: UInt32(field.parity))
            encoder.setTexture(degrainedPlanes[plane], index: 0)
            encoder.setTexture(lowPlanes[plane], index: 1)
            encoder.setTexture(highPlanes[plane], index: 2)
            encoder.setTexture(field.interpolated[plane], index: 3)
            encoder.setTexture(field.sharpened[plane], index: 4)
            encoder.setBytes(&sharpen, length: MemoryLayout<SharpenParams>.stride, index: 0)
            dispatch(encoder, "qtgmcResharpen", format.planeWidth(plane), format.planeHeight(plane))
        }
    }

    private func encodeOutput(_ index: Int, downloadIndex: Int, encoder: MTLComputeCommandEncoder) {
        let field = slot(index)
        let references: [(offset: Int, weight: Float)] = parameters.temporalRadius2 >= 2
            ? [(-2, 1.0), (-1, 1.0), (1, 1.0), (2, 1.0)]
            : [(-1, 1.0), (1, 1.0)]
        for plane in 0..<3 {
            encodeDegrain(
                field: field, plane: plane, references: references,
                source: { $0.sharpened[plane] }, threshold: parameters.thresholdSAD2,
                destination: smoothedPlanes[plane], encoder: encoder
            )
            var finish = FinishParams(
                repair: parameters.repair ? 1 : 0,
                keepSourceRows: parameters.lossless ? 1 : 0,
                parity: UInt32(field.parity)
            )
            let width = format.planeWidth(plane)
            let height = format.planeHeight(plane)
            // Lossless output is woven into a scratch plane first, then de-combed.
            let woven = parameters.lossless ? degrainedPlanes[plane] : outputPlanes[plane]
            encoder.setTexture(smoothedPlanes[plane], index: 0)
            encoder.setTexture(field.interpolated[plane], index: 1)
            encoder.setTexture(woven, index: 2)
            encoder.setBytes(&finish, length: MemoryLayout<FinishParams>.stride, index: 0)
            dispatch(encoder, "qtgmcFinish", width, height)
            if parameters.lossless {
                encoder.setTexture(woven, index: 0)
                encoder.setTexture(lowPlanes[plane], index: 1)
                dispatch(encoder, "qtgmcLosslessDiff", width, height)
                encoder.setTexture(lowPlanes[plane], index: 0)
                encoder.setTexture(highPlanes[plane], index: 1)
                dispatch(encoder, "qtgmcLosslessMinmod", width, height)
                encoder.setTexture(woven, index: 0)
                encoder.setTexture(lowPlanes[plane], index: 1)
                encoder.setTexture(highPlanes[plane], index: 2)
                encoder.setTexture(outputPlanes[plane], index: 3)
                dispatch(encoder, "qtgmcLosslessApply", width, height)
            }

            var io = planeIO(plane)
            encoder.setTexture(outputPlanes[plane], index: 0)
            encoder.setBuffer(downloadBuffers[downloadIndex], offset: 0, index: 0)
            encoder.setBytes(&io, length: MemoryLayout<PlaneIOParams>.stride, index: 1)
            dispatch(encoder, "qtgmcPackPlane", format.planeWidth(plane), format.planeHeight(plane))
        }
    }

    private func encodeDegrain(
        field: FieldSlot,
        plane: Int,
        references: [(offset: Int, weight: Float)],
        source: (FieldSlot) -> MTLTexture,
        threshold: Float,
        destination: MTLTexture,
        encoder: MTLComputeCommandEncoder
    ) {
        let shiftX = plane == 0 ? 0 : format.chromaShiftX
        let shiftY = plane == 0 ? 0 : format.chromaShiftY
        let grid = gridSizes[0]
        var weights: [Float] = references.map(\.weight)
        var sceneChangeIndices = references.map { UInt32(Self.sceneChangeIndex($0.offset)) }
        while weights.count < 4 {
            weights.append(0)
            sceneChangeIndices.append(0)
        }
        let limitA = UInt32(references.firstIndex { $0.offset == -1 } ?? 0)
        let limitB = UInt32(references.firstIndex { $0.offset == 1 } ?? 0)
        var params = DegrainParams(
            width: UInt32(format.planeWidth(plane)), height: UInt32(format.planeHeight(plane)),
            chromaShiftX: UInt32(shiftX), chromaShiftY: UInt32(shiftY),
            blockSize: UInt32(parameters.blockSize), step: UInt32(parameters.blockStep),
            blocksX: UInt32(grid.x), blocksY: UInt32(grid.y),
            referenceCount: UInt32(references.count),
            thresholdSAD: threshold, centreWeight: 1,
            sceneChangeLimit: parameters.sceneChangeFraction * Float(grid.x * grid.y),
            baseWeight: (weights[0], weights[1], weights[2], weights[3]),
            limitReferences: (limitA, limitB),
            sceneChangeIndex: (sceneChangeIndices[0], sceneChangeIndices[1],
                               sceneChangeIndices[2], sceneChangeIndices[3])
        )
        let sourceTexture = source(field)
        encoder.setTexture(sourceTexture, index: 0)
        for slotIndex in 0..<4 {
            if slotIndex < references.count {
                let reference = references[slotIndex]
                encoder.setTexture(source(slot(field.index + reference.offset)), index: 1 + slotIndex)
                encoder.setBuffer(field.vectors[reference.offset], offset: 0, index: slotIndex)
            } else {
                encoder.setTexture(sourceTexture, index: 1 + slotIndex)
                encoder.setBuffer(field.vectors[references[0].offset], offset: 0, index: slotIndex)
            }
        }
        encoder.setTexture(destination, index: 5)
        encoder.setTexture(lowPlanes[plane], index: 6)
        encoder.setTexture(highPlanes[plane], index: 7)
        encoder.setBuffer(field.sceneChange, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<DegrainParams>.stride, index: 5)
        dispatch(encoder, "qtgmcDegrain", format.planeWidth(plane), format.planeHeight(plane))
    }

    // MARK: - Dispatch helpers

    private func planeIO(_ plane: Int) -> PlaneIOParams {
        PlaneIOParams(
            width: UInt32(format.planeWidth(plane)),
            height: UInt32(format.planeHeight(plane)),
            byteOffset: UInt32(format.planeByteOffset(plane)),
            bytesPerSample: UInt32(format.bytesPerSample),
            maxValue: Float(format.maxSampleValue)
        )
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ name: String, _ width: Int, _ height: Int) {
        guard width > 0, height > 0, let pipeline = pipelines[name] else { return }
        encoder.setComputePipelineState(pipeline)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: min(threadHeight, height), depth: 1)
        )
    }
}

// MARK: - Shader parameter layouts (must match QTGMC.metal)

private struct PlaneIOParams {
    var width: UInt32
    var height: UInt32
    var byteOffset: UInt32
    var bytesPerSample: UInt32
    var maxValue: Float
}

private struct FieldParams {
    var width: UInt32
    var height: UInt32
    var parity: UInt32
}

private struct PredictorParams {
    var width: UInt32
    var height: UInt32
    var parity: UInt32
    var xdim: UInt32
    var ydim: UInt32
    var neurons: UInt32
    var qualityPasses: UInt32
}

private struct MotionParams {
    var blocksX: UInt32
    var blocksY: UInt32
    var blockSize: UInt32
    var step: UInt32
    var previousBlocksX: UInt32
    var previousBlocksY: UInt32
    var radius: Int32
    var lambda: Float
    var subpelStep: Float
    var sceneChangeSAD: Float
}

private struct DegrainParams {
    var width: UInt32
    var height: UInt32
    var chromaShiftX: UInt32
    var chromaShiftY: UInt32
    var blockSize: UInt32
    var step: UInt32
    var blocksX: UInt32
    var blocksY: UInt32
    var referenceCount: UInt32
    var thresholdSAD: Float
    var centreWeight: Float
    var sceneChangeLimit: Float
    var baseWeight: (Float, Float, Float, Float)
    var limitReferences: (UInt32, UInt32)
    var sceneChangeIndex: (UInt32, UInt32, UInt32, UInt32)
}

private struct SharpenParams {
    var strength: Float
    var keepSourceRows: UInt32
    var parity: UInt32
}

private struct FinishParams {
    var repair: UInt32
    var keepSourceRows: UInt32
    var parity: UInt32
}
