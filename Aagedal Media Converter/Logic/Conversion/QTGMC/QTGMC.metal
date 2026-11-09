// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Metal port of the QTGMC deinterlacing pipeline (after the AviSynth script by
// Didée, Vit and others): NNEDI3 edge-directed interpolation, a temporally
// smoothed search clip, hierarchical block motion estimation, motion-compensated
// temporal smoothing (MDegrain-style weights), resharpening with motion-compensated
// limiting and a final motion-compensated smoothing pass.
//
// The NNEDI3 kernels follow FFmpeg's vf_nnedi.c (Kevin Stone, Paul B Mahol,
// GPL-2.0-or-later) and use the same nnedi3_weights.bin. All working planes are
// r32Float textures holding normalized samples (0...1).

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared helpers

/// Nearest row of the kept field for a row index that may lie outside the plane.
/// `r` always has the kept parity, so stepping by two keeps the parity.
static inline int keptRow(int r, int height) {
    if (r < 0) {
        r += 2 * ((-r + 1) / 2);
    }
    if (r >= height) {
        r -= 2 * ((r - height) / 2 + 1);
    }
    return clamp(r, 0, height - 1);
}

/// FFmpeg's nnedi pads each line by mirroring with the edge sample repeated.
static inline int mirrorColumn(int x, int width) {
    if (x < 0) {
        x = -x - 1;
    }
    if (x >= width) {
        x = 2 * width - x - 1;
    }
    return clamp(x, 0, width - 1);
}

static inline float readClamped(texture2d<float, access::read> tex, int x, int y) {
    int w = int(tex.get_width());
    int h = int(tex.get_height());
    return tex.read(uint2(uint(clamp(x, 0, w - 1)), uint(clamp(y, 0, h - 1)))).r;
}

static inline float4 catmullRomWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(-0.5f * t3 + t2 - 0.5f * t,
                  1.5f * t3 - 2.5f * t2 + 1.0f,
                  -1.5f * t3 + 2.0f * t2 + 0.5f * t,
                  0.5f * t3 - 0.5f * t2);
}

/// Catmull-Rom bicubic sample with edge clamping (matches the reference's `bicubic`).
static inline float sampleBicubic(texture2d<float, access::read> tex, float x, float y) {
    float w = float(tex.get_width());
    float h = float(tex.get_height());
    x = clamp(x, 0.0f, w - 1.0f);
    y = clamp(y, 0.0f, h - 1.0f);
    float fx = floor(x);
    float fy = floor(y);
    float4 wx = catmullRomWeights(x - fx);
    float4 wy = catmullRomWeights(y - fy);
    int ix = int(fx);
    int iy = int(fy);
    float result = 0.0f;
    for (int j = 0; j < 4; j++) {
        float row = 0.0f;
        for (int i = 0; i < 4; i++) {
            row += wx[i] * readClamped(tex, ix + i - 1, iy + j - 1);
        }
        result += wy[j] * row;
    }
    return result;
}

static inline float sampleBilinear(texture2d<float, access::read> tex, float x, float y) {
    float w = float(tex.get_width());
    float h = float(tex.get_height());
    x = clamp(x, 0.0f, w - 1.0f);
    y = clamp(y, 0.0f, h - 1.0f);
    float fx = floor(x);
    float fy = floor(y);
    float ax = x - fx;
    float ay = y - fy;
    int ix = int(fx);
    int iy = int(fy);
    float a = readClamped(tex, ix, iy);
    float b = readClamped(tex, ix + 1, iy);
    float c = readClamped(tex, ix, iy + 1);
    float d = readClamped(tex, ix + 1, iy + 1);
    return mix(mix(a, b, ax), mix(c, d, ax), ay);
}

static inline float elliott(float x) {
    return x / (1.0f + fabs(x));
}

// MARK: - Upload / download

struct PlaneIOParams {
    uint width;
    uint height;
    uint byteOffset;
    uint bytesPerSample;
    float maxValue;
};

kernel void qtgmcUnpackPlane(device const uchar *source [[buffer(0)]],
                             constant PlaneIOParams &p [[buffer(1)]],
                             texture2d<float, access::write> destination [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = gid.y * p.width + gid.x;
    float value;
    if (p.bytesPerSample == 1) {
        value = float(source[p.byteOffset + index]);
    } else {
        device const ushort *samples = (device const ushort *)(source + p.byteOffset);
        value = float(samples[index]);
    }
    destination.write(float4(value / p.maxValue), gid);
}

kernel void qtgmcPackPlane(texture2d<float, access::read> source [[texture(0)]],
                           device uchar *destination [[buffer(0)]],
                           constant PlaneIOParams &p [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = gid.y * p.width + gid.x;
    float value = clamp(source.read(gid).r * p.maxValue + 0.5f, 0.0f, p.maxValue);
    if (p.bytesPerSample == 1) {
        destination[p.byteOffset + index] = uchar(value);
    } else {
        device ushort *samples = (device ushort *)(destination + p.byteOffset);
        samples[index] = ushort(value);
    }
}

// MARK: - Field interpolation

struct FieldParams {
    uint width;
    uint height;
    uint parity;   // parity of the kept (original) rows
};

/// Spatial cubic bob, used for the motion search clip (luma only).
kernel void qtgmcBob(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> destination [[texture(1)]],
                     constant FieldParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    int y = int(gid.y);
    int h = int(p.height);
    if (uint(y & 1) == p.parity) {
        destination.write(source.read(gid), gid);
        return;
    }
    uint x = gid.x;
    float a = source.read(uint2(x, uint(keptRow(y - 1, h)))).r;
    float b = source.read(uint2(x, uint(keptRow(y + 1, h)))).r;
    float a2 = source.read(uint2(x, uint(keptRow(y - 3, h)))).r;
    float b2 = source.read(uint2(x, uint(keptRow(y + 3, h)))).r;
    destination.write(float4((9.0f * (a + b) - (a2 + b2)) / 16.0f), gid);
}

/// Copies the kept field into the interpolated plane.
kernel void qtgmcCopyKeptRows(texture2d<float, access::read> source [[texture(0)]],
                              texture2d<float, access::write> destination [[texture(1)]],
                              constant FieldParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint y = gid.y * 2 + p.parity;
    if (gid.x >= p.width || y >= p.height) return;
    uint2 position = uint2(gid.x, y);
    destination.write(source.read(position), position);
}

struct PrescreenerWeights {
    float kernel0[4][64];
    float bias0[4];
    float kernel1[4][4];
    float bias1[4];
};

/// NNEDI3 "new" prescreener: one thread decides four horizontally adjacent missing
/// pixels. Easy pixels get the 4-tap cubic; hard ones are flagged for the predictor.
kernel void qtgmcNNEDIPrescreen(texture2d<float, access::read> source [[texture(0)]],
                                texture2d<float, access::write> destination [[texture(1)]],
                                texture2d<ushort, access::write> predictMask [[texture(2)]],
                                constant FieldParams &p [[buffer(0)]],
                                device const PrescreenerWeights &weights [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int w = int(p.width);
    int h = int(p.height);
    int x0 = int(gid.x) * 4;
    int y = int(gid.y) * 2 + int(1 - p.parity);
    if (x0 >= w || y >= h) return;

    int rows[4] = { keptRow(y - 3, h), keptRow(y - 1, h), keptRow(y + 1, h), keptRow(y + 3, h) };
    float input[64];
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 16; c++) {
            int x = mirrorColumn(x0 - 6 + c, w);
            input[r * 16 + c] = source.read(uint2(uint(x), uint(rows[r]))).r * 255.0f;
        }
    }
    float state0[4];
    for (int n = 0; n < 4; n++) {
        float sum = 0.0f;
        for (int k = 0; k < 64; k++) {
            sum += weights.kernel0[n][k] * input[k];
        }
        state0[n] = elliott(sum + weights.bias0[n] + 1e-20f);
    }
    for (int n = 0; n < 4; n++) {
        int x = x0 + n;
        if (x >= w) break;
        float sum = 0.0f;
        for (int k = 0; k < 4; k++) {
            sum += weights.kernel1[n][k] * state0[k];
        }
        bool easy = (sum + weights.bias1[n] + 1e-20f) > 0.0f;
        uint2 position = uint2(uint(x), uint(y));
        predictMask.write(ushort4(ushort(easy ? 0 : 1)), position);
        if (easy) {
            float a = source.read(uint2(uint(x), uint(rows[0]))).r;
            float b = source.read(uint2(uint(x), uint(rows[1]))).r;
            float c = source.read(uint2(uint(x), uint(rows[2]))).r;
            float d = source.read(uint2(uint(x), uint(rows[3]))).r;
            destination.write(float4((-3.0f * a + 19.0f * b + 19.0f * c - 3.0f * d) / 32.0f), position);
        }
    }
}

struct PredictorParams {
    uint width;
    uint height;
    uint parity;
    uint xdim;
    uint ydim;
    uint neurons;
    uint qualityPasses;   // 1 or 2
};

#define QTGMC_MAX_PREDICTOR_INPUTS 128

/// NNEDI3 predictor for pixels the prescreener flagged. Weights are laid out per
/// quality pass as softmax[neurons][size], elliott[neurons][size],
/// softmaxBias[neurons], elliottBias[neurons] (already mean-adjusted on the CPU).
kernel void qtgmcNNEDIPredict(texture2d<float, access::read> source [[texture(0)]],
                              texture2d<float, access::write> destination [[texture(1)]],
                              texture2d<ushort, access::read> predictMask [[texture(2)]],
                              constant PredictorParams &p [[buffer(0)]],
                              device const float *weights [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int w = int(p.width);
    int h = int(p.height);
    int x = int(gid.x);
    int y = int(gid.y) * 2 + int(1 - p.parity);
    if (x >= w || y >= h) return;
    uint2 position = uint2(uint(x), uint(y));
    if (predictMask.read(position).r == 0) return;

    int xdim = int(p.xdim);
    int ydim = int(p.ydim);
    int size = xdim * ydim;
    float input[QTGMC_MAX_PREDICTOR_INPUTS];
    float sum = 0.0f;
    float sumSquares = 0.0f;
    for (int r = 0; r < ydim; r++) {
        int row = keptRow(y - ydim + 1 + 2 * r, h);
        for (int c = 0; c < xdim; c++) {
            int column = mirrorColumn(x - (xdim / 2 - 1) + c, w);
            float value = source.read(uint2(uint(column), uint(row))).r * 255.0f;
            input[r * xdim + c] = value;
            sum += value;
            sumSquares += value * value;
        }
    }
    float scale = 1.0f / float(size);
    float mean = sum * scale;
    float variance = sumSquares * scale - mean * mean;
    float deviation = 0.0f;
    float inverse = 0.0f;
    if (variance >= FLT_EPSILON) {
        deviation = sqrt(variance);
        inverse = 1.0f / deviation;
    }

    int neurons = int(p.neurons);
    int passStride = 2 * neurons * size + 2 * neurons;
    float result = 0.0f;
    for (int pass = 0; pass < int(p.qualityPasses); pass++) {
        device const float *softmax = weights + pass * passStride;
        device const float *elliottWeights = softmax + neurons * size;
        device const float *softmaxBias = elliottWeights + neurons * size;
        device const float *elliottBias = softmaxBias + neurons;
        float valueSum = 0.0f;
        float weightSum = 0.0f;
        for (int n = 0; n < neurons; n++) {
            float a = 0.0f;
            float e = 0.0f;
            device const float *sw = softmax + n * size;
            device const float *ew = elliottWeights + n * size;
            for (int k = 0; k < size; k++) {
                a += sw[k] * input[k];
                e += ew[k] * input[k];
            }
            a = a * inverse + softmaxBias[n] + 1e-20f;
            e = e * inverse + elliottBias[n] + 1e-20f;
            float activation = exp(clamp(a, -80.0f, 80.0f));
            valueSum += activation * elliott(e);
            weightSum += activation;
        }
        result += weightSum > 1e-10f ? (5.0f * valueSum) / weightSum * deviation + mean : mean;
    }
    result /= float(p.qualityPasses);
    destination.write(float4(result / 255.0f), position);
}

// MARK: - Search clip

/// Temporal 1-4-6-4-1 smoothing of five bobbed fields, limited to the 3x3 range of
/// the centre field (Repair mode 1).
kernel void qtgmcSearchTemporal(texture2d<float, access::read> b0 [[texture(0)]],
                                texture2d<float, access::read> b1 [[texture(1)]],
                                texture2d<float, access::read> b2 [[texture(2)]],
                                texture2d<float, access::read> b3 [[texture(3)]],
                                texture2d<float, access::read> b4 [[texture(4)]],
                                texture2d<float, access::write> destination [[texture(5)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    float smoothed = (b0.read(gid).r + 4.0f * b1.read(gid).r + 6.0f * b2.read(gid).r
                      + 4.0f * b3.read(gid).r + b4.read(gid).r) / 16.0f;
    float lo = FLT_MAX;
    float hi = -FLT_MAX;
    int x = int(gid.x);
    int y = int(gid.y);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float v = readClamped(b2, x + dx, y + dy);
            lo = min(lo, v);
            hi = max(hi, v);
        }
    }
    destination.write(float4(clamp(smoothed, lo, hi)), gid);
}

/// 3x3 1-2-1 blur with clamped edges.
kernel void qtgmcBlur121(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::write> destination [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    int x = int(gid.x);
    int y = int(gid.y);
    const float k[3] = { 1.0f, 2.0f, 1.0f };
    float sum = 0.0f;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            sum += k[dy + 1] * k[dx + 1] * readClamped(source, x + dx, y + dy);
        }
    }
    destination.write(float4(sum / 16.0f), gid);
}

/// 2x2 box downsample for the motion search pyramid.
kernel void qtgmcDownsample(texture2d<float, access::read> source [[texture(0)]],
                            texture2d<float, access::write> destination [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    int x = int(gid.x) * 2;
    int y = int(gid.y) * 2;
    float sum = readClamped(source, x, y) + readClamped(source, x + 1, y)
              + readClamped(source, x, y + 1) + readClamped(source, x + 1, y + 1);
    destination.write(float4(sum * 0.25f), gid);
}

// MARK: - Motion estimation

struct MotionParams {
    uint blocksX;
    uint blocksY;
    uint blockSize;
    uint step;
    uint previousBlocksX;   // 0 when there is no coarser level
    uint previousBlocksY;
    int radius;
    float lambda;
    float subpelStep;       // 0 for integer search
    float sceneChangeSAD;   // thSCD1, per-pixel mean absolute difference
};

/// Mean absolute difference of one block against the reference displaced by `v`.
/// Integer vectors read directly; fractional ones use bilinear (search) or bicubic
/// (final SAD) sampling.
static float blockSAD(texture2d<float, access::read> current,
                      texture2d<float, access::read> reference,
                      int bx, int by, float2 v, int blockSize, bool bicubic) {
    float sum = 0.0f;
    bool integral = all(floor(v) == v);
    int vx = int(v.x);
    int vy = int(v.y);
    for (int j = 0; j < blockSize; j++) {
        for (int i = 0; i < blockSize; i++) {
            int x = bx + i;
            int y = by + j;
            float c = readClamped(current, x, y);
            float r;
            if (integral) {
                r = readClamped(reference, x + vx, y + vy);
            } else if (bicubic) {
                r = sampleBicubic(reference, float(x) + v.x, float(y) + v.y);
            } else {
                r = sampleBilinear(reference, float(x) + v.x, float(y) + v.y);
            }
            sum += fabs(c - r);
        }
    }
    return sum / float(blockSize * blockSize);
}

/// One pyramid level: evaluate predictor candidates from the coarser level (or the
/// zero vector at the coarsest level), then search exhaustively around the best.
kernel void qtgmcMotionSearch(texture2d<float, access::read> current [[texture(0)]],
                              texture2d<float, access::read> reference [[texture(1)]],
                              device const float4 *previous [[buffer(0)]],
                              device float4 *vectors [[buffer(1)]],
                              constant MotionParams &p [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.blocksX || gid.y >= p.blocksY) return;
    int bx = int(gid.x * p.step);
    int by = int(gid.y * p.step);
    int size = int(p.blockSize);

    float2 candidates[6];
    int candidateCount = 0;
    float2 predictor = float2(0.0f);
    if (p.previousBlocksX > 0) {
        const int2 offsets[5] = { int2(0, 0), int2(0, -1), int2(0, 1), int2(-1, 0), int2(1, 0) };
        for (int i = 0; i < 5; i++) {
            int px = clamp(int(gid.x / 2) + offsets[i].x, 0, int(p.previousBlocksX) - 1);
            int py = clamp(int(gid.y / 2) + offsets[i].y, 0, int(p.previousBlocksY) - 1);
            candidates[candidateCount++] = 2.0f * previous[py * int(p.previousBlocksX) + px].xy;
        }
        predictor = candidates[0];
    }
    candidates[candidateCount++] = float2(0.0f);

    float2 best = candidates[0];
    float bestCost = FLT_MAX;
    for (int i = 0; i < candidateCount; i++) {
        float2 v = candidates[i];
        float cost = blockSAD(current, reference, bx, by, v, size, false)
                   + p.lambda * (fabs(v.x - predictor.x) + fabs(v.y - predictor.y));
        if (cost < bestCost) {
            bestCost = cost;
            best = v;
        }
    }
    float2 centre = best;
    for (int dy = -p.radius; dy <= p.radius; dy++) {
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            if (dx == 0 && dy == 0) continue;
            float2 v = centre + float2(float(dx), float(dy));
            float cost = blockSAD(current, reference, bx, by, v, size, false)
                       + p.lambda * (fabs(v.x - predictor.x) + fabs(v.y - predictor.y));
            if (cost < bestCost) {
                bestCost = cost;
                best = v;
            }
        }
    }
    vectors[gid.y * p.blocksX + gid.x] = float4(best, bestCost, 0.0f);
}

static inline float median5(float a, float b, float c, float d, float e) {
    float lo1 = min(a, b), hi1 = max(a, b);
    float lo2 = min(c, d), hi2 = max(c, d);
    float lo = max(lo1, lo2);
    float hi = min(hi1, hi2);
    // median of {lo, hi, e} after discarding the global min and max of a..d
    return max(min(lo, hi), min(max(lo, hi), e));
}

/// Neighbour-coherence pass at full resolution: re-evaluate the block's own vector
/// and its four neighbours' against the component-wise median predictor.
kernel void qtgmcMotionCoherence(texture2d<float, access::read> current [[texture(0)]],
                                 texture2d<float, access::read> reference [[texture(1)]],
                                 device const float4 *input [[buffer(0)]],
                                 device float4 *vectors [[buffer(1)]],
                                 constant MotionParams &p [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.blocksX || gid.y >= p.blocksY) return;
    int nx = int(p.blocksX);
    int ny = int(p.blocksY);
    int x = int(gid.x);
    int y = int(gid.y);
    float2 own = input[y * nx + x].xy;
    float2 up = input[clamp(y - 1, 0, ny - 1) * nx + x].xy;
    float2 down = input[clamp(y + 1, 0, ny - 1) * nx + x].xy;
    float2 left = input[y * nx + clamp(x - 1, 0, nx - 1)].xy;
    float2 right = input[y * nx + clamp(x + 1, 0, nx - 1)].xy;
    float2 predictor = float2(median5(up.x, down.x, left.x, right.x, own.x),
                              median5(up.y, down.y, left.y, right.y, own.y));
    float2 candidates[5] = { own, up, down, left, right };
    int bx = x * int(p.step);
    int by = y * int(p.step);
    float2 best = own;
    float bestCost = FLT_MAX;
    for (int i = 0; i < 5; i++) {
        float2 v = candidates[i];
        float cost = blockSAD(current, reference, bx, by, v, int(p.blockSize), false)
                   + p.lambda * (fabs(v.x - predictor.x) + fabs(v.y - predictor.y));
        if (cost < bestCost) {
            bestCost = cost;
            best = v;
        }
    }
    vectors[y * nx + x] = float4(best, bestCost, 0.0f);
}

/// Sub-pixel refinement around the current vector with step `subpelStep`.
kernel void qtgmcMotionSubpel(texture2d<float, access::read> current [[texture(0)]],
                              texture2d<float, access::read> reference [[texture(1)]],
                              device const float4 *input [[buffer(0)]],
                              device float4 *vectors [[buffer(1)]],
                              constant MotionParams &p [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.blocksX || gid.y >= p.blocksY) return;
    uint index = gid.y * p.blocksX + gid.x;
    float2 centre = input[index].xy;
    int bx = int(gid.x * p.step);
    int by = int(gid.y * p.step);
    float2 best = centre;
    float bestCost = FLT_MAX;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 v = centre + float2(float(dx), float(dy)) * p.subpelStep;
            float cost = blockSAD(current, reference, bx, by, v, int(p.blockSize), false)
                       + p.lambda * (fabs(v.x - centre.x) + fabs(v.y - centre.y));
            if (cost < bestCost) {
                bestCost = cost;
                best = v;
            }
        }
    }
    vectors[index] = float4(best, bestCost, 0.0f);
}

/// Final per-block SAD with the compensation interpolator, plus the scene-change
/// block count (blocks whose SAD exceeds thSCD1).
kernel void qtgmcMotionFinalSAD(texture2d<float, access::read> current [[texture(0)]],
                                texture2d<float, access::read> reference [[texture(1)]],
                                device float4 *vectors [[buffer(0)]],
                                constant MotionParams &p [[buffer(1)]],
                                device atomic_uint *sceneChangeCount [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.blocksX || gid.y >= p.blocksY) return;
    uint index = gid.y * p.blocksX + gid.x;
    float2 v = vectors[index].xy;
    float sad = blockSAD(current, reference, int(gid.x * p.step), int(gid.y * p.step),
                         v, int(p.blockSize), true);
    vectors[index] = float4(v, sad, 0.0f);
    if (sad > p.sceneChangeSAD) {
        atomic_fetch_add_explicit(sceneChangeCount, 1u, memory_order_relaxed);
    }
}

// MARK: - Motion-compensated smoothing

struct DegrainParams {
    uint width;
    uint height;
    uint chromaShiftX;
    uint chromaShiftY;
    uint blockSize;          // luma units
    uint step;               // luma units
    uint blocksX;
    uint blocksY;
    uint referenceCount;     // 2 or 4
    float thresholdSAD;      // thSAD, per-pixel mean absolute difference
    float centreWeight;
    float sceneChangeLimit;  // thSCD2 * block count
    float baseWeight[4];     // per reference, in reference order
    uint limitReferences[2]; // indices of the -1 / +1 references used for limiting
    uint sceneChangeIndex[4];// per reference: slot in the field's scene-change counters
};

static inline float sadWeight(float sad, float threshold) {
    float t2 = threshold * threshold;
    float s2 = sad * sad;
    return max(0.0f, (t2 - s2) / (t2 + s2));
}

static inline float obmcWindow(int t, int size) {
    float s = sin(M_PI_F * (float(t) + 0.5f) / float(size));
    return s * s;
}

/// MDegrain-style overlapped block motion-compensated weighted average. Each
/// covering block contributes (w0*src + sum wk*ref_k(x+v)) / (w0 + sum wk),
/// blended with a raised-cosine window. Also outputs the min/max of the source and
/// the plain compensated -1/+1 neighbours (for back-limiting the resharpener).
kernel void qtgmcDegrain(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::read> ref0 [[texture(1)]],
                         texture2d<float, access::read> ref1 [[texture(2)]],
                         texture2d<float, access::read> ref2 [[texture(3)]],
                         texture2d<float, access::read> ref3 [[texture(4)]],
                         texture2d<float, access::write> destination [[texture(5)]],
                         texture2d<float, access::write> limitLow [[texture(6)]],
                         texture2d<float, access::write> limitHigh [[texture(7)]],
                         device const float4 *vectors0 [[buffer(0)]],
                         device const float4 *vectors1 [[buffer(1)]],
                         device const float4 *vectors2 [[buffer(2)]],
                         device const float4 *vectors3 [[buffer(3)]],
                         device const uint *sceneChangeCounts [[buffer(4)]],
                         constant DegrainParams &p [[buffer(5)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    int blockW = int(p.blockSize >> p.chromaShiftX);
    int blockH = int(p.blockSize >> p.chromaShiftY);
    int stepW = int(p.step >> p.chromaShiftX);
    int stepH = int(p.step >> p.chromaShiftY);
    float vectorScaleX = 1.0f / float(1u << p.chromaShiftX);
    float vectorScaleY = 1.0f / float(1u << p.chromaShiftY);
    float src = source.read(gid).r;

    float referenceGate[4];
    for (int k = 0; k < 4; k++) {
        referenceGate[k] = (uint(k) < p.referenceCount
                            && float(sceneChangeCounts[p.sceneChangeIndex[k]]) <= p.sceneChangeLimit) ? 1.0f : 0.0f;
    }

    float accumulated = 0.0f;
    float windowSum = 0.0f;
    float compensatedA = 0.0f;
    float compensatedB = 0.0f;
    for (int oy = 0; oy >= -1; oy--) {
        for (int ox = 0; ox >= -1; ox--) {
            int by = y / stepH + oy;
            int bx = x / stepW + ox;
            if (by < 0 || bx < 0 || by >= int(p.blocksY) || bx >= int(p.blocksX)) continue;
            int ty = y - by * stepH;
            int tx = x - bx * stepW;
            if (ty >= blockH || tx >= blockW) continue;
            float window = obmcWindow(ty, blockH) * obmcWindow(tx, blockW);
            uint blockIndex = uint(by) * p.blocksX + uint(bx);
            float numerator = p.centreWeight * src;
            float denominator = p.centreWeight;
            for (int k = 0; k < int(p.referenceCount); k++) {
                float4 v;
                float prediction;
                switch (k) {
                case 0:
                    v = vectors0[blockIndex];
                    prediction = sampleBicubic(ref0, float(x) + v.x * vectorScaleX, float(y) + v.y * vectorScaleY);
                    break;
                case 1:
                    v = vectors1[blockIndex];
                    prediction = sampleBicubic(ref1, float(x) + v.x * vectorScaleX, float(y) + v.y * vectorScaleY);
                    break;
                case 2:
                    v = vectors2[blockIndex];
                    prediction = sampleBicubic(ref2, float(x) + v.x * vectorScaleX, float(y) + v.y * vectorScaleY);
                    break;
                default:
                    v = vectors3[blockIndex];
                    prediction = sampleBicubic(ref3, float(x) + v.x * vectorScaleX, float(y) + v.y * vectorScaleY);
                    break;
                }
                float weight = p.baseWeight[k] * referenceGate[k] * sadWeight(v.z, p.thresholdSAD);
                numerator += weight * prediction;
                denominator += weight;
                if (uint(k) == p.limitReferences[0]) compensatedA += window * prediction;
                if (uint(k) == p.limitReferences[1]) compensatedB += window * prediction;
            }
            accumulated += window * numerator / denominator;
            windowSum += window;
        }
    }
    float inverse = windowSum > 0.0f ? 1.0f / windowSum : 0.0f;
    float result = windowSum > 0.0f ? accumulated * inverse : src;
    float a = windowSum > 0.0f ? compensatedA * inverse : src;
    float b = windowSum > 0.0f ? compensatedB * inverse : src;
    destination.write(float4(result), gid);
    limitLow.write(float4(min(src, min(a, b))), gid);
    limitHigh.write(float4(max(src, max(a, b))), gid);
}

struct SharpenParams {
    float strength;
    uint keepSourceRows;  // 1: put the original field rows back (lossless)
    uint parity;
};

/// Resharpen (x + s*(x - blur121(x))) limited to the motion-compensated range.
kernel void qtgmcResharpen(texture2d<float, access::read> degrained [[texture(0)]],
                           texture2d<float, access::read> limitLow [[texture(1)]],
                           texture2d<float, access::read> limitHigh [[texture(2)]],
                           texture2d<float, access::read> interpolated [[texture(3)]],
                           texture2d<float, access::write> destination [[texture(4)]],
                           constant SharpenParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    if (p.keepSourceRows != 0 && (gid.y & 1) == p.parity) {
        destination.write(interpolated.read(gid), gid);
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    const float k[3] = { 1.0f, 2.0f, 1.0f };
    float blur = 0.0f;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            blur += k[dy + 1] * k[dx + 1] * readClamped(degrained, x + dx, y + dy);
        }
    }
    blur /= 16.0f;
    float d = degrained.read(gid).r;
    float sharpened = d + p.strength * (d - blur);
    destination.write(float4(clamp(sharpened, limitLow.read(gid).r, limitHigh.read(gid).r)), gid);
}

struct FinishParams {
    uint repair;           // clamp to the 3x3 range of the interpolated field
    uint keepSourceRows;   // lossless: original field rows from the source
    uint parity;
};

kernel void qtgmcFinish(texture2d<float, access::read> smoothed [[texture(0)]],
                        texture2d<float, access::read> interpolated [[texture(1)]],
                        texture2d<float, access::write> destination [[texture(2)]],
                        constant FinishParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    if (p.keepSourceRows != 0 && (gid.y & 1) == p.parity) {
        destination.write(interpolated.read(gid), gid);
        return;
    }
    float value = smoothed.read(gid).r;
    if (p.repair != 0) {
        int x = int(gid.x);
        int y = int(gid.y);
        float lo = FLT_MAX;
        float hi = -FLT_MAX;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float v = readClamped(interpolated, x + dx, y + dy);
                lo = min(lo, v);
                hi = max(hi, v);
            }
        }
        value = clamp(value, lo, hi);
    }
    destination.write(float4(value), gid);
}

// MARK: - Lossless (QTGMC_MakeLossless)
//
// With the original field lines put back, the interpolated lines between them can
// comb. The vertical-median difference of each new line is limited by the same
// difference on neighbouring new lines (minmod), so only isolated combing is removed.

static inline float median3(float a, float b, float c) {
    return max(min(a, b), min(max(a, b), c));
}

static inline float minmod(float a, float b) {
    if (a * b <= 0.0f) return 0.0f;
    return fabs(a) < fabs(b) ? a : b;
}

/// Nearest new-line row (parity != kept parity) for a row that may be outside the plane.
static inline int newRow(int r, int height, uint keptParity) {
    int first = int(1 - keptParity);
    int last = ((height - 1) & 1) == int(keptParity) ? height - 2 : height - 1;
    return clamp(r, first, max(first, last));
}

kernel void qtgmcLosslessDiff(texture2d<float, access::read> woven [[texture(0)]],
                              texture2d<float, access::write> difference [[texture(1)]],
                              constant FinishParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= difference.get_width() || gid.y >= difference.get_height()) return;
    if ((gid.y & 1) == p.parity) {
        difference.write(float4(0.0f), gid);
        return;
    }
    int h = int(woven.get_height());
    int y = int(gid.y);
    int up = y > 0 ? y - 1 : min(1, h - 1);
    int down = y < h - 1 ? y + 1 : max(h - 2, 0);
    float centre = woven.read(gid).r;
    float median = median3(woven.read(uint2(gid.x, uint(up))).r, centre,
                           woven.read(uint2(gid.x, uint(down))).r);
    difference.write(float4(centre - median), gid);
}

kernel void qtgmcLosslessMinmod(texture2d<float, access::read> difference [[texture(0)]],
                                texture2d<float, access::write> limited [[texture(1)]],
                                constant FinishParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= limited.get_width() || gid.y >= limited.get_height()) return;
    if ((gid.y & 1) == p.parity) {
        limited.write(float4(0.0f), gid);
        return;
    }
    int h = int(difference.get_height());
    int y = int(gid.y);
    float d = difference.read(gid).r;
    float above = difference.read(uint2(gid.x, uint(newRow(y - 2, h, p.parity)))).r;
    float below = difference.read(uint2(gid.x, uint(newRow(y + 2, h, p.parity)))).r;
    limited.write(float4(minmod(minmod(above, d), minmod(d, below))), gid);
}

kernel void qtgmcLosslessApply(texture2d<float, access::read> woven [[texture(0)]],
                               texture2d<float, access::read> difference [[texture(1)]],
                               texture2d<float, access::read> limited [[texture(2)]],
                               texture2d<float, access::write> destination [[texture(3)]],
                               constant FinishParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    float value = woven.read(gid).r;
    if ((gid.y & 1) == p.parity) {
        destination.write(float4(value), gid);
        return;
    }
    int w = int(limited.get_width());
    int h = int(limited.get_height());
    int x = int(gid.x);
    int y = int(gid.y);
    float lo = FLT_MAX;
    float hi = -FLT_MAX;
    for (int dy = -2; dy <= 2; dy += 2) {
        int row = newRow(y + dy, h, p.parity);
        for (int dx = -1; dx <= 1; dx++) {
            float v = limited.read(uint2(uint(clamp(x + dx, 0, w - 1)), uint(row))).r;
            lo = min(lo, v);
            hi = max(hi, v);
        }
    }
    destination.write(float4(value - clamp(difference.read(gid).r, lo, hi)), gid);
}
